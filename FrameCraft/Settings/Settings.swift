import SwiftUI

/// UserDefaults keys used with @AppStorage. Preferences only, never photo data.
enum SettingsKey {
    static let controlStyle = "settings.controlStyle"
    static let gridStyle = "settings.gridStyle"
    static let gridOpacity = "settings.gridOpacity"
    static let showLevel = "settings.showLevel"
    static let showCenter = "settings.showCenter"
    static let captureFormat = "settings.captureFormat"
    static let exportFormat = "settings.exportFormat"
    static let rawMode = "camera.raw"
    static let removeLocation = "settings.removeLocation"
}

enum ControlStyle: String, CaseIterable, Identifiable {
    case glass, solid
    var id: String { rawValue }
    var label: String { self == .glass ? "Liquid Glass" : "Solid" }
}

enum GridStyle: String, CaseIterable, Identifiable {
    case off, thirds, fine
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Off"
        case .thirds: "Rule of Thirds"
        case .fine: "Fine Grid"
        }
    }
    var divisions: Int? {
        switch self {
        case .off: nil
        case .thirds: 3
        case .fine: 6
        }
    }
    var next: GridStyle {
        switch self {
        case .off: .thirds
        case .thirds: .fine
        case .fine: .off
        }
    }
}

/// The camera's flash mode.
enum FlashSetting: String, CaseIterable {
    case off, auto, on
    var label: String { rawValue.capitalized }
    var systemImage: String {
        switch self {
        case .off: "bolt.slash"
        case .auto: "bolt.badge.automatic"
        case .on: "bolt.fill"
        }
    }
    var next: FlashSetting {
        switch self {
        case .off: .auto
        case .auto: .on
        case .on: .off
        }
    }
}

/// Self-timer delay before the photo is taken.
enum TimerSetting: Int, CaseIterable {
    case off = 0, three = 3, ten = 10
    var label: String { self == .off ? "Off" : "\(rawValue)s" }
    var next: TimerSetting {
        switch self {
        case .off: .three
        case .three: .ten
        case .ten: .off
        }
    }
}

/// Capture framing. Each becomes the photo's real crop (stored with the edit, so the full sensor image is kept).
enum CaptureAspect: String, CaseIterable, Codable, Identifiable, Sendable {
    case threeFour = "3:4", fourFive = "4:5", nineSixteen = "9:16", square = "1:1"

    var id: String { rawValue }
    var label: String { rawValue }
    /// Width / height of the portrait frame.
    var ratio: CGFloat {
        switch self {
        case .threeFour: 3.0 / 4.0
        case .fourFive: 4.0 / 5.0
        case .nineSixteen: 9.0 / 16.0
        case .square: 1
        }
    }
    var next: CaptureAspect {
        let all = Self.allCases
        return all[((all.firstIndex(of: self) ?? 0) + 1) % all.count]
    }
}

/// Modes in the bottom carousel. PHOTO is the camera (✦ scans for a framing); CUSTOM lets you draw your own
/// frame and track a subject.
enum CameraMode: String, CaseIterable, Identifiable {
    case photo, custom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .photo: "PHOTO"
        case .custom: "CUSTOM"
        }
    }
    var explanation: String {
        switch self {
        case .photo: "The camera. Tap the sparkle button to scan the scene for a framing."
        case .custom: "Draw your own frame and tap a subject to see when it lines up."
        }
    }
}

enum ZoomLimits {
    static let minimum: CGFloat = 0.5
    static let maximum: CGFloat = 25
    static let presets: [CGFloat] = [0.5, 1, 2, 5]

    static func clamp(_ zoom: CGFloat) -> CGFloat {
        guard zoom.isFinite else { return 1 }
        return min(max(zoom, minimum), maximum)
    }

    static func label(for zoom: CGFloat) -> String {
        let rounded = (zoom * 10).rounded() / 10
        if rounded == 0.5 { return ".5" }
        return rounded.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(rounded)) : String(format: "%.1f", Double(rounded))
    }
}

enum FramingGeometry {
    /// Largest size with `ratio` (w/h) that fits in `container`.
    static func frameSize(ratio: CGFloat, in container: CGSize) -> CGSize {
        guard ratio > 0, container.width > 0, container.height > 0 else { return .zero }
        var width = container.width
        var height = width / ratio
        if height > container.height {
            height = container.height
            width = height * ratio
        }
        return CGSize(width: width, height: height)
    }
}

extension EnvironmentValues {
    /// System Reduce Motion.
    @Entry var cameraReduceMotion = false
    /// System Increase Contrast.
    @Entry var cameraHighContrast = false
    @Entry var cameraLargeLabels = false
    /// Degrees icons turn to stay upright when the phone is held sideways (0, 90 or -90).
    @Entry var cameraIconRotation: Double = 0
}

/// Turns a control's glyph upright in landscape, as the Camera app does (the layout itself stays put).
struct RotatesWithDevice: ViewModifier {
    @Environment(\.cameraIconRotation) private var degrees
    @Environment(\.cameraReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(degrees))
            .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.1), value: degrees)
    }
}

extension View {
    func rotatesWithDevice() -> some View { modifier(RotatesWithDevice()) }
}

/// Seeded random numbers, so generated textures (paper, dust) come out the same on every render.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// An error shown to the user.
struct AppAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}
