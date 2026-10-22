import SwiftUI

/// Small capsule tabs used inside the glass pop-ups and the controls panel.
struct GlassTabs<Tab: Hashable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String

    var body: some View {
        // Many tabs scroll sideways instead of squeezing.
        if tabs.count > 5 {
            ScrollView(.horizontal, showsIndicators: false) { row(minWidth: 70) }
        } else {
            row(minWidth: nil)
        }
    }

    private func row(minWidth: CGFloat?) -> some View {
        HStack(spacing: 6) {
            ForEach(tabs, id: \.self) { tab in
                let selected = tab == selection
                Button { selection = tab } label: {
                    Text(title(tab).uppercased())
                        .font(.caption.weight(.semibold))
                        .tracking(0.8)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(selected ? Color.yellow : .white.opacity(0.85))
                        .padding(.horizontal, minWidth == nil ? 0 : 10)
                        .frame(minWidth: minWidth, maxWidth: minWidth == nil ? .infinity : nil, minHeight: 32)
                        .cameraGlass(selected ? .selected : .interactive, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(tab))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}
