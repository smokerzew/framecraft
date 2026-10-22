import AVFoundation
import CoreImage
import ImageIO
import Observation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Controls in the ⠿ panel. Each one is only enabled when the camera really supports it.
enum CameraControl: String, CaseIterable, Identifiable {
    case flash, timer, aspect, exposure, grid, level, format, torch
    case scan, custom, manual, raw

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var group: PanelGroup {
        switch self {
        case .flash, .timer, .aspect, .exposure, .grid, .level, .format, .torch: .camera
        case .scan, .custom, .manual, .raw: .pro
        }
    }
}

enum PanelGroup: String, CaseIterable {
    case camera, pro
}

/// App state: the live camera with its settings, the photo library, and the photo open in the editor.
@MainActor
@Observable
final class AppModel {
    let camera = LiveCameraModel()
    let store: ProjectStore?

    // Shooting
    var mode: CameraMode = .photo
    private(set) var flash: FlashSetting = .off
    private(set) var timer: TimerSetting = .off
    private(set) var aspect: CaptureAspect = .threeFour
    private(set) var zoom: CGFloat = 1
    private(set) var countdown: Int?
    /// The look picked before shooting; previewed live and applied to the next photo.
    private(set) var look: FilmLook = .none
    private(set) var lookStrength: Double = 1
    private(set) var gridStyle: GridStyle
    private(set) var showLevel: Bool
    private(set) var captureHEIF: Bool

    // Focus box
    private(set) var focusPoint: CGPoint?
    private(set) var focusPulse = 0
    private(set) var isFocusDimmed = false
    private(set) var isAELocked = false
    @ObservationIgnored private var exposureDragStart: Float?
    var isDraggingExposure: Bool { exposureDragStart != nil }

    // Presentation
    var isControlPanelOpen = false
    var panelGroup: PanelGroup = .camera
    var isExposureDialVisible = false
    var showLookPicker = false
    var showManualControls = false
    var showLibrary = false
    var showPhotosPicker = false
    private(set) var isZoomDialVisible = false
    var alert: AppAlert?
    private(set) var toast: String?
    private(set) var flashPulse = 0

    // Library and editor
    private(set) var projects: [PhotoProject] = []
    private(set) var latestThumbnail: CGImage?
    private(set) var session: EditSession?
    private(set) var isSaving = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var focusTask: Task<Void, Never>?
    @ObservationIgnored private var dialHideTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(store: ProjectStore? = .standard, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        gridStyle = GridStyle(rawValue: defaults.string(forKey: SettingsKey.gridStyle) ?? "") ?? .thirds
        showLevel = defaults.bool(forKey: SettingsKey.showLevel)
        captureHEIF = defaults.object(forKey: SettingsKey.captureFormat) as? Bool ?? true
    }

    var isPopUpOpen: Bool { isControlPanelOpen || showLookPicker || showManualControls }

    func closePopUps() {
        isControlPanelOpen = false
        showLookPicker = false
        if showManualControls {
            showManualControls = false
            camera.watchReadings(false)
        }
    }

    // MARK: Lifecycle

    func startUp() {
        refreshProjects()
        Task { await startCamera() }
    }

    func startCamera() async {
        guard session == nil else { return }
        camera.captureAspect = aspect.ratio
        camera.look.setRecipe(liveEdit)
        await camera.start()
        if camera.isRunning { zoom = camera.setZoom(1) }
        modeChanged()
    }

    func sceneActive(_ active: Bool) {
        if active {
            if session == nil { Task { await startCamera() } }
        } else {
            camera.stop()
            session?.save()
        }
    }

    // MARK: Modes

    /// AUTO scans right away, CUSTOM enters frame drawing, PHOTO is a plain camera.
    func modeChanged() {
        switch mode {
        case .auto:
            camera.isComposing = false
            camera.dismissScan()
            camera.startCoaching()
        case .custom:
            camera.stopCoaching()
            camera.dismissScan()
            camera.isComposing = true
        case .photo:
            camera.stopCoaching()
            camera.dismissScan()
            camera.isComposing = false
        }
    }

    // MARK: Controls

    func isAvailable(_ control: CameraControl) -> Bool {
        let running = camera.isRunning
        switch control {
        case .flash: return running && camera.capabilities.hasFlash
        case .torch: return running && camera.capabilities.hasTorch
        case .manual: return running && camera.hasManualControls
        case .raw: return running && camera.supportsAnyRAW
        case .grid, .level, .format: return true
        default: return running
        }
    }

    func isActive(_ control: CameraControl) -> Bool {
        switch control {
        case .flash: flash != .off
        case .timer: timer != .off
        case .aspect: aspect != .threeFour
        case .exposure: isExposureDialVisible || camera.exposureBias != 0
        case .grid: gridStyle != .off
        case .level: showLevel
        case .format: false
        case .torch: camera.torch
        case .scan: camera.isCoaching || camera.scan != .idle
        case .custom: camera.isComposing || camera.frame != nil
        case .manual: showManualControls || !camera.manual.isAuto
        case .raw: camera.rawMode != .off
        }
    }

    func symbol(for control: CameraControl) -> String {
        switch control {
        case .flash: flash.systemImage
        case .timer: "timer"
        case .aspect: "aspectratio"
        case .exposure: "plusminus"
        case .grid: "squareshape.split.3x3"
        case .level: "level"
        case .format: "photo"
        case .torch: camera.torch ? "flashlight.on.fill" : "flashlight.off.fill"
        case .scan: "viewfinder"
        case .custom: "rectangle.dashed"
        case .manual: "dial.medium"
        case .raw: "r.square"
        }
    }

    /// Short text drawn instead of the icon.
    func valueText(for control: CameraControl) -> String? {
        switch control {
        case .timer: timer == .off ? nil : timer.label
        case .aspect: aspect.label
        case .format: captureHEIF && camera.capabilities.supportsHEIF ? "HEIF" : "JPEG"
        case .raw: camera.rawMode == .off ? nil : (camera.rawMode == .proRAW ? "PRO" : "RAW")
        default: nil
        }
    }

    func stateDescription(for control: CameraControl) -> String {
        switch control {
        case .flash: flash.label
        case .timer: timer.label
        case .aspect: aspect.label
        case .exposure: String(format: "%+.1f EV", camera.exposureBias)
        case .grid: gridStyle.label
        case .level, .torch: isActive(control) ? "On" : "Off"
        case .format: valueText(for: .format) ?? ""
        case .scan: camera.isCoaching ? (camera.coachAdvice?.isAligned == true ? "Framed" : "Guiding") : "Off"
        case .custom: camera.frame == nil ? "No frame" : (camera.alignment?.isAligned == true ? "Aligned" : "Frame set")
        case .manual: camera.manual.isAuto ? "Auto" : "Manual"
        case .raw: camera.rawMode.label
        }
    }

    func hint(for control: CameraControl) -> String {
        switch control {
        case .flash: "Flash for the photo: off, auto or on"
        case .timer: "Waits 3 or 10 seconds before taking the photo"
        case .aspect: "3:4, 4:5, 9:16 or 1:1; the photo is cropped to it (you can change it later in Crop)"
        case .exposure: "Exposure compensation"
        case .grid: "Off, rule of thirds or a fine grid"
        case .level: "Shows a level that follows your phone's tilt"
        case .format: "HEIF (smaller, 10-bit) or JPEG for new photos"
        case .torch: "Keeps the flashlight on while you frame"
        case .scan: "AUTO FRAME: live guidance to a well-framed shot (move, tilt, zoom), with measured exposure and level notes"
        case .custom: "Draw your own frame and tap a subject to see when it lines up"
        case .manual: "ISO, shutter speed, focus and white balance, where this camera supports them"
        case .raw: "Also captures a RAW or Apple ProRAW original, where this iPhone supports it"
        }
    }

    func perform(_ control: CameraControl) {
        switch control {
        case .flash: flash = flash.next
        case .timer: timer = timer.next
        case .aspect:
            aspect = aspect.next
            camera.captureAspect = aspect.ratio
            camera.composeAspect = camera.composeAspect == nil ? nil : aspect
        case .exposure: isExposureDialVisible.toggle()
        case .grid:
            gridStyle = gridStyle.next
            defaults.set(gridStyle.rawValue, forKey: SettingsKey.gridStyle)
        case .level:
            showLevel.toggle()
            defaults.set(showLevel, forKey: SettingsKey.showLevel)
        case .format:
            captureHEIF.toggle()
            defaults.set(captureHEIF, forKey: SettingsKey.captureFormat)
        case .torch: camera.setTorch(!camera.torch)
        case .scan:
            isControlPanelOpen = false
            mode = mode == .auto ? .photo : .auto
            modeChanged()
        case .custom:
            isControlPanelOpen = false
            mode = .custom
            modeChanged()
        case .manual:
            isControlPanelOpen = false
            showManualControls = true
            camera.watchReadings(true)
        case .raw: camera.cycleRaw()
        }
    }

    func setZoom(_ value: CGFloat) {
        zoom = camera.setZoom(ZoomLimits.clamp(value))
    }

    /// The coach's "SET ZOOM": zooms smoothly to the suggested framing.
    func applyCoachZoom() {
        guard let target = camera.coachAdvice?.zoomTo else { return }
        withAnimation(.spring(duration: 0.35)) { zoom = camera.setZoom(target, animated: true) }
    }

    var zoomPresets: [CGFloat] { camera.isRunning ? camera.capabilities.zoomPresets : [1] }

    func showZoomDial() {
        isZoomDialVisible = true
        dialHideTask?.cancel()
        dialHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.isZoomDialVisible = false
        }
    }

    var exposureRange: ClosedRange<Double> {
        let low = max(-4, Double(camera.capabilities.minExposureBias)), high = min(4, Double(camera.capabilities.maxExposureBias))
        return low < high ? low...high : -2...2
    }

    // MARK: Look before shooting

    var liveEdit: EditState {
        var e = EditState()
        e.look = look
        e.lookStrength = lookStrength
        return e
    }

    func setLook(_ value: FilmLook) {
        look = value
        camera.look.setRecipe(liveEdit)
    }

    func setLookStrength(_ value: Double) {
        lookStrength = min(max(value, 0), 1)
        camera.look.setRecipe(liveEdit)
    }

    // MARK: Focus

    func focus(atView point: CGPoint, lock: Bool) {
        focusPoint = point
        focusPulse += 1
        isFocusDimmed = false
        isAELocked = lock
        camera.focus(atLayerPoint: point, lock: lock)
        scheduleFocusDim()
    }

    func beginExposureDrag() {
        focusTask?.cancel()
        isFocusDimmed = false
        exposureDragStart = camera.exposureBias
    }

    func updateExposureDrag(by translation: CGFloat) {
        guard let start = exposureDragStart else { return }
        camera.setExposureBias(start - Float(translation) / 120)
    }

    func endExposureDrag() {
        exposureDragStart = nil
        scheduleFocusDim()
    }

    private func scheduleFocusDim() {
        focusTask?.cancel()
        guard !isAELocked else { return }
        focusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.isFocusDimmed = true
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.focusPoint = nil
        }
    }

    // MARK: Capture

    func shutterPressed() {
        guard camera.isRunning, !camera.isCapturing, !isSaving else { return }
        guard countdown == nil else { cancelCountdown(); return }
        guard timer != .off else { capture(); return }
        let seconds = timer.rawValue
        countdownTask = Task { [weak self] in
            for remaining in stride(from: seconds, to: 0, by: -1) {
                self?.countdown = remaining
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            self?.countdown = nil
            self?.capture()
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    /// The crop the next photo gets: an applied suggestion or custom frame, else what the aspect shows.
    var captureCrop: CGRect {
        if let frame = camera.frame { return frame }
        return AspectFillMapping.visibleRect(imageAspect: camera.imageAspect, viewSize: CGSize(width: aspect.ratio, height: 1))
    }

    private func capture() {
        var edit = liveEdit
        let crop = captureCrop
        edit.cropRect = crop.width > 0.995 && crop.height > 0.995 ? EditState.fullCrop : crop
        let heif = captureHEIF
        let flash = self.flash
        Task { [weak self, edit] in
            guard let self else { return }
            do {
                let shot = try await self.camera.capture(flash: flash, heif: heif)
                self.flashPulse += 1
                await self.saveCapture(shot, edit: edit)
            } catch {
                self.alert = AppAlert(title: "Couldn't Take Photo", message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// Stores the capture as a new project (the RAW is the original when there is one) and opens it for review.
    private func saveCapture(_ shot: CapturedPhoto, edit: EditState) async {
        guard let store else { return }
        isSaving = true
        defer { isSaving = false }
        let isRAW = shot.rawData != nil
        let source: PhotoProject.Source = !isRAW ? .camera : (shot.rawKind == .proRAW ? .cameraProRAW : .cameraRAW)
        do {
            let project = try await Task.detached(priority: .userInitiated) {
                try store.create(original: shot.rawData ?? shot.processedData,
                                 typeIdentifier: isRAW ? "com.adobe.raw-image" : shot.processedType,
                                 source: source, companion: isRAW ? shot.processedData : nil, edit: edit)
            }.value
            await open(project)
        } catch {
            alert = AppAlert(title: "Couldn't Save Photo", message: (error as? LocalizedError)?.errorDescription ?? "")
        }
    }

    // MARK: Library and editor

    func refreshProjects() {
        guard let store else { return }
        projects = store.list()
        latestThumbnail = projects.first.flatMap { Self.loadThumbnail(store.thumbnailURL($0.id)) }
    }

    nonisolated static func loadThumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func open(_ project: PhotoProject) async {
        guard let store else { return }
        guard let data = try? Data(contentsOf: store.originalURL(project)) else {
            alert = AppAlert(title: "Original Missing", message: ProjectError.missingOriginal.errorDescription ?? "")
            return
        }
        showLibrary = false
        closePopUps()
        let session = EditSession(project: project, original: data, store: store)
        session.onSaved = { [weak self] in self?.refreshProjects() }
        self.session = session
        camera.stop()
        await session.load()
        session.save() // writes the first thumbnail
    }

    /// Back to the camera from the editor (the edit is already saved as you go; this saves once more).
    func closeEditor() {
        session?.save()
        session = nil
        refreshProjects()
        Task { await startCamera() }
    }

    /// Imports photos from Photos as new projects (originals copied byte for byte), then opens the first.
    func importPhotos(_ items: [PhotosPickerItem]) {
        guard let store, !items.isEmpty else { return }
        Task { [weak self] in
            var first: PhotoProject?
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) })?.identifier
                if let project = try? store.create(original: data, typeIdentifier: type, source: .imported, edit: EditState()) {
                    if first == nil { first = project }
                    if let preview = EditSession.makePreview(data, maxPixel: 480) { store.writeThumbnail(preview, for: project.id) }
                }
            }
            guard let self else { return }
            self.refreshProjects()
            if let first { await self.open(first) } else { self.alert = AppAlert(title: "Couldn't Import", message: "Those photos couldn't be read.") }
        }
    }

    func duplicate(_ project: PhotoProject) {
        guard let store else { return }
        do {
            _ = try store.duplicate(project)
            refreshProjects()
            showToast("Duplicated")
        } catch {
            alert = AppAlert(title: "Couldn't Duplicate", message: (error as? LocalizedError)?.errorDescription ?? "")
        }
    }

    /// Removes FrameCraft's copy and its edits (never anything in the Photos app).
    func delete(_ project: PhotoProject) {
        guard let store else { return }
        if session?.project.id == project.id { session = nil; Task { await startCamera() } }
        store.delete(project.id)
        refreshProjects()
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
