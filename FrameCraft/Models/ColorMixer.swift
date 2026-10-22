import Foundation

/// The eight color ranges of the Color Mixer (as in Lightroom/VSCO HSL).
enum ColorBand: Int, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, aqua, blue, purple, magenta

    var id: Int { rawValue }
    var label: String { String(describing: self).capitalized }

    /// Band center on the hue wheel, in degrees.
    var hue: Double { [0, 30, 60, 120, 180, 225, 270, 315][rawValue] }
}

enum MixerChannel: String, CaseIterable, Identifiable, Sendable {
    case hue, saturation, luminance

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Per-color hue, saturation and luminance. Every value is -1...1; 0 everywhere = no change.
struct ColorMixer: Equatable, Codable, Sendable {
    private(set) var hue = [Double](repeating: 0, count: 8)
    private(set) var saturation = [Double](repeating: 0, count: 8)
    private(set) var luminance = [Double](repeating: 0, count: 8)

    var isNeutral: Bool { self == ColorMixer() }

    init() {}

    /// Wrong-length or out-of-range saved values fall back to neutral / are clamped.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func values(_ key: CodingKeys) -> [Double] {
            let list = (try? c.decodeIfPresent([Double].self, forKey: key)) ?? []
            return list.count == 8 ? list.map { $0.isFinite ? min(max($0, -1), 1) : 0 } : [Double](repeating: 0, count: 8)
        }
        hue = values(.hue)
        saturation = values(.saturation)
        luminance = values(.luminance)
    }

    subscript(band: ColorBand, channel: MixerChannel) -> Double {
        get {
            switch channel {
            case .hue: hue[band.rawValue]
            case .saturation: saturation[band.rawValue]
            case .luminance: luminance[band.rawValue]
            }
        }
        set {
            let value = newValue.isFinite ? min(max(newValue, -1), 1) : 0
            switch channel {
            case .hue: hue[band.rawValue] = value
            case .saturation: saturation[band.rawValue] = value
            case .luminance: luminance[band.rawValue] = value
            }
        }
    }

    func isModified(_ band: ColorBand) -> Bool {
        MixerChannel.allCases.contains { self[band, $0] != 0 }
    }

    /// How much each band owns hue `h` (degrees). Neighbouring bands cross-fade smoothly; weights sum to 1.
    static func weights(hue h: Double) -> [Double] {
        let centers = ColorBand.allCases.map(\.hue)
        func delta(_ from: Double, _ to: Double) -> Double { // signed angle from → to, in (-180, 180]
            var d = (to - from).truncatingRemainder(dividingBy: 360)
            if d > 180 { d -= 360 }
            if d <= -180 { d += 360 }
            return d
        }
        func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }
        return centers.indices.map { i in
            let d = delta(centers[i], h)
            let neighbor = centers[(i + (d >= 0 ? 1 : centers.count - 1)) % centers.count]
            let span = abs(delta(centers[i], neighbor))
            let t = abs(d) / span
            return t < 1 ? 1 - smooth(t) : 0
        }
    }

    /// Maps one sRGB color (components 0...1). Grays are left alone: every change scales with how colorful the pixel is.
    func map(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let maxC = max(r, g, b), minC = min(r, g, b), chroma = maxC - minC
        guard chroma > 0.0001 else { return (r, g, b) }
        // RGB → HSL
        let l = (maxC + minC) / 2
        let s = chroma / (1 - abs(2 * l - 1))
        var h: Double
        if maxC == r { h = 60 * ((g - b) / chroma).truncatingRemainder(dividingBy: 6) }
        else if maxC == g { h = 60 * ((b - r) / chroma + 2) }
        else { h = 60 * ((r - g) / chroma + 4) }
        if h < 0 { h += 360 }

        let w = Self.weights(hue: h)
        // Full effect from modest color up; fades only toward true grays (iOS photos are rarely very saturated).
        let colorful = min(1, chroma / 0.12)
        var hueShift = 0.0, satChange = 0.0, lumChange = 0.0
        for i in 0..<8 {
            hueShift += w[i] * hue[i]
            satChange += w[i] * saturation[i]
            lumChange += w[i] * luminance[i]
        }
        h = (h + hueShift * 30 * colorful + 360).truncatingRemainder(dividingBy: 360)
        let newS = min(max(s * (1 + satChange), 0), 1)
        let lum = lumChange * 0.35 * colorful
        let newL = lum >= 0 ? l + (1 - l) * lum : l * (1 + lum)

        // HSL → RGB
        let c = (1 - abs(2 * newL - 1)) * newS
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = newL - c / 2
        let (r1, g1, b1): (Double, Double, Double)
        switch h {
        case ..<60: (r1, g1, b1) = (c, x, 0)
        case ..<120: (r1, g1, b1) = (x, c, 0)
        case ..<180: (r1, g1, b1) = (0, c, x)
        case ..<240: (r1, g1, b1) = (0, x, c)
        case ..<300: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        return (r1 + m, g1 + m, b1 + m)
    }

    static let cubeSize = 32

    /// RGBA float32 color cube for CIColorCubeWithColorSpace (red varies fastest).
    func cubeData() -> Data {
        let n = Self.cubeSize
        var values = [Float]()
        values.reserveCapacity(n * n * n * 4)
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let (r, g, b) = map(Double(ri) / Double(n - 1), Double(gi) / Double(n - 1), Double(bi) / Double(n - 1))
                    values += [Float(r), Float(g), Float(b), 1]
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
