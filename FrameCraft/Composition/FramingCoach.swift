import CoreGraphics
import Foundation

// Coordinates: image-normalized (0...1, top-left origin) unless a name says "frame" (relative to what the
// viewfinder shows right now).

enum BodyJoint: String, CaseIterable, Sendable {
    case nose, neck, leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist
    case leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle
}

/// One person's body joints (only those Vision was confident about).
struct PersonPose: Equatable, Sendable {
    var joints: [BodyJoint: CGPoint]

    /// Average height of the joints that exist (left and right pairs).
    func y(_ names: BodyJoint...) -> CGFloat? {
        let ys = names.compactMap { joints[$0]?.y }
        return ys.isEmpty ? nil : ys.reduce(0, +) / CGFloat(ys.count)
    }

    func x(_ names: BodyJoint...) -> CGFloat? {
        let xs = names.compactMap { joints[$0]?.x }
        return xs.isEmpty ? nil : xs.reduce(0, +) / CGFloat(xs.count)
    }

    var neckY: CGFloat? { y(.neck) ?? y(.leftShoulder, .rightShoulder) }
    var hipY: CGFloat? { y(.leftHip, .rightHip) }
    var kneeY: CGFloat? { y(.leftKnee, .rightKnee) }
    var ankleY: CGFloat? { y(.leftAnkle, .rightAnkle) }
    var centerX: CGFloat? { x(.nose) ?? x(.neck) ?? x(.leftShoulder, .rightShoulder) }

    var bounds: CGRect {
        let points = Array(joints.values)
        guard let first = points.first else { return .null }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    }
}

/// Where the horizon crosses the middle of the frame, and whether the sky above it is plain.
struct HorizonLine: Equatable, Sendable {
    var y: CGFloat
    var skyIsPlain: Bool
}

enum ShotKind: String, Sendable {
    case subject, headAndShoulders, waistUp, kneesUp, fullBody, landscape

    var title: String {
        switch self {
        case .subject: "SUBJECT"
        case .headAndShoulders: "HEAD & SHOULDERS"
        case .waistUp: "WAIST UP"
        case .kneesUp: "KNEES UP"
        case .fullBody: "FULL BODY"
        case .landscape: "LANDSCAPE"
        }
    }
}

/// A framing to aim for: the ideal frame (it may reach past what the camera sees now, which means
/// "move" or "zoom out"), and where the anchor (face, subject or horizon) sits in it.
struct FramingPlan: Equatable, Sendable {
    var kind: ShotKind
    var rect: CGRect
    /// Anchor position inside `rect` (0...1).
    var anchor: CGPoint
    /// Where the anchor is in the image now.
    var anchorNow: CGPoint
    /// Horizon height inside `rect` (0...1) the plan aims for, when it places the horizon.
    var horizonTarget: CGFloat?
    var score: Double
    var breakdown: [String: Double]

    /// Same kind of shot with the anchor on the same third: used to hold a plan steady between frames.
    func sameIdea(as other: FramingPlan) -> Bool {
        kind == other.kind && Self.bucket(anchor.x) == Self.bucket(other.anchor.x) && Self.bucket(anchor.y) == Self.bucket(other.anchor.y)
            && (horizonTarget.map(Self.bucket) == other.horizonTarget.map(Self.bucket))
    }

    private static func bucket(_ v: CGFloat) -> Int { v < 0.42 ? 0 : v > 0.58 ? 2 : 1 }
}

/// What the camera shows now.
struct ViewContext: Equatable, Sendable {
    /// The visible part of the image (the capture frame), in image coordinates.
    var visible: CGRect
    var zoom: CGFloat = 1
    var minZoom: CGFloat = 1
    var maxZoom: CGFloat = 10
    var isFront = false
}

/// The scan's crop: the chosen frame (viewfinder coordinates, 0...1) fills the viewfinder. The lens zooms about
/// the center as far as keeps the frame in view; the rest is a digital crop, and the photo gets the same crop.
enum ViewCrop {
    /// How far the lens should zoom (×) so the frame's farthest edge just reaches the view's edge
    /// (below 1 when the frame reaches past what the camera sees now).
    static func lensFactor(for box: CGRect) -> CGFloat {
        let reach = max(abs(box.minX - 0.5), abs(box.maxX - 0.5), abs(box.minY - 0.5), abs(box.maxY - 0.5))
        return 0.5 / max(reach, 0.01)
    }

    /// The frame after the lens zoomed by `factor`: the view's shape, kept inside the view.
    /// nil when it's (nearly) the whole view.
    static func crop(_ box: CGRect, afterZoom factor: CGFloat) -> CGRect? {
        let side = min(1, max(box.width, box.height) * factor)
        guard side < 0.97 else { return nil }
        let mid = CGPoint(x: 0.5 + (box.midX - 0.5) * factor, y: 0.5 + (box.midY - 0.5) * factor)
        return CGRect(x: min(max(mid.x - side / 2, 0), 1 - side), y: min(max(mid.y - side / 2, 0), 1 - side),
                      width: side, height: side)
    }

    /// An image rect as viewfinder coordinates, given the image's visible part.
    static func inView(_ rect: CGRect, visible v: CGRect) -> CGRect {
        CGRect(x: (rect.minX - v.minX) / v.width, y: (rect.minY - v.minY) / v.height,
               width: rect.width / v.width, height: rect.height / v.height)
    }

    /// The part of the image the cropped viewfinder shows.
    static func visible(_ v: CGRect, crop: CGRect?) -> CGRect {
        guard let c = crop else { return v }
        return CGRect(x: v.minX + c.minX * v.width, y: v.minY + c.minY * v.height, width: c.width * v.width, height: c.height * v.height)
    }

    /// A point on the cropped viewfinder → the same spot on the uncropped preview (both in points).
    static func uncropped(_ p: CGPoint, crop: CGRect?, size: CGSize) -> CGPoint {
        guard let c = crop else { return p }
        return CGPoint(x: (c.minX + p.x / size.width * c.width) * size.width, y: (c.minY + p.y / size.height * c.height) * size.height)
    }

    /// A rect on the uncropped preview → where it shows on the cropped viewfinder (both in points).
    static func cropped(_ r: CGRect, crop: CGRect?, size: CGSize) -> CGRect {
        guard let c = crop else { return r }
        return CGRect(x: (r.minX / size.width - c.minX) / c.width * size.width, y: (r.minY / size.height - c.minY) / c.height * size.height,
                      width: r.width / c.width, height: r.height / c.height)
    }
}

/// What to do to reach a plan, measured on the current frame.
struct CoachAdvice: Equatable, Sendable {
    /// Where the anchor should be in the frame now (accounting for any suggested zoom).
    var target: CGPoint
    /// Where it is (nil for a horizon-only plan, which only moves vertically).
    var current: CGPoint?
    var horizonTarget: CGFloat?
    var horizonNow: CGFloat?
    /// Camera zoom to set (Camera-app units), when the frame needs it and the camera can do it.
    var zoomTo: CGFloat?
    var stepBack = false
    var stepCloser = false
    var hints: [String]
    var isAligned: Bool
}

/// Live framing coach: proposes framings that guide the camera (move, tilt, zoom) instead of cropping.
/// Scores, all measured: anchor on a third or the center, room to look into, no cut at a body joint,
/// eye line, horizon on a third, nothing else cut by an edge, and how little you need to move.
enum FramingCoach {
    static let thirds = CompositionEngine.thirds

    /// Candidate framings, best first.
    static func plans(_ f: SceneFeatures, view: ViewContext, aspect: CGFloat) -> [FramingPlan] {
        var plans: [FramingPlan] = []
        let subject = CompositionEngine.primarySubject(f)
        if let subject {
            let face = f.subjects.filter { $0.kind == .face }.max { $0.box.width < $1.box.width }
            if let pose = pose(for: subject, face: face, in: f) {
                plans += personPlans(pose: pose, face: face, subject: subject, f: f, view: view, aspect: aspect)
            }
            if plans.isEmpty { plans += subjectPlans(subject, f: f, view: view, aspect: aspect) }
        }
        if subject == nil, let horizon = f.horizon {
            plans += landscapePlans(horizon, f: f, view: view, aspect: aspect)
        }
        return plans.sorted { $0.score > $1.score }
    }

    /// The pose belonging to the main subject (the person whose body contains the face, or the largest one).
    private static func pose(for subject: SceneSubject, face: SceneSubject?, in f: SceneFeatures) -> PersonPose? {
        let usable = f.poses.filter { $0.neckY != nil && $0.hipY != nil && $0.centerX != nil }
        guard !usable.isEmpty, subject.kind == .face || subject.kind == .person else { return nil }
        let point = CGPoint(x: (face ?? subject).box.midX, y: (face ?? subject).box.maxY)
        return usable.min {
            hypot(($0.centerX ?? 0) - point.x, ($0.neckY ?? 0) - point.y) < hypot(($1.centerX ?? 0) - point.x, ($1.neckY ?? 0) - point.y)
        }
    }

    // MARK: Plan builders

    /// Normalized size of a frame with pixel aspect `aspect` and normalized height `h`.
    private static func size(height h: CGFloat, aspect: CGFloat, imageAspect: CGFloat) -> CGSize {
        CGSize(width: h * aspect / imageAspect, height: h)
    }

    static func subjectPlans(_ subject: SceneSubject, f: SceneFeatures, view: ViewContext, aspect: CGFloat) -> [FramingPlan] {
        let box = subject.box
        var out: [FramingPlan] = []
        for z: CGFloat in [0.75, 0.9, 1, 1.25, 1.6, 2] {
            let s = size(height: view.visible.height / z, aspect: aspect, imageAspect: f.imageAspect)
            guard box.width < s.width * 0.92, box.height < s.height * 0.92 else { continue }
            for target in thirds + [CompositionEngine.center] {
                let rect = CGRect(x: box.midX - target.x * s.width, y: box.midY - target.y * s.height, width: s.width, height: s.height)
                guard rect.contains(box) else { continue }
                var parts: [String: Double] = [:]
                parts["placement"] = target == CompositionEngine.center ? 0.85 : 1
                let fill = Double((box.width * box.height) / (s.width * s.height))
                let band: ClosedRange<Double> = subject.kind == .face ? 0.03...0.2 : subject.kind == .person ? 0.1...0.5 : 0.05...0.4
                parts["size"] = band.contains(fill) ? 1 : fill < band.lowerBound ? fill / band.lowerBound : max(0, 1 - (fill - band.upperBound) / 0.4)
                parts["room"] = room(box, in: rect)
                parts["lead"] = lead(facing: subject.facing, anchorX: target.x)
                if let h = f.horizon { parts["horizon"] = horizonScore(h.y, in: rect) }
                parts["edges"] = edges(f, rect: rect, except: box)
                parts["effort"] = effort(rect, view: view)
                out.append(plan(.subject, rect: rect, anchor: target, anchorNow: CGPoint(x: box.midX, y: box.midY),
                                horizon: nil, parts: parts))
            }
        }
        return out
    }

    static func personPlans(pose: PersonPose, face: SceneSubject?, subject: SceneSubject, f: SceneFeatures,
                            view: ViewContext, aspect: CGFloat) -> [FramingPlan] {
        guard let neck = pose.neckY, let hip = pose.hipY, let cx = face?.box.midX ?? pose.centerX else { return [] }
        let torso = hip - neck
        guard torso > 0.02 else { return [] }
        let headTop = face.map { $0.box.minY - 0.25 * $0.box.height } ?? (neck - 0.55 * torso)
        let eyes = face.map { $0.box.minY + 0.4 * $0.box.height } ?? (neck - 0.3 * torso)
        let anchorY = eyes

        var shots: [(ShotKind, CGFloat, CGFloat)] = [ // kind, bottom edge, headroom share
            (.headAndShoulders, neck + 0.6 * torso, 0.06),
            (.waistUp, neck + 0.82 * torso, 0.08),
        ]
        if let knee = pose.kneeY, knee > hip { shots.append((.kneesUp, (hip + knee) / 2, 0.08)) }
        if let ankle = pose.ankleY, ankle > hip { shots.append((.fullBody, ankle + 0.1 * (ankle - headTop), 0.07)) }

        var out: [FramingPlan] = []
        for (kind, bottom, headroom) in shots {
            let h = (bottom - headTop) / (1 - headroom)
            guard h > 0.05 else { continue }
            let s = size(height: h, aspect: aspect, imageAspect: f.imageAspect)
            let top = headTop - headroom * h
            for tx: CGFloat in [1.0 / 3, 0.5, 2.0 / 3] {
                let rect = CGRect(x: cx - tx * s.width, y: top, width: s.width, height: s.height)
                if let face, !rect.contains(face.box) { continue }
                var parts: [String: Double] = [:]
                let eyeLine = (anchorY - rect.minY) / rect.height
                parts["placement"] = kind == .fullBody ? (tx == 0.5 ? 0.85 : 1) : Double(max(0, 1 - abs(eyeLine - 1.0 / 3) / 0.15))
                parts["lead"] = lead(facing: face?.facing ?? 0, anchorX: tx)
                parts["joints"] = jointScore(pose, rect: rect)
                parts["room"] = Double(min(1, sideRoom(pose, rect: rect) / 0.04))
                if let horizon = f.horizon { parts["horizon"] = horizonScore(horizon.y, in: rect) }
                parts["edges"] = edges(f, rect: rect, except: subject.box)
                parts["effort"] = effort(rect, view: view)
                out.append(plan(kind, rect: rect, anchor: CGPoint(x: tx, y: eyeLine), anchorNow: CGPoint(x: cx, y: anchorY),
                                horizon: nil, parts: parts))
            }
        }
        return out
    }

    /// No subject, but a horizon: place it on a third (high when the sky is plain, low when it's interesting).
    static func landscapePlans(_ horizon: HorizonLine, f: SceneFeatures, view: ViewContext, aspect: CGFloat) -> [FramingPlan] {
        var out: [FramingPlan] = []
        for z: CGFloat in [0.85, 1, 1.25] {
            let s = size(height: view.visible.height / z, aspect: aspect, imageAspect: f.imageAspect)
            for t: CGFloat in [1.0 / 3, 2.0 / 3] {
                let rect = CGRect(x: view.visible.midX - s.width / 2, y: horizon.y - t * s.height, width: s.width, height: s.height)
                var parts: [String: Double] = [:]
                parts["horizon"] = horizon.skyIsPlain == (t < 0.5) ? 1 : 0.75
                parts["effort"] = effort(rect, view: view)
                out.append(plan(.landscape, rect: rect, anchor: CGPoint(x: 0.5, y: t),
                                anchorNow: CGPoint(x: view.visible.midX, y: horizon.y), horizon: t, parts: parts))
            }
        }
        return out
    }

    private static let weights: [String: Double] = [
        "placement": 0.26, "size": 0.14, "room": 0.1, "lead": 0.12, "joints": 0.2, "horizon": 0.1, "edges": 0.06, "effort": 0.14,
    ]

    private static func plan(_ kind: ShotKind, rect: CGRect, anchor: CGPoint, anchorNow: CGPoint, horizon: CGFloat?,
                             parts: [String: Double]) -> FramingPlan {
        let total = parts.reduce(0.0) { $0 + (weights[$1.key] ?? 0) * $1.value }
        let weight = parts.keys.reduce(0.0) { $0 + (weights[$1] ?? 0) }
        return FramingPlan(kind: kind, rect: rect, anchor: anchor, anchorNow: anchorNow, horizonTarget: horizon,
                           score: weight > 0 ? total / weight : 0, breakdown: parts)
    }

    // MARK: Measurements

    static func room(_ box: CGRect, in rect: CGRect) -> Double {
        let m = [(box.minX - rect.minX) / rect.width, (rect.maxX - box.maxX) / rect.width,
                 (box.minY - rect.minY) / rect.height, (rect.maxY - box.maxY) / rect.height].min() ?? 0
        return Double(min(1, max(0, m) / 0.06))
    }

    /// 1 when there's more space in front of the face than behind it; neutral without a direction.
    static func lead(facing: CGFloat, anchorX: CGFloat) -> Double {
        guard abs(facing) > 0.01 else { return 0.8 }
        let ahead = facing > 0 ? 1 - anchorX : anchorX
        return ahead >= 0.55 ? 1 : ahead >= 0.45 ? 0.6 : 0.15
    }

    /// 1 when no frame edge runs through a joint (neck, elbows, wrists, hips, knees, ankles).
    static func jointScore(_ pose: PersonPose, rect: CGRect) -> Double {
        var cuts = 0
        for (name, p) in pose.joints where name != .nose {
            let insideX = p.x > rect.minX && p.x < rect.maxX
            let insideY = p.y > rect.minY && p.y < rect.maxY
            if insideX, abs(p.y - rect.maxY) < 0.04 * rect.height || abs(p.y - rect.minY) < 0.03 * rect.height { cuts += 1 }
            if insideY, min(abs(p.x - rect.minX), abs(p.x - rect.maxX)) < 0.03 * rect.width { cuts += 1 }
        }
        return max(0, 1 - 0.35 * Double(cuts))
    }

    /// Smallest gap between the shoulders/elbows/wrists and the side edges (negative when cut off).
    private static func sideRoom(_ pose: PersonPose, rect: CGRect) -> CGFloat {
        let arms: [BodyJoint] = [.leftShoulder, .rightShoulder, .leftElbow, .rightElbow, .leftWrist, .rightWrist]
        let xs = arms.compactMap { name -> CGFloat? in
            guard let p = pose.joints[name], p.y > rect.minY, p.y < rect.maxY else { return nil }
            return min(p.x - rect.minX, rect.maxX - p.x) / rect.width
        }
        return xs.min() ?? 0.06
    }

    /// 1 with the horizon on a third, low when it splits the frame in the middle.
    static func horizonScore(_ y: CGFloat, in rect: CGRect) -> Double {
        let t = (y - rect.minY) / rect.height
        guard (0...1).contains(t) else { return 0.7 }
        let toThird = min(abs(t - 1.0 / 3), abs(t - 2.0 / 3))
        return Double(max(0, 1 - toThird / 0.12))
    }

    /// Other subjects cut by an edge pull the eye out of the frame.
    private static func edges(_ f: SceneFeatures, rect: CGRect, except box: CGRect) -> Double {
        let cut = f.subjects.filter { $0.box != box && $0.box.intersects(rect) && !rect.contains($0.box) && !$0.box.contains(box) }.count
        return max(0, 1 - 0.25 * Double(cut))
    }

    /// Prefers framings reached with little zoom and a small turn of the phone.
    static func effort(_ rect: CGRect, view: ViewContext) -> Double {
        let zoom = abs(log(view.visible.height / rect.height))
        let move = hypot(rect.midX - view.visible.midX, rect.midY - view.visible.midY) / max(view.visible.height, 0.01)
        return Double(max(0, 1 - zoom / 1.2 - move * 0.7))
    }

    // MARK: Advice

    /// Turns a plan into on-screen targets and instructions for the current frame.
    static func advice(for plan: FramingPlan, view: ViewContext, horizonNow: CGFloat?, tolerance: CGFloat = 0.045) -> CoachAdvice {
        let v = view.visible
        let z = v.height / plan.rect.height // > 1: zoom in
        // Where the anchor must be in today's frame so that, after zooming by z, it lands on the plan's spot.
        let target = CGPoint(x: 0.5 + (plan.anchor.x - 0.5) / z, y: 0.5 + (plan.anchor.y - 0.5) / z)
        let isHorizonOnly = plan.kind == .landscape
        let current = isHorizonOnly ? nil : CGPoint(x: (plan.anchorNow.x - v.minX) / v.width, y: (plan.anchorNow.y - v.minY) / v.height)
        let horizonTarget = plan.horizonTarget.map { 0.5 + ($0 - 0.5) / z }

        var hints: [String] = []
        var dx: CGFloat = 0, dy: CGFloat = 0
        if let current {
            dx = target.x - current.x
            dy = target.y - current.y
        } else if let horizonTarget, let horizonNow {
            dy = horizonTarget - horizonNow
        }
        if view.isFront {
            if abs(dx) > tolerance || abs(dy) > tolerance { hints.append("Line up with the ring") }
        } else {
            // The subject moves right in the picture when the phone turns left, and down when it tilts up.
            if abs(dx) > tolerance { hints.append(dx > 0 ? "Pan left" : "Pan right") }
            if abs(dy) > tolerance { hints.append(dy > 0 ? "Tilt up" : "Tilt down") }
        }

        var zoomTo: CGFloat?
        var stepBack = false, stepCloser = false
        if abs(z - 1) > 0.12 {
            let wanted = view.zoom * z
            if wanted < view.minZoom - 0.01 {
                stepBack = true
                hints.append("Step back")
            } else if wanted > view.maxZoom + 0.01 {
                stepCloser = true
                hints.append("Step closer")
            } else {
                zoomTo = (wanted * 10).rounded() / 10
                hints.append(String(format: "Zoom to %@×", ZoomLimits.label(for: zoomTo ?? wanted)))
            }
        }
        let placed = abs(dx) <= tolerance && abs(dy) <= tolerance
        return CoachAdvice(target: target, current: current, horizonTarget: horizonTarget, horizonNow: horizonNow,
                           zoomTo: zoomTo, stepBack: stepBack, stepCloser: stepCloser, hints: hints,
                           isAligned: placed && abs(z - 1) <= 0.12)
    }

    // MARK: Steadiness

    /// Keeps the previous idea (same shot, same third) unless something clearly better appears, so the
    /// target doesn't flicker between thirds while you move.
    static func stabilized(previous: FramingPlan?, candidates: [FramingPlan], margin: Double = 0.08) -> FramingPlan? {
        guard let best = candidates.first else { return nil }
        guard let previous, let same = candidates.first(where: { $0.sameIdea(as: previous) }) else { return best }
        guard best.score - same.score < margin else { return best }
        // Ease toward the new measurement instead of jumping.
        var eased = same
        eased.rect = smooth(previous.rect, same.rect, 0.35)
        eased.anchor = smooth(previous.anchor, same.anchor, 0.35)
        return eased
    }

    static func smooth(_ old: CGPoint, _ new: CGPoint, _ k: CGFloat) -> CGPoint {
        CGPoint(x: old.x + (new.x - old.x) * k, y: old.y + (new.y - old.y) * k)
    }

    static func smooth(_ old: CGRect, _ new: CGRect, _ k: CGFloat) -> CGRect {
        CGRect(x: old.minX + (new.minX - old.minX) * k, y: old.minY + (new.minY - old.minY) * k,
               width: old.width + (new.width - old.width) * k, height: old.height + (new.height - old.height) * k)
    }
}
