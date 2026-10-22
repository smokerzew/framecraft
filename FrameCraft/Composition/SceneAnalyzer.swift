import CoreImage
import CoreVideo
import Vision

/// Measures one camera frame with Vision (faces, people, salient objects, horizon) plus a luminance sample.
/// Frames arrive already upright (portrait) and mirrored like the preview, so results map straight onto it.
enum SceneAnalyzer {
    static func analyze(_ buffer: CVPixelBuffer) -> SceneFeatures {
        var features = SceneFeatures()
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        features.imageAspect = height > 0 ? CGFloat(width) / CGFloat(height) : 0.75

        let faces = VNDetectFaceRectanglesRequest()
        let people = VNDetectHumanRectanglesRequest()
        people.upperBodyOnly = false
        let saliency = VNGenerateObjectnessBasedSaliencyImageRequest()
        let horizon = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
        try? handler.perform([faces, people, saliency, horizon])

        // Vision boxes are bottom-left origin; flip to top-left.
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height) }
        for face in faces.results ?? [] {
            features.subjects.append(SceneSubject(kind: .face, box: flip(face.boundingBox), confidence: Double(face.confidence)))
        }
        for person in people.results ?? [] {
            features.subjects.append(SceneSubject(kind: .person, box: flip(person.boundingBox), confidence: Double(person.confidence)))
        }
        for object in (saliency.results?.first?.salientObjects ?? []) {
            features.subjects.append(SceneSubject(kind: .salient, box: flip(object.boundingBox), confidence: Double(object.confidence)))
        }
        if let line = horizon.results?.first {
            // The horizon's own angle (counterclockwise positive). shortcut: sign only reasoned from the docs,
            // not yet checked on a device; if the level hint points the wrong way, negate this.
            features.horizonDegrees = Double(line.angle) * 180 / .pi
        }
        let luma = sampleLuminance(buffer)
        features.meanLuminance = luma.mean
        features.highlightClipping = luma.high
        features.shadowClipping = luma.low
        return features
    }

    /// Mean luminance and clipped fractions from a coarse grid of BGRA pixels.
    static func sampleLuminance(_ buffer: CVPixelBuffer) -> (mean: Double, high: Double, low: Double) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return (0.5, 0, 0) }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return (0.5, 0, 0) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let step = max(1, min(width, height) / 64)
        var sum = 0.0, high = 0, low = 0, count = 0
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let p = pixels + y * row + x * 4
                let l = (0.0722 * Double(p[0]) + 0.7152 * Double(p[1]) + 0.2126 * Double(p[2])) / 255
                sum += l
                if l >= 0.98 { high += 1 }
                if l <= 0.02 { low += 1 }
                count += 1
            }
        }
        guard count > 0 else { return (0.5, 0, 0) }
        return (sum / Double(count), Double(high) / Double(count), Double(low) / Double(count))
    }
}

/// Follows one chosen subject from frame to frame with Vision's object tracker.
final class SubjectTracker {
    private let handler = VNSequenceRequestHandler()
    private var observation: VNDetectedObjectObservation?

    var isTracking: Bool { observation != nil }

    /// `box` in top-left normalized image coordinates.
    func start(box: CGRect) {
        let clamped = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard clamped.width > 0.01, clamped.height > 0.01 else { observation = nil; return }
        observation = VNDetectedObjectObservation(boundingBox: CGRect(
            x: clamped.minX, y: 1 - clamped.maxY, width: clamped.width, height: clamped.height))
    }

    func stop() { observation = nil }

    /// The subject's new box (top-left normalized), or nil once it's lost.
    func update(_ buffer: CVPixelBuffer) -> CGRect? {
        guard let observation else { return nil }
        let request = VNTrackObjectRequest(detectedObjectObservation: observation)
        request.trackingLevel = .accurate
        do {
            try handler.perform([request], on: buffer, orientation: .up)
        } catch {
            self.observation = nil
            return nil
        }
        guard let result = request.results?.first as? VNDetectedObjectObservation, result.confidence >= 0.3 else {
            self.observation = nil
            return nil
        }
        self.observation = result
        let b = result.boundingBox
        return CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
    }
}

/// Runs on the camera's frame queue: hands frames to the live look, and to scanning and tracking at a
/// limited rate on its own queue so the preview never waits for Vision.
final class FrameRouter: @unchecked Sendable {
    private let lock = NSLock()
    private let analysisQueue = DispatchQueue(label: "camera.analysis", qos: .userInitiated)
    private var busy = false
    private var scanRequests = 0
    private var scanFrames: [SceneFeatures] = []
    private var tracker: SubjectTracker?
    private var latest: CVPixelBuffer?
    private var lastTrack = Date.distantPast

    var look: LiveLookRenderer?
    var onScan: (@MainActor (SceneFeatures) -> Void)?
    var onTrack: (@MainActor (CGRect?) -> Void)?

    func handle(_ buffer: CVPixelBuffer) {
        look?.push(buffer)
        lock.lock()
        latest = buffer
        let wantsScan = scanRequests > 0
        let wantsTrack = tracker != nil && Date().timeIntervalSince(lastTrack) >= 1.0 / 15
        guard !busy, wantsScan || wantsTrack else { lock.unlock(); return }
        busy = true
        if wantsTrack { lastTrack = Date() }
        let tracker = self.tracker
        lock.unlock()

        analysisQueue.async { [self] in
            if wantsScan {
                let features = SceneAnalyzer.analyze(buffer)
                lock.lock()
                scanFrames.append(features)
                scanRequests -= 1
                let done = scanRequests == 0
                let frames = scanFrames
                if done { scanFrames = [] }
                lock.unlock()
                if done, let merged = Self.merge(frames) {
                    let callback = onScan
                    DispatchQueue.main.async { MainActor.assumeIsolated { callback?(merged) } }
                }
            } else if let tracker {
                let box = tracker.update(buffer)
                let callback = onTrack
                DispatchQueue.main.async { MainActor.assumeIsolated { callback?(box) } }
            }
            lock.lock()
            busy = false
            lock.unlock()
        }
    }

    /// Analyzes the next few frames and reports their combined measurements once.
    func requestScan(frames: Int = 3) {
        lock.lock()
        scanRequests = frames
        scanFrames = []
        lock.unlock()
    }

    func startTracking(_ box: CGRect) {
        let tracker = SubjectTracker()
        tracker.start(box: box)
        lock.lock()
        self.tracker = tracker.isTracking ? tracker : nil
        lock.unlock()
    }

    func stopTracking() {
        lock.lock()
        tracker = nil
        lock.unlock()
    }

    /// The newest frame as an image (filter tiles and the scan freeze frame).
    func latestImage(maxSide: CGFloat = 480) -> CGImage? {
        lock.lock()
        let buffer = latest
        lock.unlock()
        guard let buffer else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, maxSide / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return PhotoRenderer.shared.context.createCGImage(small, from: small.extent)
    }

    /// Several frames smooth out flicker: average the measurements, keep subjects seen in the middle frame.
    static func merge(_ frames: [SceneFeatures]) -> SceneFeatures? {
        guard !frames.isEmpty else { return nil }
        var merged = frames[frames.count / 2]
        let n = Double(frames.count)
        merged.meanLuminance = frames.map(\.meanLuminance).reduce(0, +) / n
        merged.highlightClipping = frames.map(\.highlightClipping).reduce(0, +) / n
        merged.shadowClipping = frames.map(\.shadowClipping).reduce(0, +) / n
        let tilts = frames.compactMap(\.horizonDegrees)
        merged.horizonDegrees = tilts.isEmpty ? nil : tilts.reduce(0, +) / Double(tilts.count)
        return merged
    }
}
