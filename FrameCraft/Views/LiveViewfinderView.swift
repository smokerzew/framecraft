import AVFoundation
import SwiftUI

/// The live camera in the viewfinder spot: same framing, guides and focus box as the photo view, plus the
/// composition guide (SCAN), the custom frame (COMPOSE) and the tracked subject.
struct LiveViewfinderView: View {
    @Bindable var app: AppModel
    let motion: MotionLevel
    let size: CGSize

    @AppStorage(SettingsKey.gridOpacity) private var gridOpacity = 0.45
    @AppStorage(SettingsKey.showCenter) private var showCenter = false
    @Environment(\.cameraReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @State private var pinchStart: CGFloat?
    @State private var dragIsExposure: Bool?
    @State private var touchStart: CGPoint?
    /// Custom-frame drag: what the drag is doing and the frame when it began (image coordinates).
    @State private var frameDrag: FrameDrag?

    private enum FrameDrag {
        case draw
        case move(CGRect)
        case resize(CGRect, anchor: CGPoint)
    }

    private var camera: LiveCameraModel { app.camera }

    var body: some View {
        let frame = FramingGeometry.frameSize(ratio: app.aspect.ratio, in: size)
        ZStack {
            CameraPreviewView(session: camera.service.session, look: camera.look, crop: camera.viewCrop) { layer in
                camera.previewLayer = layer
            }
            .opacity(camera.isRunning || isPaused ? 1 : 0)

            overlays(frame: frame)

            if let point = app.focusPoint {
                FocusBox(exposure: Double(app.camera.exposureBias), isDimmed: app.isFocusDimmed,
                         isDragging: app.isDraggingExposure, pulse: app.focusPulse)
                    .position(point)
                    .transition(.opacity)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .clipped()
        .contentShape(Rectangle())
        .gesture(pinch)
        .simultaneousGesture(drag(frame: frame))
        .onTapGesture(coordinateSpace: .local) { location in tap(location, frame: frame, lock: false) }
        .onLongPressGesture(minimumDuration: 0.6) {
            guard let location = touchStart, !camera.isComposing else { return }
            tap(location, frame: frame, lock: true)
        }
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { value in
            if touchStart != value.startLocation { touchStart = value.startLocation }
        })
        .overlay { statusOverlay }
        .frame(width: size.width, height: size.height)
        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.15), value: app.aspect.ratio)
        .sensoryFeedback(.success, trigger: camera.alignedPulse)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Camera viewfinder")
        .accessibilityHint(camera.isComposing ? "Drag to draw a frame. Tap a subject to track it." : "Tap to focus. Touch and hold to lock focus and exposure.")
        .accessibilityAction(named: "Focus in the center") {
            app.focus(atView: CGPoint(x: frame.width / 2, y: frame.height / 2), lock: false)
        }
    }

    private var isPaused: Bool {
        if case .paused = camera.status { return true }
        return false
    }

    // MARK: Overlays

    /// An image rect where it shows in the viewfinder (after the scan's crop, if any).
    private func onScreen(_ rect: CGRect, frame: CGSize) -> CGRect {
        ViewCrop.cropped(AspectFillMapping.toView(rect, imageAspect: camera.imageAspect, viewSize: frame), crop: camera.viewCrop, size: frame)
    }

    private func onScreen(_ point: CGPoint, frame: CGSize) -> CGPoint {
        let r = onScreen(CGRect(origin: point, size: .zero), frame: frame)
        return CGPoint(x: r.minX, y: r.minY)
    }

    @ViewBuilder
    private func overlays(frame: CGSize) -> some View {
        ZStack {
            CameraGridOverlay(style: app.gridStyle, opacity: gridOpacity)
            if app.showLevel { LiveLevelGuide(motion: motion).rotatesWithDevice() }
            if showCenter { CenterGuide() }

            if camera.scan == .scanning {
                ScanSweep().transition(.opacity)
            }
            if let suggestion = camera.shownSuggestion {
                SuggestionGuide(rect: onScreen(suggestion.rect, frame: frame),
                                subject: onScreen(suggestion.subject.box, frame: frame),
                                target: CGPoint(x: suggestion.target.x, y: suggestion.target.y),
                                isAlternative: camera.showsAlternative)
                    .transition(.opacity)
            }
            if camera.isCoaching, let advice = camera.coachAdvice {
                CoachGuide(advice: advice,
                           idealFrame: camera.coachPlan.map { onScreen($0.rect, frame: frame) },
                           size: frame, tag: camera.framingBox == nil ? camera.subjectTag : nil,
                           showFrame: camera.scanPhase == .guiding)
                    .transition(.opacity)
            }
            if let box = camera.framingBox {
                FramingBox(rect: CGRect(x: box.minX * frame.width, y: box.minY * frame.height,
                                        width: box.width * frame.width, height: box.height * frame.height),
                           tag: camera.subjectTag)
                    .transition(.opacity)
            }
            if let chosen = camera.frame {
                FrameGuide(rect: onScreen(chosen, frame: frame),
                           viewSize: frame,
                           isEditing: camera.isComposing,
                           isAligned: camera.alignment?.isAligned == true,
                           target: camera.alignment.map { onScreen($0.target, frame: frame) })
                    .transition(.opacity)
            }
            if let box = camera.trackedBox, !camera.subjectLost {
                let r = onScreen(box, frame: frame)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(camera.alignment?.isAligned == true ? Color.yellow : .white, lineWidth: 1.5)
                    .frame(width: max(24, r.width), height: max(24, r.height))
                    .position(x: r.midX, y: r.midY)
                    .shadow(color: .black.opacity(0.4), radius: 1)
                    .animation(.linear(duration: 0.08), value: box)
            }
        }
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: camera.scan)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: camera.frame)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: camera.framingBox)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch camera.status {
        case .denied:
            CameraMessage(icon: "camera.fill", title: "Camera access is off",
                          text: "Allow camera access in Settings to take photos. You can still edit photos from your library.",
                          action: "Open Settings") {
                if let url = URL(string: "app-settings:") { openURL(url) } // UIApplication.openSettingsURLString; the Photos extension can't use UIApplication
            } secondary: { app.showPhotosPicker = true }
        case .unavailable:
            CameraMessage(icon: "camera.badge.ellipsis", title: "No camera available",
                          text: "This device has no camera FrameCraft can use. Import a photo to edit it.",
                          action: "Choose a Photo", perform: { app.showPhotosPicker = true }, secondary: nil)
        case .failed(let message):
            CameraMessage(icon: "exclamationmark.triangle", title: "Camera stopped", text: message, action: "Try Again") {
                Task { await camera.start() }
            } secondary: { app.showPhotosPicker = true }
        case .paused(let message):
            CameraTag(text: message.uppercased(), isOff: true)
        case .starting, .idle:
            ProgressView().tint(.white)
        case .running:
            EmptyView()
        }
    }

    // MARK: Touch

    private func imagePoint(_ location: CGPoint, frame: CGSize) -> CGPoint {
        AspectFillMapping.toImage(ViewCrop.uncropped(location, crop: camera.viewCrop, size: frame),
                                  imageAspect: camera.imageAspect, viewSize: frame)
    }

    private func tap(_ location: CGPoint, frame: CGSize, lock: Bool) {
        if app.isPopUpOpen {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.35)) { app.closePopUps() }
            return
        }
        guard camera.isRunning else { return }
        if camera.isComposing {
            camera.selectSubject(at: imagePoint(location, frame: frame))
            return
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            app.focus(atView: location, lock: lock)
        }
    }

    private func drag(frame: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if camera.isComposing {
                    composeDrag(value, frame: frame)
                    return
                }
                // With the focus box up, a mostly vertical drag slides the ☀︎ exposure.
                if dragIsExposure == nil {
                    dragIsExposure = app.focusPoint != nil && abs(value.translation.height) > abs(value.translation.width)
                    if dragIsExposure == true { app.beginExposureDrag() }
                }
                if dragIsExposure == true { app.updateExposureDrag(by: value.translation.height) }
            }
            .onEnded { _ in
                frameDrag = nil
                if dragIsExposure == true { app.endExposureDrag() }
                dragIsExposure = nil
            }
    }

    private func composeDrag(_ value: DragGesture.Value, frame: CGSize) {
        let start = imagePoint(value.startLocation, frame: frame)
        let now = imagePoint(value.location, frame: frame)
        if frameDrag == nil {
            if let current = camera.frame {
                let view = AspectFillMapping.toView(current, imageAspect: camera.imageAspect, viewSize: frame)
                let corners = [CGPoint(x: view.minX, y: view.minY), CGPoint(x: view.maxX, y: view.minY),
                               CGPoint(x: view.minX, y: view.maxY), CGPoint(x: view.maxX, y: view.maxY)]
                if let corner = corners.first(where: { hypot($0.x - value.startLocation.x, $0.y - value.startLocation.y) < 36 }) {
                    // The opposite corner stays put while this one moves.
                    let opposite = CGPoint(x: corner.x == view.minX ? view.maxX : view.minX, y: corner.y == view.minY ? view.maxY : view.minY)
                    frameDrag = .resize(current, anchor: imagePoint(opposite, frame: frame))
                } else if view.contains(value.startLocation) {
                    frameDrag = .move(current)
                } else {
                    frameDrag = .draw
                }
            } else {
                frameDrag = .draw
            }
        }
        switch frameDrag {
        case .draw, .none:
            camera.setCustomFrame(CGRect(x: min(start.x, now.x), y: min(start.y, now.y),
                                         width: abs(now.x - start.x), height: abs(now.y - start.y)))
        case .move(let original):
            camera.setCustomFrame(original.offsetBy(dx: now.x - start.x, dy: now.y - start.y))
        case .resize(_, let anchor):
            camera.setCustomFrame(CGRect(x: min(anchor.x, now.x), y: min(anchor.y, now.y),
                                         width: abs(now.x - anchor.x), height: abs(now.y - anchor.y)))
        }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? app.zoom
                pinchStart = start
                app.setZoom(start * value.magnification)
            }
            .onEnded { _ in pinchStart = nil }
    }
}

// MARK: - Guides

/// Yellow corner brackets around the suggested framing, the area outside dimmed, the subject outlined
/// and the thirds point it lands on.
private struct SuggestionGuide: View {
    let rect: CGRect
    let subject: CGRect
    /// Subject center inside `rect` (0...1).
    let target: CGPoint
    let isAlternative: Bool

    var body: some View {
        ZStack {
            DimOutside(rect: rect)
            CornerBrackets(rect: rect, color: .yellow, dashed: isAlternative)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(width: subject.width, height: subject.height)
                .position(x: subject.midX, y: subject.midY)
            Circle()
                .fill(Color.yellow)
                .frame(width: 8, height: 8)
                .position(x: rect.minX + target.x * rect.width, y: rect.minY + target.y * rect.height)
        }
    }
}

/// The frame the scan chose, for a moment before the viewfinder crops to it: a bold yellow rounded box in the
/// viewfinder's shape, with the subject's name under it.
private struct FramingBox: View {
    let rect: CGRect
    var tag: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: max(6, min(rect.width, rect.height) * 0.14), style: .continuous)
                .strokeBorder(Color.yellow, lineWidth: 3)
                .frame(width: rect.width, height: rect.height)
                .shadow(color: .yellow.opacity(0.35), radius: 4)
                .position(x: rect.midX, y: rect.midY)
            if let tag {
                Text(tag)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.yellow)
                    .lineLimit(2)
                    .frame(width: max(rect.width + 60, 150), alignment: .leading)
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .offset(x: rect.minX, y: rect.maxY + 6)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

/// Live coach: the ideal frame's outline, a ring where the subject (or a line where the horizon) should go,
/// and where it is now. The ring fills yellow once the shot is framed.
private struct CoachGuide: View {
    let advice: CoachAdvice
    let idealFrame: CGRect?
    let size: CGSize
    var tag: String?
    var showFrame = true

    var body: some View {
        let target = CGPoint(x: advice.target.x * size.width, y: advice.target.y * size.height)
        ZStack {
            if let idealFrame, showFrame, !advice.isAligned {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(.white.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
                    .frame(width: idealFrame.width, height: idealFrame.height)
                    .position(x: idealFrame.midX, y: idealFrame.midY)
            }
            if let horizon = advice.horizonTarget {
                line(at: horizon * size.height, color: .yellow, dashed: true)
            }
            if let now = advice.horizonNow, advice.horizonTarget != nil, !advice.isAligned {
                line(at: now * size.height, color: .white.opacity(0.8), dashed: false)
            }
            if let current = advice.current {
                let here = CGPoint(x: current.x * size.width, y: current.y * size.height)
                if !advice.isAligned, hypot(here.x - target.x, here.y - target.y) > 24 {
                    Path { p in
                        p.move(to: here)
                        p.addLine(to: target)
                    }
                    .stroke(.white.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                // Where the subject should go: a cross on a short level-style line, green once it's there.
                ZStack {
                    Rectangle().fill(Color.yellow).frame(width: 120, height: 1.2)
                    Rectangle().fill(advice.isAligned ? Color.green : Color.yellow).frame(width: 2, height: 16)
                }
                .position(target)
                .shadow(color: .black.opacity(0.4), radius: 1)
                // What and where the subject is.
                if let tag {
                    HStack(spacing: 6) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text(tag)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.green)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(maxWidth: 170)
                    .position(x: min(max(here.x, 90), size.width - 90), y: min(here.y + 44, size.height - 20))
                } else {
                    Circle().fill(.white).frame(width: 8, height: 8).position(here).shadow(radius: 1)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: advice)
    }

    private func line(at y: CGFloat, color: Color, dashed: Bool) -> some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: size.width, y: y))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [8, 6] : []))
        .shadow(color: .black.opacity(0.4), radius: 1)
    }
}

/// The accepted or custom frame: dimmed outside, its own thirds, corner handles while editing, and a
/// crosshair where the subject should go (yellow once it's there).
private struct FrameGuide: View {
    let rect: CGRect
    let viewSize: CGSize
    let isEditing: Bool
    let isAligned: Bool
    let target: CGPoint?

    var body: some View {
        ZStack {
            DimOutside(rect: rect)
            Rectangle()
                .strokeBorder(isAligned ? Color.yellow : .white, lineWidth: isAligned ? 2 : 1.2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            GridShape(divisions: 3)
                .stroke(.white.opacity(0.35), lineWidth: 0.6)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            if isEditing {
                ForEach(Array([CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                               CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)].enumerated()), id: \.offset) { item in
                    Circle().fill(.white).frame(width: 14, height: 14).shadow(radius: 2).position(item.element)
                }
            }
            if let target {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isAligned ? Color.yellow : .white)
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .position(target)
            }
        }
    }
}

private struct DimOutside: View {
    let rect: CGRect

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.addRect(CGRect(origin: .zero, size: proxy.size))
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
        }
    }
}

private struct CornerBrackets: View {
    let rect: CGRect
    let color: Color
    var dashed = false

    var body: some View {
        let arm = min(rect.width, rect.height) * 0.14
        Path { p in
            let corners: [(CGPoint, CGFloat, CGFloat)] = [
                (CGPoint(x: rect.minX, y: rect.minY), 1, 1), (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
                (CGPoint(x: rect.minX, y: rect.maxY), 1, -1), (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
            ]
            for (corner, dx, dy) in corners {
                p.move(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
                p.addLine(to: corner)
                p.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
            }
        }
        .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: dashed ? [6, 4] : []))
        .shadow(color: .black.opacity(0.35), radius: 1)
    }
}

/// A soft band sweeping down while the scene is analyzed (only shown while the analysis actually runs).
private struct ScanSweep: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(colors: [.clear, .yellow.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: proxy.size.height * 0.25)
                .offset(y: phase * proxy.size.height * 0.85)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = 1 }
                }
        }
    }
}

/// Glass card for camera problems, with what to do about them.
private struct CameraMessage: View {
    let icon: String
    let title: String
    let text: String
    let action: String
    let perform: () -> Void
    let secondary: (() -> Void)?

    init(icon: String, title: String, text: String, action: String, perform: @escaping () -> Void, secondary: (() -> Void)?) {
        self.icon = icon
        self.title = title
        self.text = text
        self.action = action
        self.perform = perform
        self.secondary = secondary
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 34, weight: .light)).foregroundStyle(.white.opacity(0.85))
            Text(title).font(.headline).foregroundStyle(.white)
            Text(text).font(.subheadline).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
            Button(action, action: perform)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.yellow)
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
                .cameraGlass(.interactive, in: Capsule())
            if let secondary {
                Button("Edit a Photo Instead", action: secondary)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(22)
        .frame(maxWidth: 320)
        .cameraGlass(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}
