import SwiftUI

/// Evenly spaced grid. Drawn only in the viewfinder layer, never into the image data.
struct GridShape: Shape {
    var divisions: Int

    /// Interior line positions for `length` split into `divisions` parts.
    static func lineOffsets(divisions: Int, length: CGFloat) -> [CGFloat] {
        guard divisions > 1 else { return [] }
        return (1..<divisions).map { length * CGFloat($0) / CGFloat(divisions) }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for x in Self.lineOffsets(divisions: divisions, length: rect.width) {
            path.move(to: CGPoint(x: rect.minX + x, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + x, y: rect.maxY))
        }
        for y in Self.lineOffsets(divisions: divisions, length: rect.height) {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + y))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + y))
        }
        return path
    }
}

struct CameraGridOverlay: View {
    let style: GridStyle
    let opacity: Double

    var body: some View {
        if let divisions = style.divisions {
            GridShape(divisions: divisions)
                .stroke(.white.opacity(opacity), lineWidth: style == .fine ? 0.5 : 0.8)
                .shadow(color: .black.opacity(0.35), radius: 0.5) // keeps lines visible on bright skies
                .accessibilityHidden(true)
        }
    }
}

/// Level guide fed straight from `MotionLevel`. Reading the tilt here (not in the parent) means
/// only this small view redraws as the phone moves.
struct LiveLevelGuide: View {
    let motion: MotionLevel

    var body: some View {
        CameraLevelGuide(angle: motion.levelAngle, isUpright: motion.isUpright)
    }
}

/// iOS-style level. The outer segments stay fixed to the screen; the middle segment shows the true horizon
/// from the phone's tilt. Within ~1° everything turns yellow and joins into one line (with a light tap).
struct CameraLevelGuide: View {
    /// Phone tilt in radians (from `MotionLevel`); 0 = level.
    var angle: Double = 0
    var isUpright = true

    @Environment(\.cameraReduceMotion) private var reduceMotion

    private var isLevel: Bool { isUpright && MotionLevel.isLevel(angle) }

    var body: some View {
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let arm = proxy.size.width * 0.16
            let gap: CGFloat = isLevel ? 0 : 34
            let color: Color = isLevel ? .yellow : .white

            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: center.x - gap - 40 - arm, y: center.y))
                    path.addLine(to: CGPoint(x: center.x - gap - 40, y: center.y))
                    path.move(to: CGPoint(x: center.x + gap + 40, y: center.y))
                    path.addLine(to: CGPoint(x: center.x + gap + 40 + arm, y: center.y))
                }
                .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))

                // The horizon: counter-rotates against the phone's tilt.
                Capsule()
                    .fill(color)
                    .frame(width: 80, height: 1.6)
                    .rotationEffect(.radians(isUpright ? -clampedAngle : 0))
                    .position(center)
            }
            .shadow(color: .black.opacity(0.4), radius: 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isLevel)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: isLevel) { _, nowLevel in nowLevel }
        .accessibilityHidden(true)
    }

    /// Beyond ~30° the guide stops following, like the Camera app's level.
    private var clampedAngle: Double { min(max(angle, -.pi / 6), .pi / 6) }
}

/// Center crosshair, as in the reference screenshots.
struct CenterGuide: View {
    var body: some View {
        ZStack {
            Rectangle().frame(width: 44, height: 1.2)
            Rectangle().frame(width: 1.2, height: 44)
        }
        .foregroundStyle(.yellow)
        .shadow(color: .black.opacity(0.4), radius: 1)
        .accessibilityHidden(true)
    }
}
