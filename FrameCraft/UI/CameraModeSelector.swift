import SwiftUI

/// iOS 27 Camera mode carousel. At rest it's a glass capsule showing the selected mode (in a glass
/// pill) and its neighbors. While you slide, the capsule opens to full width, the side buttons hide
/// (`isInteracting`), the labels glide under a pill fixed in the center, and whatever sits in the
/// center is highlighted. On release it snaps to the nearest mode and closes back up.
struct CameraModeSelector: View {
    @Binding var selection: CameraMode
    /// True while sliding; the bottom bar hides the thumbnail and side button.
    @Binding var isInteracting: Bool
    /// Width of the resting capsule.
    var collapsedWidth: CGFloat = 250
    /// Tapping the already-selected mode opens Camera Controls, as in iOS 27.
    var onReselect: () -> Void = {}

    @Environment(\.cameraReduceMotion) private var reduceMotion
    @Environment(\.cameraLargeLabels) private var largeLabels
    @State private var labelWidths: [CameraMode: CGFloat] = [:]
    @State private var dragOffset: CGFloat = 0
    @State private var collapseTask: Task<Void, Never>?

    private let modes = CameraMode.allCases
    private let spacing: CGFloat = 28
    private let pillHeight: CGFloat = 40

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let centers = labelCenters()
            let selectedIndex = modes.firstIndex(of: selection) ?? 0
            let stripOrigin = width / 2 - (centers[safe: selectedIndex] ?? 0) + rubberBanded(dragOffset, centers: centers, selectedIndex: selectedIndex)
            let active = nearestMode(toStripX: width / 2 - stripOrigin, centers: centers)
            let visibleWidth = isInteracting ? width : min(collapsedWidth, width)

            ZStack {
                // Resting capsule; fades away while sliding (the labels then span the full width).
                Capsule()
                    .fill(.clear)
                    .frame(width: min(collapsedWidth, width), height: 52)
                    .cameraGlass(.regular, in: Capsule())
                    .opacity(isInteracting ? 0 : 1)

                // The pill sits behind the labels: Liquid Glass blurs whatever is under it,
                // so placing it over the text made the selected mode unreadable on device.
                pill(for: active).allowsHitTesting(false)
                labels(stripOrigin: stripOrigin, active: active, width: width)
            }
            .frame(width: width, height: proxy.size.height)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: isInteracting ? 0.06 : 0.14),
                        .init(color: .black, location: isInteracting ? 0.94 : 0.86),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: visibleWidth)
            }
            .contentShape(Rectangle())
            .gesture(slide(centers: centers, selectedIndex: selectedIndex, width: width))
            .sensoryFeedback(.selection, trigger: active)
        }
        .frame(height: 56)
        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.12), value: isInteracting)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mode")
        .accessibilityValue(selection.title.capitalized)
        .accessibilityHint(selection.explanation)
        .accessibilityAdjustableAction { direction in
            let index = modes.firstIndex(of: selection) ?? 0
            switch direction {
            case .increment: if index + 1 < modes.count { selection = modes[index + 1] }
            case .decrement: if index > 0 { selection = modes[index - 1] }
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Open camera controls", onReselect)
    }

    // MARK: Pieces

    private func labels(stripOrigin: CGFloat, active: CameraMode, width: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(modes) { mode in
                Text(mode.title)
                    .font(.system(size: largeLabels ? 17 : 15, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(mode == active ? Color.yellow : .white.opacity(0.92))
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { labelWidths[mode] = $0 }
                    .contentShape(Rectangle().inset(by: -10))
                    .onTapGesture { tap(mode) }
            }
        }
        .fixedSize()
        .frame(width: width, alignment: .leading)
        .offset(x: stripOrigin)
        .animation(isInteracting ? nil : (reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.1)),
                   value: selection)
    }

    private func pill(for mode: CameraMode) -> some View {
        Capsule()
            .fill(Color.black.opacity(0.35))
            .frame(width: (labelWidths[mode] ?? 60) + 34, height: pillHeight)
            .cameraGlass(.selected, in: Capsule())
            .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.1), value: mode)
    }

    // MARK: Geometry

    /// Center of each label measured from the strip's leading edge.
    private func labelCenters() -> [CGFloat] {
        var x: CGFloat = 0
        return modes.map { mode in
            let w = labelWidths[mode] ?? 60
            defer { x += w + spacing }
            return x + w / 2
        }
    }

    private func nearestMode(toStripX x: CGFloat, centers: [CGFloat]) -> CameraMode {
        guard let index = centers.indices.min(by: { abs(centers[$0] - x) < abs(centers[$1] - x) }) else { return selection }
        return modes[index]
    }

    /// Past the first/last mode the strip resists, like a scroll view's edge.
    private func rubberBanded(_ offset: CGFloat, centers: [CGFloat], selectedIndex: Int) -> CGFloat {
        guard let first = centers.first, let last = centers.last, let current = centers[safe: selectedIndex] else { return offset }
        let maxRight = current - first   // dragging right shows earlier modes
        let maxLeft = -(last - current)
        if offset > maxRight { return maxRight + (offset - maxRight) * 0.3 }
        if offset < maxLeft { return maxLeft + (offset - maxLeft) * 0.3 }
        return offset
    }

    // MARK: Interaction

    private func slide(centers: [CGFloat], selectedIndex: Int, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                collapseTask?.cancel()
                if !isInteracting { isInteracting = true }
                dragOffset = value.translation.width
            }
            .onEnded { value in
                // Include some flick momentum, then land on the nearest mode.
                let momentum = (value.predictedEndTranslation.width - value.translation.width) * 0.35
                let offset = rubberBanded(value.translation.width + momentum, centers: centers, selectedIndex: selectedIndex)
                let current = centers[safe: selectedIndex] ?? 0
                let target = nearestMode(toStripX: current - offset, centers: centers)
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.12)) {
                    selection = target
                    dragOffset = 0
                }
                scheduleCollapse()
            }
    }

    private func tap(_ mode: CameraMode) {
        if mode == selection { onReselect(); return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.12)) {
            selection = mode
        }
    }

    /// Closes the capsule shortly after the strip settles.
    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            isInteracting = false
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
