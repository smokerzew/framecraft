import SwiftUI

/// `AUTO | shutter | ISO | meter` under the viewfinder. Tap the shutter speed or ISO to pick it (yellow
/// underline) and drag its ruler; AUTO hands exposure back to the camera. The last number is the camera's own
/// meter: how many stops brighter (+) or darker (−) than it would choose.
struct ExposureStrip: View {
    @Bindable var app: AppModel
    @State private var selected: Dial?

    enum Dial { case shutter, iso }

    private var camera: LiveCameraModel { app.camera }
    private var manualOK: Bool { camera.capabilities.supportsManualExposure }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Button {
                    selected = nil
                    camera.setAutoExposure()
                } label: {
                    Text("AUTO")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(camera.isAutoExposure ? Color.yellow : .white.opacity(0.6))
                }
                .accessibilityLabel("Automatic exposure")
                .accessibilityAddTraits(camera.isAutoExposure ? .isSelected : [])

                Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 14)

                value(ExposureStops.shutterLabel(shutter), dial: .shutter, manual: camera.manual.shutterSeconds != nil)
                    .accessibilityLabel("Shutter speed")
                value("ISO \(Int(iso.rounded()))", dial: .iso, manual: camera.manual.iso != nil)
                    .accessibilityLabel("ISO")

                Text(offsetText)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(minWidth: 34, alignment: .leading)
                    .accessibilityLabel("Meter")
                    .accessibilityValue(offsetText)
            }
            .disabled(!camera.isRunning)

            if let selected, manualOK {
                switch selected {
                case .shutter:
                    let stops = ExposureStops.shutters(in: camera.capabilities.minExposureDuration...max(camera.capabilities.maxExposureDuration,
                                                                                                         camera.capabilities.minExposureDuration))
                    TickRuler(count: stops.count, index: nearest(stops.map { log($0) }, log(shutter)),
                              label: { ExposureStops.shutterLabels.contains(stops[$0]) ? ExposureStops.shutterLabel(stops[$0]) : nil }) { i in
                        camera.setShutter(stops[i])
                    }
                case .iso:
                    let stops = ExposureStops.isos(in: camera.capabilities.minISO...max(camera.capabilities.maxISO, camera.capabilities.minISO))
                    TickRuler(count: stops.count, index: nearest(stops.map { log(Double($0)) }, log(Double(iso))),
                              label: { ExposureStops.isoLabels.contains(stops[$0]) ? "\(Int(stops[$0]))" : nil }) { i in
                        camera.setISO(stops[i])
                    }
                }
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 2)
        .animation(.easeOut(duration: 0.2), value: selected)
    }

    private var shutter: Double { camera.manual.shutterSeconds ?? camera.readings?.seconds ?? 1.0 / 60 }
    private var iso: Float { camera.manual.iso ?? camera.readings?.iso ?? 100 }

    private var offsetText: String {
        guard let offset = camera.readings?.offset, offset.isFinite else { return "±0" }
        return abs(offset) < 0.05 ? "±0" : String(format: "%+.1f", offset)
    }

    private func value(_ text: String, dial: Dial, manual: Bool) -> some View {
        Button {
            guard manualOK else { return }
            selected = selected == dial ? nil : dial
        } label: {
            Text(text)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(selected == dial ? Color.yellow : (camera.isAutoExposure ? .white.opacity(0.6) : .white))
                .padding(.bottom, 3)
                .overlay(alignment: .bottom) {
                    if selected == dial || manual {
                        Rectangle().fill(selected == dial ? Color.yellow : .white.opacity(0.5)).frame(height: 1.5)
                    }
                }
        }
        .accessibilityValue(text)
        .accessibilityHint(manualOK ? "Shows a ruler to set it by hand" : "Not adjustable on this camera")
    }

    private func nearest(_ values: [Double], _ target: Double) -> Int {
        values.indices.min { abs(values[$0] - target) < abs(values[$1] - target) } ?? 0
    }
}

/// A camera-style tick ruler: one tick per value, labels on some, a yellow mark on the current one.
/// Tap or drag anywhere along it to pick a value.
struct TickRuler: View {
    let count: Int
    let index: Int
    let label: (Int) -> String?
    let onPick: (Int) -> Void

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let step = count > 1 ? w / CGFloat(count - 1) : 0
            ZStack(alignment: .topLeading) {
                ForEach(0..<max(count, 0), id: \.self) { i in
                    let labeled = label(i)
                    Rectangle()
                        .fill(i == index ? Color.yellow : .white.opacity(labeled == nil ? 0.35 : 0.7))
                        .frame(width: i == index ? 2 : 1, height: i == index ? 16 : (labeled == nil ? 7 : 11))
                        .position(x: CGFloat(i) * step, y: 8)
                    if let labeled {
                        Text(labeled)
                            .font(.system(size: 9, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize()
                            .position(x: CGFloat(i) * step, y: 24)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard count > 1 else { return }
                let i = Int((value.location.x / step).rounded())
                let clamped = min(max(i, 0), count - 1)
                if clamped != index { onPick(clamped) }
            })
        }
        .frame(height: 30)
        .padding(.horizontal, 22)
        .sensoryFeedback(.selection, trigger: index)
        .accessibilityElement()
        .accessibilityLabel("Ruler")
        .accessibilityValue(label(index) ?? "\(index + 1) of \(count)")
        .accessibilityAdjustableAction { direction in
            let next = direction == .increment ? index + 1 : index - 1
            if (0..<count).contains(next) { onPick(next) }
        }
    }
}
