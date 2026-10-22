import SwiftUI
import UIKit

/// Export: format, finish (frame and date stamp) with a preview, location removal, then Save to Photos or Share.
/// The full-resolution render comes from the original; nothing is reported as saved until it really is.
struct ExportSheet: View {
    @Bindable var app: AppModel
    @Bindable var session: EditSession
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.exportFormat) private var format = ExportFormat.jpeg
    @AppStorage(SettingsKey.removeLocation) private var removeLocation = false
    @State private var preview: CGImage?
    @State private var isWorking = false
    @State private var shareURL: URL?

    private var options: ExportOptions {
        ExportOptions(format: format, finish: session.project.finish, removeLocation: removeLocation)
    }

    var body: some View {
        let metadata = session.metadata
        NavigationStack {
            Form {
                Section {
                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Remove Location", isOn: $removeLocation)
                } footer: {
                    Text("Full resolution from the original. Capture details (camera, exposure, date) are kept\(removeLocation ? "; GPS location is removed" : "").")
                }

                Section {
                    Picker("Frame", selection: Binding(get: { session.project.finish.frame },
                                                       set: { var f = session.project.finish; f.frame = $0; session.setFinish(f) })) {
                        ForEach(FrameStyle.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Date Stamp", isOn: Binding(get: { session.project.finish.dateStamp },
                                                       set: { var f = session.project.finish; f.dateStamp = $0; session.setFinish(f) }))
                        .disabled(metadata.date == nil)
                    if let preview {
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 280)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Preview of the finished photo")
                    }
                } header: {
                    Text("Finish")
                } footer: {
                    Text(footer(metadata))
                }

                Section {
                    Button {
                        run { url in
                            try await ExportService.saveToPhotos(url)
                            app.showToast("Saved to Photos")
                            dismiss()
                        }
                    } label: {
                        Label("Save to Photos", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        run { url in shareURL = url }
                    } label: {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(isWorking)
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                if isWorking { ToolbarItem(placement: .primaryAction) { ProgressView() } }
            }
            .task(id: session.project.finish) { await renderPreview(metadata) }
            .sheet(item: $shareURL) { url in ActivityView(items: [url]) }
            .appAlert(app)
        }
    }

    private func footer(_ m: CaptureMetadata) -> String {
        var lines = ["Frames and stamps are added to the exported copy only; the original and your edit don't change."]
        if m.date == nil { lines.append("This photo has no capture date, so it can't be stamped.") }
        if session.project.finish.frame == .specs, m.isEmpty { lines.append("No camera details were recorded; the Specs frame says so instead of guessing.") }
        return lines.joined(separator: " ")
    }

    private func run(_ then: @escaping (URL) async throws -> Void) {
        isWorking = true
        let original = session.original
        let edit = session.edit
        let options = self.options
        Task {
            defer { isWorking = false }
            do {
                let url = try await ExportService().export(original: original, edit: edit, options: options)
                try await then(url)
            } catch {
                app.alert = AppAlert(title: "Export Failed", message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func renderPreview(_ metadata: CaptureMetadata) async {
        guard let source = session.displayed else { preview = nil; return }
        let finish = session.project.finish
        preview = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let full = CIImage(cgImage: source)
            let scale = min(1, 900 / max(full.extent.width, full.extent.height, 1))
            let small = full.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let image = PhotoRenderer.shared.context.createCGImage(small, from: small.extent) else { return nil }
            return finish.isEmpty ? image : FinishingRenderer.render(image, settings: finish, metadata: metadata)
        }.value
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// The native share sheet.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
