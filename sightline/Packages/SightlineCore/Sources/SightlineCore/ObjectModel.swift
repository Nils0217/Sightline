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

        let support = supportHeight(objectYs: lidar.map(\.y), ring: ring)
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
    /// Flat objects only: the palm is above the object's footprint (not beside its edge).
    /// Always true for solid objects, which are gripped from the side.
    public var palmOver: Bool = true
    /// At least two fingertips on it, or one plus the palm within 7 cm (the 2026-10-28 phone grab:
    /// only the thumb had depth, palm 6.1 cm from the surface; the other tips were on the glossy screen).
    /// Flat objects also need `palmOver` (2026-10-29 test: the hand stopped beside the book's corner and
    /// grabbed the USB hub next to it).
    public var touching: Bool {
        palmOver && (tipsNear >= 2 || (tipsNear >= 1 && (palmToSurface ?? .infinity) <= 0.07))
    }

    public static let touchDistance: Float = 0.03
    /// Palm-over-footprint test for flat objects: horizontal distance to the nearest object point.
    public static let overMargin: Float = 0.03

    public static func assess(_ hand: HandKeypoints, object: ObjectModel) -> GraspAssessment {
        let near = hand.tips.filter { object.distanceToSurface($0.value) <= touchDistance + 0.01 }
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
        let strict = near.filter { object.distanceToSurface($0.value) <= touchDistance }.count
        var over = true
        if object.isFlat {
            over = hand.reference.map { object.horizontalDistance($0) <= overMargin } ?? false
        }
        return GraspAssessment(tipsNear: strict, opposed: opposed,
                               palmToSurface: hand.reference.map { object.distanceToSurface($0) }, palmOver: over)
    }
}

/// Things standing near the target that the reaching hand could knock over.
public struct ObstacleMap: Sendable {
    /// World points (3 cm grid), not part of the target.
    public let points: [SIMD3<Float>]

    public init(points: [SIMD3<Float>]) { self.points = points }

    /// From the lock frame: depth points 3–50 cm above the support, within 60 cm of the target,
    /// outside the target mask (dilated).
    public static func build(mask: SourceMask, depth: DepthImage, intrinsics: CameraIntrinsics,
                             cameraTransform t: simd_float4x4, object: ObjectModel) -> ObstacleMap? {
        guard let support = object.supportHeight else { return nil }
        let r = mask.record
        let sw = Float(r.sourceWidth), sh = Float(r.sourceHeight)
        let k = intrinsics.scaled(to: SIMD2(Float(depth.width), Float(depth.height)))
        var cells: [SIMD3<Int32>: SIMD3<Float>] = [:]
        for j in stride(from: 0, to: depth.height, by: 2) {
            for i in stride(from: 0, to: depth.width, by: 2) {
                let idx = j * depth.width + i
                let d = depth.depth[idx]
                guard d.isFinite, d > 0, depth.confidence.map({ $0[idx] >= 2 }) ?? true else { continue }
                let p = MaskTarget.portraitNormalized(fromRawNormalized:
                    SIMD2((Float(i) + 0.5) / Float(depth.width), (Float(j) + 0.5) / Float(depth.height)))
                let sx = Int(p.x * sw), sy = Int(p.y * sh)
                if (-4...4).contains(where: { e in mask.contains(sx + e, sy) || mask.contains(sx, sy + e) }) { continue }
                let w = DepthProjector.world(fromCamera: DepthProjector.unproject(pixel: SIMD2(Float(i), Float(j)), depth: d,
                                                                                    intrinsics: k), cameraTransform: t)
                let h = w.y - support
                var flat = w - object.centre
                flat.y = 0
                guard h > 0.03, h < 0.5, simd_length(flat) < 0.6, object.distanceToSurface(w) > 0.05 else { continue }
                let key = SIMD3<Int32>(Int32((w.x / 0.03).rounded()), Int32((w.y / 0.03).rounded()), Int32((w.z / 0.03).rounded()))
                cells[key] = w
            }
        }
        // Single cells are depth noise; keep cells with a neighbour.
        let keys = Set(cells.keys)
        let kept = cells.filter { key, _ in
            [SIMD3<Int32>(1, 0, 0), [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]].contains { keys.contains(key &+ $0) }
        }
        return ObstacleMap(points: Array(kept.values))
    }

    /// An obstacle point within `clearance` of the straight path from the hand to `goal`
    /// (excluding the last few cm at the goal), nearest to the hand first.
    public func blocking(from hand: SIMD3<Float>, to goal: SIMD3<Float>, clearance: Float = 0.06) -> SIMD3<Float>? {
        let seg = goal - hand
        let len2 = simd_length_squared(seg)
        guard len2 > 1e-4 else { return nil }
        var best: (Float, SIMD3<Float>)?
        for p in points {
            let s = simd_dot(p - hand, seg) / len2
            guard s > 0.05, s < 0.85 else { continue }
            if simd_distance(hand + seg * s, p) <= clearance, s < (best?.0 ?? .infinity) { best = (s, p) }
        }
        return best?.1
    }
}
