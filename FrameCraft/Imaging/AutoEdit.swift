import CoreGraphics
import CoreImage
import Foundation

/// The edit a new capture opens with: a look, a gentle correction measured from the photo's own brightness,
/// and a touch of grain. Everything is a normal editable setting (Reset or undo takes it off).
enum AutoEdit {
    /// `luma` are display-brightness samples (0...1) of the photo.
    static func suggest(luma: [Double], base: EditState) -> EditState {
        var e = base
        if e.look == .none { e.look = .clean }
        guard luma.count >= 16 else { return e }
        let sorted = luma.sorted()
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))] }
        let mean = luma.reduce(0, +) / Double(luma.count)
        let p05 = percentile(0.05), p95 = percentile(0.95)
        let clipped = Double(luma.filter { $0 >= 0.985 }.count) / Double(luma.count)

        // Exposure toward a mid-tone average, at most a stop, and only when it's clearly off.
        let ev = log2(0.42 / max(mean, 0.01)) * 0.6
        if abs(ev) > 0.12 { e.exposure = min(max(ev, -1), 1) }
        if clipped > 0.02 { e.highlights = -min(0.6, clipped * 8) }
        if p05 < 0.06 { e.shadows = min(0.4, (0.06 - p05) * 6 + 0.1) }
        if p95 - p05 < 0.55 { e.contrast = min(0.3, (0.55 - (p95 - p05)) * 0.8) }
        e.vibrance = 0.1
        if e.grain == 0 { e.grain = 0.12 }
        return e
    }

    /// Display-brightness samples on a small grid of the image.
    static func lumaSamples(_ image: CGImage, side: Int = 48, context: CIContext = PhotoRenderer.shared.context) -> [Double] {
        let input = CIImage(cgImage: image)
        let scaled = input.transformed(by: CGAffineTransform(scaleX: CGFloat(side) / input.extent.width, y: CGFloat(side) / input.extent.height))
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        context.render(scaled, toBitmap: &pixels, rowBytes: side * 4, bounds: CGRect(x: 0, y: 0, width: side, height: side),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return stride(from: 0, to: pixels.count, by: 4).map {
            (0.2126 * Double(pixels[$0]) + 0.7152 * Double(pixels[$0 + 1]) + 0.0722 * Double(pixels[$0 + 2])) / 255
        }
    }
}
