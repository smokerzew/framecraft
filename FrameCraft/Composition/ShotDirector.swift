import CoreGraphics
import CoreImage
import Foundation
import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Names the subject and writes the one-line instruction shown after a scan, on the phone: Vision's image
/// classifier names what's in the subject's box and the scene; the instruction is built from those names and the
/// measured framing (and, on iPhones with Apple Intelligence, worded by Apple's on-device model).
enum ShotDirector {
    struct Facts: Equatable, Sendable {
        var subject: String
        var scene: String?
        var kind: ShotKind
        /// Subject brightness minus background brightness (display values, -1...1).
        var contrast: Double
        /// How much of the frame the subject fills (0...1).
        var fill: Double
        /// Where the plan puts the subject (0...1 across the frame) and the horizon, if any.
        var anchorX: CGFloat
        var horizonTarget: CGFloat?
        var facing: CGFloat
    }

    // MARK: Naming

    /// Top classifier labels for a region (top-left normalized), most confident first, skipping vague ones.
    static func labels(in buffer: CVPixelBuffer, region: CGRect? = nil, count: Int = 2) -> [String] {
        let request = VNClassifyImageRequest()
        if let region {
            let r = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            if r.width > 0.02, r.height > 0.02 {
                request.regionOfInterest = CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
            }
        }
        try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
        let vague: Set<String> = ["structure", "indoor", "outdoor", "material", "people", "adult", "consumer_electronics",
                                  "interior_room", "wood_processed", "textile", "furniture", "machine", "art"]
        return (request.results ?? [])
            .filter { $0.confidence > 0.12 && !vague.contains($0.identifier) }
            .prefix(count)
            .map { readable($0.identifier) }
    }

    static func readable(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: " ").lowercased()
    }

    /// The tag shown on the subject: what it is, and where, when the scene adds something ("flower · bedroom").
    static func tag(subject: String, scene: String?) -> String {
        guard let scene, !scene.isEmpty, scene != subject else { return subject }
        return "\(subject) · \(scene)"
    }

    // MARK: Instruction

    /// A short instruction from the facts, without any model (also the fallback).
    static func instruction(_ f: Facts) -> String {
        let side = f.anchorX < 0.42 ? "left" : f.anchorX > 0.58 ? "right" : "center"
        switch f.kind {
        case .landscape:
            let third = (f.horizonTarget ?? 0.5) < 0.5 ? "upper" : "lower"
            return "Put the horizon on the \(third) third."
        case .headAndShoulders, .waistUp, .kneesUp, .fullBody:
            let shot = f.kind.title.lowercased().replacingOccurrences(of: "&", with: "and")
            if abs(f.facing) > 0.01 { return "Frame them \(shot), with room in front of their face." }
            return "Frame them \(shot), eyes on the upper third."
        case .subject:
            if f.contrast > 0.15 { return "Isolate the \(f.subject) against the dark background." }
            if f.contrast < -0.15 { return "Silhouette the \(f.subject) against the light." }
            if f.fill < 0.04 { return "Get closer — let the \(f.subject) fill more of the frame." }
            return side == "center" ? "Center the \(f.subject) and keep the edges clean."
                : "Place the \(f.subject) on the \(side) third."
        }
    }

    /// The instruction worded by Apple's on-device language model when it's available (iOS 26 with Apple
    /// Intelligence), else the built-in sentence. Never waits more than a couple of seconds.
    static func wordedInstruction(_ f: Facts) async -> String {
        let fallback = instruction(f)
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            let prompt = """
            Rewrite this photo tip as one short, friendly instruction of at most 9 words, no quotes, no emoji. \
            Keep its meaning. Subject: \(f.subject). Scene: \(f.scene ?? "unknown"). Tip: \(fallback)
            """
            let worded = await withTaskGroup(of: String?.self) { group -> String? in
                group.addTask {
                    let session = LanguageModelSession()
                    return (try? await session.respond(to: prompt))?.content
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(2.5))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            if let worded = clean(worded) { return worded }
        }
        #endif
        return fallback
    }

    /// One line, sentence-cased, ends with a period, reasonable length; nil if the model said something unusable.
    static func clean(_ text: String?) -> String? {
        guard var line = text?.split(whereSeparator: \.isNewline).first.map(String.init) else { return nil }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”*-"))
        guard line.count >= 8, line.count <= 80 else { return nil }
        if !line.hasSuffix(".") && !line.hasSuffix("!") { line += "." }
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    // MARK: Measuring

    /// Average display brightness inside and outside a region of the frame.
    static func contrast(in buffer: CVPixelBuffer, region: CGRect) -> Double {
        let image = CIImage(cvPixelBuffer: buffer)
        let e = image.extent
        let box = CGRect(x: e.minX + region.minX * e.width, y: e.minY + (1 - region.maxY) * e.height,
                         width: region.width * e.width, height: region.height * e.height).intersection(e)
        guard !box.isEmpty else { return 0 }
        func average(_ rect: CGRect) -> Double {
            let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: rect)])
            guard let output = filter?.outputImage else { return 0.5 }
            var px = [UInt8](repeating: 0, count: 4)
            PhotoRenderer.shared.context.render(output, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            let r: Double = 0.2126 * Double(px[0])
            let g: Double = 0.7152 * Double(px[1])
            let b: Double = 0.0722 * Double(px[2])
            return (r + g + b) / 255
        }
        let inside = average(box)
        let whole = average(e)
        let area = Double((box.width * box.height) / (e.width * e.height))
        let outside = area < 0.95 ? (whole - inside * area) / (1 - area) : whole
        return inside - outside
    }
}
