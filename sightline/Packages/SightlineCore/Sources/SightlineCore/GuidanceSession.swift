// labels: production, needs-review, important
// Local reach session shared by the app and synthetic simulator. Uses one real fingertip,
// a fixed camera frame, staged approach and obstacle vetoes. Near/contact geometry begins
// tactile exploration; it does not prove physical contact or grip. Tracking, camera changes
// and blocked paths latch a stop. Only the app's temporal check or explicit user confirmation
// completes the task. See docs/HUMAN_FACTORS.md for thresholds and unverified limitations.

import Foundation
import simd

public struct SpokenLine: Sendable, Equatable {
    public var text: String
    /// Cut off whatever is being said ("Stop.", "Grab it").
    public var interrupt: Bool

    public init(text: String, interrupt: Bool) {
        self.text = text
        self.interrupt = interrupt
    }
}

public struct GuidanceOutput: Sendable {
    public var lines: [SpokenLine] = []
    /// Hand-to-target distance for the proximity tones; nil = silent.
    public var toneDistance: Float?
    public var phase: GuidanceSession.Phase
    /// Actual fingertip to the visible object surface (not the intermediate waypoint).
    public var handDistance: Float?
    public var grasp: GraspAssessment?
    /// True once when the session wants the app to check the held object (photo -> Spark yes/no);
    /// answer with `resolveCheck`.
    public var requestCheck = false
    /// Why the session asked: lift, hand_lost_low, depth, near_then_left, left_object, stalled.
    public var checkReason: String?
}

public struct GuidanceSession: Sendable {
    public enum Phase: String, Sendable {
        case waitingForHand, guiding, grabbing, checking, done, gaveUp
    }

    public let targetName: String
    public private(set) var target: SIMD3<Float>
    public private(set) var object: ObjectModel?
    public private(set) var phase = Phase.waitingForHand

    public var handPromptEvery: Double = 7
    public var handSteadyFor: Double = 0.3
    public var grabNudgeAfter: Double = 8
    public var giveUpAfterGrab: Double = 20
    /// The hand counts as gone from the object when its nearest fingertip is this far from the object.
    public var leaveDistance: Float = 0.10
    /// While guiding, a fingertip this close to the surface arms the leave check.
    public var nearDistance: Float = 0.04
    public var obstacleRepeat: Double = 10
    /// Fingertip contact must hold this long before "Grab it" (measurement noise, SightlineSim).
    public var touchHold: Double = 0.3
    /// After "Grab it", nothing happening this long with the hand off the object -> guide again.
    public var regrabAfter: Double = 5

    private let reachProfile: ReachProfile?
    private var directionFrame: simd_float4x4
    private var approach: ReachApproach?
    private var lastReferenceJoint: HandJoint?
    private var referenceMissingSince: Double?
    private var lastHandSeen: Double?
    private var handLossSaid = false
    private var blocked = false
    public private(set) var pauseReason: String?
    private var guide: StepGuide
    private var pickup = PickupDetector()
    /// Any pick-up, of anything: the palm went down to the table and came up (Nils, 2026-10-30 v7).
    private var lift = LiftDetector()
    private let obstacles: ObstacleMap?
    private var handSince: Double?
    private var lastHandPrompt: Double
    private var grabbingSince: Double?
    private var nudged = false
    private var lastObstacleWarning: Double = -.infinity
    /// Grasp history while grabbing.
    /// Kept for the log/overlay; the leave decision no longer depends on it (see header).
    private var touched = false
    private var opposed = false
    private var graspPalm: SIMD3<Float>?
    private var touchSince: Double?
    /// A fingertip was within `nearDistance` of the object while guiding.
    private var cameNear = false
    /// "Keep going …" said in a row: the hand does not get there (it may already hold the object).
    private var keepGoing = 0
    /// After this many in a row, check instead of saying it again (v5 6.17, v6 run: "Keep going down"
    /// while the fingers were on the table or the phone was already in the hand).
    public var keepGoingLimit = 3
    /// Starts at most one bounded evidence cycle per search. A negative/uncertain result waits for
    /// explicit user choice; it never re-arms on subsequent hand motion.
    public private(set) var autoChecks = 0
    public var maxAutoChecks = 1
    public private(set) var awaitingUserDecision = false
    private var tapOnlySaid = false
    /// A check ran since the last "Grab it": going back to guiding must not re-arm the leave check.
    private var checkedSinceGrab = false
    /// Recent (time, nearest fingertip to the surface). v6 run 2 (2026-10-30 10:37): single-frame fingertip
    /// depth jumps of ~6 cm started 4 checks while the hand hovered 7 cm over the phone. Near and away
    /// must hold over `distanceWindow`.
    private var fingerHistory: [(time: Double, distance: Float)] = []
    public var distanceWindow: Double = 0.4
    /// Last time the hand was seen while waiting for it.
    private var handSeenAt: Double?
    /// Low-pass filtered hand reference point; keypoint jitter otherwise reads as motion.
    private var smoothed: SIMD3<Float>?
    private var smoothedAt: Double?
    public var smoothingTime: Double = 0.15

    public private(set) var opening: [SpokenLine]
    let handPrompt: String

    /// Starts the session; `opening` holds the lines to say right away.
    public init(targetName: String, target: SIMD3<Float>, object: ObjectModel? = nil, obstacles: ObstacleMap? = nil,
                cameraTransform: simd_float4x4, time: Double, reachProfile: ReachProfile? = nil) {
        self.reachProfile = reachProfile
        self.directionFrame = cameraTransform
        self.targetName = targetName
        self.object = object
        let goal = object?.centre ?? target
        self.target = goal
        self.obstacles = obstacles
        var g = StepGuide()
        g.grabRadius = 0.04  // the forward part of the hand point is the leading fingertip
        guide = g
        lastHandPrompt = time
        let prompt = "Keep your body still. Show only the hand you will use, comfortably in front of the camera."
        handPrompt = prompt
        opening = [SpokenLine(text: Self.whereIs(target: goal, cameraTransform: cameraTransform, name: targetName), interrupt: true)]
        if let profile = reachProfile, !profile.permits(target: goal, cameraTransform: cameraTransform) {
            pauseReason = "This object is outside your comfortable reach. Keep your body still. Stop and start a new search from a comfortable position."
        } else if reachProfile != nil && object == nil {
            pauseReason = "I cannot measure this object's surface reliably. Stop and start a new search."
        } else if reachProfile != nil, let turn = Self.faceLine(goal: goal, cameraTransform: cameraTransform) {
            let bodyTurn = turn.replacingOccurrences(of: "Turn a little", with: "Turn your body a little")
            pauseReason = "Keep your hand lowered. The object is near the edge of the camera view. \(bodyTurn) Then start a new search before reaching."
        }
        if let pauseReason { opening.append(SpokenLine(text: pauseReason, interrupt: false)) }
        else { opening.append(SpokenLine(text: prompt, interrupt: false)) }

    }

    /// Target moved (re-lock).
    public mutating func moveTarget(to p: SIMD3<Float>) {
        object = object?.moved(by: p - target)
        target = p
    }

    /// The app gave up waiting for a check (no photo, or the calls timed out): same as "could not tell".
    public mutating func checkTimedOut(time: Double) -> [SpokenLine] { resolveCheck(nil, time: time) }

    /// Explicit Check uses the same state machine as automatic evidence requests.
    public mutating func beginManualCheck() {
        guard !awaitingUserDecision else { return }
        phase = .checking
        lift.disarm()
        cameNear = false
        fingerHistory.removeAll()
    }

    /// Answer to `requestCheck`: true = holding it, false = not it, nil = could not tell.
    public mutating func resolveCheck(_ ok: Bool?, time: Double) -> [SpokenLine] {
        guard phase == .checking else { return [] }
        awaitingUserDecision = ok != true
        switch ok {
        case true?:
            phase = .done
            return [SpokenLine(text: "Confirmed. You have the \(targetName).", interrupt: true)]
        case false?:
            phase = .grabbing
            grabbingSince = time
            resetGrasp()
            guide.release()
            return [SpokenLine(text: "I cannot confirm the \(targetName). Confirm it yourself, start a new search, or stop.", interrupt: true)]
        case nil:
            phase = .grabbing
            grabbingSince = time
            cameNear = false  // the hand must come back to the object before the next automatic check
            return [SpokenLine(text: "I cannot confirm it. Keep your hand still. Confirm it yourself, start a new search, or stop.", interrupt: true)]
        }
    }

    public mutating func update(time: Double, hand: HandKeypoints?, cameraTransform t: simd_float4x4,
                                targetDepthDelta: Float?, speaking: Bool, trackingNormal: Bool = true,
                                liveObstacles: ObstacleMap? = nil) -> GuidanceOutput {
        if !trackingNormal || ReachFrame.rotationDifference(directionFrame, t) > 15 * .pi / 180
            || simd_distance(SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z), SIMD3(directionFrame.columns.3.x, directionFrame.columns.3.y, directionFrame.columns.3.z)) > 0.06 {
            pauseReason = "Stop your hand. Tracking or the camera direction changed. Start a new search to confirm the object again."
        }
        if let pauseReason {
            var out = GuidanceOutput(phase: phase)
            if !blocked { out.lines = [SpokenLine(text: pauseReason, interrupt: true)]; blocked = true }
            return out
        }
        if awaitingUserDecision || phase == .checking { return GuidanceOutput(phase: phase) }
        // Keep the same physical fingertip through short occlusions; switching on every frame
        // continually resets the still-hand clock and makes intermittent hands impossible to guide.
        var referencePoint: SIMD3<Float>?
        if let selected = lastReferenceJoint, let point = hand?.joints[selected] {
            referencePoint = point
            referenceMissingSince = nil
        } else {
            referenceMissingSince = referenceMissingSince ?? time
            if lastReferenceJoint == nil || time - (referenceMissingSince ?? time) > 0.5,
               let replacement = Self.referenceJoint(hand), let point = hand?.joints[replacement] {
                lastReferenceJoint = replacement
                referenceMissingSince = nil
                smoothed = nil
                smoothedAt = nil
                guide.release()
                referencePoint = point
            }
        }
        let ref = smooth(referencePoint, time: time)
        if let ref, approach == nil, let object { approach = ReachApproach(object: object, from: ref, cameraTransform: directionFrame) }
        let previousStage = approach?.stage
        let goal = ref.map { approach?.waypoint(from: $0) ?? target } ?? target
        if previousStage != approach?.stage { guide.release() }
        if let reachProfile, !reachProfile.permits(target: goal, cameraTransform: directionFrame) {
            pauseReason = "Stop your hand. The approach would exceed your comfortable reach. Stop and start a new search from a comfortable position."
            var out = GuidanceOutput(phase: phase)
            out.lines = [SpokenLine(text: pauseReason!, interrupt: true)]
            blocked = true
            return out
        }
        var offset = ref.map { BodyOffset(from: $0, to: goal, cameraTransform: directionFrame) }
        if let r = ref, let support = object?.supportHeight, r.y <= support + 0.02, let o = offset, o.up < 0 { offset?.up = 0 }
        let grasp = hand.flatMap { h in object.map { GraspAssessment.assess(h, object: $0) } }
        var out = GuidanceOutput(phase: phase, handDistance: ref.map { object?.distanceToSurface($0) ?? simd_distance($0, target) }, grasp: grasp)
        if ref != nil { lastHandSeen = time; handLossSaid = false }
        if ref == nil, phase != .waitingForHand, time - (lastHandSeen ?? time) > 0.5 {
            if !handLossSaid {
                out.lines.append(SpokenLine(text: "Stop your hand. I cannot see it; it may be covered or outside the camera view. If you already picked something up, choose Check. Otherwise return your hand slowly to its last visible position.", interrupt: true))
                handLossSaid = true
            }
            return out
        }
        // Check the actual axis segment, palm, fingertips and a conservative forearm segment.
        if phase == .guiding, let ref, let offset, let hand {
            var axes = [StepGuide.dominantAxis(offset, tolerance: guide.startTolerance).0]
            if case .moving(let activeAxis, _, _) = guide.state, !axes.contains(activeAxis) { axes.append(activeAxis) }
            var forward = -SIMD3(directionFrame.columns.2.x, 0, directionFrame.columns.2.z)
            if simd_length(forward) < 0.001 { forward = SIMD3(directionFrame.columns.1.x, 0, directionFrame.columns.1.z) }
            forward = simd_normalize(forward)
            let right = simd_cross(forward, SIMD3<Float>(0, 1, 0))
            let camera = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            let parts = HandEnvelope.centres(hand: hand, camera: camera)
            let map = liveObstacles ?? obstacles
            for axis in axes {
                let delta: SIMD3<Float>
                switch axis {
                case .right: delta = right * offset.right
                case .up: delta = SIMD3(0, offset.up, 0)
                case .forward: delta = forward * offset.forward
                }
                let reason: String?
                if let reachProfile, !reachProfile.permits(target: ref + delta, cameraTransform: directionFrame) {
                    reason = "Stop your hand. This movement would exceed your comfortable reach. Stop and start a new search from a comfortable position."
                } else if let map, parts.contains(where: { map.blocking(from: $0, to: $0 + delta) != nil }) {
                    reason = "Stop your hand. Something blocks the hand or forearm path. I cannot confirm a clear route. Stop and start a new search after the area is clear."
                } else { reason = nil }
                if let reason {
                    pauseReason = reason
                    out.lines = [SpokenLine(text: reason, interrupt: true)]
                    blocked = true
                    return out
                }
            }
        }

        if phase == .guiding || phase == .grabbing,
           pickup.update(time: time, depthDelta: targetDepthDelta, handDistance: offset?.length) {
            pickup = PickupDetector()
            return check(&out, "depth")
        }
        // Nils, 2026-10-30 (v7: "Grab it", then 8 s until a check while he held the phone): as soon as
        // the user picks anything up, check. Object-agnostic: the palm rests low, then rises or vanishes.
        if phase == .guiding || phase == .grabbing,
           let reason = lift.update(time: time, palmY: hand?.palmCentre?.y, tableY: object?.supportHeight ?? goal.y) {
            return check(&out, reason)
        }

        switch phase {
        case .waitingForHand:
            if ref != nil {
                let since = handSince ?? time
                handSince = since
                handSeenAt = time
                if time - since >= handSteadyFor && !speaking {
                    phase = .guiding
                    out.lines.append(SpokenLine(text: "I see your hand.", interrupt: false))
                }
            } else {
                // Vision drops a gripping hand in most frames: short gaps keep the steady clock.
                if let seen = handSeenAt, time - seen > 0.5 { handSince = nil }
                if speaking { lastHandPrompt = time }  // the repeat gap counts from the end of speech
                if !speaking && time - lastHandPrompt >= handPromptEvery {
                    lastHandPrompt = time
                    out.lines.append(SpokenLine(text: handPrompt, interrupt: false))
                }
            }
        case .guiding:
            out.toneDistance = out.handDistance.flatMap { $0 <= ProximityTone.maxDistance ? $0 : nil }
            if grasp?.touching == true { touchSince = touchSince ?? time } else { touchSince = nil }
            if let hand, let d = fingerDistance(hand, goal: goal) {
                recordFinger(d, time: time)
                if heldNear { cameNear = true }
                if cameNear && heldAway { return check(&out, "near_then_left") }
            }
            if let since = touchSince, time - since >= touchHold {
                guide.markGrabbing()
                startGrabbing(time: time, palm: ref)
                out.lines.append(SpokenLine(text: explorationLine, interrupt: true))
                break
            }
            if let cue = guide.update(time: time, offset: offset, canInstruct: !speaking) {
                switch cue.kind {
                case .noHand:
                    // Hand lost on the way to an object near the edge of the view: turning brings both back in.
                    let text = "Stop your hand. I cannot see it. Return slowly to the last visible position, or choose Check if you picked something up."
                    out.lines.append(SpokenLine(text: text, interrupt: false))
                case .stop:
                    keepGoing = 0  // the axis was reached: that is progress (sim sam_blind: "A little forward." / "Stop." ×3)
                    out.lines.append(SpokenLine(text: cue.phrase, interrupt: true))
                case .grab:
                    if let approach, approach.stage != .approach { guide.release(); break }
                    startGrabbing(time: time, palm: ref)
                    out.lines.append(SpokenLine(text: explorationLine, interrupt: true))
                case .move:
                    keepGoing = cue.repeated ? keepGoing + 1 : 0
                    if keepGoing >= keepGoingLimit { keepGoing = 0; return check(&out, "stalled") }
                    out.lines.append(SpokenLine(text: cue.phrase, interrupt: false))
                }
            }
        case .grabbing:
            if let grasp {
                if grasp.touching { touched = true; graspPalm = ref ?? graspPalm }
                if grasp.opposed { opposed = true; graspPalm = ref ?? graspPalm }
            }
            if let hand, let away = fingerDistance(hand, goal: goal) {
                recordFinger(away, time: time)
                if heldNear { cameNear = true }
                if cameNear, heldAway, grasp?.touching != true { return check(&out, "left_object") }
            }
            let since = grabbingSince ?? time
            // Told to grab, but the hand sits off the object and nothing happens: it could not feel it.
            // Clearly off the object, not just at the edge of "at your hand" (v6 run 2: "Grab it" every 5 s at 5–6 cm).
            if !nudged && time - since >= grabNudgeAfter && !speaking {
                nudged = true
                out.lines.append(SpokenLine(text: "Choose Check when you are holding it. Tap the main area to stop.", interrupt: false))
            }
            if time - since >= giveUpAfterGrab { phase = .gaveUp }
        case .checking, .done, .gaveUp:
            break
        }
        out.phase = phase
        return out
    }

    private mutating func check(_ out: inout GuidanceOutput, _ reason: String) -> GuidanceOutput {
        lift.disarm()
        cameNear = false
        fingerHistory.removeAll()
        keepGoing = 0
        guard autoChecks < maxAutoChecks else {
            if !tapOnlySaid {
                tapOnlySaid = true
                out.lines.append(SpokenLine(text: "Choose Check when you are holding it. Tap the main area to stop.", interrupt: false))
            }
            out.phase = phase
            return out
        }
        autoChecks += 1
        checkedSinceGrab = true
        phase = .checking
        out.requestCheck = true
        out.checkReason = reason
        out.lines.append(SpokenLine(text: "Checking.", interrupt: true))
        out.phase = phase
        return out
    }

    private mutating func recordFinger(_ d: Float, time: Double) {
        fingerHistory.append((time, d))
        fingerHistory.removeAll { time - $0.time > distanceWindow }
    }

    /// Median of the window within `nearDistance`.
    private var heldNear: Bool {
        guard fingerHistory.count >= 3 else { return false }
        return fingerHistory.map(\.distance).sorted()[fingerHistory.count / 2] <= nearDistance
    }

    /// Every sample of a window that spans most of `distanceWindow` at least `leaveDistance` away.
    private var heldAway: Bool {
        guard fingerHistory.count >= 3, let first = fingerHistory.first, let last = fingerHistory.last,
              last.time - first.time >= distanceWindow * 0.75 else { return false }
        return fingerHistory.allSatisfy { $0.distance >= leaveDistance }
    }

    /// Nearest fingertip (else the palm) to the object's surface where it was locked.
    private func fingerDistance(_ hand: HandKeypoints, goal: SIMD3<Float>) -> Float? {
        let points = hand.tips.isEmpty ? hand.reference.map { [$0] } ?? [] : Array(hand.tips.values)
        return points.map { p in object?.distanceToSurface(p) ?? simd_distance(p, goal) }.min()
    }

    /// One real fingertip on every axis; nil without a valid fingertip.
    public static func referenceJoint(_ hand: HandKeypoints?) -> HandJoint? {
        guard let hand else { return nil }
        return [HandJoint.indexTip, .middleTip, .ringTip, .littleTip, .thumbTip].first { hand.joints[$0] != nil }
    }

    public static func guidePoint(_ hand: HandKeypoints, cameraTransform t: simd_float4x4) -> SIMD3<Float>? {
        guard let joint = referenceJoint(hand) else { return nil }
        return hand.joints[joint]
    }

    private var explorationLine: String {
        let action: String
        let name = targetName.lowercased()
        if name.contains("cup") || name.contains("mug") {
            action = "Locate the side or handle by touch; I have not confirmed a handle or the contents."
        } else if object?.isFlat == true {
            action = "Find the near edge by touch, then use your usual grip."
        } else {
            action = "Locate the near surface by touch, then use your usual grip."
        }
        return "Stop. The \(targetName) is nearby; contact is not confirmed. \(action) Choose Check after picking it up."
    }

    private mutating func startGrabbing(time: Double, palm: SIMD3<Float>?) {
        phase = .grabbing
        grabbingSince = time
        nudged = false
        graspPalm = palm
        cameNear = true  // "Grab it" = the hand is at the object
        checkedSinceGrab = false
    }

    private mutating func resetGrasp() {
        touched = false
        opposed = false
        graspPalm = nil
        grabbingSince = nil
        touchSince = nil
        cameNear = false
        keepGoing = 0
    }

    private mutating func smooth(_ p: SIMD3<Float>?, time: Double) -> SIMD3<Float>? {
        guard let p else {
            if let at = smoothedAt, time - at > 0.5 { smoothed = nil }
            return nil
        }
        if let s = smoothed, let at = smoothedAt {
            let k = Float(1 - exp(-(time - at) / smoothingTime))
            smoothed = s + (p - s) * k
        } else {
            smoothed = p
        }
        smoothedAt = time
        return smoothed
    }

    /// "Found the phone. It's ahead, a little to the right, about 50 centimetres."
    /// More than this off the camera's forward direction (horizontally) = ask the user to turn.
    public static let faceAngle: Float = 20 * .pi / 180

    /// "Turn a little to your left, to face it." when the goal is off to the side; nil when ahead.
    public static func faceLine(goal: SIMD3<Float>, cameraTransform t: simd_float4x4) -> String? {
        let camera = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let forward = -SIMD3(t.columns.2.x, 0, t.columns.2.z)
        let to = SIMD3(goal.x - camera.x, 0, goal.z - camera.z)
        guard simd_length(forward) > 0.1, simd_length(to) > 0.05 else { return nil }
        let f = simd_normalize(forward), d = simd_normalize(to)
        let angle = atan2(simd_cross(f, d).y, simd_dot(f, d))  // + = left (counter-clockwise from above)
        guard abs(angle) > faceAngle else { return nil }
        return angle > 0 ? "Turn a little to your left, to face it." : "Turn a little to your right, to face it."
    }

    public static func whereIs(target: SIMD3<Float>, cameraTransform t: simd_float4x4, name: String) -> String {
        let camera = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let o = BodyOffset(from: camera, to: target, cameraTransform: t)
        let horizontal = (o.right * o.right + o.forward * o.forward).squareRoot()
        let cm = max(10, Int((horizontal * 100 / 10).rounded()) * 10)
        let side: String
        if abs(o.right) < 0.05 { side = "straight ahead" }
        else if abs(o.right) < 0.15 { side = o.right > 0 ? "ahead, a little to the right" : "ahead, a little to the left" }
        else { side = o.right > 0 ? "to your right" : "to your left" }
        return "Found the \(name). It's \(side), about \(cm) centimetres."
    }
}
