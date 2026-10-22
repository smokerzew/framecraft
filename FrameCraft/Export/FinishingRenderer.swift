import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import UIKit

/// Border styles added when finishing an export. Frames and the date stamp exist only in the finished copy:
/// they are never part of filters or effects, and the original and the edit stay untouched.
enum FrameStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case none, plain, white, paper, black, negative, specs

    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: "None"
        case .plain: "Plain"
        case .white: "White"
        case .paper: "Paper"
        case .black: "Black"
        case .negative: "Negative"
        case .specs: "Specs"
        }
    }
}

struct FinishSettings: Codable, Equatable, Sendable {
    var frame: FrameStyle = .none
    var dateStamp = false

    var isEmpty: Bool { frame == .none && !dateStamp }
}

/// Capture facts read from the photo's own metadata. Missing values stay nil and are never guessed.
struct CaptureMetadata: Equatable, Sendable {
    var date: Date?
    var make: String?
    var model: String?
    var lens: String?
    var iso: Int?
    var exposureSeconds: Double?
    var fNumber: Double?
    var focalLength35mm: Int?
    var focalLength: Double?

    init(date: Date? = nil, make: String? = nil, model: String? = nil, lens: String? = nil, iso: Int? = nil,
         exposureSeconds: Double? = nil, fNumber: Double? = nil, focalLength35mm: Int? = nil, focalLength: Double? = nil) {
        self.date = date
        self.make = make
        self.model = model
        self.lens = lens
        self.iso = iso
        self.exposureSeconds = exposureSeconds
        self.fNumber = fNumber
        self.focalLength35mm = focalLength35mm
        self.focalLength = focalLength
    }

    init(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { self.init(); return }
        self.init(properties: props)
    }

    init(properties props: [CFString: Any]) {
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let dateText = (exif[kCGImagePropertyExifDateTimeOriginal] ?? exif[kCGImagePropertyExifDateTimeDigitized]) as? String
        date = dateText.flatMap(Self.exifDate)
        make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        lens = (exif[kCGImagePropertyExifLensModel] as? String)?.trimmingCharacters(in: .whitespaces)
        iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.intValue
        exposureSeconds = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue
        fNumber = (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue
        focalLength35mm = (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.intValue
        focalLength = (exif[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue
    }

    static func exifDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }

    /// "1/250s", "0.5s", "2s".
    static func shutterText(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        if seconds >= 0.5 { return seconds == seconds.rounded() ? "\(Int(seconds))s" : String(format: "%.1fs", seconds) }
        return "1/\(Int((1 / seconds).rounded()))s"
    }

    /// The settings line for the Specs frame, built only from values that exist.
    var settingsLine: String {
        var parts: [String] = []
        if let focalLength35mm { parts.append("\(focalLength35mm)mm") } else if let focalLength { parts.append(String(format: "%.1fmm", focalLength)) }
        if let fNumber { parts.append(String(format: "ƒ/%.1f", fNumber)) }
        if let exposureSeconds { parts.append(Self.shutterText(exposureSeconds)) }
        if let iso { parts.append("ISO \(iso)") }
        return parts.joined(separator: "  ")
    }

    var cameraLine: String {
        let name = [make, model].compactMap { $0 }.filter { !$0.isEmpty }
        // Apple's own model names stand alone ("iPhone 16 Pro", not "Apple iPhone 16 Pro"), as does a model that
        // already includes the make.
        if let model, let make, make.lowercased() == "apple" || model.lowercased().contains(make.lowercased()) { return model }
        return name.joined(separator: " ")
    }

    var isEmpty: Bool { cameraLine.isEmpty && settingsLine.isEmpty && lens == nil }

    /// Date stamp text in the classic '26 10 22 style, or nil without a capture date.
    var stampText: String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "''yy MM dd"
        return formatter.string(from: date)
    }
}

enum FinishingRenderer {
    /// Border thickness as a fraction of the photo's short side, per side (top, left, right, bottom).
    static func insets(for style: FrameStyle, size: CGSize) -> UIEdgeInsets {
        let s = min(size.width, size.height)
        switch style {
        case .none: return .zero
        case .plain: return UIEdgeInsets(top: s * 0.03, left: s * 0.03, bottom: s * 0.03, right: s * 0.03)
        case .white, .black: return UIEdgeInsets(top: s * 0.06, left: s * 0.06, bottom: s * 0.06, right: s * 0.06)
        case .paper: return UIEdgeInsets(top: s * 0.07, left: s * 0.07, bottom: s * 0.2, right: s * 0.07)
        case .negative: return UIEdgeInsets(top: s * 0.11, left: s * 0.04, bottom: s * 0.11, right: s * 0.04)
        case .specs: return UIEdgeInsets(top: s * 0.04, left: s * 0.04, bottom: s * 0.16, right: s * 0.04)
        }
    }

    static func finish(_ image: CIImage, settings: FinishSettings, metadata: CaptureMetadata,
                       context: CIContext = PhotoRenderer.shared.context) -> CIImage {
        guard !settings.isEmpty else { return image }
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0,
              let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let photo = context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: space) else {
            return image
        }
        guard let finished = render(photo, settings: settings, metadata: metadata) else { return image }
        return CIImage(cgImage: finished)
    }

    /// Draws the frame and stamp around/onto `photo` at its full resolution.
    static func render(_ photo: CGImage, settings: FinishSettings, metadata: CaptureMetadata) -> CGImage? {
        let size = CGSize(width: photo.width, height: photo.height)
        let inset = insets(for: settings.frame, size: size)
        let canvas = CGSize(width: size.width + inset.left + inset.right, height: size.height + inset.top + inset.bottom)
        let space = photo.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space.model == .rgb ? space : CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Work top-left-origin like UIKit so text and layout math stay readable.
        ctx.translateBy(x: 0, y: canvas.height)
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }

        let photoRect = CGRect(x: inset.left, y: inset.top, width: size.width, height: size.height)
        drawBackground(settings.frame, canvas: canvas, photoRect: photoRect, in: ctx)

        // CGContext draws images bottom-up; flip locally for the photo.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: photoRect.maxY + photoRect.minY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(photo, in: photoRect)
        ctx.restoreGState()

        if settings.frame == .negative { drawNegativeDetails(canvas: canvas, photoRect: photoRect, in: ctx) }
        if settings.frame == .specs { drawSpecs(metadata, canvas: canvas, photoRect: photoRect) }
        if settings.dateStamp, let text = metadata.stampText { drawStamp(text, photoRect: photoRect) }
        return ctx.makeImage()
    }

    private static func drawBackground(_ style: FrameStyle, canvas: CGSize, photoRect: CGRect, in ctx: CGContext) {
        let full = CGRect(origin: .zero, size: canvas)
        switch style {
        case .none: return
        case .plain, .white, .specs: ctx.setFillColor(UIColor.white.cgColor); ctx.fill(full)
        case .black: ctx.setFillColor(UIColor(white: 0.04, alpha: 1).cgColor); ctx.fill(full)
        case .negative: ctx.setFillColor(UIColor(red: 0.09, green: 0.06, blue: 0.04, alpha: 1).cgColor); ctx.fill(full)
        case .paper:
            ctx.setFillColor(UIColor(red: 0.95, green: 0.93, blue: 0.88, alpha: 1).cgColor)
            ctx.fill(full)
            // Fine paper fibers: a fixed pattern, so the same photo always finishes the same way.
            var rng = SplitMix64(seed: 0x9A7E)
            let s = min(canvas.width, canvas.height)
            let count = Int(canvas.width * canvas.height / max(1, s * s) * 900)
            for _ in 0..<count {
                let x = CGFloat.random(in: 0...canvas.width, using: &rng)
                let y = CGFloat.random(in: 0...canvas.height, using: &rng)
                let length = s * CGFloat.random(in: 0.002...0.012, using: &rng)
                let angle = CGFloat.random(in: 0...(.pi * 2), using: &rng)
                ctx.setStrokeColor(UIColor(white: CGFloat.random(in: 0.55...0.8, using: &rng), alpha: 0.18).cgColor)
                ctx.setLineWidth(max(1, s * 0.0007))
                ctx.move(to: CGPoint(x: x, y: y))
                ctx.addLine(to: CGPoint(x: x + cos(angle) * length, y: y + sin(angle) * length))
                ctx.strokePath()
            }
            // A soft shadow line where the print meets the paper.
            ctx.setStrokeColor(UIColor(white: 0, alpha: 0.12).cgColor)
            ctx.setLineWidth(max(1, s * 0.0015))
            ctx.stroke(photoRect.insetBy(dx: -s * 0.001, dy: -s * 0.001))
        }
    }

    /// Sprocket holes and frame numbers along both edges, like a contact strip (no brand names).
    private static func drawNegativeDetails(canvas: CGSize, photoRect: CGRect, in ctx: CGContext) {
        let band = photoRect.minY
        let hole = CGSize(width: band * 0.32, height: band * 0.42)
        let spacing = hole.width * 2.1
        ctx.setFillColor(UIColor(white: 0.97, alpha: 0.9).cgColor)
        var x = spacing * 0.4
        while x + hole.width < canvas.width {
            for y in [band * 0.12, canvas.height - band * 0.12 - hole.height] {
                ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: hole.width, height: hole.height),
                                   cornerWidth: hole.width * 0.2, cornerHeight: hole.width * 0.2, transform: nil))
            }
            x += spacing
        }
        ctx.fillPath()
        let font = UIFont.monospacedSystemFont(ofSize: band * 0.2, weight: .semibold)
        let color = UIColor(red: 1, green: 0.62, blue: 0.2, alpha: 0.9)
        for (index, frameNumber) in ["12", "12A", "13"].enumerated() {
            let text = NSAttributedString(string: "▸ \(frameNumber)", attributes: [.font: font, .foregroundColor: color])
            let px = photoRect.minX + photoRect.width * (0.08 + 0.4 * CGFloat(index))
            text.draw(at: CGPoint(x: px, y: canvas.height - band * 0.62))
        }
    }

    private static func drawSpecs(_ m: CaptureMetadata, canvas: CGSize, photoRect: CGRect) {
        let bar = CGRect(x: photoRect.minX, y: photoRect.maxY, width: photoRect.width, height: canvas.height - photoRect.maxY)
        let big = UIFont.systemFont(ofSize: bar.height * 0.2, weight: .semibold)
        let small = UIFont.systemFont(ofSize: bar.height * 0.15, weight: .regular)
        let dark = UIColor(white: 0.1, alpha: 1), gray = UIColor(white: 0.45, alpha: 1)
        let title = m.cameraLine.isEmpty ? "Camera details unavailable" : m.cameraLine
        let lens = m.lens ?? ""
        let settings = m.settingsLine.isEmpty ? "Exposure details unavailable" : m.settingsLine
        NSAttributedString(string: title, attributes: [.font: big, .foregroundColor: dark])
            .draw(at: CGPoint(x: bar.minX, y: bar.minY + bar.height * 0.2))
        NSAttributedString(string: lens, attributes: [.font: small, .foregroundColor: gray])
            .draw(at: CGPoint(x: bar.minX, y: bar.minY + bar.height * 0.5))
        let right = NSAttributedString(string: settings, attributes: [.font: big, .foregroundColor: dark])
        right.draw(at: CGPoint(x: bar.maxX - right.size().width, y: bar.minY + bar.height * 0.2))
        if let date = m.date {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            let line = NSAttributedString(string: formatter.string(from: date), attributes: [.font: small, .foregroundColor: gray])
            line.draw(at: CGPoint(x: bar.maxX - line.size().width, y: bar.minY + bar.height * 0.5))
        }
    }

    /// Orange seven-segment-style stamp in the bottom right of the photo, with a soft glow like film date backs.
    private static func drawStamp(_ text: String, photoRect: CGRect) {
        let s = min(photoRect.width, photoRect.height)
        let font = UIFont.monospacedDigitSystemFont(ofSize: s * 0.045, weight: .semibold)
        let glow = NSShadow()
        glow.shadowColor = UIColor(red: 1, green: 0.4, blue: 0.1, alpha: 0.8)
        glow.shadowBlurRadius = s * 0.008
        let string = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: UIColor(red: 1, green: 0.58, blue: 0.18, alpha: 0.92), .shadow: glow, .kern: s * 0.004,
        ])
        let size = string.size()
        string.draw(at: CGPoint(x: photoRect.maxX - size.width - s * 0.05, y: photoRect.maxY - size.height - s * 0.045))
    }
}
