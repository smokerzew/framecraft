import SwiftUI

/// The Camera app's yellow focus/exposure square with the ☀︎ slider beside it.
struct FocusBox: View {
    let exposure: Double
    let isDimmed: Bool
    let isDragging: Bool
    let pulse: Int

    @Environment(\.cameraReduceMotion) private var reduceMotion
    @State private var scale: CGFloat = 1

    private let side: CGFloat = 74

    var body: some View {
        ZStack {
            Rectangle()
                .strokeBorder(Color.yellow, lineWidth: 1.2)
                .frame(width: side, height: side)
                .overlay { edgeTicks }

            sunSlider
                .offset(x: side / 2 + 18)
        }
        .scaleEffect(scale)
        .opacity(isDimmed && !isDragging ? 0.45 : 1)
        .shadow(color: .black.opacity(0.35), radius: 1)
        .onChange(of: pulse, initial: true) {
            guard !reduceMotion else { return }
            scale = 1.35
            withAnimation(.spring(duration: 0.35, bounce: 0.25)) { scale = 1 }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isDimmed)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Small inward ticks at the middle of each side, like the iOS focus square.
    private var edgeTicks: some View {
        ZStack {
            Rectangle().frame(width: 1.2, height: 6).offset(y: -side / 2 + 3)
            Rectangle().frame(width: 1.2, height: 6).offset(y: side / 2 - 3)
            Rectangle().frame(width: 6, height: 1.2).offset(x: -side / 2 + 3)
            Rectangle().frame(width: 6, height: 1.2).offset(x: side / 2 - 3)
        }
        .foregroundStyle(Color.yellow)
    }

    /// Sun moves up for brighter, down for darker; the track only shows while dragging or fresh.
    private var sunSlider: some View {
        let travel: CGFloat = 46
        let y = -CGFloat(min(max(exposure / 2, -1), 1)) * travel
        return ZStack {
            if isDragging || !isDimmed {
                Rectangle()
                    .fill(Color.yellow.opacity(0.85))
                    .frame(width: 1, height: travel * 2 + 20)
                    .mask {
                        VStack(spacing: 0) {
                            Rectangle().frame(height: max(0, travel + 10 + y - 12))
                            Color.clear.frame(height: 24)
                            Rectangle()
                        }
                    }
            }
            Image(systemName: "sun.max.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.yellow)
                .offset(y: y)
        }
        .frame(width: 24, height: travel * 2 + 20)
    }
}
