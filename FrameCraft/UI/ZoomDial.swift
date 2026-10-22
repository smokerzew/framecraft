import SwiftUI

/// iOS 27-style zoom dial: a wide arc over a dark disc, dense ticks along the outer edge
/// (log scale, 0.5×–25×), lens labels with focal lengths, and a fixed yellow pointer at the top.
/// Purely visual; the drag that drives it lives on the zoom area in `CameraShutterControls`.
struct ZoomDial: View {
    let zoom: CGFloat

    /// Angle (radians) the full 0.5×–25× range spans (~45° per decade, as in the Camera app).
    static let span: Double = 76 * .pi / 180
    /// Arc radius as a fraction of the dial's width.
    static let radiusFactor: CGFloat = 0.55

    /// Lens stops with their 35 mm-equivalent focal lengths (iPhone Pro camera system).
    static let lensStops: [(zoom: CGFloat, focal: String?)] = [
        (0.5, "13MM"), (1, "24MM"), (2, "48MM"), (5, "120MM"), (25, nil),
    ]

    /// 0...1 position of a zoom value on the dial (log scale).
    static func position(for zoom: CGFloat) -> Double {
        log(Double(ZoomLimits.clamp(zoom)) / Double(ZoomLimits.minimum))
            / log(Double(ZoomLimits.maximum) / Double(ZoomLimits.minimum))
    }

    static func zoom(at position: Double) -> CGFloat {
        let ratio = Double(ZoomLimits.maximum) / Double(ZoomLimits.minimum)
        return ZoomLimits.clamp(CGFloat(Double(ZoomLimits.minimum) * pow(ratio, min(max(position, 0), 1))))
    }

    /// Zoom after dragging `distance` points along an arc of `radius` (drag left = zoom in).
    static func zoom(from start: CGFloat, dragDistance distance: CGFloat, radius: CGFloat) -> CGFloat {
        guard radius > 0 else { return start }
        let deltaPosition = -Double(distance / radius) / span
        return zoom(at: position(for: start) + deltaPosition)
    }

    /// Ticks get denser toward telephoto, like the real dial.
    static let ticks: [CGFloat] = {
        var values: [CGFloat] = []
        var z: CGFloat = 0.5
        while z <= 25.0001 {
            values.append(z)
            z += z < 2 ? 0.05 : (z < 5 ? 0.1 : (z < 10 ? 0.25 : 0.5))
        }
        return values
    }()

    /// The current value matches a lens stop (shows its focal length in yellow).
    private var currentStop: (zoom: CGFloat, focal: String?)? {
        Self.lensStops.first { abs($0.zoom - zoom) < 0.05 }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let radius = width * Self.radiusFactor
            let center = CGPoint(x: width / 2, y: 14 + radius)

            ZStack(alignment: .top) {
                // Dark disc under the arc (extends down behind the shutter row).
                Circle()
                    .fill(
                        RadialGradient(colors: [.black.opacity(0.65), .black.opacity(0.45)],
                                       center: .center, startRadius: 0, endRadius: radius)
                    )
                    .frame(width: radius * 2, height: radius * 2)
                    .position(center)

                Canvas { context, _ in
                    let current = Self.position(for: zoom)

                    for tick in Self.ticks {
                        let theta = (Self.position(for: tick) - current) * Self.span
                        guard abs(theta) < 1.15 else { continue }
                        let isStop = Self.lensStops.contains { abs($0.zoom - tick) < 0.01 }
                        let fade = max(0, 1 - abs(theta) / 1.15) // ticks fade toward the ends
                        let length: CGFloat = isStop ? 13 : 7
                        var line = Path()
                        line.move(to: point(center, radius, theta))
                        line.addLine(to: point(center, radius - length, theta))
                        context.stroke(line, with: .color(.white.opacity((isStop ? 1 : 0.6) * fade)),
                                       lineWidth: isStop ? 1.6 : 1)
                    }

                    for stop in Self.lensStops {
                        let theta = (Self.position(for: stop.zoom) - current) * Self.span
                        // The stop under the pointer is replaced by the yellow current value.
                        guard abs(theta) < 1.1, abs(theta) > 0.06 else { continue }
                        let fade = max(0, 1 - abs(theta) / 1.1)
                        context.draw(
                            Text(ZoomLimits.label(for: stop.zoom))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white.opacity(fade)),
                            at: point(center, radius - 30, theta)
                        )
                        if let focal = stop.focal {
                            context.draw(
                                Text(focal)
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.45 * fade)),
                                at: point(center, radius - 44, theta)
                            )
                        }
                    }

                    // Fixed pointer at the top of the arc.
                    var pointer = Path()
                    pointer.move(to: CGPoint(x: width / 2 - 4, y: center.y - radius - 6))
                    pointer.addLine(to: CGPoint(x: width / 2 + 4, y: center.y - radius - 6))
                    pointer.addLine(to: CGPoint(x: width / 2, y: center.y - radius + 1))
                    pointer.closeSubpath()
                    context.fill(pointer, with: .color(.yellow))
                }

                // Current value (and focal length at a lens stop) in yellow under the pointer.
                VStack(spacing: 0) {
                    Text(ZoomLimits.label(for: zoom) + "×")
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    if let focal = currentStop?.focal {
                        Text(focal).font(.system(size: 8, weight: .semibold))
                    }
                }
                .foregroundStyle(.yellow)
                .rotatesWithDevice()
                .offset(y: 14 + 22)
            }
        }
        .accessibilityHidden(true) // the zoom area carries the accessible adjustable action
    }

    private func point(_ center: CGPoint, _ radius: CGFloat, _ angle: Double) -> CGPoint {
        CGPoint(x: center.x + radius * CGFloat(sin(angle)), y: center.y - radius * CGFloat(cos(angle)))
    }
}
