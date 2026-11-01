// labels: obsolete, needs-review
// OBSOLETE since v9 (2026-10-31): the app and simulator no longer use this multi-observation check
// with a requested 4 cm movement (v8: normal sim run 8/20, ~50 s). Replaced by HoldCheck.swift.
// Kept compiling for HoldVerificationTests and as a record; do not build on it.
import simd

public struct HandTrace: Sendable {
    private var samples: [(time: Double, joints: [HandJoint: SIMD3<Float>])] = []
    public init() {}
    public mutating func append(time: Double, hand: HandKeypoints?) {
        samples.removeAll { time - $0.time > 2 }
        if let hand { samples.append((time, hand.joints)) }
    }
    public func isSteady(at time: Double) -> Bool {
        let recent = samples.filter { $0.time <= time && time - $0.time <= 0.4 }
        guard let first = recent.first, let last = recent.last, last.time - first.time >= 0.25 else { return false }
        return HandJoint.tips.filter { joint in
            let seen = recent.compactMap { sample -> (Double, SIMD3<Float>)? in
                sample.joints[joint].map { (sample.time, $0) }
            }
            guard seen.count >= 6, let a = seen.first, let b = seen.last, b.0 - a.0 >= 0.25 else { return false }
            for pair in zip(seen, seen.dropFirst()) where pair.1.0 - pair.0.0 > 0.15 { return false }
            return seen.allSatisfy { simd_distance($0.1, a.1) <= 0.015 }
        }.count >= 2
    }

    /// Only preceding measurements within 150 ms; never borrow future joints or stale grips.
    public func hand(at time: Double) -> HandKeypoints? {
        var joints: [HandJoint: SIMD3<Float>] = [:]
        for sample in samples.reversed() where sample.time <= time && time - sample.time <= 0.15 {
            for (joint, p) in sample.joints where joints[joint] == nil { joints[joint] = p }
        }
        return joints.isEmpty ? nil : HandKeypoints(joints: joints)
    }
}

public struct HoldObservation: Sendable {
    public var time: Double
    public var object: SIMD3<Float>?
    public var hand: HandKeypoints?
    public var identity: Bool?
    public var nearHand: Bool
    public var surface: [SIMD3<Float>]
    public var awayFromOriginal: Bool
    public init(time: Double, object: SIMD3<Float>?, hand: HandKeypoints?, identity: Bool?,
                nearHand: Bool, awayFromOriginal: Bool, surface: [SIMD3<Float>] = []) {
        self.time = time; self.object = object; self.hand = hand; self.identity = identity
        self.nearHand = nearHand; self.awayFromOriginal = awayFromOriginal; self.surface = surface
    }
    public var usable: Bool { object != nil && identity == true && nearHand && awayFromOriginal }
}

public enum HoldFailure: String, Sendable {
    case insufficientEvidence, identityMismatch, timeout, noClearMovement, missingReference, budget
}
public enum HoldVerificationResult: Sendable, Equatable {
    case collect
    case confirmed(SIMD3<Float>)
    case uncertain(HoldFailure)
}

public struct HoldVerification: Sendable {
    public static let maxObservations = 3
    public private(set) var observations: [HoldObservation] = []
    public private(set) var result = HoldVerificationResult.collect
    public init() {}
    public var attempts: Int { observations.count }
    public var latestAnchor: HoldObservation? { observations.last(where: \.usable) }

    @discardableResult public mutating func finish(_ reason: HoldFailure) -> HoldVerificationResult {
        if result == .collect { result = .uncertain(reason) }
        return result
    }

    @discardableResult public mutating func add(_ observation: HoldObservation) -> HoldVerificationResult {
        guard result == .collect else { return result }
        if let last = observations.last, observation.time <= last.time { return result }
        if let first = observations.first, observation.time - first.time > 30 { return finish(.timeout) }
        observations.append(observation)
        if observation.identity == false { return finish(.identityMismatch) }
        if observation.usable, let object = observation.object, let hand = observation.hand {
            for first in observations.dropLast() where first.usable {
                guard let firstObject = first.object, let firstHand = first.hand else { continue }
                // Any two common physical fingertips can establish motion; no per-frame tip switching.
                let agreeing = HandJoint.tips.filter { joint in
                    guard let a = firstHand.joints[joint], let b = hand.joints[joint] else { return false }
                    return HoldMotion.verified(firstObject: firstObject, firstHand: a, firstTime: first.time,
                                               object: object, hand: b, time: observation.time)
                }
                if agreeing.count >= 2 { result = .confirmed(object); return result }
            }
        }
        if observations.count >= Self.maxObservations { return finish(.insufficientEvidence) }
        return result
    }
}

public struct HoldMovementPlan: Sendable {
    public let delta: SIMD3<Float>
    public let phrase: String
    public static func make(object: SIMD3<Float>, hand: HandKeypoints, camera: simd_float4x4,
                            profile: ReachProfile, obstacles: ObstacleMap?, surface: [SIMD3<Float>] = [],
                            canSee: (SIMD3<Float>) -> Bool) -> HoldMovementPlan? {
        var forward = -SIMD3(camera.columns.2.x, 0, camera.columns.2.z)
        if simd_length(forward) < 0.001 { forward = SIMD3(camera.columns.1.x, 0, camera.columns.1.z) }
        guard simd_length(forward) > 0.001 else { return nil }
        forward = simd_normalize(forward)
        let right = simd_cross(forward, SIMD3<Float>(0, 1, 0))
        for (direction, word) in [(right, "right"), (-right, "left"), (-forward, "back"), (forward, "forward")] {
            let delta = direction * 0.04
            let context = HoldMovementContext(baseline: hand, object: object, surface: surface, delta: delta)
            guard context.failure(hand: hand, camera: camera, profile: profile, obstacles: obstacles, canSee: canSee) == nil else { continue }
            return HoldMovementPlan(delta: delta, phrase: "Move your hand and the object \(word), about four centimetres, then stop.")
        }
        return nil
    }
}

public enum HoldMovementFailure: String, Sendable { case tracking, depth, overshoot, direction, reach, view, blocked }

/// Revalidated while the instruction is spoken and during the movement. The visible object
/// surface and hand/forearm envelope share the same remaining-axis collision screen.
public struct HoldMovementContext: Sendable {
    public let baseline: HandKeypoints
    public let object: SIMD3<Float>
    public let surface: [SIMD3<Float>]
    public let delta: SIMD3<Float>
    public init(baseline: HandKeypoints, object: SIMD3<Float>, surface: [SIMD3<Float>], delta: SIMD3<Float>) {
        self.baseline = baseline; self.object = object; self.surface = surface; self.delta = delta
    }
    public func failure(hand: HandKeypoints?, camera: simd_float4x4, profile: ReachProfile,
                        obstacles: ObstacleMap?, canSee: (SIMD3<Float>) -> Bool) -> HoldMovementFailure? {
        guard let obstacles else { return .depth }
        guard let hand else { return .tracking }
        let shifts = HandJoint.tips.compactMap { joint -> SIMD3<Float>? in
            guard let a = baseline.joints[joint], let b = hand.joints[joint] else { return nil }
            return b - a
        }
        guard shifts.count >= 2 else { return .tracking }
        if shifts.contains(where: { simd_length($0) > 0.07 }) { return .overshoot }
        let shift = shifts.reduce(.zero, +) / Float(shifts.count)
        guard simd_length(delta) > 0 else { return .direction }
        let direction = simd_normalize(delta), along = simd_dot(shift, direction)
        if along < -0.015 || simd_length(shift - direction * along) > 0.025 { return .direction }
        let remaining = direction * max(0, simd_length(delta) - along)
        let movedSurface = surface.map { $0 + shift }
        var envelope = [object + shift]
        // Extremes retain wide-object edges; a sparse interior sample bounds per-frame work.
        if !movedSurface.isEmpty {
            for axis in 0..<3 {
                envelope.append(movedSurface.min { $0[axis] < $1[axis] }!)
                envelope.append(movedSurface.max { $0[axis] < $1[axis] }!)
            }
            for i in stride(from: 0, to: movedSurface.count, by: max(1, movedSurface.count / 24)) { envelope.append(movedSurface[i]) }
        }
        let points = Array(hand.tips.values) + envelope
        if !points.allSatisfy({ profile.permits(target: $0, cameraTransform: camera) && profile.permits(target: $0 + remaining, cameraTransform: camera) }) { return .reach }
        if !points.allSatisfy({ canSee($0) && canSee($0 + remaining) }) { return .view }
        let origin = SIMD3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        let selfFiltered = ObstacleMap(points: obstacles.points.filter { p in !movedSurface.contains { simd_distance_squared($0, p) <= 0.0016 } })
        let parts = HandEnvelope.centres(hand: hand, camera: origin) + envelope
        if parts.contains(where: { selfFiltered.blocking(from: $0, to: $0 + remaining) != nil }) { return .blocked }
        return nil
    }
}

/// A single movement request, observed locally. It never requests a second movement.
public struct HoldMovementCapture: Sendable {
    public let baseline: HandKeypoints
    public let delta: SIMD3<Float>
    public let started: Double
    public init(baseline: HandKeypoints, delta: SIMD3<Float>, started: Double) {
        self.baseline = baseline; self.delta = delta; self.started = started
    }
    public func overLimit(hand: HandKeypoints?) -> Bool {
        guard let hand else { return false }
        return HandJoint.tips.contains { joint in
            guard let a = baseline.joints[joint], let b = hand.joints[joint] else { return false }
            return simd_distance(a, b) > 0.07
        }
    }
    public func ready(time: Double, hand: HandKeypoints?) -> Bool {
        if time - started >= 4 { return true } // collect once even if the movement did not happen
        guard let hand, simd_length(delta) > 0 else { return false }
        let direction = simd_normalize(delta)
        return HandJoint.tips.filter { joint in
            guard let a = baseline.joints[joint], let b = hand.joints[joint] else { return false }
            let d = b - a, along = simd_dot(d, direction)
            return along >= 0.03 && along <= 0.07 && simd_length(d - direction * along) <= 0.025
        }.count >= 2
    }
}
