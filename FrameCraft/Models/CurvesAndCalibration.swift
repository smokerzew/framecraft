import Foundation

/// Point curves: a master (RGB) curve plus red, green and blue curves, each five heights at x = 0, ¼, ½, ¾, 1.
struct ToneCurves: Codable, Equatable, Sendable {
    enum Channel: String, CaseIterable, Identifiable, Sendable {
        case master, red, green, blue
        var id: String { rawValue }
        var label: String { self == .master ? "RGB" : rawValue.capitalized }
    }

    static let xs: [Double] = [0, 0.25, 0.5, 0.75, 1]

    var master = ToneCurves.xs
    var red = ToneCurves.xs
    var green = ToneCurves.xs
    var blue = ToneCurves.xs

    var isIdentity: Bool { self == ToneCurves() }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func points(_ key: CodingKeys) -> [Double] {
            guard let values = try? c.decodeIfPresent([Double].self, forKey: key), values.count == 5,
                  values.allSatisfy(\.isFinite) else { return Self.xs }
            return values.map { min(max($0, 0), 1) }
        }
        master = points(.master)
        red = points(.red)
        green = points(.green)
        blue = points(.blue)
    }

    subscript(channel: Channel) -> [Double] {
        get {
            switch channel {
            case .master: master
            case .red: red
            case .green: green
            case .blue: blue
            }
        }
        set {
            let clamped = newValue.count == 5 ? newValue.map { min(max($0, 0), 1) } : Self.xs
            switch channel {
            case .master: master = clamped
            case .red: red = clamped
            case .green: green = clamped
            case .blue: blue = clamped
            }
        }
    }

    /// Smooth curve through the five points without overshoot (monotone cubic, Fritsch–Carlson), sampled `count` times.
    static func sample(_ ys: [Double], count: Int) -> [Double] {
        guard ys.count == xs.count, count > 1 else { return (0..<max(count, 1)).map { Double($0) / Double(max(count - 1, 1)) } }
        let n = xs.count
        var delta = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { delta[i] = (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]) }
        var m = [Double](repeating: 0, count: n)
        m[0] = delta[0]
        m[n - 1] = delta[n - 2]
        for i in 1..<(n - 1) { m[i] = delta[i - 1] * delta[i] <= 0 ? 0 : (delta[i - 1] + delta[i]) / 2 }
        for i in 0..<(n - 1) where delta[i] == 0 {
            m[i] = 0
            m[i + 1] = 0
        }
        for i in 0..<(n - 1) where delta[i] != 0 {
            let a = m[i] / delta[i], b = m[i + 1] / delta[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m[i] = t * a * delta[i]
                m[i + 1] = t * b * delta[i]
            }
        }
        return (0..<count).map { k in
            let x = Double(k) / Double(count - 1)
            let i = min(Int(x / 0.25), n - 2)
            let h = xs[i + 1] - xs[i]
            let t = (x - xs[i]) / h
            let t2 = t * t, t3 = t2 * t
            let y = (2 * t3 - 3 * t2 + 1) * ys[i] + (t3 - 2 * t2 + t) * h * m[i]
                + (-2 * t3 + 3 * t2) * ys[i + 1] + (t3 - t2) * h * m[i + 1]
            return min(max(y, 0), 1)
        }
    }

    /// RGB lookup table for CIColorCurves: each channel goes through its own curve, then the master curve.
    func lut(count: Int = 256) -> [Float] {
        let m = Self.sample(master, count: count)
        let channels = [red, green, blue].map { Self.sample($0, count: count) }
        func throughMaster(_ v: Double) -> Double {
            let position = v * Double(count - 1)
            let i = min(Int(position), count - 2)
            let f = position - Double(i)
            return m[i] * (1 - f) + m[i + 1] * f
        }
        var table: [Float] = []
        table.reserveCapacity(count * 3)
        for k in 0..<count {
            for c in channels { table.append(Float(throughMaster(c[k]))) }
        }
        return table
    }
}

/// Color calibration: moves the hue (±30°) and saturation (±50%) of the red, green and blue primaries,
/// which shifts every color made from them, the way a camera profile does.
struct ColorCalibration: Codable, Equatable, Sendable {
    var redHue = 0.0
    var redSaturation = 0.0
    var greenHue = 0.0
    var greenSaturation = 0.0
    var blueHue = 0.0
    var blueSaturation = 0.0

    var isNeutral: Bool { self == ColorCalibration() }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func unit(_ key: CodingKeys) -> Double {
            let v = (try? c.decodeIfPresent(Double.self, forKey: key)) ?? 0
            return v.isFinite ? min(max(v, -1), 1) : 0
        }
        redHue = unit(.redHue)
        redSaturation = unit(.redSaturation)
        greenHue = unit(.greenHue)
        greenSaturation = unit(.greenSaturation)
        blueHue = unit(.blueHue)
        blueSaturation = unit(.blueSaturation)
    }

    /// Rows are the new red, green and blue; columns are where each primary moves.
    func matrix() -> [[Double]] {
        let luma = [0.2126, 0.7152, 0.0722]
        let k = 1 / 3.0.squareRoot() // gray axis
        let settings = [(redHue, redSaturation), (greenHue, greenSaturation), (blueHue, blueSaturation)]
        var columns: [[Double]] = []
        for j in 0..<3 {
            let y = luma[j]
            var chroma = [0.0, 0.0, 0.0]
            for i in 0..<3 { chroma[i] = (i == j ? 1 : 0) - y }
            let scale = 1 + settings[j].1 * 0.5
            chroma = chroma.map { $0 * scale }
            // Rotate the chroma around the gray axis (Rodrigues).
            let angle = settings[j].0 * .pi / 6
            let (c, s) = (cos(angle), sin(angle))
            let axis = [k, k, k]
            let cross = [axis[1] * chroma[2] - axis[2] * chroma[1],
                         axis[2] * chroma[0] - axis[0] * chroma[2],
                         axis[0] * chroma[1] - axis[1] * chroma[0]]
            let dot = axis[0] * chroma[0] + axis[1] * chroma[1] + axis[2] * chroma[2]
            let rotated = (0..<3).map { chroma[$0] * c + cross[$0] * s + axis[$0] * dot * (1 - c) }
            columns.append(rotated.map { $0 + y })
        }
        return (0..<3).map { row in (0..<3).map { columns[$0][row] } }
    }
}
