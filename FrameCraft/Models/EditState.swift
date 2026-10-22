import CoreGraphics
import Foundation

/// Every edit applied to a photo, as data. The original file is never changed; rendering applies this.
struct EditState: Codable, Equatable, Sendable {
    // Look
    var look: FilmLook = .none
    var lookStrength: Double = 1

    // Light
    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var fade: Double = 0
    var temperature: Double = 0
    var tint: Double = 0

    // Color
    var saturation: Double = 0
    var vibrance: Double = 0
    var mixer = ColorMixer()
    var gradeShadowHue: Double = 210
    var gradeShadowAmount: Double = 0
    var gradeHighlightHue: Double = 40
    var gradeHighlightAmount: Double = 0
    var curves = ToneCurves()
    var calibration = ColorCalibration()

    // Effects
    var grain: Double = 0
    var halation: Double = 0
    var glow: Double = 0
    var lightLeak: Double = 0
    var dust: Double = 0
    var scratches: Double = 0
    var motionBlur: Double = 0
    var motionAngle: Double = 0
    var vignette: Double = 0

    // Geometry: crop (normalized, top-left origin, on the upright photo after rotation), quarter turns clockwise,
    // straighten in degrees.
    var cropRect = EditState.fullCrop
    var rotation = 0
    var straighten: Double = 0

    static let fullCrop = CGRect(x: 0, y: 0, width: 1, height: 1)

    var isIdentity: Bool { self == EditState() }
    var hasGeometry: Bool { cropRect != Self.fullCrop || rotation % 4 != 0 || abs(straighten) > 0.01 }

    init() {}

    /// Missing or invalid values fall back to defaults, so projects saved by older versions keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func number(_ key: CodingKeys, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            guard let v = try? c.decodeIfPresent(Double.self, forKey: key), v.isFinite else { return fallback }
            return min(max(v, range.lowerBound), range.upperBound)
        }
        look = (try? c.decodeIfPresent(FilmLook.self, forKey: .look)) ?? .none
        lookStrength = number(.lookStrength, 0...1, 1)
        for p in EditParameter.allCases {
            self[keyPath: p.keyPath] = number(CodingKeys(stringValue: p.storageKey) ?? .exposure, p.range, p.defaultValue)
        }
        mixer = (try? c.decodeIfPresent(ColorMixer.self, forKey: .mixer)) ?? ColorMixer()
        gradeShadowHue = number(.gradeShadowHue, 0...360, 210)
        gradeShadowAmount = number(.gradeShadowAmount, 0...1, 0)
        gradeHighlightHue = number(.gradeHighlightHue, 0...360, 40)
        gradeHighlightAmount = number(.gradeHighlightAmount, 0...1, 0)
        curves = (try? c.decodeIfPresent(ToneCurves.self, forKey: .curves)) ?? ToneCurves()
        calibration = (try? c.decodeIfPresent(ColorCalibration.self, forKey: .calibration)) ?? ColorCalibration()
        motionAngle = number(.motionAngle, -90...90, 0)
        let crop = (try? c.decodeIfPresent(CGRect.self, forKey: .cropRect)) ?? Self.fullCrop
        cropRect = Self.fullCrop.insetBy(dx: -0.0001, dy: -0.0001).contains(crop) && crop.width > 0.02 && crop.height > 0.02
            ? crop : Self.fullCrop
        rotation = (((try? c.decodeIfPresent(Int.self, forKey: .rotation)) ?? 0) % 4 + 4) % 4
        straighten = number(.straighten, -45...45, 0)
    }

    subscript(parameter: EditParameter) -> Double {
        get { self[keyPath: parameter.keyPath] }
        set { self[keyPath: parameter.keyPath] = parameter.clamp(newValue) }
    }

    /// Only these groups back to their defaults (per-section Reset).
    func resetting(_ group: EditGroup) -> EditState {
        let d = EditState()
        var next = self
        for p in EditParameter.allCases where p.group == group { next[p] = p.defaultValue }
        switch group {
        case .look:
            next.look = d.look
            next.lookStrength = d.lookStrength
        case .color:
            next.mixer = d.mixer
            next.gradeShadowHue = d.gradeShadowHue
            next.gradeShadowAmount = d.gradeShadowAmount
            next.gradeHighlightHue = d.gradeHighlightHue
            next.gradeHighlightAmount = d.gradeHighlightAmount
            next.curves = d.curves
            next.calibration = d.calibration
        case .effects:
            next.motionAngle = d.motionAngle
        case .crop:
            next.cropRect = d.cropRect
            next.rotation = d.rotation
            next.straighten = d.straighten
        case .light: break
        }
        return next
    }
}

enum EditGroup: String, CaseIterable, Identifiable, Sendable {
    case look, light, color, effects, crop
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
}

/// The slider-backed edits. Each knows its range, default, group and label.
enum EditParameter: String, CaseIterable, Identifiable, Sendable {
    case exposure, contrast, highlights, shadows, whites, blacks, fade, temperature, tint
    case saturation, vibrance
    case grain, halation, glow, lightLeak, dust, scratches, motionBlur, vignette

    var id: String { rawValue }
    var storageKey: String { rawValue }

    var title: String {
        switch self {
        case .lightLeak: "Light Leak"
        case .motionBlur: "Motion Blur"
        default: rawValue.capitalized
        }
    }

    var group: EditGroup {
        switch self {
        case .exposure, .contrast, .highlights, .shadows, .whites, .blacks, .fade, .temperature, .tint: .light
        case .saturation, .vibrance: .color
        case .grain, .halation, .glow, .lightLeak, .dust, .scratches, .motionBlur, .vignette: .effects
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .exposure: -2...2
        case .fade, .grain, .halation, .glow, .lightLeak, .dust, .scratches, .motionBlur: 0...1
        default: -1...1
        }
    }

    var defaultValue: Double { 0 }

    var keyPath: WritableKeyPath<EditState, Double> {
        switch self {
        case .exposure: \.exposure
        case .contrast: \.contrast
        case .highlights: \.highlights
        case .shadows: \.shadows
        case .whites: \.whites
        case .blacks: \.blacks
        case .fade: \.fade
        case .temperature: \.temperature
        case .tint: \.tint
        case .saturation: \.saturation
        case .vibrance: \.vibrance
        case .grain: \.grain
        case .halation: \.halation
        case .glow: \.glow
        case .lightLeak: \.lightLeak
        case .dust: \.dust
        case .scratches: \.scratches
        case .motionBlur: \.motionBlur
        case .vignette: \.vignette
        }
    }

    var systemImage: String {
        switch self {
        case .exposure: "plusminus.circle"
        case .contrast: "circle.lefthalf.filled"
        case .highlights: "circle.righthalf.filled.inverse"
        case .shadows: "circle.bottomhalf.filled"
        case .whites: "circle"
        case .blacks: "circle.fill"
        case .fade: "circle.dotted.circle"
        case .temperature: "thermometer.medium"
        case .tint: "drop.triangle"
        case .saturation: "drop"
        case .vibrance: "paintpalette"
        case .grain: "circle.dotted"
        case .halation: "sun.haze"
        case .glow: "sparkle"
        case .lightLeak: "light.max"
        case .dust: "aqi.medium"
        case .scratches: "scribble"
        case .motionBlur: "wind"
        case .vignette: "camera.aperture"
        }
    }

    func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// "+1.0 EV" for exposure, -100...100 for the rest.
    func format(_ value: Double) -> String {
        if self == .exposure { return String(format: "%+.1f EV", value) }
        let relative = Int((value * 100).rounded())
        return relative == 0 ? "0" : (range.lowerBound < 0 ? String(format: "%+ld", relative) : "\(relative)")
    }
}
