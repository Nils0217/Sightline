// labels: production, needs-review, important
// The target as a 3D shape, not a point (Nils, 2026-10-28: "object centre + outline + fingertips").
// Built once at lock from the SAM mask + LiDAR depth: while the hand covers the object, LiDAR sees
// the hand, so guidance and grasp checks use this stored shape (the object does not move until lifted).
//
// - support: height (world y) of the surface it stands on, from the LiDAR ring around the mask
//   (matte table depth is good; glossy black phone depth is not, 2026-10-28 recording).
// - flat objects (median height < 3.5 cm above the support: phone, ruler, keys). The 0.8 cm phone
//   read 1.9–2.6 cm in the 2026-10-28 recording, the water bottle 8.4 cm.: points come from the mask rays hitting the support
//   plane instead of the object's own noisy depth.

import simd

public struct ObjectModel: Sendable {
    /// Visible-surface points, world space (m), at most `maxPoints`.
    public let points: [SIMD3<Float>]
    public let centre: SIMD3<Float>
    /// 10th–90th percentile extent per world axis (m).
    public let size: SIMD3<Float>
    /// World y of the supporting surface; nil when it could not be measured.
    public let supportHeight: Float?
    public let isFlat: Bool

    public static let maxPoints = 400
    public static let flatBelow: Float = 0.035

    public init(points: [SIMD3<Float>], supportHeight: Float?, isFlat: Bool) {
        precondition(!points.isEmpty)
        self.points = points
        self.supportHeight = supportHeight
        self.isFlat = isFlat
        let xs = points.map(\.x), ys = points.map(\.y), zs = points.map(\.z)
        centre = SIMD3(Stats.median(xs)!, Stats.median(ys)!, Stats.median(zs)!)
        func extent(_ v: [Float]) -> Float { (Stats.percentile(v, 0.9) ?? 0) - (Stats.percentile(v, 0.1) ?? 0) }
        size = SIMD3(extent(xs), extent(ys), extent(zs))
    }

    /// Point of the visible surface nearest to `p`.
    public func nearestSurfacePoint(to p: SIMD3<Float>) -> SIMD3<Float> {
        points.min { simd_distance_squared($0, p) < simd_distance_squared($1, p) }!
    }

    public func distanceToSurface(_ p: SIMD3<Float>) -> Float { simd_distance(nearestSurfacePoint(to: p), p) }

    /// Distance from `p` to the object's footprint seen from above (0 when directly over it).
    public func horizontalDistance(_ p: SIMD3<Float>) -> Float {
        points.map { q in
            let d = SIMD2(q.x - p.x, q.z - p.z)
            return simd_length(d)
        }.min()!
    }

    /// Where guidance steers the palm: flat objects are grabbed from above, so their centre (the
    /// nearest edge led the hand beside the book, 2026-10-29); solid ones from the nearest side.
    public func goal(for palm: SIMD3<Float>) -> SIMD3<Float> {
        isFlat ? centre : nearestSurfacePoint(to: palm)
    }

    /// Same shape moved (re-lock found it a little elsewhere).
    public func moved(by d: SIMD3<Float>) -> ObjectModel {
        ObjectModel(points: points.map { $0 + d }, supportHeight: supportHeight.map { $0 + d.y }, isFlat: isFlat)
    }

    // MARK: Build

    /// - Parameters: `intrinsics` of the raw image; `cameraTransform` = ARCamera.transform of the same frame.
    public static func build(mask: SourceMask, depth: DepthImage, intrinsics: CameraIntrinsics,
                             cameraTransform t: simd_float4x4, erosion: Int = 1) -> ObjectModel? {
        let r = mask.record
        let sw = Float(r.sourceWidth), sh = Float(r.sourceHeight)
        let k = intrinsics.scaled(to: SIMD2(Float(depth.width), Float(depth.height)))
        let origin = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)

        var inside: [(ray: SIMD3<Float>, point: SIMD3<Float>?)] = []  // eroded-mask pixels
        var ring: [SIMD3<Float>] = []                                  // around the mask, for the support
        let pad = max(6, Int(Float(max(r.right - r.left, r.bottom - r.top)) * 0.4))
        for j in 0..<depth.height {
            for i in 0..<depth.width {
                let p = MaskTarget.portraitNormalized(fromRawNormalized:
                    SIMD2((Float(i) + 0.5) / Float(depth.width), (Float(j) + 0.5) / Float(depth.height)))
                let sx = Int(p.x * sw), sy = Int(p.y * sh)
                let nearBox = sx >= r.left - pad && sx < r.right + pad && sy >= r.top - pad && sy < r.bottom + pad
                guard nearBox else { continue }
                let pixel = SIMD2(Float(i), Float(j))
                let ray = DepthProjector.world(fromCamera: DepthProjector.unproject(pixel: pixel, depth: 1, intrinsics: k),
                                               cameraTransform: t) - origin
                let idx = j * depth.width + i
                let d = depth.depth[idx]
                let ok = d.isFinite && d > 0 && (depth.confidence.map { $0[idx] >= 1 } ?? true)
                let world: SIMD3<Float>? = ok ? origin + ray * d : nil
                if mask.contains(sx, sy) {
                    guard (-erosion...erosion).allSatisfy({ e in
                        mask.contains(sx + e, sy) && mask.contains(sx, sy + e)
                    }) else { continue }
                    inside.append((ray, world))
                } else if !(-3...3).contains(where: { e in mask.contains(sx + e, sy) || mask.contains(sx, sy + e) }),
                          let world {
                    ring.append(world)
                }
            }
        }
        var lidar = inside.compactMap(\.point)
        guard lidar.count >= 8 else { return nil }
        // Depth outliers (edge pixels that saw the table or wall behind).
        let dists = lidar.map { simd_distance($0, origin) }
        if let med = Stats.median(dists) { lidar = lidar.filter { abs(simd_distance($0, origin) - med) <= 0.08 } }
        guard lidar.count >= 8 else { return nil }

        // A key in a door lock or a switch on a wall (v5 test, 2026-10-29): the surface around it is
        // vertical, so there is no table under it. Treat it as solid: no "down", goal = nearest surface.
        let support = isVertical(ring) ? nil : supportHeight(objectYs: lidar.map(\.y), ring: ring)
        if let support {
            lidar = lidar.filter { $0.y >= support - 0.02 }  // nothing of the object is inside the table
            // Median, not the top: glossy surfaces scatter several cm either way (2026-10-28 phone: 6 cm).
            let middle = Stats.median(lidar.map(\.y)) ?? support
            if middle - support < flatBelow {
                // Flat: intersect each mask ray with a plane 1 cm above the support.
                let planeY = support + 0.01
                let hits = inside.compactMap { item -> SIMD3<Float>? in
                    guard item.ray.y < -1e-3 else { return nil }
                    let s = (planeY - origin.y) / item.ray.y
                    return s > 0 ? origin + item.ray * s : nil
                }
                if hits.count >= 8 { return ObjectModel(points: thin(hits), supportHeight: support, isFlat: true) }
            }
        }
        guard !lidar.isEmpty else { return nil }
        return ObjectModel(points: thin(lidar), supportHeight: support, isFlat: false)
    }

    /// The ring of LiDAR points around the mask is a wall, door or cabinet front rather than a table:
    /// it spreads up and down about as much as sideways (a table ring is within ~1 cm in height).
    static func isVertical(_ ring: [SIMD3<Float>]) -> Bool {
        guard ring.count >= 10 else { return false }
        func iqr(_ v: [Float]) -> Float { (Stats.percentile(v, 0.75) ?? 0) - (Stats.percentile(v, 0.25) ?? 0) }
        let y = iqr(ring.map(\.y))
        let h = max(iqr(ring.map(\.x)), iqr(ring.map(\.z)))
        return y > 0.03 && y > 0.6 * h
    }

    /// Median height of ring points level with the object's bottom (the table, not the wall behind).
    static func supportHeight(objectYs: [Float], ring: [SIMD3<Float>]) -> Float? {
        guard let bottom = Stats.percentile(objectYs, 0.1) else { return nil }
        let level = ring.map(\.y).filter { $0 >= bottom - 0.06 && $0 <= bottom + 0.03 }
        guard level.count >= 10 else { return nil }
        return Stats.median(level)
    }

    static func thin(_ p: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard p.count > maxPoints else { return p }
        let step = Double(p.count) / Double(maxPoints)
        return (0..<maxPoints).map { p[Int(Double($0) * step)] }
    }
}

/// Where the fingertips are relative to the object.
public struct GraspAssessment: Sendable, Equatable {
    /// Fingertips within `touchDistance` of the surface.
    public var tipsNear: Int
    /// Thumb on one side, other near fingertips on the other (the object is between them).
    public var opposed: Bool
    /// Palm centre to the nearest surface point (m).
    public var palmToSurface: Float?
    /// Flat objects only: the palm is above the object's footprint. Logged, no longer part of `touching`.
    public var palmOver: Bool = true
    /// A fingertip on the surface (Nils, 2026-10-29 v5 test: judge contact with the fingertips, not the
    /// palm; the longest finger is ~11 cm from the palm centre, so palm distances miss real grasps).
    /// Before v6: palm over the footprint and two tips, or one tip plus the palm within 7 cm.
    public var touching: Bool { tipsNear >= 1 }

    public static let touchDistance: Float = 0.03

    /// Provisional geometric hold candidate. This alone never confirms possession.
    /// Nils, 2026-10-29: being next to the hand is not enough. Held = the thumb tip and at least one
    /// other fingertip on it (pinch / grip), or it rests on the palm (above the palm centre).
    public static func holds(_ hand: HandKeypoints, points: [SIMD3<Float>], centre: SIMD3<Float>) -> Bool {
        let surface = points.isEmpty ? [centre] : points
        func onIt(_ p: SIMD3<Float>) -> Bool {
            surface.contains { simd_distance($0, p) <= touchDistance + 0.01 }
        }
        if let thumb = hand.joints[.thumbTip], onIt(thumb),
           hand.tips.contains(where: { $0.key != .thumbTip && onIt($0.value) }) { return true }
        if let palm = hand.palmCentre {
            let d = centre - palm
            let across = SIMD2(d.x, d.z)
            // On the open palm: centre within 6 cm sideways and 0–10 cm above it.
            if simd_length(across) <= 0.035 && d.y >= -0.01 && d.y <= 0.035 { return true }
        }
        return false
    }
    /// Palm-over-footprint test for flat objects: horizontal distance to the nearest object point.
    public static let overMargin: Float = 0.03

    /// `touch`: fingertip-to-surface distance for this user's hand (BodyScale.handSized(touchDistance)).
    public static func assess(_ hand: HandKeypoints, object: ObjectModel, touch: Float = touchDistance) -> GraspAssessment {
        let near = hand.tips.filter { object.distanceToSurface($0.value) <= touch + 0.01 }
        var opposed = false
        if let thumb = near[.thumbTip] {
            let others = near.filter { $0.key != .thumbTip }.map(\.value)
            if !others.isEmpty {
                let fingers = others.reduce(.zero, +) / Float(others.count)
                // Directions from the centre, horizontal only (a flat object is gripped from its sides).
                var a = thumb - object.centre, b = fingers - object.centre
                a.y = 0; b.y = 0
                if simd_length(a) > 0.005, simd_length(b) > 0.005 {
                    opposed = simd_dot(simd_normalize(a), simd_normalize(b)) < -0.2
                }
            }
        }
        let strict = near.filter { object.distanceToSurface($0.value) <= touch }.count
        var over = true
        if object.isFlat {
            over = hand.reference.map { object.horizontalDistance($0) <= overMargin } ?? false
        }
        return GraspAssessment(tipsNear: strict, opposed: opposed,
                               palmToSurface: hand.reference.map { object.distanceToSurface($0) }, palmOver: over)
    }
}

/// Things standing near the target that the reaching hand could knock over.
/// v9.1 (2026-10-31, device: "Stop. Something's in the way." with nothing in the way, every search):
/// the app used a full live depth frame each frame, which holds the user's own arm, sleeve, other hand,
/// lap and flying pixels at the hand's edge; the simulator never fed it. Now one map, from the lock
/// frame (before the hand comes in), built by `scene` (shared with the simulator), carved where the
/// hand has been, and an obstacle needs a cluster of points (`minPoints`), not one.
public struct ObstacleMap: Sendable {
    /// World points (3 cm grid), not part of the target.
    public private(set) var points: [SIMD3<Float>]
    /// Points inside a path capsule needed to call it blocked: one 3 cm cell is noise or a flying pixel.
    public static let minPoints = 3

    public init(points: [SIMD3<Float>]) { self.points = points }

    /// Scene points that could be something standing near the target: 3–50 cm above its support, within
    /// 60 cm of it, more than a hand-sized 4 cm from its surface (its unmasked edge and edge pixels; 8 cm
    /// hid a bottle standing 2.5 cm from a phone, and the hand came down on it, sim 2026-10-31),
    /// and away from the user's own body (an arm-sized 25 cm around the chest camera). Single 3 cm cells
    /// without a neighbour are dropped as noise. Nil without a support height (cannot tell the table).
    public static func scene(_ world: [SIMD3<Float>], object: ObjectModel, camera: SIMD3<Float>,
                             scale: BodyScale = BodyScale()) -> ObstacleMap? {
        guard let support = object.supportHeight else { return nil }
        let nearObject = scale.handSized(0.04), body = scale.arm(0.25)
        var cells: [SIMD3<Int32>: SIMD3<Float>] = [:]
        for w in world {
            let h = w.y - support
            var flat = w - object.centre
            flat.y = 0
            var fromBody = w - camera
            fromBody.y = 0
            guard h > 0.03, h < 0.5, simd_length(flat) < 0.6, simd_length(fromBody) > body,
                  object.distanceToSurface(w) > nearObject else { continue }
            let key = SIMD3<Int32>(Int32((w.x / 0.03).rounded()), Int32((w.y / 0.03).rounded()), Int32((w.z / 0.03).rounded()))
            cells[key] = w
        }
        let keys = Set(cells.keys)
        let kept = cells.filter { key, _ in
            [SIMD3<Int32>(1, 0, 0), [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]].contains { keys.contains(key &+ $0) }
        }
        // Sorted: dictionary order changes every launch, and ties in `blocking` must not (same run, same result).
        return ObstacleMap(points: kept.sorted { ($0.key.x, $0.key.y, $0.key.z) < ($1.key.x, $1.key.y, $1.key.z) }.map(\.value))
    }

    /// One standing thing in the map: its centre, highest point and horizontal size (for naming it and
    /// for the user, who remembers its shape and size).
    public struct Cluster: Sendable, Equatable {
        public var centre: SIMD3<Float>
        public var top: Float
        public var width: Float
        public var count: Int
    }

    /// Points joined into things: neighbours closer than `link` belong together. Clusters below
    /// `minPoints` are dropped (noise). Largest first.
    public func clusters(link: Float = 0.05) -> [Cluster] {
        var left = points
        var out: [Cluster] = []
        while let seed = left.popLast() {
            var group = [seed]
            var i = 0
            while i < group.count {
                let p = group[i]
                var j = 0
                while j < left.count {
                    if simd_distance(left[j], p) < link { group.append(left.remove(at: j)) } else { j += 1 }
                }
                i += 1
            }
            guard group.count >= Self.minPoints else { continue }
            let centre = group.reduce(SIMD3<Float>(repeating: 0), +) / Float(group.count)
            let xs = group.map(\.x), zs = group.map(\.z)
            let width = max((xs.max() ?? 0) - (xs.min() ?? 0), (zs.max() ?? 0) - (zs.min() ?? 0)) + 0.03
            out.append(Cluster(centre: centre, top: group.map(\.y).max() ?? centre.y, width: width, count: group.count))
        }
        return out.sorted { $0.count > $1.count }
    }

    /// Rolling scan (v9.2, Nils: "live scan? rolling scanning"): a cell seen in two scans in a row (about
    /// a second apart) joins the map. One scan alone could be the moving arm or flying pixels, which is
    /// why v9 stopped every search; a thing put down after the lock photo stays and is added.
    /// `previous` is the last scan; returns this scan to pass next time.
    @discardableResult
    public mutating func merge(scan: ObstacleMap, previous: ObstacleMap?) -> ObstacleMap {
        guard let previous else { return scan }
        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3(Int32((p.x / 0.03).rounded()), Int32((p.y / 0.03).rounded()), Int32((p.z / 0.03).rounded()))
        }
        let before = Set(previous.points.map(key))
        let have = Set(points.map(key))
        // Same cell or a neighbouring one: keypoint-free depth still moves about a cell between frames.
        let steady = scan.points.filter { p in
            let k = key(p)
            return !have.contains(k) && (-1...1).contains { dx in (-1...1).contains { dy in (-1...1).contains { dz in
                before.contains(k &+ SIMD3(Int32(dx), Int32(dy), Int32(dz))) } } }
        }
        points += steady
        return scan
    }

    /// Space a hand joint has occupied is free: remove points within `radius` of these joints.
    public mutating func carve(_ joints: [SIMD3<Float>], radius: Float) {
        guard !joints.isEmpty, !points.isEmpty else { return }
        let r2 = radius * radius
        points.removeAll { p in joints.contains { simd_distance_squared($0, p) < r2 } }
    }

    /// Without the user's own arm: a cone from the wrist (hand-sized 6 cm) widening toward the chest
    /// camera (plus an arm-sized 14 cm there). The real arm runs from the wrist to a shoulder beside the
    /// camera; the elbow drops below that line.
    public func withoutArm(wrist: SIMD3<Float>, camera: SIMD3<Float>, scale: BodyScale = BodyScale()) -> ObstacleMap {
        let axis = camera - wrist
        let len2 = simd_length_squared(axis)
        guard len2 > 1e-6 else { return self }
        let base = scale.handSized(0.06), grow = scale.arm(0.14)
        return ObstacleMap(points: points.filter { p in
            let s = min(1, max(0, simd_dot(p - wrist, axis) / len2))
            return simd_distance(wrist + axis * s, p) > base + grow * s
        })
    }

    /// From the lock frame: unprojected depth outside the target mask (dilated), then `scene`.
    public static func build(mask: SourceMask, depth: DepthImage, intrinsics: CameraIntrinsics,
                             cameraTransform t: simd_float4x4, object: ObjectModel, scale: BodyScale = BodyScale()) -> ObstacleMap? {
        guard object.supportHeight != nil else { return nil }
        let r = mask.record
        let sw = Float(r.sourceWidth), sh = Float(r.sourceHeight)
        let k = intrinsics.scaled(to: SIMD2(Float(depth.width), Float(depth.height)))
        var world: [SIMD3<Float>] = []
        for j in stride(from: 0, to: depth.height, by: 2) {
            for i in stride(from: 0, to: depth.width, by: 2) {
                let idx = j * depth.width + i
                let d = depth.depth[idx]
                guard d.isFinite, d > 0, depth.confidence.map({ $0[idx] >= 2 }) ?? true else { continue }
                let p = MaskTarget.portraitNormalized(fromRawNormalized:
                    SIMD2((Float(i) + 0.5) / Float(depth.width), (Float(j) + 0.5) / Float(depth.height)))
                let sx = Int(p.x * sw), sy = Int(p.y * sh)
                if (-4...4).contains(where: { e in mask.contains(sx + e, sy) || mask.contains(sx, sy + e) }) { continue }
                world.append(DepthProjector.world(fromCamera: DepthProjector.unproject(pixel: SIMD2(Float(i), Float(j)), depth: d,
                                                                                    intrinsics: k), cameraTransform: t))
            }
        }
        return scene(world, object: object, camera: SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z), scale: scale)
    }

    /// Obstacle within a capsule around the segment, including both endpoint caps: the first point along
    /// the segment, when at least `minCount` points are inside. `approaching`: count only points the move
    /// brings closer (by 1 cm or more). A hand already beside something can still move along it or away;
    /// without this every direction was "blocked" next to a bottle (sim, 2026-10-31).
    public func blocking(from hand: SIMD3<Float>, to goal: SIMD3<Float>, clearance: Float = 0.08,
                         minCount: Int = 1, approaching: Bool = false) -> SIMD3<Float>? {
        let seg = goal - hand
        let len2 = simd_length_squared(seg)
        var best: (Float, SIMD3<Float>)?
        var count = 0
        for p in points {
            let s = len2 > 1e-8 ? min(1, max(0, simd_dot(p - hand, seg) / len2)) : 0
            let d = simd_distance(hand + seg * s, p)
            if d <= clearance, !approaching || d < simd_distance(hand, p) - 0.01 {
                count += 1
                if s < (best?.0 ?? .infinity) { best = (s, p) }
            }
        }
        return count >= minCount ? best?.1 : nil
    }
}

/// The hold check's verdict from its two layers (app and simulator share it). v6, 2026-10-29;
/// v9 restores the v7 rules after v8 required a 4 cm movement test (sim normal 8/20).
public enum HoldDecision {
    public enum Reason: String, Sendable { case held, stillAtSpot = "still_at_spot", goneFromSpot = "gone_from_spot", sparkOnly = "spark_only" }

    /// - Parameters:
    ///   - held: SAM sees it at the fingertips, away from its spot (and risen, if it stood on something).
    ///   - atSpot: SAM sees it at its spot (nil = cannot tell: off-screen, covered by the hand, no answer).
    ///   - spark: Spark's yes/no (photo + reference): is the hand holding that object. nil = unclear.
    /// - Returns: true = holding it, false = not it (guide again), nil = not sure.
    public static func decide(held: Bool, atSpot: Bool?, spark: Bool?) -> (result: Bool?, reason: Reason) {
        // SAM sees it in the hand: Spark can only veto (then the layers disagree: not sure).
        if held { return (spark == false ? nil : true, .held) }
        switch atSpot {
        // v7: SAM saw a key at the spot (another one of the bunch) while Spark saw the key in the hand:
        // the layers disagree, so "not sure" instead of "put it down".
        case true?: return (spark == true ? nil : false, .stillAtSpot)
        // Gone from its spot, or SAM cannot see it (a gripping hand covers it): Spark decides, yes only.
        case false?: return (spark == true ? true : nil, .goneFromSpot)
        case nil: return (spark == true ? true : nil, .sparkOnly)
        }
    }
}
