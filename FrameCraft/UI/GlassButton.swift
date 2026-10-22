import SwiftUI

/// Subtle press feedback shared by all camera controls.
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.cameraReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.22), value: configuration.isPressed)
    }
}

/// Circular glass icon button. State is shown by symbol shape and tint, never color alone.
struct GlassIconButton: View {
    let systemImage: String
    let label: String
    var hint: String = ""
    var value: String? = nil
    var isActive = false
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.38, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isActive ? Color.yellow : .white)
                .rotatesWithDevice()
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .cameraGlass(isActive ? .selected : .interactive, in: Circle())
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .accessibilityValue(value ?? "")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Large captioned circle used in the expanded control panel (FLASH, LIVE, TIMER…).
struct PanelControlButton: View {
    let systemImage: String
    let title: String
    /// Short text drawn inside the circle instead of the icon (e.g. "3s", "4:3").
    var value: String? = nil
    var isActive = false
    var stateDescription: String? = nil
    var hint: String = ""
    /// Edit mode badge: true = pinned to the top bar (shows −), false = not pinned (shows +), nil = not editing.
    var pinnedInTopBar: Bool? = nil
    let action: () -> Void

    @Environment(\.cameraLargeLabels) private var largeLabels

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(.black.opacity(isActive ? 0.55 : 0.35))
                    if let value {
                        Text(value)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 22, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .foregroundStyle(isActive ? Color.yellow : .white)
                .rotatesWithDevice()
                .frame(width: 62, height: 62)
                .overlay { if isActive { Circle().strokeBorder(.yellow.opacity(0.7), lineWidth: 1.5) } }
                .overlay(alignment: .topTrailing) {
                    if let pinned = pinnedInTopBar {
                        Image(systemName: pinned ? "minus.circle.fill" : "plus.circle.fill")
                            .font(.system(size: 20))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, pinned ? Color.red : Color.green)
                            .offset(x: 4, y: -4)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                Text(title)
                    .font(largeLabels ? .footnote.weight(.semibold) : .caption2.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.capitalized)
        .accessibilityValue(stateDescription ?? value ?? (isActive ? "On" : "Off"))
        .accessibilityHint(pinnedInTopBar.map { $0 ? "Removes it from the top bar" : "Adds it to the top bar" } ?? hint)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
