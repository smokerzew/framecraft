import CoreImage
import Foundation
import ImageIO
import Observation

/// One photo open in the editor: its original (read once), a screen-sized preview, the edit with undo/redo,
/// and a render loop that always ends on the newest edit. Saving writes only the edit, never the original.
@MainActor
@Observable
final class EditSession {
    private(set) var project: PhotoProject
    private(set) var edit: EditState
    private(set) var preview: CGImage?
    private(set) var rendered: CGImage?
    var showOriginal = false
    private(set) var canUndo = false
    private(set) var canRedo = false
    let original: Data

    @ObservationIgnored private var undoStack: [EditState] = []
    @ObservationIgnored private var redoStack: [EditState] = []
    @ObservationIgnored private var lastUndoPoint = Date.distantPast
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var renderNeeded = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let store: ProjectStore?
    @ObservationIgnored private let renderer: PhotoRenderer
    @ObservationIgnored var onSaved: (@MainActor () -> Void)?

    init(project: PhotoProject, original: Data, store: ProjectStore?, renderer: PhotoRenderer = .shared) {
        self.project = project
        self.edit = project.edit
        self.original = original
        self.store = store
        self.renderer = renderer
    }

    /// Decodes a screen-sized, upright preview (works for HEIF, JPEG, PNG and DNG).
    func load(maxPixel: Int = 2400) async {
        let data = original
        preview = await Task.detached(priority: .userInitiated) { Self.makePreview(data, maxPixel: maxPixel) }.value
        scheduleRender()
    }

    nonisolated static func makePreview(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// What the editor shows: the original while "before" is held, else the newest render.
    var displayed: CGImage? {
        if showOriginal || edit.isIdentity { return preview }
        return rendered ?? preview
    }

    // MARK: Editing

    /// Applies a change. A burst of changes (one slider drag) is one undo step.
    func update(_ change: (inout EditState) -> Void) {
        var next = edit
        change(&next)
        guard next != edit else { return }
        if Date().timeIntervalSince(lastUndoPoint) > 0.6 {
            undoStack.append(edit)
            if undoStack.count > 60 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        lastUndoPoint = Date()
        edit = next
        changed()
    }

    /// A deliberate step (preset, reset): always its own undo point.
    func replace(with next: EditState) {
        guard next != edit else { return }
        undoStack.append(edit)
        redoStack.removeAll()
        lastUndoPoint = .distantPast
        edit = next
        changed()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(edit)
        edit = previous
        lastUndoPoint = .distantPast
        changed()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(edit)
        edit = next
        lastUndoPoint = .distantPast
        changed()
    }

    func reset(_ group: EditGroup) { replace(with: edit.resetting(group)) }

    func resetAll() { replace(with: EditState()) }

    private func changed() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        scheduleRender()
        scheduleSave()
    }

    // MARK: Rendering

    /// One render at a time; edits made meanwhile fold into one follow-up render of the newest edit.
    private func scheduleRender() {
        guard preview != nil else { return }
        renderNeeded = true
        guard renderTask == nil else { return }
        renderTask = Task { [weak self] in
            while let self, self.renderNeeded {
                self.renderNeeded = false
                guard let source = self.preview else { break }
                let edit = self.edit
                let renderer = self.renderer
                let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                    let output = renderer.render(edit, to: CIImage(cgImage: source))
                    return renderer.context.createCGImage(output, from: output.extent)
                }.value
                if edit == self.edit { self.rendered = image }
            }
            self?.renderTask = nil
        }
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Writes the edit (and the finish) into the project and refreshes its thumbnail.
    func save() {
        saveTask?.cancel()
        guard let store else { return }
        project.edit = edit
        try? store.save(project)
        let id = project.id
        if let image = displayed {
            Task.detached(priority: .utility) { [weak self] in
                let full = CIImage(cgImage: image)
                let scale = min(1, 480 / max(full.extent.width, full.extent.height, 1))
                let small = full.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                if let thumb = PhotoRenderer.shared.context.createCGImage(small, from: small.extent) {
                    store.writeThumbnail(thumb, for: id)
                }
                await MainActor.run { self?.onSaved?() }
            }
        }
    }

    func setFinish(_ finish: FinishSettings) {
        guard finish != project.finish else { return }
        project.finish = finish
        scheduleSave()
    }

    var metadata: CaptureMetadata { CaptureMetadata(data: original) }
}
