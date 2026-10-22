import AVFoundation
import CoreImage
import ImageIO
import UIKit

/// What the current camera can really do. Controls the hardware lacks are hidden or disabled, never faked.
struct CameraCapabilities: Equatable, Sendable {
    var position: AVCaptureDevice.Position = .back
    var deviceName = ""
    var hasFlash = false
    var hasTorch = false
    var canFlip = false
    var supportsManualExposure = false
    var supportsManualFocus = false
    var supportsManualWhiteBalance = false
    var minISO: Float = 0
    var maxISO: Float = 0
    var minExposureDuration: Double = 0
    var maxExposureDuration: Double = 0
    var minExposureBias: Float = 0
    var maxExposureBias: Float = 0
    /// Zoom as the Camera app labels it (0.5 = ultra wide when there is one).
    var minZoom: CGFloat = 1
    var maxZoom: CGFloat = 1
    var zoomPresets: [CGFloat] = [1]
    var supportsRAW = false
    var supportsProRAW = false
    var supportsHEIF = false
    var maxPhotoSize = CGSize.zero
}

enum RawCaptureMode: String, CaseIterable, Codable, Sendable {
    case off, raw, proRAW
    var label: String {
        switch self {
        case .off: "Off"
        case .raw: "RAW"
        case .proRAW: "ProRAW"
        }
    }
}

/// What the camera is doing right now. `offset` is the meter reading in stops: 0 is what the camera
/// considers correct, negative is darker, positive brighter.
struct CameraReadings: Equatable, Sendable {
    var iso: Float
    var seconds: Double
    var lens: Float
    var kelvin: Float
    var offset: Float
}

/// Shutter speeds and ISO values for the exposure rulers (third stops, like a camera dial).
enum ExposureStops {
    static let shutterSeconds: [Double] = [
        1.0 / 8000, 1.0 / 6400, 1.0 / 5000, 1.0 / 4000, 1.0 / 3200, 1.0 / 2500, 1.0 / 2000, 1.0 / 1600, 1.0 / 1250, 1.0 / 1000,
        1.0 / 800, 1.0 / 640, 1.0 / 500, 1.0 / 400, 1.0 / 320, 1.0 / 250, 1.0 / 200, 1.0 / 160, 1.0 / 125, 1.0 / 100, 1.0 / 80,
        1.0 / 60, 1.0 / 50, 1.0 / 40, 1.0 / 30, 1.0 / 25, 1.0 / 20, 1.0 / 15, 1.0 / 13, 1.0 / 10, 1.0 / 8, 1.0 / 6, 1.0 / 5,
        1.0 / 4, 0.3, 0.4, 0.5, 0.6, 0.8, 1,
    ]
    static let isoValues: [Float] = [
        25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000,
        6400, 8000, 10000, 12800,
    ]

    /// Labeled ticks on the rulers (whole stops).
    static let shutterLabels: Set<Double> = [1.0 / 8000, 1.0 / 4000, 1.0 / 2000, 1.0 / 1000, 1.0 / 500, 1.0 / 250, 1.0 / 125,
                                             1.0 / 60, 1.0 / 30, 1.0 / 15, 1.0 / 8, 1.0 / 4, 0.5, 1]
    static let isoLabels: Set<Float> = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000]

    static func shutters(in range: ClosedRange<Double>) -> [Double] {
        shutterSeconds.filter { $0 >= range.lowerBound * 0.98 && $0 <= range.upperBound * 1.02 }
    }

    static func isos(in range: ClosedRange<Float>) -> [Float] {
        isoValues.filter { $0 >= range.lowerBound * 0.98 && $0 <= range.upperBound * 1.02 }
    }

    /// "1/250", "0.5\"", "1\"" (the way camera dials write shutter speeds).
    static func shutterLabel(_ s: Double) -> String {
        if s >= 0.3 { return s >= 1 ? "\(Int(s.rounded()))\"" : String(format: "%.1f\"", s) }
        return "1/\(Int((1 / s).rounded()))"
    }
}

/// One capture's files. `rawData` is a real DNG from the sensor (Bayer RAW or Apple ProRAW), never a relabeled JPEG.
struct CapturedPhoto: Sendable {
    let processedData: Data
    let processedType: String
    let rawData: Data?
    let rawKind: RawCaptureMode
}

struct CaptureRequest: Sendable {
    var flash: AVCaptureDevice.FlashMode = .off
    var heif = true
    var raw: RawCaptureMode = .off
}

enum CameraError: LocalizedError, Equatable {
    case denied, unavailable, configurationFailed, captureFailed(String), busy

    var errorDescription: String? {
        switch self {
        case .denied: "Camera access is off. Turn it on in Settings > Privacy & Security > Camera > FrameCraft."
        case .unavailable: "No camera is available on this device."
        case .configurationFailed: "The camera couldn't be set up. Close other camera apps and try again."
        case .captureFailed(let reason): "The photo couldn't be taken: \(reason)"
        case .busy: "A photo is still being taken."
        }
    }
}

/// Owns the AVCaptureSession. Every session and device call runs on `sessionQueue`; callbacks come back on
/// the main actor. Frames for analysis and the live look arrive on `frameQueue` through `onFrame`.
final class CameraService: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let frameQueue = DispatchQueue(label: "camera.frames", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var inFlight: [Int64: PhotoCaptureDelegate] = [:]
    private var isConfigured = false

    /// Called on `frameQueue` with every preview-sized frame (portrait, mirrored like the preview for the front camera).
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Session problems (interruptions, runtime errors), on the main actor.
    var onStatus: (@MainActor (String?) -> Void)?

    var device: AVCaptureDevice? { input?.device }

    // MARK: Setup

    static func authorization() -> AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }

    static func requestAccess() async -> Bool { await AVCaptureDevice.requestAccess(for: .video) }

    static func bestDevice(_ position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = position == .front
            ? [.builtInTrueDepthCamera, .builtInWideAngleCamera]
            : [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        // The discovery session returns devices in the order of `types`, so the first is the most capable.
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position).devices.first
    }

    /// Configures (once) and starts the session with the camera at `position`.
    func start(position: AVCaptureDevice.Position) async throws -> CameraCapabilities {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [self] in
                do {
                    if !isConfigured || device?.position != position { try configure(position: position) }
                    if !session.isRunning { session.startRunning() }
                    continuation.resume(returning: capabilities())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure(position: AVCaptureDevice.Position) throws {
        guard let device = Self.bestDevice(position) else { throw CameraError.unavailable }
        let newInput: AVCaptureDeviceInput
        do { newInput = try AVCaptureDeviceInput(device: device) } catch { throw CameraError.configurationFailed }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        if let input { session.removeInput(input) }
        guard session.canAddInput(newInput) else {
            if let input { session.addInput(input) }
            throw CameraError.configurationFailed
        }
        session.addInput(newInput)
        input = newInput

        if !session.outputs.contains(photoOutput) {
            guard session.canAddOutput(photoOutput) else { throw CameraError.configurationFailed }
            session.addOutput(photoOutput)
        }
        if !session.outputs.contains(videoOutput) {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        }

        // Largest photo the active format offers, best quality, and ProRAW switched on where it exists
        // (it must be enabled before capture settings can ask for it).
        if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            photoOutput.maxPhotoDimensions = largest
        }
        photoOutput.maxPhotoQualityPrioritization = .quality
        photoOutput.isAppleProRAWEnabled = photoOutput.isAppleProRAWSupported

        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = position == .front
            }
        }
        rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)

        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            // Start at 1× (the wide camera) like the Camera app, not the ultra wide.
            device.videoZoomFactor = clampFactor(1 / Self.multiplier(device), device)
            device.unlockForConfiguration()
        } catch {}

        isConfigured = true
        observe()
    }

    private var observers: [NSObjectProtocol] = []

    private func observe() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int).flatMap { AVCaptureSession.InterruptionReason(rawValue: $0) }
            let text: String = switch reason {
            case .videoDeviceInUseByAnotherClient: "Camera in use by another app"
            case .videoDeviceNotAvailableWithMultipleForegroundApps: "Camera unavailable in Split View"
            case .videoDeviceNotAvailableDueToSystemPressure: "Camera paused: device too hot"
            default: "Camera paused"
            }
            MainActor.assumeIsolated { self?.onStatus?(text) }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onStatus?(nil) }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onStatus?("Camera error, restarting…") }
            self?.sessionQueue.async {
                guard let self else { return }
                self.session.startRunning()
                let running = self.session.isRunning
                DispatchQueue.main.async { MainActor.assumeIsolated { self.onStatus?(running ? nil : "Camera stopped") } }
            }
        })
    }

    // MARK: Capabilities and zoom mapping

    /// Device zoom factor × multiplier = the number the Camera app shows (1 = wide camera).
    static func multiplier(_ device: AVCaptureDevice) -> CGFloat {
        CGFloat(device.displayVideoZoomFactorMultiplier)
    }

    private func clampFactor(_ factor: CGFloat, _ device: AVCaptureDevice) -> CGFloat {
        min(max(factor, device.minAvailableVideoZoomFactor), min(device.maxAvailableVideoZoomFactor, 60))
    }

    private func capabilities() -> CameraCapabilities {
        guard let device else { return CameraCapabilities() }
        var c = CameraCapabilities()
        c.position = device.position
        c.deviceName = device.localizedName
        c.hasFlash = device.hasFlash && !photoOutput.supportedFlashModes.isEmpty
        c.hasTorch = device.hasTorch && device.isTorchModeSupported(.on)
        c.canFlip = Self.bestDevice(device.position == .back ? .front : .back) != nil
        c.supportsManualExposure = device.isExposureModeSupported(.custom)
        c.supportsManualFocus = device.isFocusModeSupported(.locked) && device.isLockingFocusWithCustomLensPositionSupported
        c.supportsManualWhiteBalance = device.isWhiteBalanceModeSupported(.locked) && device.isLockingWhiteBalanceWithCustomDeviceGainsSupported
        c.minISO = device.activeFormat.minISO
        c.maxISO = device.activeFormat.maxISO
        c.minExposureDuration = device.activeFormat.minExposureDuration.seconds
        c.maxExposureDuration = min(device.activeFormat.maxExposureDuration.seconds, 1)
        c.minExposureBias = device.minExposureTargetBias
        c.maxExposureBias = device.maxExposureTargetBias
        let m = Self.multiplier(device)
        c.minZoom = device.minAvailableVideoZoomFactor * m
        c.maxZoom = clampFactor(.greatestFiniteMagnitude, device) * m
        c.zoomPresets = Self.zoomPresets(minZoom: c.minZoom, maxZoom: c.maxZoom,
                                         switchOvers: device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) * m })
        c.supportsRAW = photoOutput.availableRawPhotoPixelFormatTypes.contains { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
        c.supportsProRAW = photoOutput.isAppleProRAWEnabled
            && photoOutput.availableRawPhotoPixelFormatTypes.contains { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
        c.supportsHEIF = photoOutput.availablePhotoCodecTypes.contains(.hevc)
        c.maxPhotoSize = CGSize(width: Int(photoOutput.maxPhotoDimensions.width), height: Int(photoOutput.maxPhotoDimensions.height))
        return c
    }

    /// Buttons like the Camera app: 0.5 for an ultra wide, 1, 2 (sensor crop), then each telephoto lens.
    static func zoomPresets(minZoom: CGFloat, maxZoom: CGFloat, switchOvers: [CGFloat]) -> [CGFloat] {
        var presets: [CGFloat] = []
        if minZoom < 0.95 { presets.append(0.5) }
        presets.append(1)
        if maxZoom >= 2 { presets.append(2) }
        for lens in switchOvers where lens > 2.2 && lens <= maxZoom { presets.append((lens * 2).rounded() / 2) }
        return Array(Set(presets)).sorted()
    }

    // MARK: Controls (all on the session queue)

    private func withDevice(_ body: @escaping (AVCaptureDevice) throws -> Void) {
        sessionQueue.async { [self] in
            guard let device else { return }
            do {
                try device.lockForConfiguration()
                try body(device)
                device.unlockForConfiguration()
            } catch {
                device.unlockForConfiguration()
            }
        }
    }

    /// `zoom` in Camera-app units. Ramps briefly so lens switches look smooth.
    func setZoom(_ zoom: CGFloat, animated: Bool = false) {
        withDevice { [self] device in
            let factor = clampFactor(zoom / Self.multiplier(device), device)
            if animated { device.ramp(toVideoZoomFactor: factor, withRate: 12) } else { device.videoZoomFactor = factor }
        }
    }

    /// Focus and meter at a point in device coordinates (0...1, landscape sensor space).
    func focus(at point: CGPoint, lock: Bool) {
        withDevice { device in
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = point }
            if device.isFocusModeSupported(lock ? .autoFocus : .continuousAutoFocus) {
                device.focusMode = lock ? .autoFocus : .continuousAutoFocus
            }
            if device.isExposurePointOfInterestSupported, device.exposureMode != .custom { device.exposurePointOfInterest = point }
            if device.exposureMode != .custom, device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = lock ? .autoExpose : .continuousAutoExposure
            }
            device.isSubjectAreaChangeMonitoringEnabled = !lock
        }
    }

    func setExposureBias(_ bias: Float) {
        withDevice { device in
            device.setExposureTargetBias(min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias), completionHandler: nil)
        }
    }

    /// nil for both returns to auto exposure. One of them nil keeps the camera's current value for it.
    func setManualExposure(iso: Float?, seconds: Double?) {
        withDevice { device in
            guard iso != nil || seconds != nil else {
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                return
            }
            guard device.isExposureModeSupported(.custom) else { return }
            let format = device.activeFormat
            let duration: CMTime = seconds.map {
                let clamped = min(max($0, format.minExposureDuration.seconds), format.maxExposureDuration.seconds)
                return CMTime(seconds: clamped, preferredTimescale: 1_000_000)
            } ?? AVCaptureDevice.currentExposureDuration
            let isoValue = iso.map { min(max($0, format.minISO), format.maxISO) } ?? AVCaptureDevice.currentISO
            device.setExposureModeCustom(duration: duration, iso: isoValue, completionHandler: nil)
        }
    }

    /// 0 (near) ... 1 (far); nil = continuous autofocus.
    func setLensPosition(_ position: Float?) {
        withDevice { device in
            if let position, device.isLockingFocusWithCustomLensPositionSupported {
                device.setFocusModeLocked(lensPosition: min(max(position, 0), 1), completionHandler: nil)
            } else if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
        }
    }

    /// Kelvin and tint; nil = auto white balance.
    func setWhiteBalance(kelvin: Float?, tint: Float) {
        withDevice { device in
            guard let kelvin, device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else {
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
                return
            }
            var gains = device.deviceWhiteBalanceGains(for: .init(temperature: kelvin, tint: tint))
            let maxGain = device.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1), maxGain)
            gains.greenGain = min(max(gains.greenGain, 1), maxGain)
            gains.blueGain = min(max(gains.blueGain, 1), maxGain)
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        }
    }

    func setTorch(_ on: Bool) {
        withDevice { device in
            guard device.hasTorch, device.isTorchModeSupported(on ? .on : .off) else { return }
            device.torchMode = on ? .on : .off
        }
    }

    /// Live readouts: what the camera is using now, and how far that is from its own meter.
    func readings() async -> CameraReadings? {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                guard let device else { continuation.resume(returning: nil); return }
                let kelvin = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains).temperature
                continuation.resume(returning: CameraReadings(iso: device.iso, seconds: device.exposureDuration.seconds,
                                                              lens: device.lensPosition, kelvin: kelvin,
                                                              offset: device.exposureTargetOffset))
            }
        }
    }

    /// Maps a point in the preview layer to device coordinates (needs the layer, so main actor).
    @MainActor
    static func devicePoint(_ layerPoint: CGPoint, in layer: AVCaptureVideoPreviewLayer) -> CGPoint {
        layer.captureDevicePointConverted(fromLayerPoint: layerPoint)
    }

    // MARK: Capture

    func capture(_ request: CaptureRequest) async throws -> CapturedPhoto {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [self] in
                guard session.isRunning, let device else {
                    continuation.resume(throwing: CameraError.captureFailed("the camera isn't running"))
                    return
                }
                let settings = makeSettings(request)
                if let connection = photoOutput.connection(with: .video) {
                    if let angle = rotation?.videoRotationAngleForHorizonLevelCapture,
                       connection.isVideoRotationAngleSupported(angle) {
                        connection.videoRotationAngle = angle
                    }
                    // Front photos match the mirrored preview, as the user framed them.
                    if connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = device.position == .front
                    }
                }
                let rawKind: RawCaptureMode = settings.rawPhotoPixelFormatType == 0 ? .off
                    : (AVCapturePhotoOutput.isAppleProRAWPixelFormat(settings.rawPhotoPixelFormatType) ? .proRAW : .raw)
                let delegate = PhotoCaptureDelegate(rawKind: rawKind) { [weak self] result in
                    self?.sessionQueue.async { self?.inFlight[settings.uniqueID] = nil }
                    continuation.resume(with: result)
                }
                inFlight[settings.uniqueID] = delegate
                photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    /// Only combinations the output reports as available, so AVFoundation never raises an exception.
    private func makeSettings(_ request: CaptureRequest) -> AVCapturePhotoSettings {
        let codec: AVVideoCodecType = request.heif && photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
        let processed: [String: Any] = [AVVideoCodecKey: codec]
        var settings = AVCapturePhotoSettings(format: processed)
        var isBayer = false
        if request.raw != .off {
            let wantPro = request.raw == .proRAW && photoOutput.isAppleProRAWEnabled
            let type = photoOutput.availableRawPhotoPixelFormatTypes.first {
                wantPro ? AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) : AVCapturePhotoOutput.isBayerRAWPixelFormat($0)
            }
            if let type {
                settings = AVCapturePhotoSettings(rawPixelFormatType: type, processedFormat: processed)
                isBayer = AVCapturePhotoOutput.isBayerRAWPixelFormat(type)
            }
        }
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        // Bayer RAW only allows speed prioritization; everything else gets the best quality.
        settings.photoQualityPrioritization = isBayer ? .speed : .quality
        if photoOutput.supportedFlashModes.contains(request.flash) { settings.flashMode = request.flash }
        return settings
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(buffer)
    }
}

/// Collects the processed photo and the optional RAW companion of one capture.
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let rawKind: RawCaptureMode
    private let completion: (Result<CapturedPhoto, Error>) -> Void
    private var processed: Data?
    private var processedType = "public.heic"
    private var raw: Data?
    private var failure: Error?

    init(rawKind: RawCaptureMode, completion: @escaping (Result<CapturedPhoto, Error>) -> Void) {
        self.rawKind = rawKind
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { failure = error; return }
        guard let data = photo.fileDataRepresentation() else { return }
        if photo.isRawPhoto {
            raw = data
        } else {
            processed = data
            processedType = Self.typeIdentifier(of: data)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let processed {
            completion(.success(CapturedPhoto(processedData: processed, processedType: processedType,
                                              rawData: raw, rawKind: raw == nil ? .off : rawKind)))
        } else {
            let reason = (error ?? failure)?.localizedDescription ?? "no image came back"
            completion(.failure(CameraError.captureFailed(reason)))
        }
    }

    static func typeIdentifier(of data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else { return "public.jpeg" }
        return type
    }
}
