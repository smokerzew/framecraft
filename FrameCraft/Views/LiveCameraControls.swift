import SwiftUI

/// Shown above the zoom row while shooting: the scan result, the custom-frame bar, or alignment feedback.
struct LiveCompositionArea: View {
    @Bindable var app: AppModel
    @Environment(\.cameraReduceMotion) private var reduceMotion

    private var camera: LiveCameraModel { app.camera }

    var body: some View {
        Group {
            if camera.scan == .scanning {
                CameraTag(text: "ANALYZING SCENE…", isOff: true)
            } else if let result = camera.scanResult {
                CompositionCard(app: app, result: result)
            } else if camera.isComposing {
                ComposeBar(app: app)
            } else if camera.frame != nil {
                frameStatus
            }
        }
        .padding(.horizontal, 14)
        .animation(reduceMotion ? nil : .spring(duration: 0.35), value: camera.scan)
        .animation(reduceMotion ? nil : .spring(duration: 0.35), value: camera.isComposing)
    }

    private var frameStatus: some View {
        HStack(spacing: 8) {
            if camera.subjectLost {
                CameraTag(text: "SUBJECT LOST · TAP IT IN CUSTOM", isOff: true)
            } else if let alignment = camera.alignment {
                CameraTag(text: alignment.isAligned ? "ALIGNED" : alignment.hint.uppercased(), isOff: !alignment.isAligned)
            } else {
                CameraTag(text: "FRAME SET", isOff: true)
            }
            Button {
                withAnimation(reduceMotion ? nil : .spring(duration: 0.3)) { camera.clearFrame() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .cameraGlass(.interactive, in: Circle())
            }
            .accessibilityLabel("Remove frame")
        }
    }
}

/// The scan's measured findings and suggestions, with Apply, Alternative, Rescan and close.
private struct CompositionCard: View {
    @Bindable var app: AppModel
    let result: CompositionResult

    private var camera: LiveCameraModel { app.camera }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(result.isConclusive ? "SUGGESTED FRAME" : "NO CLEAR SUGGESTION")
                    .font(.caption.weight(.semibold))
                    .tracking(1.1)
                    .foregroundStyle(result.isConclusive ? Color.yellow : .white.opacity(0.9))
                Spacer()
                Button { camera.dismissScan() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("Dismiss suggestion")
            }
            ForEach(result.guidance.prefix(4)) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.kind == .measured ? "ruler" : "lightbulb")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(item.kind == .measured ? Color.white.opacity(0.8) : Color.yellow.opacity(0.9))
                        .frame(width: 14)
                        .accessibilityLabel(item.kind == .measured ? "Measured" : "Suggestion")
                    Text(item.text)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(item.kind == .measured ? 0.95 : 0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                if result.primary != nil {
                    pill("APPLY", highlighted: true) { camera.acceptSuggestion() }
                }
                if result.alternative != nil {
                    pill(camera.showsAlternative ? "FIRST" : "ALTERNATIVE") { camera.toggleAlternative() }
                }
                pill("RESCAN") { camera.startScan() }
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: 380, alignment: .leading)
        .cameraGlass(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func pill(_ title: String, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(highlighted ? Color.yellow : .white)
                .padding(.horizontal, 12)
                .frame(minHeight: 30)
                .cameraGlass(highlighted ? .selected : .interactive, in: Capsule())
        }
        .buttonStyle(PressableButtonStyle())
    }
}

/// Custom frame editing: ratio choice, reset and done.
private struct ComposeBar: View {
    @Bindable var app: AppModel

    private var camera: LiveCameraModel { app.camera }
    private let ratios: [CaptureAspect?] = [nil, .threeFour, .fourFive, .square, .nineSixteen]

    var body: some View {
        VStack(spacing: 8) {
            Text(camera.frame == nil ? "DRAG TO DRAW A FRAME · TAP A SUBJECT TO TRACK" : "DRAG TO MOVE · CORNERS RESIZE · TAP A SUBJECT")
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.black)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            HStack(spacing: 6) {
                ForEach(ratios, id: \.self) { ratio in
                    let selected = camera.composeAspect == ratio
                    Button {
                        camera.composeAspect = ratio
                        if let frame = camera.frame { camera.setCustomFrame(frame) }
                    } label: {
                        Text(ratio?.label ?? "FREE")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(selected ? Color.yellow : .white)
                            .frame(minWidth: 40, minHeight: 30)
                            .cameraGlass(selected ? .selected : .interactive, in: Capsule())
                    }
                    .buttonStyle(PressableButtonStyle())
                }
                Button("RESET") { camera.clearFrame() }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 48, minHeight: 30)
                    .cameraGlass(.interactive, in: Capsule())
                Button("DONE") { camera.isComposing = false; app.mode = .photo }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.yellow)
                    .frame(minWidth: 48, minHeight: 30)
                    .cameraGlass(.selected, in: Capsule())
            }
        }
    }
}

/// Manual exposure, focus and white balance pop-up. Every row is only enabled where the camera supports it,
/// and AUTO hands that control back to the camera. Readouts show what the camera is doing right now.
struct ManualControlsView: View {
    @Bindable var app: AppModel
    @Environment(\.cameraReduceMotion) private var reduceMotion

    private var camera: LiveCameraModel { app.camera }
    private var caps: CameraCapabilities { camera.capabilities }

    var body: some View {
        VStack(spacing: 14) {
            Capsule().fill(.white.opacity(0.35)).frame(width: 36, height: 5).padding(.top, 8).accessibilityHidden(true)
            HStack {
                Text("MANUAL").font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.white.opacity(0.9))
                Spacer()
                Button("All Auto") { camera.setManual(ManualSettings()) }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(camera.manual.isAuto ? Color.white.opacity(0.4) : .yellow)
                    .disabled(camera.manual.isAuto)
                Button("Done") { close() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.yellow)
                    .padding(.leading, 12)
            }
            .padding(.horizontal, 6)

            row("EV", value: String(format: "%+.1f", camera.exposureBias), isAuto: nil, supported: true,
                slider: Slider(value: Binding(get: { Double(camera.exposureBias) }, set: { camera.setExposureBias(Float($0)) }),
                               in: app.exposureRange, step: 0.1))

            row("ISO", value: camera.manual.iso.map { "\(Int($0))" } ?? camera.readings.map { "\(Int($0.iso))" } ?? "—",
                isAuto: camera.manual.iso == nil, supported: caps.supportsManualExposure,
                slider: Slider(value: Binding(get: { log(Double(camera.manual.iso ?? camera.readings?.iso ?? max(caps.minISO, 1))) },
                                              set: { v in update { $0.iso = Float(exp(v)) } }),
                               in: log(Double(max(caps.minISO, 1)))...log(Double(max(caps.maxISO, caps.minISO + 1))))) {
                update { $0.iso = nil }
            }

            row("SHUTTER", value: CaptureMetadata.shutterText(camera.manual.shutterSeconds ?? camera.readings?.seconds ?? 0),
                isAuto: camera.manual.shutterSeconds == nil, supported: caps.supportsManualExposure,
                slider: Slider(value: Binding(get: { log(camera.manual.shutterSeconds ?? camera.readings?.seconds ?? 1.0 / 60) },
                                              set: { v in update { $0.shutterSeconds = exp(v) } }),
                               in: log(max(caps.minExposureDuration, 1e-5))...log(max(caps.maxExposureDuration, caps.minExposureDuration * 2, 2e-5)))) {
                update { $0.shutterSeconds = nil }
            }

            row("FOCUS", value: String(format: "%.2f", camera.manual.lensPosition ?? camera.readings?.lens ?? 0),
                isAuto: camera.manual.lensPosition == nil, supported: caps.supportsManualFocus,
                slider: Slider(value: Binding(get: { Double(camera.manual.lensPosition ?? camera.readings?.lens ?? 0.5) },
                                              set: { v in update { $0.lensPosition = Float(v) } }), in: 0...1)) {
                update { $0.lensPosition = nil }
            }

            row("WB", value: "\(Int(camera.manual.kelvin ?? camera.readings?.kelvin ?? 5500))K",
                isAuto: camera.manual.kelvin == nil, supported: caps.supportsManualWhiteBalance,
                slider: Slider(value: Binding(get: { Double(camera.manual.kelvin ?? camera.readings?.kelvin ?? 5500) },
                                              set: { v in update { $0.kelvin = Float(v) } }), in: 2500...9000, step: 50)) {
                update { $0.kelvin = nil }
            }

            if !caps.supportsManualExposure && !caps.supportsManualFocus && !caps.supportsManualWhiteBalance {
                Text("This camera doesn't offer manual exposure, focus or white balance.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 18)
        .frame(maxWidth: 520)
        .cameraGlass(.regular, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Manual camera controls")
        .accessibilityAction(.escape) { close() }
    }

    private func update(_ change: (inout ManualSettings) -> Void) {
        var next = camera.manual
        change(&next)
        camera.setManual(next)
    }

    private func row(_ title: String, value: String, isAuto: Bool?, supported: Bool, slider: Slider<EmptyView, EmptyView>,
                     auto: (() -> Void)? = nil) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 62, alignment: .leading)
            slider
                .tint(.yellow)
                .accessibilityLabel(title)
                .accessibilityValue(supported ? value : "Not supported")
            Text(supported ? value : "N/A")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(isAuto == false ? Color.yellow : .white.opacity(0.7))
                .frame(width: 58, alignment: .trailing)
            if let isAuto, let auto {
                Button(action: auto) {
                    Text("AUTO")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isAuto ? Color.yellow : .white)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 26)
                        .cameraGlass(isAuto ? .selected : .interactive, in: Capsule())
                }
                .disabled(isAuto || !supported)
            }
        }
        .padding(.horizontal, 6)
        .opacity(supported ? 1 : 0.4)
        .disabled(!supported)
    }

    private func close() {
        withAnimation(reduceMotion ? nil : .spring(duration: 0.35)) { app.closePopUps() }
    }
}
