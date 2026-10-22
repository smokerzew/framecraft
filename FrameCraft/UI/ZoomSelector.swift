import SwiftUI

/// Camera-style ".5  1×  2  5" pill. Tapping the selected value toggles the fine slider.
struct ZoomSelector: View {
    let zoom: CGFloat
    var presets: [CGFloat] = ZoomLimits.presets
    let onSelect: (CGFloat) -> Void
    let onToggleSlider: () -> Void

    @Environment(\.cameraReduceMotion) private var reduceMotion
    @Namespace private var selection

    private var activePreset: CGFloat {
        presets.last { $0 <= zoom + 0.001 } ?? presets.first ?? ZoomLimits.minimum
    }

    var body: some View {
        HStack(spacing: 14) {
            ForEach(presets, id: \.self) { preset in
                let isActive = preset == activePreset
                Button {
                    isActive ? onToggleSlider() : onSelect(preset)
                } label: {
                    Text(isActive ? ZoomLimits.label(for: zoom) + "×" : ZoomLimits.label(for: preset))
                        .font(.system(size: isActive ? 13 : 15, weight: .medium))
                        .monospacedDigit()
                        .rotatesWithDevice()
                        .foregroundStyle(isActive ? Color.yellow : .white)
                        .frame(width: isActive ? 40 : 32, height: isActive ? 40 : 32)
                        .background {
                            if isActive {
                                Circle()
                                    .fill(.black.opacity(0.45))
                                    .matchedGeometryEffect(id: "zoom", in: selection)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Preview zoom \(ZoomLimits.label(for: preset)) times")
                .accessibilityHint(isActive ? "Shows the fine zoom slider" : "Zooms the preview")
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 2)
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.2), value: activePreset)
    }
}
