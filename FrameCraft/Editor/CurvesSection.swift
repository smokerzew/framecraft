import SwiftUI

/// Point curves: drag the five points of the RGB, red, green or blue curve up and down.
struct CurvesSection: View {
    @Bindable var session: EditSession
    @State private var channel: ToneCurves.Channel = .master

    private func color(_ channel: ToneCurves.Channel) -> Color {
        switch channel {
        case .master: .white
        case .red: .red
        case .green: .green
        case .blue: .blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("Curves")
                Spacer()
                Button("Reset") {
                    var curves = session.edit.curves
                    curves[channel] = ToneCurves.xs
                    session.update { $0.curves = curves }
                }
                .font(.subheadline)
                .disabled(session.edit.curves[channel] == ToneCurves.xs)
            }
            Picker("Channel", selection: $channel) {
                ForEach(ToneCurves.Channel.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            GeometryReader { proxy in
                let size = proxy.size
                let points = session.edit.curves[channel]
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.35))
                    GridShape(divisions: 4).stroke(.white.opacity(0.12), lineWidth: 0.5)
                    Path { p in
                        let samples = ToneCurves.sample(points, count: 64)
                        for (i, y) in samples.enumerated() {
                            let pt = CGPoint(x: CGFloat(i) / 63 * size.width, y: CGFloat(1 - y) * size.height)
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                    }
                    .stroke(color(channel), lineWidth: 2)
                    ForEach(0..<5, id: \.self) { i in
                        Circle()
                            .fill(color(channel))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 1))
                            .position(x: CGFloat(ToneCurves.xs[i]) * size.width, y: CGFloat(1 - points[i]) * size.height)
                            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                var curves = session.edit.curves
                                var ys = curves[channel]
                                ys[i] = min(max(1 - Double(value.location.y / size.height), 0), 1)
                                curves[channel] = ys
                                session.update { $0.curves = curves }
                            })
                            .accessibilityElement()
                            .accessibilityLabel("\(channel.label) curve point \(i + 1)")
                            .accessibilityValue("\(Int((points[i] * 100).rounded()))")
                            .accessibilityAdjustableAction { direction in
                                var curves = session.edit.curves
                                var ys = curves[channel]
                                ys[i] = min(max(ys[i] + (direction == .increment ? 0.02 : -0.02), 0), 1)
                                curves[channel] = ys
                                session.update { $0.curves = curves }
                            }
                    }
                }
            }
            .aspectRatio(1.6, contentMode: .fit)
        }
        .padding(.vertical, 6)
    }
}

/// Color calibration: hue and saturation of the red, green and blue primaries.
struct CalibrationSection: View {
    @Bindable var session: EditSession

    private struct Row: Identifiable {
        let id: String
        let title: String
        let tint: Color
        let path: WritableKeyPath<ColorCalibration, Double>
    }

    private let rows: [Row] = [
        Row(id: "rh", title: "Red Hue", tint: .red, path: \.redHue),
        Row(id: "rs", title: "Red Saturation", tint: .red, path: \.redSaturation),
        Row(id: "gh", title: "Green Hue", tint: .green, path: \.greenHue),
        Row(id: "gs", title: "Green Saturation", tint: .green, path: \.greenSaturation),
        Row(id: "bh", title: "Blue Hue", tint: .blue, path: \.blueHue),
        Row(id: "bs", title: "Blue Saturation", tint: .blue, path: \.blueSaturation),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("Calibration")
                Spacer()
                Button("Reset") { session.update { $0.calibration = ColorCalibration() } }
                    .font(.subheadline)
                    .disabled(session.edit.calibration.isNeutral)
            }
            ForEach(rows) { row in
                let value = session.edit.calibration[keyPath: row.path]
                VStack(spacing: 4) {
                    HStack {
                        Text(row.title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        Text(value == 0 ? "0" : String(format: "%+d", Int((value * 100).rounded())))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(value == 0 ? Color.white.opacity(0.6) : Color.yellow)
                    }
                    Slider(value: Binding(get: { session.edit.calibration[keyPath: row.path] },
                                          set: { new in
                                              var calibration = session.edit.calibration
                                              calibration[keyPath: row.path] = new
                                              session.update { $0.calibration = calibration }
                                          }), in: -1...1)
                        .tint(row.tint)
                        .accessibilityLabel(row.title)
                        .accessibilityValue(String(Int((value * 100).rounded())))
                }
            }
        }
        .padding(.vertical, 6)
    }
}
