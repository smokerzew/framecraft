import SwiftUI

/// Full-screen editor for one photo. Everything is non-destructive: the original stays as captured, the edit is
/// data, and it saves as you go. Hold the photo to see the original.
struct EditorView: View {
    @Bindable var app: AppModel
    @Bindable var session: EditSession
    @Environment(\.cameraReduceMotion) private var reduceMotion
    @State private var group: EditGroup = .look
    @State private var showExport = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            photo
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 12) {
                GlassTabs(tabs: EditGroup.allCases, selection: $group) { $0.title }
                ScrollView(showsIndicators: false) {
                    content
                        .padding(.horizontal, 6)
                        .padding(.bottom, 8)
                }
                .frame(height: 290)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .cameraGlass(.regular, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $showExport) { ExportSheet(app: app, session: session) }
        .appAlert(app)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { app.closeEditor() } label: {
                Label("Camera", systemImage: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
                    .cameraGlass(.interactive, in: Capsule())
            }
            .accessibilityHint("Saves the edit and goes back to the camera")
            Spacer()
            iconButton("arrow.uturn.backward", label: "Undo", enabled: session.canUndo) { session.undo() }
            iconButton("arrow.uturn.forward", label: "Redo", enabled: session.canRedo) { session.redo() }
            Button { showExport = true } label: {
                Text("Export")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
                    .cameraGlass(.selected, in: Capsule())
            }
        }
        .buttonStyle(PressableButtonStyle())
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func iconButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .cameraGlass(.interactive, in: Circle())
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }

    private var photo: some View {
        ZStack(alignment: .top) {
            if let image = session.displayed {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(.horizontal, 8)
                    .accessibilityLabel(session.showOriginal ? "Original photo" : "Edited photo")
            } else {
                ProgressView().tint(.white)
            }
            if session.showOriginal {
                CameraTag(text: "ORIGINAL", isOff: true).padding(.top, 8)
            }
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0, maximumDistance: 60, perform: {}, onPressingChanged: { session.showOriginal = $0 })
        .accessibilityAction(named: "Show original") { session.showOriginal.toggle() }
        .accessibilityHint("Touch and hold to compare with the original")
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 14) {
            HStack {
                Spacer()
                Button("Reset \(group.title.capitalized)") { session.reset(group) }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(session.edit.resetting(group) != session.edit ? Color.yellow : .white.opacity(0.4))
                    .disabled(session.edit.resetting(group) == session.edit)
            }
            switch group {
            case .look: LookSection(session: session)
            case .light: sliders(.light)
            case .color:
                sliders(.color)
                MixerSection(session: session)
                GradeSection(session: session)
                CurvesSection(session: session)
                CalibrationSection(session: session)
            case .effects:
                sliders(.effects)
                if session.edit.motionBlur > 0 {
                    SliderRow(title: "Blur Angle", value: session.edit.motionAngle, range: -90...90,
                              display: { "\(Int($0))°" }) { v in session.update { $0.motionAngle = v } }
                }
            case .crop: CropSection(session: session)
            }
        }
    }

    private func sliders(_ group: EditGroup) -> some View {
        VStack(spacing: 12) {
            ForEach(EditParameter.allCases.filter { $0.group == group }) { p in
                SliderRow(title: p.title, value: session.edit[p], range: p.range, display: p.format) { v in
                    session.update { $0[p] = v }
                }
            }
        }
    }
}

/// A labeled slider in the pop-ups' style (caption, yellow slider, value). Double-tap the title to reset.
struct SliderRow: View {
    let title: String
    let value: Double
    var range: ClosedRange<Double> = 0...1
    var display: (Double) -> String = { "\(Int(($0 * 100).rounded()))" }
    let onChange: (Double) -> Void

    private var neutral: Double { range.lowerBound < 0 ? 0 : range.lowerBound }

    var body: some View {
        HStack(spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 92, alignment: .leading)
                .onTapGesture(count: 2) { onChange(neutral) }
            Slider(value: Binding(get: { value }, set: onChange), in: range)
                .tint(.yellow)
                .accessibilityLabel(title)
                .accessibilityValue(display(value))
            Text(display(value))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(value == neutral ? Color.white.opacity(0.6) : Color.yellow)
                .frame(width: 58, alignment: .trailing)
        }
    }
}

/// Looks rendered on the photo itself, plus strength.
private struct LookSection: View {
    @Bindable var session: EditSession
    @State private var tiles: [FilmLook: CGImage] = [:]

    var body: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(FilmLook.allCases) { look in
                        LookTile(look: look, image: tiles[look], isSelected: session.edit.look == look) {
                            var next = session.edit
                            next.look = look
                            session.replace(with: next)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            Text(session.edit.look.summary.uppercased())
                .font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(.white.opacity(0.7))
            SliderRow(title: "Strength", value: session.edit.lookStrength) { v in session.update { $0.lookStrength = v } }
                .opacity(session.edit.look == .none ? 0.4 : 1)
                .disabled(session.edit.look == .none)
        }
        .task(id: session.preview == nil) { await render() }
    }

    private func render() async {
        guard let preview = session.preview else { return }
        tiles = await Task.detached(priority: .userInitiated) { () -> [FilmLook: CGImage] in
            let renderer = PhotoRenderer.shared
            let full = CIImage(cgImage: preview)
            let scale = 160 / max(full.extent.width, full.extent.height, 1)
            let small = full.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            var result: [FilmLook: CGImage] = [:]
            for look in FilmLook.allCases {
                var edit = EditState()
                edit.look = look
                let output = renderer.render(edit, to: small)
                if let image = renderer.context.createCGImage(output, from: small.extent) { result[look] = image }
            }
            return result
        }.value
    }
}

/// HSL: pick one of eight colors, then shift its hue, saturation and luminance.
private struct MixerSection: View {
    @Bindable var session: EditSession
    @State private var band: ColorBand = .red

    private func swatch(_ band: ColorBand) -> Color { Color(hue: band.hue / 360, saturation: 0.85, brightness: 0.95) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("HSL")
            HStack(spacing: 0) {
                ForEach(ColorBand.allCases) { item in
                    Button { band = item } label: {
                        Circle().fill(swatch(item)).frame(width: 24, height: 24)
                            .overlay(Circle().stroke(Color.white, lineWidth: band == item ? 2.5 : 0).padding(-4))
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.label)
                    .accessibilityAddTraits(band == item ? .isSelected : [])
                }
            }
            ForEach(MixerChannel.allCases) { channel in
                SliderRow(title: channel.label, value: session.edit.mixer[band, channel], range: -1...1,
                          display: { $0 == 0 ? "0" : String(format: "%+d", Int(($0 * 100).rounded())) }) { v in
                    session.update { $0.mixer[band, channel] = v }
                }
            }
        }
    }
}

/// Color grading: a hue and amount for shadows and for highlights.
private struct GradeSection: View {
    @Bindable var session: EditSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Color Grading")
            SliderRow(title: "Shadow Hue", value: session.edit.gradeShadowHue, range: 0...360, display: { "\(Int($0))°" }) { v in
                session.update { $0.gradeShadowHue = v }
            }
            SliderRow(title: "Shadows", value: session.edit.gradeShadowAmount) { v in session.update { $0.gradeShadowAmount = v } }
            SliderRow(title: "Highlight Hue", value: session.edit.gradeHighlightHue, range: 0...360, display: { "\(Int($0))°" }) { v in
                session.update { $0.gradeHighlightHue = v }
            }
            SliderRow(title: "Highlights", value: session.edit.gradeHighlightAmount) { v in session.update { $0.gradeHighlightAmount = v } }
        }
    }
}

/// Crop: ratio presets (centered), quarter turns and straighten.
private struct CropSection: View {
    @Bindable var session: EditSession

    private let ratios: [(String, CGFloat?)] = [("ORIGINAL", nil), ("3:4", 3.0 / 4), ("4:5", 4.0 / 5), ("1:1", 1), ("9:16", 9.0 / 16),
                                                 ("4:3", 4.0 / 3), ("16:9", 16.0 / 9)]

    var body: some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ratios.indices, id: \.self) { index in
                        let item = ratios[index]
                        Button(item.0) {
                            var next = session.edit
                            next.cropRect = item.1.map { CropMath.centered(ratio: $0, imageSize: rotatedSize) } ?? EditState.fullCrop
                            session.replace(with: next)
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 30)
                        .cameraGlass(.interactive, in: Capsule())
                    }
                }
            }
            HStack(spacing: 10) {
                Button {
                    var next = session.edit
                    next.rotation = (next.rotation + 1) % 4
                    next.cropRect = EditState.fullCrop
                    session.replace(with: next)
                } label: {
                    Label("Rotate", systemImage: "rotate.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 32)
                        .cameraGlass(.interactive, in: Capsule())
                }
                Spacer()
            }
            SliderRow(title: "Straighten", value: session.edit.straighten, range: -45...45,
                      display: { String(format: "%.1f°", $0) }) { v in session.update { $0.straighten = v } }
            SliderRow(title: "Move ↔", value: Double(session.edit.cropRect.midX), range: 0...1,
                      display: { String(format: "%.0f%%", $0 * 100) }) { v in move(x: v) }
                .disabled(session.edit.cropRect.width > 0.999)
            SliderRow(title: "Move ↕", value: Double(session.edit.cropRect.midY), range: 0...1,
                      display: { String(format: "%.0f%%", $0 * 100) }) { v in move(y: v) }
                .disabled(session.edit.cropRect.height > 0.999)
        }
    }

    /// The photo's size after its quarter turns (ratios are measured in pixels).
    private var rotatedSize: CGSize {
        guard let p = session.preview else { return CGSize(width: 3, height: 4) }
        return session.edit.rotation % 2 == 0 ? CGSize(width: p.width, height: p.height) : CGSize(width: p.height, height: p.width)
    }

    private func move(x: Double? = nil, y: Double? = nil) {
        session.update { edit in
            var r = edit.cropRect
            if let x { r.origin.x = min(max(CGFloat(x) - r.width / 2, 0), 1 - r.width) }
            if let y { r.origin.y = min(max(CGFloat(y) - r.height / 2, 0), 1 - r.height) }
            edit.cropRect = r
        }
    }
}

enum CropMath {
    /// Largest centered normalized crop with `ratio` (pixel width / height) inside an image of `imageSize`.
    static func centered(ratio: CGFloat, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, ratio > 0 else { return EditState.fullCrop }
        let imageRatio = imageSize.width / imageSize.height
        let w = ratio < imageRatio ? ratio / imageRatio : 1
        let h = ratio < imageRatio ? 1 : imageRatio / ratio
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }
}

func sectionTitle(_ text: String) -> some View {
    Text(text.uppercased())
        .font(.caption.weight(.semibold))
        .tracking(1.1)
        .foregroundStyle(.white.opacity(0.9))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
}

extension View {
    func appAlert(_ app: AppModel) -> some View {
        alert(app.alert?.title ?? "", isPresented: Binding(get: { app.alert != nil }, set: { if !$0 { app.alert = nil } }),
              presenting: app.alert) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
    }
}
