import SwiftUI

/// The ⠿ controls card: grabber, CAMERA / PRO tabs and a 3-column grid of controls (same look as Camera Glass Pro).
struct ControlPanel: View {
    @Bindable var app: AppModel
    @Environment(\.cameraReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat = 0

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(.white.opacity(0.35)).frame(width: 36, height: 5).padding(.top, 8).padding(.bottom, 10)
                .accessibilityHidden(true)

            GlassTabs(tabs: PanelGroup.allCases, selection: $app.panelGroup) { $0.rawValue.capitalized }
                .padding(.bottom, 14)

            VStack(spacing: 18) {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(CameraControl.allCases.filter { $0.group == app.panelGroup }) { control in
                        let available = app.isAvailable(control)
                        PanelControlButton(systemImage: app.symbol(for: control), title: control.title,
                                           value: app.valueText(for: control), isActive: app.isActive(control),
                                           stateDescription: available ? app.stateDescription(for: control) : "Not available on this camera",
                                           hint: app.hint(for: control)) {
                            withAnimation(reduceMotion ? nil : .spring(duration: 0.3)) { app.perform(control) }
                        }
                        .disabled(!available)
                        .opacity(available ? 1 : 0.45)
                    }
                }

                if app.isExposureDialVisible {
                    HStack(spacing: 10) {
                        Image(systemName: "plusminus").foregroundStyle(.white.opacity(0.8)).accessibilityHidden(true)
                        Slider(value: Binding(get: { Double(app.camera.exposureBias) }, set: { app.camera.setExposureBias(Float($0)) }),
                               in: app.exposureRange, step: 0.1)
                            .tint(.yellow)
                            .accessibilityLabel("Exposure")
                        Text(String(format: "%+.1f", app.camera.exposureBias))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.yellow)
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                    .padding(.horizontal, 6)
                    .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 22)
        .frame(maxWidth: 520)
        .cameraGlass(.regular, in: RoundedRectangle(cornerRadius: 38, style: .continuous))
        .offset(y: max(0, dragOffset))
        .simultaneousGesture(
            DragGesture()
                .onChanged { if $0.startLocation.y < 44 { dragOffset = $0.translation.height } }
                .onEnded { value in
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.35)) {
                        if value.startLocation.y < 44, value.translation.height > 80 { app.isControlPanelOpen = false }
                        dragOffset = 0
                    }
                }
        )
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("More controls")
        .accessibilityAction(.escape) { app.isControlPanelOpen = false }
    }
}

/// Film looks before shooting: live preview tiles from the current frame, and strength.
struct LookPicker: View {
    @Bindable var app: AppModel
    @Environment(\.cameraReduceMotion) private var reduceMotion
    @State private var tiles: [FilmLook: CGImage] = [:]

    var body: some View {
        VStack(spacing: 14) {
            Capsule().fill(.white.opacity(0.35)).frame(width: 36, height: 5).padding(.top, 8).accessibilityHidden(true)
            HStack {
                Text("LOOKS").font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.white.opacity(0.9))
                Spacer()
                Button("Done") { withAnimation(reduceMotion ? nil : .spring(duration: 0.35)) { app.showLookPicker = false } }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.yellow)
            }
            .padding(.horizontal, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(FilmLook.allCases) { look in
                        LookTile(look: look, image: tiles[look], isSelected: app.look == look) { app.setLook(look) }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }

            Text(app.look.summary.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.7))

            HStack(spacing: 10) {
                Text("STRENGTH").font(.caption2.weight(.semibold)).tracking(1).foregroundStyle(.white.opacity(0.85))
                Slider(value: Binding(get: { app.lookStrength }, set: { app.setLookStrength($0) }), in: 0...1)
                    .tint(.yellow)
                    .accessibilityLabel("Look strength")
                Text("\(Int((app.lookStrength * 100).rounded()))")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.yellow)
                    .frame(width: 32, alignment: .trailing)
            }
            .padding(.horizontal, 6)
            .opacity(app.look == .none ? 0.4 : 1)
            .disabled(app.look == .none)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 18)
        .frame(maxWidth: 520)
        .cameraGlass(.regular, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        .padding(.horizontal, 12)
        .task { await renderTiles() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Looks")
    }

    /// Every look rendered on a small copy of the current camera frame (or a gray card without one).
    private func renderTiles() async {
        let source = app.camera.frames.latestImage(maxSide: 200)
        tiles = await Task.detached(priority: .userInitiated) { () -> [FilmLook: CGImage] in
            let renderer = PhotoRenderer.shared
            let base = source.map { CIImage(cgImage: $0) }
                ?? CIImage(color: CIColor(red: 0.5, green: 0.48, blue: 0.45)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 160))
            var result: [FilmLook: CGImage] = [:]
            for look in FilmLook.allCases {
                var edit = EditState()
                edit.look = look
                let output = renderer.render(edit, to: base)
                if let image = renderer.context.createCGImage(output, from: base.extent) { result[look] = image }
            }
            return result
        }.value
    }
}

/// A look's preview tile and name; yellow outline when chosen.
struct LookTile: View {
    let look: FilmLook
    let image: CGImage?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.08)
                        ProgressView().controlSize(.small).tint(.white)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isSelected ? Color.yellow : .white.opacity(0.18), lineWidth: isSelected ? 2 : 0.8)
                }
                Text(look.label.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.9)
                    .foregroundStyle(isSelected ? Color.yellow : .white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: 74)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("\(look.label), \(look.summary)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
