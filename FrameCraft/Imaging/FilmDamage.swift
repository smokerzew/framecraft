import CoreGraphics
import CoreImage
import Foundation

extension PhotoRenderer {
    /// Dust specks, hairs and long scratches like a scanned print. The marks come from a fixed sequence,
    /// so raising the slider adds marks instead of reshuffling them, and every render of the same photo matches.
    func filmDamage(_ image: CIImage, dust: Double, scratches: Double, seed: Int = 0, extent: CGRect) -> CIImage {
        guard dust > 0 || scratches > 0, extent.width > 8, extent.height > 8 else { return image }
        let scale = min(1, 2048 / max(extent.width, extent.height))
        let width = Int((extent.width * scale).rounded()), height = Int((extent.height * scale).rounded())
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        let w = CGFloat(width), h = CGFloat(height), s = min(w, h)
        ctx.setLineCap(.round)

        if dust > 0 {
            var rng = SplitMix64(seed: 0xD057 &+ UInt64(bitPattern: Int64(seed)) &* 0x9E37)
            let area = Double(w * h) / Double(s * s) // more marks on longer frames
            let count = Int(dust * 320 * area)
            for index in 0..<count {
                let x = CGFloat.random(in: 0...w, using: &rng), y = CGFloat.random(in: 0...h, using: &rng)
                let light = Double.random(in: 0...1, using: &rng) < 0.8 // dust on a negative prints white
                let alpha = CGFloat.random(in: 0.35...0.8, using: &rng)
                let color = light ? CGColor(gray: 1, alpha: alpha) : CGColor(gray: 0, alpha: alpha * 0.8)
                if index % 9 == 0 {
                    // A hair: a short curved fiber.
                    let length = s * CGFloat.random(in: 0.015...0.05, using: &rng)
                    let angle = CGFloat.random(in: 0...(2 * .pi), using: &rng)
                    let bend = CGFloat.random(in: -0.6...0.6, using: &rng)
                    ctx.setStrokeColor(color)
                    ctx.setLineWidth(max(0.8, s * 0.0011))
                    ctx.move(to: CGPoint(x: x, y: y))
                    ctx.addQuadCurve(to: CGPoint(x: x + cos(angle) * length, y: y + sin(angle) * length),
                                     control: CGPoint(x: x + cos(angle + bend) * length * 0.6, y: y + sin(angle + bend) * length * 0.6))
                    ctx.strokePath()
                } else {
                    let r = s * CGFloat.random(in: 0.0006...0.0035, using: &rng)
                    let stretch = CGFloat.random(in: 0.6...1.6, using: &rng)
                    ctx.setFillColor(color)
                    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r / stretch, width: 2 * r, height: 2 * r / stretch))
                }
            }
        }

        if scratches > 0 {
            var rng = SplitMix64(seed: 0x5C7A &+ UInt64(bitPattern: Int64(seed)) &* 0x9E37)
            let count = Int((scratches * 7).rounded(.up))
            for _ in 0..<count {
                var x = CGFloat.random(in: 0.05...0.95, using: &rng) * w
                var y = CGFloat.random(in: -0.1...0.3, using: &rng) * h
                let end = CGFloat.random(in: 0.6...1.1, using: &rng) * h
                let light = Double.random(in: 0...1, using: &rng) < 0.7
                let alpha = CGFloat.random(in: 0.25...0.55, using: &rng) * CGFloat(0.5 + scratches * 0.5)
                ctx.setStrokeColor(light ? CGColor(gray: 1, alpha: alpha) : CGColor(gray: 0, alpha: alpha * 0.8))
                ctx.setLineWidth(max(0.7, s * CGFloat.random(in: 0.0005...0.0014, using: &rng)))
                ctx.move(to: CGPoint(x: x, y: y))
                // Long, slightly wandering vertical line with occasional breaks.
                while y < end {
                    y += h * 0.02
                    x += CGFloat.random(in: -0.0015...0.0015, using: &rng) * w
                    if Double.random(in: 0...1, using: &rng) < 0.06 { ctx.move(to: CGPoint(x: x, y: y)) } else { ctx.addLine(to: CGPoint(x: x, y: y)) }
                }
                ctx.strokePath()
            }
        }

        guard let marks = ctx.makeImage() else { return image }
        let overlay = CIImage(cgImage: marks)
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(width), y: extent.height / CGFloat(height)))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        return overlay.composited(over: image).cropped(to: extent)
    }
}
