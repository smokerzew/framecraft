import CoreGraphics
import Foundation

// All rects and points here are normalized to the camera image (0...1, top-left origin, portrait as shown).

struct SceneSubject: Equatable, Sendable {
    enum Kind: String, Sendable { case face, person, salient, chosen }
    var kind: Kind
    var box: CGRect
    var confidence: Double
    /// Which way a face looks in the picture: -1 left, +1 right, 0 toward the camera or unknown.
    var facing: CGFloat = 0
}

/// What the analyzer measured in one frame. Nothing here is a judgment, only measurements.
struct SceneFeatures: Equatable, Sendable {
    var subjects: [SceneSubject] = []
    /// Horizon tilt in degrees as it appears in the frame (+ = rising to the right); nil when none was found.
    var horizonDegrees: Double?
    var meanLuminance: Double = 0.5
    /// Fractions of the frame that are clipped to white / crushed to black.
    var highlightClipping: Double = 0
    var shadowClipping: Double = 0
    /// Width / height of the frame.
    var imageAspect: CGFloat = 3.0 / 4.0
    /// Body joints of the people found (for framing that never cuts at a joint).
    var poses: [PersonPose] = []
    /// Where the horizon crosses the middle of the frame, when one was found.
    var horizon: HorizonLine?
}

struct CompositionGuidance: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Follows from a measurement (tilt in degrees, clipped pixels, subject position).
        case measured
        /// A common photographic convention, offered as an option, not a fact about quality.
        case suggestion
    }
    let id: String
    let kind: Kind
    let text: String
}

struct CompositionSuggestion: Equatable, Sendable {
    /// Suggested framing (becomes the photo's crop when accepted).
    var rect: CGRect
    /// Where the subject's center sits inside `rect` (0...1 of the rect).
    var target: CGPoint
    var subject: SceneSubject
    /// 0...1: how closely the measured rules below are met. Not a rating of the photo.
    var score: Double
    var breakdown: [String: Double]
    /// rect.width relative to the largest crop of this aspect (1 = no zoom needed).
    var scale: CGFloat
}

struct CompositionResult: Equatable, Sendable {
    var primary: CompositionSuggestion?
    var alternative: CompositionSuggestion?
    var guidance: [CompositionGuidance]
    /// False when no subject was found clearly enough to suggest a frame.
    var isConclusive: Bool
}

/// Explainable framing search: candidate crops are scored on subject placement (thirds or center), subject
/// size, room around the subject, headroom for people, and how much of the image is kept.
enum CompositionEngine {
    static let thirds: [CGPoint] = [
        CGPoint(x: 1.0 / 3, y: 1.0 / 3), CGPoint(x: 2.0 / 3, y: 1.0 / 3),
        CGPoint(x: 1.0 / 3, y: 2.0 / 3), CGPoint(x: 2.0 / 3, y: 2.0 / 3),
    ]
    static let center = CGPoint(x: 0.5, y: 0.5)
    static let scales: [CGFloat] = [1, 0.9, 0.8, 0.7, 0.6, 0.5]

    /// The main subject: faces first (all faces together), then people, then the most confident salient object.
    static func primarySubject(_ features: SceneFeatures) -> SceneSubject? {
        let usable = features.subjects.filter { $0.box.width * $0.box.height >= 0.002 && $0.confidence >= 0.3 }
        let faces = usable.filter { $0.kind == .face }
        if !faces.isEmpty {
            let union = faces.dropFirst().reduce(faces[0].box) { $0.union($1.box) }
            // Keep the direction the faces look (a group facing the same way still needs space in front).
            let facing = faces.map(\.facing).reduce(0, +) / CGFloat(faces.count)
            return SceneSubject(kind: .face, box: union, confidence: faces.map(\.confidence).max() ?? 1,
                                facing: abs(facing) >= 0.5 ? (facing > 0 ? 1 : -1) : 0)
        }
        if let chosen = usable.first(where: { $0.kind == .chosen }) { return chosen }
        if let person = usable.filter({ $0.kind == .person }).max(by: { area($0.box) < area($1.box) }) { return person }
        return usable.filter { $0.kind == .salient }.max { $0.confidence * Double(area($0.box)) < $1.confidence * Double(area($1.box)) }
    }

    /// Largest crop of `aspect` (width / height, in pixels) that fits an image of `imageAspect`, in normalized units.
    static func maxCropSize(aspect: CGFloat, imageAspect: CGFloat) -> CGSize {
        guard aspect > 0, imageAspect > 0 else { return CGSize(width: 1, height: 1) }
        return aspect <= imageAspect
            ? CGSize(width: aspect / imageAspect, height: 1)
            : CGSize(width: 1, height: imageAspect / aspect)
    }

    static func analyze(_ features: SceneFeatures, aspect: CGFloat? = nil, isFrontCamera: Bool = false) -> CompositionResult {
        var guidance = exposureAndLevelGuidance(features, isFrontCamera: isFrontCamera)
        guard let subject = primarySubject(features) else {
            guidance.insert(CompositionGuidance(
                id: "no-subject", kind: .measured,
                text: "No clear subject found. Switch to CUSTOM and tap your subject, or move closer."), at: 0)
            return CompositionResult(primary: nil, alternative: nil, guidance: guidance, isConclusive: false)
        }
        let candidates = self.candidates(for: subject, features: features, aspect: aspect ?? features.imageAspect)
            .sorted { $0.score > $1.score }
        guard let best = candidates.first else {
            guidance.insert(CompositionGuidance(
                id: "too-big", kind: .measured,
                text: "The subject fills the frame, so no tighter framing fits. Step back or zoom out to frame it."), at: 0)
            return CompositionResult(primary: nil, alternative: nil, guidance: guidance, isConclusive: false)
        }
        // A real alternative puts the subject somewhere else (other third or the center), not the same crop again.
        let alternative = candidates.first {
            ($0.target.x - best.target.x).magnitude > 0.1 || ($0.target.y - best.target.y).magnitude > 0.1
        }.flatMap { $0.score >= best.score * 0.75 ? $0 : nil }

        guidance.insert(contentsOf: framingGuidance(best, subject: subject), at: 0)
        return CompositionResult(primary: best, alternative: alternative, guidance: guidance, isConclusive: best.score >= 0.35)
    }

    static func candidates(for subject: SceneSubject, features: SceneFeatures, aspect: CGFloat) -> [CompositionSuggestion] {
        let full = maxCropSize(aspect: aspect, imageAspect: features.imageAspect)
        let box = subject.box
        var results: [CompositionSuggestion] = []
        for scale in scales {
            let size = CGSize(width: full.width * scale, height: full.height * scale)
            guard box.width < size.width * 0.95, box.height < size.height * 0.95 else { continue }
            for target in thirds + [center] {
                var origin = CGPoint(x: box.midX - target.x * size.width, y: box.midY - target.y * size.height)
                origin.x = min(max(origin.x, 0), 1 - size.width)
                origin.y = min(max(origin.y, 0), 1 - size.height)
                let rect = CGRect(origin: origin, size: size)
                guard rect.contains(box) else { continue }
                results.append(score(rect: rect, aimedAt: target, subject: subject, features: features, scale: scale))
            }
        }
        // Clamping can make several aims land on the same crop; keep one of each.
        var seen = Set<String>()
        return results.filter { seen.insert(String(format: "%.3f %.3f %.3f", $0.rect.minX, $0.rect.minY, $0.rect.width)).inserted }
    }

    static func score(rect: CGRect, aimedAt aim: CGPoint, subject: SceneSubject, features: SceneFeatures,
                      scale: CGFloat) -> CompositionSuggestion {
        let box = subject.box
        // Where the subject actually ends up inside the crop (clamping at the image edge can move it).
        let p = CGPoint(x: (box.midX - rect.minX) / rect.width, y: (box.midY - rect.minY) / rect.height)
        let toThird = thirds.map { hypot($0.x - p.x, $0.y - p.y) }.min() ?? 1
        let toCenter = hypot(p.x - 0.5, p.y - 0.5)
        let centered = aim == center
        // Centering is a valid choice for symmetric subjects, so it scores, slightly below thirds.
        let placement = Double(centered ? max(0, 1 - toCenter / 0.15) * 0.85 : max(0, 1 - toThird / 0.2))

        let fill = Double((box.width * box.height) / (rect.width * rect.height))
        let band: ClosedRange<Double> = switch subject.kind {
        case .face: 0.03...0.2
        case .person: 0.1...0.5
        case .salient, .chosen: 0.05...0.4
        }
        let size = band.contains(fill) ? 1 : (fill < band.lowerBound ? fill / band.lowerBound : max(0, 1 - (fill - band.upperBound) / 0.4))

        let margins = [box.minX - rect.minX, rect.maxX - box.maxX].map { $0 / rect.width }
            + [box.minY - rect.minY, rect.maxY - box.maxY].map { $0 / rect.height }
        let room = Double(min(1, max(0, margins.min() ?? 0) / 0.06))

        // People: some space above the head, but not so much the subject sinks.
        let headroomValue = Double((box.minY - rect.minY) / rect.height)
        let headroom = subject.kind == .face || subject.kind == .person
            ? (0.04...0.25).contains(headroomValue) ? 1 : 0.4
            : 1

        // Other subjects pulling the eye: prefer them inside the frame rather than cut by an edge.
        let cut = features.subjects.filter { $0.box != box && $0.box.intersects(rect) && !rect.contains($0.box) }.count
        let edges = max(0, 1 - 0.25 * Double(cut))

        let keep = Double(scale)
        let parts: [String: Double] = ["placement": placement, "size": size, "room": room, "headroom": headroom,
                                       "edges": edges, "kept": keep]
        let total = 0.34 * placement + 0.2 * size + 0.16 * room + 0.1 * headroom + 0.08 * edges + 0.12 * keep
        return CompositionSuggestion(rect: rect, target: p, subject: subject, score: total, breakdown: parts, scale: scale)
    }

    static func exposureAndLevelGuidance(_ f: SceneFeatures, isFrontCamera: Bool) -> [CompositionGuidance] {
        var items: [CompositionGuidance] = []
        if let tilt = f.horizonDegrees, abs(tilt) >= 1, abs(tilt) <= 20, !isFrontCamera {
            // A horizon rising to the right means the phone is rolled clockwise; turn it back the other way.
            let way = tilt > 0 ? "counterclockwise" : "clockwise"
            items.append(.init(id: "level", kind: .measured,
                               text: String(format: "Horizon is tilted %.1f°. Turn the phone %@ to level it.", abs(tilt), way)))
        }
        if f.highlightClipping > 0.02 {
            items.append(.init(id: "highlights", kind: .measured,
                               text: "\(percent(f.highlightClipping)) of the frame is clipped to white. Lower exposure (EV) to keep detail."))
        }
        if f.shadowClipping > 0.08 {
            items.append(.init(id: "shadows", kind: .measured,
                               text: "\(percent(f.shadowClipping)) of the frame is pure black. Raise exposure or add light if you want detail there."))
        }
        if f.highlightClipping <= 0.02, f.meanLuminance < 0.16 {
            items.append(.init(id: "dark", kind: .measured, text: "The scene is very dark (average brightness \(percent(f.meanLuminance)))."))
        }
        return items
    }

    static func framingGuidance(_ s: CompositionSuggestion, subject: SceneSubject) -> [CompositionGuidance] {
        var items: [CompositionGuidance] = []
        let fill = (subject.box.width * subject.box.height) / (s.rect.width * s.rect.height)
        let spot = s.target.x < 0.42 ? "left third" : s.target.x > 0.58 ? "right third" : "center"
        let height = s.target.y < 0.42 ? "upper " : s.target.y > 0.58 ? "lower " : ""
        let name = subject.kind == .face ? "The face" : subject.kind == .person ? "The person" : "The subject"
        items.append(.init(id: "place", kind: .measured,
                           text: "\(name) sits on the \(spot == "center" ? "center" : height + spot) of this frame and fills \(percent(Double(fill))) of it."))
        if s.scale < 0.95 {
            items.append(.init(id: "zoom", kind: .measured,
                               text: String(format: "This frame is a %.1f× crop. Zoom in or step closer to keep full resolution.", 1 / s.scale)))
        }
        items.append(.init(id: "why", kind: .suggestion, text: spot == "center"
            ? "A centered subject suits symmetrical scenes and portraits; it's one option, not a rule."
            : "Off-center placement leaves open space beside the subject; a common choice, not a rule."))
        return items
    }

    // MARK: Alignment for custom frames and tracking

    struct Alignment: Equatable, Sendable {
        /// Where the subject's center should go, in image coordinates.
        var target: CGPoint
        /// How far the subject's center is from it, in image units.
        var offset: CGVector
        var isAligned: Bool
        /// Short instruction ("Pan left"), empty when aligned.
        var hint: String
    }

    /// Nearest third (or the center) of `frame` to the subject's center, and how to move the phone to get there.
    static func alignment(subject: CGRect, in frame: CGRect, tolerance: CGFloat = 0.035) -> Alignment {
        let c = CGPoint(x: subject.midX, y: subject.midY)
        let points = (thirds + [center]).map { CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height) }
        let target = points.min { hypot($0.x - c.x, $0.y - c.y) < hypot($1.x - c.x, $1.y - c.y) } ?? c
        let offset = CGVector(dx: target.x - c.x, dy: target.y - c.y)
        let aligned = hypot(offset.dx, offset.dy) <= tolerance
        var parts: [String] = []
        // Moving the subject right in the picture means turning the phone left, and so on.
        if abs(offset.dx) > tolerance { parts.append(offset.dx > 0 ? "Pan left" : "Pan right") }
        if abs(offset.dy) > tolerance { parts.append(offset.dy > 0 ? "tilt up" : "tilt down") }
        let hint = parts.joined(separator: ", ")
        return Alignment(target: target, offset: offset, isAligned: aligned,
                         hint: aligned ? "" : hint.prefix(1).uppercased() + hint.dropFirst())
    }

    private static func area(_ r: CGRect) -> CGFloat { r.width * r.height }

    private static func percent(_ value: Double) -> String {
        value < 0.01 ? "<1%" : "\(Int((value * 100).rounded()))%"
    }
}

/// Maps between the camera image (normalized, top-left) and a view that shows it aspect-filled.
enum AspectFillMapping {
    /// Where the whole image lands in a view of `viewSize` (it overflows on one axis).
    static func imageRect(imageAspect: CGFloat, viewSize: CGSize) -> CGRect {
        guard imageAspect > 0, viewSize.width > 0, viewSize.height > 0 else { return CGRect(origin: .zero, size: viewSize) }
        let viewAspect = viewSize.width / viewSize.height
        let size = imageAspect > viewAspect
            ? CGSize(width: viewSize.height * imageAspect, height: viewSize.height)
            : CGSize(width: viewSize.width, height: viewSize.width / imageAspect)
        return CGRect(x: (viewSize.width - size.width) / 2, y: (viewSize.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    static func toView(_ rect: CGRect, imageAspect: CGFloat, viewSize: CGSize) -> CGRect {
        let i = imageRect(imageAspect: imageAspect, viewSize: viewSize)
        return CGRect(x: i.minX + rect.minX * i.width, y: i.minY + rect.minY * i.height,
                      width: rect.width * i.width, height: rect.height * i.height)
    }

    static func toView(_ point: CGPoint, imageAspect: CGFloat, viewSize: CGSize) -> CGPoint {
        let i = imageRect(imageAspect: imageAspect, viewSize: viewSize)
        return CGPoint(x: i.minX + point.x * i.width, y: i.minY + point.y * i.height)
    }

    static func toImage(_ point: CGPoint, imageAspect: CGFloat, viewSize: CGSize) -> CGPoint {
        let i = imageRect(imageAspect: imageAspect, viewSize: viewSize)
        guard i.width > 0, i.height > 0 else { return .zero }
        return CGPoint(x: (point.x - i.minX) / i.width, y: (point.y - i.minY) / i.height)
    }

    static func toImage(_ rect: CGRect, imageAspect: CGFloat, viewSize: CGSize) -> CGRect {
        let a = toImage(CGPoint(x: rect.minX, y: rect.minY), imageAspect: imageAspect, viewSize: viewSize)
        let b = toImage(CGPoint(x: rect.maxX, y: rect.maxY), imageAspect: imageAspect, viewSize: viewSize)
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// The part of the image the view shows (this becomes the photo's crop for a chosen aspect ratio).
    static func visibleRect(imageAspect: CGFloat, viewSize: CGSize) -> CGRect {
        toImage(CGRect(origin: .zero, size: viewSize), imageAspect: imageAspect, viewSize: viewSize)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}
