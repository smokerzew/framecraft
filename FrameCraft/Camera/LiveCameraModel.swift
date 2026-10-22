import AVFoundation
import SwiftUI

/// Manual exposure, focus and white balance. nil means automatic for that control.
struct ManualSettings: Equatable, Sendable {
    var iso: Float?
    var shutterSeconds: Double?
    var lensPosition: Float?
    var kelvin: Float?
    var tint: Float = 0

    var isAuto: Bool { iso == nil && shutterSeconds == nil && lensPosition == nil && kelvin == nil }
}

/// State of the live camera: session status, hardware capabilities, zoom/exposure, composition scan,
/// custom frame and subject tracking. The workspace view model owns one and routes the shared controls here.
@MainActor
@Observable
final class LiveCameraModel {
    enum Status: Equatable {
        case idle, starting, running, denied, unavailable
        case paused(String)
        case failed(String)
    }

    enum Scan: Equatable {
        case idle, scanning
        case result(CompositionResult)
    }

    private(set) var status: Status = .idle
    private(set) var capabilities = CameraCapabilities()
    private(set) var position: AVCaptureDevice.Position = .back
    private(set) var isCapturing = false
    private(set) var exposureBias: Float = 0
    private(set) var manual = ManualSettings()
    private(set) var readings: (iso: Float, seconds: Double, lens: Float, kelvin: Float)?
    private(set) var torch = false
    private(set) var rawMode: RawCaptureMode = RawCaptureMode(rawValue: UserDefaults.standard.string(forKey: SettingsKey.rawMode) ?? "") ?? .off

    private func setRaw(_ mode: RawCaptureMode) {
        rawMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: SettingsKey.rawMode)
    }

    // Composition
    private(set) var scan: Scan = .idle
    private(set) var showsAlternative = false
    /// The framing the next photo is cropped to (accepted suggestion or a custom frame), in image coordinates.
    private(set) var frame: CGRect?
    private(set) var frameIsCustom = false
    /// Custom frame editing (COMPOSE): drag to draw or move the frame, tap a subject to track it.
    var isComposing = false
    /// Ratio of the custom frame; nil = free.
    var composeAspect: CaptureAspect?
    private(set) var trackedBox: CGRect?
    private(set) var alignment: CompositionEngine.Alignment?
    private(set) var subjectLost = false
    private(set) var lastFeatures: SceneFeatures?
    /// Width / height of the camera frames (portrait).
    private(set) var imageAspect: CGFloat = 3.0 / 4.0
    private var pendingSubjectTap: CGPoint?

    // Live framing coach (AUTO FRAME)
    private(set) var isCoaching = false
    private(set) var coachPlan: FramingPlan?
    private(set) var coachAdvice: CoachAdvice?
    private(set) var coachAlternative: FramingPlan?
    private(set) var coachNotes: [CompositionGuidance] = []
    @ObservationIgnored private var coachLostSince: Date?
    @ObservationIgnored private var coachMargin = 0.08
    /// Current zoom (Camera-app units) and the capture frame's width / height, for the coach's measurements.
    private(set) var zoom: CGFloat = 1
    var captureAspect: CGFloat = 0.75

    let service = CameraService()
    let frames = FrameRouter()
    let look = LiveLookRenderer()
    @ObservationIgnored weak var previewLayer: AVCaptureVideoPreviewLayer?
    @ObservationIgnored private var readingsTask: Task<Void, Never>?

    init() {
        frames.look = look
        let router = frames
        service.onFrame = { router.handle($0) }
        service.onStatus = { [weak self] message in
            guard let self else { return }
            if let message { self.status = .paused(message) } else if case .paused = self.status { self.status = .running }
        }
        frames.onScan = { [weak self] features in self?.finishScan(features) }
        frames.onTrack = { [weak self] box in self?.updateTracking(box) }
        frames.onLive = { [weak self] features in self?.updateCoach(features) }
    }

    var isRunning: Bool { status == .running }
    var hasManualControls: Bool {
        capabilities.supportsManualExposure || capabilities.supportsManualFocus || capabilities.supportsManualWhiteBalance
    }
    var supportsAnyRAW: Bool { capabilities.supportsRAW || capabilities.supportsProRAW }

    // MARK: Session

    func start() async {
        switch CameraService.authorization() {
        case .denied, .restricted:
            status = .denied
            return
        case .notDetermined:
            status = .starting
            guard await CameraService.requestAccess() else { status = .denied; return }
        default: break
        }
        guard CameraService.bestDevice(position) != nil else { status = .unavailable; return }
        status = .starting
        do {
            capabilities = try await service.start(position: position)
            status = .running
            if isCoaching { frames.setLive(interval: 0.2) }
            if !supportsAnyRAW { setRaw(.off) } else if rawMode == .proRAW, !capabilities.supportsProRAW { setRaw(.raw) }
            reapplyManual()
        } catch {
            status = (error as? CameraError) == .unavailable ? .unavailable
                : .failed((error as? LocalizedError)?.errorDescription ?? "The camera couldn't start.")
        }
    }

    func stop() {
        frames.setLive(interval: nil)
        frames.stopTracking()
        readingsTask?.cancel()
        if torch { setTorch(false) }
        service.stop()
        if status == .running || status == .starting { status = .idle }
    }

    func flip() async {
        guard capabilities.canFlip else { return }
        position = position == .back ? .front : .back
        clearFrame()
        manual = ManualSettings()
        exposureBias = 0
        await start()
    }

    // MARK: Controls

    /// Zoom in Camera-app units, clamped to what this camera can do. Returns the value applied.
    @discardableResult
    func setZoom(_ zoom: CGFloat, animated: Bool = false) -> CGFloat {
        let value = min(max(zoom, capabilities.minZoom), max(capabilities.minZoom, capabilities.maxZoom))
        service.setZoom(value, animated: animated)
        self.zoom = value
        return value
    }

    func setExposureBias(_ value: Float) {
        exposureBias = min(max(value, capabilities.minExposureBias), capabilities.maxExposureBias)
        service.setExposureBias(exposureBias)
    }

    func focus(atLayerPoint point: CGPoint, lock: Bool) {
        guard let previewLayer else { return }
        service.focus(at: CameraService.devicePoint(point, in: previewLayer), lock: lock)
        if manual.lensPosition != nil { manual.lensPosition = nil }
    }

    func setManual(_ settings: ManualSettings) {
        manual = settings
        reapplyManual()
    }

    private func reapplyManual() {
        if capabilities.supportsManualExposure { service.setManualExposure(iso: manual.iso, seconds: manual.shutterSeconds) }
        if capabilities.supportsManualFocus { service.setLensPosition(manual.lensPosition) }
        if capabilities.supportsManualWhiteBalance { service.setWhiteBalance(kelvin: manual.kelvin, tint: manual.tint) }
    }

    func setTorch(_ on: Bool) {
        guard capabilities.hasTorch else { return }
        torch = on
        service.setTorch(on)
    }

    /// Polls ISO, shutter, lens and white balance while the manual controls are open.
    func watchReadings(_ on: Bool) {
        readingsTask?.cancel()
        guard on else { return }
        readingsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.readings = await self.service.readings()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    func cycleRaw() {
        let options: [RawCaptureMode] = [.off] + (capabilities.supportsRAW ? [.raw] : []) + (capabilities.supportsProRAW ? [.proRAW] : [])
        let index = options.firstIndex(of: rawMode) ?? 0
        setRaw(options[(index + 1) % options.count])
    }

    // MARK: Live framing coach

    /// Re-analyzes the scene about five times a second and keeps a steady framing target with live advice.
    func startCoaching() {
        isCoaching = true
        coachMargin = 0.08
        if isRunning { frames.setLive(interval: 0.2) }
    }

    func stopCoaching() {
        isCoaching = false
        frames.setLive(interval: nil)
        coachPlan = nil
        coachAdvice = nil
        coachAlternative = nil
        coachNotes = []
    }

    /// Switches to the other framing idea and holds it more firmly (it was chosen on purpose).
    func useAlternative() {
        guard let alternative = coachAlternative else { return }
        coachAlternative = coachPlan
        coachPlan = alternative
        coachMargin = 0.2
        if let features = lastFeatures { updateCoach(features) }
    }

    var viewContext: ViewContext {
        ViewContext(visible: AspectFillMapping.visibleRect(imageAspect: imageAspect, viewSize: CGSize(width: captureAspect, height: 1)),
                    zoom: zoom, minZoom: capabilities.minZoom, maxZoom: max(capabilities.minZoom, capabilities.maxZoom),
                    isFront: position == .front)
    }

    private func updateCoach(_ features: SceneFeatures) {
        guard isCoaching else { return }
        lastFeatures = features
        imageAspect = features.imageAspect
        coachNotes = CompositionEngine.exposureAndLevelGuidance(features, isFrontCamera: position == .front)
        let view = viewContext
        let candidates = FramingCoach.plans(features, view: view, aspect: captureAspect)
        guard !candidates.isEmpty else {
            // A missed detection or two shouldn't wipe the target; after a second with nothing, say so.
            let since = coachLostSince ?? Date()
            coachLostSince = since
            if Date().timeIntervalSince(since) > 1 {
                coachPlan = nil
                coachAdvice = nil
                coachAlternative = nil
            }
            return
        }
        coachLostSince = nil
        guard let plan = FramingCoach.stabilized(previous: coachPlan, candidates: candidates, margin: coachMargin) else { return }
        coachPlan = plan
        coachAlternative = candidates.first { !$0.sameIdea(as: plan) }
        let horizonNow = features.horizon.map { ($0.y - view.visible.minY) / view.visible.height }
        let advice = FramingCoach.advice(for: plan, view: view, horizonNow: horizonNow)
        if advice.isAligned, coachAdvice?.isAligned != true { alignedPulse += 1 }
        coachAdvice = advice
    }

    /// Fallback: crop the next photo to the best framing inside what the camera sees (no moving needed).
    func cropInstead() {
        guard let features = lastFeatures,
              let best = CompositionEngine.analyze(features, aspect: captureAspect, isFrontCamera: position == .front).primary else { return }
        frame = best.rect
        frameIsCustom = false
        frames.startTracking(best.subject.box)
        trackedBox = best.subject.box
        subjectLost = false
        updateAlignment()
    }

    // MARK: Composition scan

    func startScan() {
        guard isRunning else { return }
        showsAlternative = false
        scan = .scanning
        frames.requestScan(frames: 3)
    }

    private func finishScan(_ features: SceneFeatures) {
        lastFeatures = features
        imageAspect = features.imageAspect
        if let tap = pendingSubjectTap {
            pendingSubjectTap = nil
            chooseSubject(at: tap, features: features)
            return
        }
        guard scan == .scanning else { return }
        scan = .result(CompositionEngine.analyze(features, aspect: aspectValue(composeAspect), isFrontCamera: position == .front))
    }

    var scanResult: CompositionResult? {
        if case .result(let result) = scan { return result }
        return nil
    }

    var shownSuggestion: CompositionSuggestion? {
        guard let result = scanResult else { return nil }
        return showsAlternative ? (result.alternative ?? result.primary) : result.primary
    }

    func toggleAlternative() { showsAlternative.toggle() }

    /// Uses the suggested framing for the next photo and follows its subject to show alignment.
    func acceptSuggestion() {
        guard let suggestion = shownSuggestion else { return }
        frame = suggestion.rect
        frameIsCustom = false
        scan = .idle
        frames.startTracking(suggestion.subject.box)
        trackedBox = suggestion.subject.box
        subjectLost = false
        updateAlignment()
    }

    func dismissScan() {
        scan = .idle
        showsAlternative = false
    }

    // MARK: Custom frame and tracking

    /// Starts or replaces the custom frame (image coordinates), constrained to the compose aspect.
    func setCustomFrame(_ rect: CGRect) {
        frame = Self.constrained(rect, aspect: aspectValue(composeAspect), imageAspect: imageAspect)
        frameIsCustom = true
        updateAlignment()
    }

    func clearFrame() {
        frame = nil
        frameIsCustom = false
        frames.stopTracking()
        trackedBox = nil
        alignment = nil
        subjectLost = false
    }

    /// Picks the subject under a tap (face, person or object found there), else a box around the tap.
    func selectSubject(at point: CGPoint) {
        pendingSubjectTap = point
        frames.requestScan(frames: 1)
    }

    private func chooseSubject(at point: CGPoint, features: SceneFeatures) {
        let hits = features.subjects.filter { $0.box.insetBy(dx: -0.02, dy: -0.02).contains(point) }
        let box = hits.min { $0.box.width * $0.box.height < $1.box.width * $1.box.height }?.box
            ?? CGRect(x: point.x - 0.09, y: point.y - 0.09 * imageAspect, width: 0.18, height: 0.18 * imageAspect)
        frames.startTracking(box)
        trackedBox = box
        subjectLost = false
        updateAlignment()
    }

    private func updateTracking(_ box: CGRect?) {
        guard trackedBox != nil else { return }
        if let box {
            trackedBox = box
            subjectLost = false
        } else {
            subjectLost = true
            frames.stopTracking()
        }
        updateAlignment()
    }

    private func updateAlignment() {
        guard let frame, let trackedBox, !subjectLost else { alignment = nil; return }
        let wasAligned = alignment?.isAligned ?? false
        alignment = CompositionEngine.alignment(subject: trackedBox, in: frame)
        if alignment?.isAligned == true, !wasAligned { alignedPulse += 1 }
    }

    /// Bumps when the subject first lines up (drives a haptic tap).
    private(set) var alignedPulse = 0

    func aspectValue(_ option: CaptureAspect?) -> CGFloat? { option?.ratio }

    /// Fits `rect` to `aspect` (pixel width / height) around its center, inside the image.
    static func constrained(_ rect: CGRect, aspect: CGFloat?, imageAspect: CGFloat) -> CGRect {
        var r = rect.standardized
        if let aspect, imageAspect > 0 {
            // Normalized width / height that gives the pixel aspect.
            let k = aspect / imageAspect
            let area = max(r.width * r.height, 0.0025)
            var w = sqrt(area * k), h = w / k
            if w > 1 { w = 1; h = w / k }
            if h > 1 { h = 1; w = h * k }
            r = CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
        }
        r.size.width = min(max(r.width, 0.05), 1)
        r.size.height = min(max(r.height, 0.05), 1)
        r.origin.x = min(max(r.minX, 0), 1 - r.width)
        r.origin.y = min(max(r.minY, 0), 1 - r.height)
        return r
    }

    // MARK: Capture

    func capture(flash: FlashSetting, heif: Bool) async throws -> CapturedPhoto {
        guard !isCapturing else { throw CameraError.busy }
        isCapturing = true
        defer { isCapturing = false }
        let mode: AVCaptureDevice.FlashMode = switch flash {
        case .off: .off
        case .auto: .auto
        case .on: .on
        }
        return try await service.capture(CaptureRequest(flash: mode, heif: heif, raw: supportsAnyRAW ? rawMode : .off))
    }
}
