// labels: production, needs-review, important
// Local reach session shared by the app and synthetic simulator. One real fingertip, staged
// approach, reach gate and obstacle stop. v9 (2026-10-31): nothing latches. Lost tracking says
// "Hold still." and resumes; a turned body re-bases the direction frame; an obstacle stops the hand
// and resumes once the path is clear, or says where it is and guides on. Nothing ends the task.
// Spoken lines are short: one action each.
// v9.1 (2026-10-31): the check trigger is object-centred. A fingertip must stay near the target's
// surface (a contact candidate, not proof of touch), then the hand leaves it or vanishes: one check per
// such event. A hand that never came near the object never triggers (v9 LiftDetector did: palm low,
// then up). All arm and hand distances come from BodyScale (the user's reach and hand).

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
    /// Why the session asked: near_then_left (guiding), left_object (after "at your fingers"), near_then_lost.
    public var checkReason: String?
    /// True once when the hand has been gone a while: the app opens the mic and lets Spark talk with the
    /// user (v9.2, Nils: "I need to see your hand to guide you", user: ..., LLM: ...). Set `conversing`
    /// while that runs.
    public var askAboutHand = false
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
    public var grabNudgeAfter: Double = 6
    /// v9.2: 20 -> 12 and 10 -> 6 (Nils: every 8 s wait down to 6 s; the sim found 14 s silences after the
    /// 6 s nudge with 20 s here).
    public var giveUpAfterGrab: Double = 12
    public var belowRepeat: Double = 6
    /// The hand counts as gone from the object when its nearest fingertip is this far from the object.
    public var leaveDistance: Float = 0.10  // arm motion; set from BodyScale in init
    /// While guiding, a fingertip this close to the surface arms the leave check.
    public var nearDistance: Float = 0.04  // hand size; set from BodyScale in init
    /// Contact candidate, then no hand for this long: it may be hidden by what it holds (v9.1).
    public var lostAfterContact: Double = 1.5
    public let scale: BodyScale
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
    /// Hand visible without a gap since then; a flickering (gripping) hand must not reset "I can't see
    /// your hand." (v9 sim grab_unasked: said 8 times in 30 s with the hand missed in 80% of frames).
    private var handBackSince: Double?
    private var handLossSaidAt: Double = -.infinity
    public var handLossRepeat: Double = 10
    public var handLossAfter: Double = 1.0
    /// The app is talking with the user (hand help, which one): guidance is paused meanwhile.
    public var conversing = false
    private var handHelpAsked = false
    /// Last rolling scan (`addScan`), for the two-scans-in-a-row rule.
    private var lastScan: ObstacleMap?
    /// Names of things in the obstacle map (from one Spark look at the lock photo), by cluster centre.
    private var obstacleNames: [(centre: SIMD3<Float>, name: String, dangerous: Bool)] = []
    /// The object's spot looked empty (LiDAR farther than the object was thick) since then.
    private var spotEmptySince: Double?
    public var spotEmptyHold: Double = 0.5
    /// The spot was first seen with the object on it (a lock centre whose pixel shows the table behind
    /// must not read as "gone" from the start).
    private var spotSeenFull = false
    /// Set when the task cannot go on; the app ends the search. Since v9.1 nothing sets it (distance and
    /// obstacles no longer end a search); kept so the app's ending path stays in one place.
    public private(set) var endReason: String?
    private var endSaid = false
    /// The object was off to the side at the start: waiting for the user to turn and face it.
    private var needsTurn = false
    /// "Hold still." was said for lost tracking; guidance resumes silently when it is back.
    private var trackingHeld = false
    /// An obstacle stopped the hand: since when, and since when the path has been clear again.
    private var clearSince: Double?
    public var obstacleResumeAfter: Double = 1
    /// Obstacle handling: stopped (planning), going around (to a world point), or warned (guide on slowly).
    private enum ObstaclePlan: Equatable { case none, stopped(Double), detour(SIMD3<Float>), warned(StepGuide.Axis) }
    private var obstaclePlan = ObstaclePlan.none
    private var detours = 0
    private var armCarved = false
    /// Obstacles already announced with "Go slowly." this search.
    private var warnedAt: [(axis: StepGuide.Axis, point: SIMD3<Float>, hand: SIMD3<Float>)] = []
    /// Sideways shift of the goal chosen to stay clear of an obstacle beside the object.
    private var goalShift = SIMD3<Float>(repeating: 0)
    /// Planned ways around per search; then name it, say which side to pass it and guide on.
    /// 0 since v9.2 (Nils: touching things on the way is normal for a blind user, time to the object is the
    /// KPI). Sim obstacle, 20 runs: 6 detours 55.6 s median with a touch in 5; none 34.5 s with a touch in 16.
    public var maxDetours = 0
    private var lastWarnLine: Double = -.infinity
    /// Last way-around line ("Go around it on your right.") and when: the same one at most every `warnRepeat` s.
    private var lastDetourLine: (text: String, time: Double)?
    private var obstacleStopAt: Double = -.infinity
    private var directClearSince: Double?
    private var stoppedAxis: StepGuide.Axis?
    private var stoppedPoint: SIMD3<Float>?
    private var lastObstacleLine: Double = -.infinity
    public var obstacleLineGap: Double = 3
    public var warnRepeat: Double = 10
    /// Path side clearance for the reference hand (scaled by hand length).
    public static let pathClearance: Float = 0.05
    /// After lifting over an obstacle: the hand stays above this height until it is over the goal.
    private var detourFloorY: Float?
    /// The obstacle the floor keeps the hand above; the floor goes when it is no longer in the map.
    private var floorObstacle: SIMD3<Float>?
    private var guide: StepGuide
    /// Lock-frame map (see `ObstacleMap`), carved as the hand moves through it.
    private var obstacles: ObstacleMap?
    private var handSince: Double?
    private var lastHandPrompt: Double
    private var grabbingSince: Double?
    private var nudged = false
    /// "Not sure." was said then (the check could not tell).
    private var unsureAt: Double?
    private var unsureReminded = false
    public var unsureRemind: Double = 6
    private var lastObstacleWarning: Double = -.infinity
    /// Grasp history while grabbing.
    /// Kept for the log/overlay; the leave decision no longer depends on it (see header).
    private var touched = false
    private var opposed = false
    private var graspPalm: SIMD3<Float>?
    private var touchSince: Double?
    /// A fingertip was within `nearDistance` of the object while guiding.
    private var cameNear = false
    /// Lowest hand height while in contact; a rise from it with the contact candidate = carried off.
    /// v9.1: a tall bottle lifted 20 cm keeps the fingertips inside its old outline, so "left the
    /// object" never fired (sim bottle 0/20); a rise after contact is still object-centred.
    private var contactLowY: Float?
    private var riseSince: Double?
    public var riseDistance: Float = 0.05  // arm motion; set from BodyScale in init
    public var riseHold: Double = 0.2
    /// "Keep going …" said in a row: the hand does not get there (it may already hold the object).
    private var keepGoing = 0
    private var lastMoveWord: String?
    /// After this many in a row, check instead of saying it again (v5 6.17, v6 run: "Keep going down"
    /// while the fingers were on the table or the phone was already in the hand).
    public var keepGoingLimit = 3
    /// Automatic checks per search (v7: 6). After that, a double tap checks or confirms.
    public private(set) var autoChecks = 0
    public var maxAutoChecks = 6
    private var tapOnlySaid = false
    private var stillThereStreak = 0
    /// Last line while guiding (or speech still playing).
    private var lastGuideLine: Double = 0
    public var silenceLimit: Double = 6
    /// After a stall, directions repeat no sooner than this.
    private var quietUntil: Double = -.infinity
    public var stallQuiet: Double = 6
    /// "Double tap if you have it." after repeated "Keep going", once per search.
    private var stallHintSaid = false
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
                cameraTransform: simd_float4x4, time: Double, reachProfile: ReachProfile? = nil,
                scale: BodyScale = BodyScale()) {
        self.reachProfile = reachProfile
        self.scale = scale
        leaveDistance = scale.arm(0.10)
        riseDistance = scale.arm(0.05)
        nearDistance = scale.handSized(0.04)
        self.directionFrame = cameraTransform
        self.targetName = targetName
        self.object = object
        let goal = object?.centre ?? target
        self.target = goal
        self.obstacles = obstacles
        var g = StepGuide()
        g.grabRadius = scale.handSized(0.04)  // the forward part of the hand point is the leading fingertip
        g.axisTolerance = scale.handSized(g.axisTolerance)
        g.startTolerance = scale.handSized(g.startTolerance)
        guide = g
        lastHandPrompt = time
        let prompt = "Hold your hand out."
        handPrompt = prompt
        opening = [SpokenLine(text: Self.whereIs(target: goal, cameraTransform: cameraTransform, name: targetName), interrupt: true)]
        // Distance never ends the search (Nils, 2026-10-31: "I don't care how far the object is, it must
        // guide"). The reach only scales thresholds and drops a staged waypoint beyond it.
        if reachProfile != nil, let turn = Self.faceLine(goal: goal, cameraTransform: cameraTransform) {
            // Off to the side: turn the body first (the app always passes a reach profile).
            needsTurn = true
            opening.append(SpokenLine(text: turn, interrupt: false))
        } else {
            opening.append(SpokenLine(text: prompt, interrupt: false))
        }

    }

    /// Obstacle-map points within `radius` of `p` (diagnostics and the simulator).
    public func obstaclePoints(near p: SIMD3<Float>, radius: Float) -> Int {
        obstacles?.points.filter { simd_distance($0, p) < radius }.count ?? 0
    }

    /// Target moved (re-lock).
    public mutating func moveTarget(to p: SIMD3<Float>) {
        object = object?.moved(by: p - target)
        target = p
    }

    /// The app gave up waiting for a check (no photo, or the calls timed out): same as "could not tell".
    public mutating func checkTimedOut(time: Double) -> [SpokenLine] { resolveCheck(nil, time: time) }

    /// A double tap ("I have it") uses the same check as the automatic ones.
    public mutating func beginManualCheck() {
        phase = .checking
        clearContact()
        fingerHistory.removeAll()
    }

    /// Answer to `requestCheck`: true = holding it, false = not it, nil = could not tell.
    public mutating func resolveCheck(_ ok: Bool?, time: Double) -> [SpokenLine] {
        guard phase == .checking else { return [] }
        switch ok {
        case true?:
            stillThereStreak = 0
            phase = .done
            return [SpokenLine(text: "Got it. You have the \(targetName).", interrupt: true)]
        case false?:
            stillThereStreak += 1
            // HoldDecision says false only when SAM still sees it where it was: guide again from here
            // ("Stop. The ... is at your fingers." comes at once when the hand is already there).
            phase = .guiding
            resetGrasp()
            guide.release()
            lastHandSeen = time  // the check took a while: no "I can't see your hand." over this line
            return [SpokenLine(text: "The \(targetName) is still there.", interrupt: true)]
        case nil:
            stillThereStreak = 0
            phase = .grabbing
            grabbingSince = time
            nudged = true
            unsureAt = time
            unsureReminded = false
            clearContact()  // the hand must come back to the object before the next automatic check
            return [SpokenLine(text: "Not sure. Double tap if you have it.", interrupt: true)]
        }
    }

    public mutating func update(time: Double, hand: HandKeypoints?, cameraTransform t: simd_float4x4,
                                targetDepthDelta: Float?, speaking: Bool, trackingNormal: Bool = true,
                                liveObstacles: ObstacleMap? = nil) -> GuidanceOutput {
        if let endReason {
            var out = GuidanceOutput(phase: phase)
            if !endSaid { out.lines = [SpokenLine(text: endReason, interrupt: true)]; endSaid = true }
            return out
        }
        if phase == .checking { return GuidanceOutput(phase: phase) }
        // Talking with the user (hand help, which one): no directions over the conversation.
        if conversing { lastGuideLine = time; return GuidanceOutput(phase: phase) }
        // Lost tracking: hold, then carry on (v8 latched a stop until a new search).
        if !trackingNormal {
            var out = GuidanceOutput(phase: phase)
            if !trackingHeld, phase != .waitingForHand {
                trackingHeld = true
                guide.release()
                out.lines = [SpokenLine(text: "Hold still.", interrupt: true)]
            }
            return out
        }
        trackingHeld = false
        // The body turned or moved: directions follow the body, so re-base instead of stopping.
        if ReachFrame.rotationDifference(directionFrame, t) > 15 * .pi / 180
            || simd_distance(SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z),
                             SIMD3(directionFrame.columns.3.x, directionFrame.columns.3.y, directionFrame.columns.3.z)) > 0.06 {
            directionFrame = t
            approach = nil
            guide.release()
        }
        if needsTurn {
            var out = GuidanceOutput(phase: phase)
            if speaking { lastHandPrompt = time }
            if let turn = Self.faceLine(goal: target, cameraTransform: t) {
                if !speaking && time - lastHandPrompt >= handPromptEvery {
                    lastHandPrompt = time
                    out.lines = [SpokenLine(text: turn, interrupt: false)]
                }
            } else {
                needsTurn = false
                directionFrame = t
                approach = nil
                lastHandPrompt = time
                out.lines = [SpokenLine(text: "Good. " + handPrompt, interrupt: false)]
            }
            return out
        }
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
        if let ref, approach == nil, let object { approach = ReachApproach(object: object, from: ref, cameraTransform: directionFrame,
                                                                                      clearance: scale.arm(0.10)) }
        let previousStage = approach?.stage
        // The approach works on the unshifted object; a side shift (obstacle beside it) moves the whole path.
        let staged = ref.map { approach?.waypoint(from: $0 - goalShift) ?? target } ?? target
        if previousStage != approach?.stage { guide.release() }
        var goal = staged + goalShift
        if let reachProfile, !reachProfile.permits(target: goal, cameraTransform: directionFrame),
           reachProfile.permits(target: target, cameraTransform: directionFrame) {
            // A staged waypoint (lift first) beyond reach while the object is within it: go straight for the
            // object. When the object itself is beyond reach (still guided), keep the staged approach.
            approach = nil
            goal = target + goalShift
            guide.release()
        }
        var offset = ref.map { BodyOffset(from: $0, to: goal, cameraTransform: directionFrame) }
        if let r = ref, let support = object?.supportHeight, r.y <= support + 0.02, let o = offset, o.up < 0 { offset?.up = 0 }
        // Lifted over an obstacle: stay above it until the hand is over the goal.
        if let floor = detourFloorY, let r = ref, let o = offset {
            if (o.right * o.right + o.forward * o.forward).squareRoot() > guide.startTolerance {
                // Below it: rise first (the guide would otherwise move sideways first, into the obstacle).
                if r.y < floor - guide.startTolerance { offset = BodyOffset(right: 0, up: floor - r.y, forward: 0) }
                else if r.y + o.up < floor { offset?.up = floor - r.y }
            } else {
                detourFloorY = nil
            }
        }
        let grasp = hand.flatMap { h in object.map { GraspAssessment.assess(h, object: $0, touch: scale.handSized(GraspAssessment.touchDistance)) } }
        var out = GuidanceOutput(phase: phase, handDistance: ref.map { object?.distanceToSurface($0) ?? simd_distance($0, target) }, grasp: grasp)
        if ref != nil {
            if time - (lastHandSeen ?? time) > 0.2 { handBackSince = time }
            handBackSince = handBackSince ?? time
            lastHandSeen = time
            if time - handBackSince! >= 1 { handLossSaid = false }
        }
        // Contact candidate, then the hand is gone: a gripping hand is often hidden by what it holds.
        if ref == nil, cameNear, phase == .guiding || phase == .grabbing,
           let seen = lastHandSeen, time - seen >= lostAfterContact {
            return check(&out, "near_then_lost")
        }
        // v9.1: no palm-height (LiftDetector) or single-pixel depth (PickupDetector) triggers: both fired
        // without the hand ever reaching the object. v9.2 (Nils: "doesn't scan again the original place to
        // check if the object is still there?"): the spot itself going empty starts a check, which looks at
        // the spot again. Only for objects thick enough to tell from the table (a phone is 0.8 cm), only after
        // the spot was seen full, and held for `spotEmptyHold`: a hand over it reads nearer, not farther.
        if phase == .guiding || phase == .grabbing, let object, let support = object.supportHeight {
            let thick = (object.points.map(\.y).max() ?? object.centre.y) - support
            if thick >= 0.03, let d = targetDepthDelta {
                if d < thick * 0.3 { spotSeenFull = true }
                if spotSeenFull, d > max(0.02, thick * 0.6) {
                    spotEmptySince = spotEmptySince ?? time
                    if time - spotEmptySince! >= spotEmptyHold {
                        spotEmptySince = nil
                        spotSeenFull = false
                        return check(&out, "spot_empty")
                    }
                } else {
                    spotEmptySince = nil
                }
            }
        }

        // Only while guiding: a hand at or around the object is often hidden by it (Vision drops gripping hands).
        if ref == nil, phase == .guiding, time - (lastHandSeen ?? time) > handLossAfter {
            if case .detour = obstaclePlan { obstaclePlan = .none }  // the hand may come back anywhere
            // Once, then every `handLossRepeat` s while it stays gone: never silent for long (sim, 2026-10-31:
            // 117 s of silence with the hand out of view), never the v9 burst of 8 lines in 30 s.
            if !conversing, !handLossSaid || time - handLossSaidAt >= handLossRepeat {
                if handLossSaid, !handHelpAsked {
                    // Still gone after a repeat gap: talk it through once (the app listens, Spark answers).
                    handHelpAsked = true
                    out.askAboutHand = true
                    out.lines.append(SpokenLine(text: "I need to see your hand to guide you.", interrupt: false))
                } else {
                    out.lines.append(SpokenLine(text: "I can't see your hand.", interrupt: !handLossSaid))
                }
                handLossSaid = true
                handLossSaidAt = time
            }
            return out
        }
        // Obstacle on the next move (fingertips, palm and a forearm segment): stop the hand. Resume once
        // the path has been clear for `obstacleResumeAfter`. Still blocked after `obstacleGoOnAfter`: say
        // which side it is on and keep guiding (Nils, 2026-10-31: it must guide; v9 ended the search).
        if let hand {
            // Where a hand joint is, nothing else is: carve the map so a stale point cannot block forever.
            // Only about a finger's radius plus keypoint noise: a 4 cm carve erased a bottle the hand passed
            // close to, and the hand then went into it (sim obstacle).
            obstacles?.carve(Array(hand.joints.values), radius: scale.handSized(0.015))
        }
        var detouring = false
        if phase == .guiding, let ref, let o = offset, let hand {
            var forward = -SIMD3(directionFrame.columns.2.x, 0, directionFrame.columns.2.z)
            if simd_length(forward) < 0.001 { forward = SIMD3(directionFrame.columns.1.x, 0, directionFrame.columns.1.z) }
            forward = simd_normalize(forward)
            let right = simd_cross(forward, SIMD3<Float>(0, 1, 0))
            let camera = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            let parts = HandEnvelope.centres(hand: hand, camera: camera, forearm: scale.arm(0.20))
            let wrist = hand.joints[.wrist] ?? hand.joints[.middleMCP] ?? ref
            // A live map holds the arm every frame. The lock map is carved once when the hand first shows
            // (an arm already out in the lock photo is still there then); filtering it every frame hid a
            // bottle under the forearm, and the hand came down on it (sim obstacle, 2026-10-31).
            if !armCarved {
                armCarved = true
                if let o = obstacles { obstacles = o.withoutArm(wrist: wrist, camera: camera, scale: scale) }
            }
            let map = liveObstacles.map { $0.withoutArm(wrist: wrist, camera: camera, scale: scale) } ?? obstacles
            if let p = floorObstacle, (map?.points.filter { simd_distance($0, p) < 0.10 }.count ?? 0) < ObstacleMap.minPoints {
                detourFloorY = nil  // it is gone (moved away, or the hand carved through stale points)
                floorObstacle = nil
            }
            /// First obstacle point the move along `axis` of `move` brings a hand part close to; nil when clear.
            func hit(_ move: BodyOffset, _ axis: StepGuide.Axis, clearance: Float, from shift: SIMD3<Float> = .zero) -> SIMD3<Float>? {
                guard let map, !map.points.isEmpty else { return nil }
                let delta: SIMD3<Float>
                switch axis {
                case .right: delta = right * move.right
                case .up: delta = SIMD3(0, move.up, 0)
                case .forward: delta = forward * move.forward
                }
                for part in parts.map({ $0 + shift }) {
                    if let p = map.blocking(from: part, to: part + delta, clearance: clearance,
                                            minCount: ObstacleMap.minPoints, approaching: true) { return p }
                }
                return nil
            }
            // Side clearance around every hand part: keypoint error (2–3 cm on the device) plus a finger.
            // v8 used 8 cm, which made every move beside a bottle "blocked" and every way around it too.
            let clearance = scale.handSized(GuidanceSession.pathClearance)
            // A committed detour runs to its end; re-planning every frame flipped between two moves and
            // never said either (sim, 2026-10-31).
            if case .detour(let goal) = obstaclePlan {
                let d = BodyOffset(from: ref, to: goal, cameraTransform: directionFrame)
                let dAxis = StepGuide.dominantAxis(d, tolerance: guide.startTolerance).0
                let directAxis = StepGuide.dominantAxis(o, tolerance: guide.startTolerance).0
                // The direct move is clear again (the thing was moved, or the hand got past it): take it.
                // Clear for a second, not one frame: flipping between the detour and the direct move each
                // frame gave "Keep going right." / "Stop." for a minute (sim obstacle seed 11).
                if hit(o, directAxis, clearance: clearance) == nil { directClearSince = directClearSince ?? time } else { directClearSince = nil }
                let directClear = time - (directClearSince ?? time) >= 1
                // A lift was planned with the keypoint error only as side clearance (it rises beside the thing).
                let dClear = dAxis == .up && d.up > 0 ? scale.handSized(0.03) : clearance
                if d.length > guide.startTolerance, !directClear, hit(d, dAxis, clearance: dClear) == nil {
                    offset = d
                    detouring = true
                } else {
                    // Arrived, or the way around is blocked too (the hand drifted): plan again.
                    directClearSince = nil
                    obstaclePlan = .none
                    guide.release()
                }
            }
            if !detouring {
                // Moving: only the move in progress can stop the hand. At rest: the move about to be given
                // (planned around silently). Checking the next move while the current one ran stopped a
                // clear "Right" because the "Forward" after it was blocked, again and again (sim obstacle).
                var activeAxis: StepGuide.Axis?
                if case .moving(let a, _, _) = guide.state { activeAxis = a }
                // Stopped: plan for the move that was stopped. The at-rest guess of the next move can be another
                // axis, which read as clear, resumed, and the same move was stopped again (sim hazard: three
                // "Stop. A knife is in the way.").
                var axis = activeAxis ?? StepGuide.dominantAxis(o, tolerance: guide.startTolerance).0
                if activeAxis == nil, case .stopped = obstaclePlan, let s = stoppedAxis { axis = s }
                var blocked = hit(o, axis, clearance: clearance).map { (axis, $0) }
                // Stopped for something dangerous: plan around where it was seen, even if this frame's hand
                // points miss it (a switched fingertip read the stopped move as clear; the hand was sent
                // into the same stop again, sim hazard).
                if blocked == nil, case .stopped = obstaclePlan, let p = stoppedPoint, isDangerous(near: p) { blocked = (axis, p) }
                switch (obstaclePlan, blocked) {
                // Same obstacle, same move, hand still about where it was warned: no new "Stop.". From
                // elsewhere (later, coming down onto it) it is a new situation and is planned again.
                case (.none, let b?) where warnedAt.contains {
                    // A dangerous thing was named with where it is: no second "Stop." for it from anywhere
                    // (sim hazard: "Stop. A knife is in the way." / "Down" three times).
                    $0.axis == b.0 && simd_distance($0.point, b.1) < 0.12
                        && (simd_distance($0.hand, ref) < scale.handSized(0.08) || isDangerous(near: b.1))
                }:
                    // Already told about this one: no new "Stop." when the hand flickers at its edge
                    // (sim obstacle: "Stop." / "Go slowly." alternating for two minutes).
                    clearSince = nil
                    obstaclePlan = .warned(b.0)
                case (.none, let b?):
                    clearSince = nil
                    if activeAxis != nil, detours < maxDetours || isDangerous(near: b.1) {
                        // The hand is moving toward it: stop it, then plan the way around.
                        obstaclePlan = .stopped(time)
                        stoppedAxis = b.0
                        stoppedPoint = b.1
                        guide.release()
                        let thing = thingIs(near: b.1) ?? "Something's"
                        out.lines = [SpokenLine(text: "Stop. \(thing) in the way.", interrupt: true)]
                        obstacleStopAt = time
                        lastObstacleLine = time
                        return out
                    }
                    planAround(b, offset: o, ref: ref, right: right, time: time, map: map, hit: hit, out: &out)
                    if !out.lines.isEmpty { return out }
                case (.stopped(let since), let b?):
                    guard time - since >= 0.5 else { return out }
                    planAround(b, offset: o, ref: ref, right: right, time: time, map: map, hit: hit, out: &out)
                    if !out.lines.isEmpty { return out }
                case (.warned(let warnedAxis), let b?) where b.0 != warnedAxis
                        || !warnedAt.contains { simd_distance($0.hand, ref) < scale.handSized(0.08) }:
                    planAround(b, offset: o, ref: ref, right: right, time: time, map: map, hit: hit, out: &out)
                    if !out.lines.isEmpty { return out }
                case (.stopped, nil), (.warned, nil):
                    clearSince = clearSince ?? time
                    if time - clearSince! >= obstacleResumeAfter {
                        obstaclePlan = .none
                        clearSince = nil
                    } else if case .stopped = obstaclePlan {
                        return out
                    }
                case (.none, nil):
                    break
                case (.warned, _?), (.detour, _):
                    break  // warned: guide on slowly, the user knows where it is
                }
                if case .detour(let goal) = obstaclePlan {
                    offset = BodyOffset(from: ref, to: goal, cameraTransform: directionFrame)
                    detouring = true
                }
            }
        }

        switch phase {
        case .waitingForHand:
            if ref != nil {
                let since = handSince ?? time
                handSince = since
                handSeenAt = time
                if time - since >= handSteadyFor && !speaking {
                    phase = .guiding
                    lastGuideLine = time
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
                if rose(hand, time: time) { return check(&out, "near_then_rose") }
            }
            if let since = touchSince, time - since >= touchHold {
                guide.markGrabbing()
                startGrabbing(time: time, palm: ref)
                out.lines.append(SpokenLine(text: explorationLine, interrupt: true))
                break
            }
            // Never leave the user waiting in silence (sim flaky_tracking: 24 s with a flickering hand, the
            // guide waiting for a steady one): after `silenceLimit` s, say the current move again.
            if speaking || !out.lines.isEmpty { lastGuideLine = time }
            if !speaking, time - lastGuideLine >= silenceLimit, time >= quietUntil, let o = offset, o.length > guide.grabRadius {
                lastGuideLine = time
                guide.release()
                let (axis, v) = StepGuide.dominantAxis(o, tolerance: guide.startTolerance)
                out.lines.append(SpokenLine(text: StepGuide.phrase(axis: axis, value: v), interrupt: false))
                guide.resume(axis: axis, sign: v >= 0 ? 1 : -1, time: time, value: v)
                break
            }
            if let cue = guide.update(time: time, offset: offset, canInstruct: !speaking) {
                switch cue.kind {
                case .noHand:
                    // Hand lost on the way to an object near the edge of the view: turning brings both back in.
                    out.lines.append(SpokenLine(text: "I can't see your hand.", interrupt: false))
                case .stop:
                    lastMoveWord = nil
                    keepGoing = 0  // the axis was reached: that is progress (sim sam_blind: "A little forward." / "Stop." ×3)
                    out.lines.append(SpokenLine(text: cue.phrase, interrupt: true))
                case .grab:
                    // The end of a detour or a staged waypoint is not the object.
                    if detouring { guide.release(); break }
                    if let approach, approach.stage != .approach { guide.release(); break }
                    startGrabbing(time: time, palm: ref)
                    out.lines.append(SpokenLine(text: explorationLine, interrupt: true))
                case .move:
                    lastGuideLine = time
                    // Same direction again without a "Stop." in between, whether said as "Keep going left." or
                    // re-measured as "Left, 8 centimetres." (sim grab_unasked: six of them before any check).
                    let word = cue.key.split(separator: "-").first.map(String.init)
                    keepGoing = word != nil && word == lastMoveWord ? keepGoing + 1 : 0
                    lastMoveWord = word
                    // The hand does not get there: re-measure and say the full instruction again (v9.1: no
                    // check here; a hand that never reached the object has nothing to check).
                    // Said once: they may already hold it (v6: "Keep going down" with the phone in the hand).
                    if keepGoing >= keepGoingLimit {
                        keepGoing = 0
                        guide.release()
                        // The hand is not moving: after the hint, repeat the direction at most every
                        // `stallQuiet` s (sim wrong_object: "Left" / "Keep going left" every 3 s for 100 s).
                        quietUntil = time + stallQuiet
                        // Look again (v9.2, Nils): the photo shows whether it is still at its spot or in the
                        // hand. A hand hidden while gripping never gives the contact trigger (sim grab_unasked:
                        // "Keep going left" three times with the phone in the hand).
                        if autoChecks < maxAutoChecks, stillThereStreak < 2 { return check(&out, "stalled") }
                        if !stallHintSaid {
                            stallHintSaid = true
                            out.lines.append(SpokenLine(text: "Double tap if you have it.", interrupt: false))
                        }
                        break
                    }
                    if time < quietUntil {
                        // Held back, not counted: the first direction after the quiet is said in full
                        // (counting held-back cues kept extending the quiet: 80 s of silence, sim).
                        keepGoing = 0
                        guide.release()
                        break
                    }
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
                if rose(hand, time: time) { return check(&out, "near_then_rose") }
            }
            // After "Not sure.": the hand went away from the object -> guide again at once; else one reminder
            // after `unsureRemind` s (v9.2, Nils: 6 s; T11 left up to 20 s of silence after "Not sure.").
            if let at = unsureAt {
                if heldAway {
                    unsureAt = nil
                    phase = .guiding
                    resetGrasp()
                    guide.release()
                    lastGuideLine = time
                    out.phase = phase
                    return out
                }
                if !unsureReminded, time - at >= unsureRemind, !speaking {
                    unsureReminded = true
                    out.lines.append(SpokenLine(text: "Double tap if you have it.", interrupt: false))
                }
            }
            let since = grabbingSince ?? time
            // Told to grab, but the hand sits off the object and nothing happens: it could not feel it.
            // Clearly off the object, not just at the edge of "at your hand" (v6 run 2: "Grab it" every 5 s at 5–6 cm).
            if !nudged && time - since >= grabNudgeAfter && !speaking {
                nudged = true
                out.lines.append(SpokenLine(text: "Pick it up when you find it.", interrupt: false))
            }
            // No pick-up for a long while: guide again from where the hand is (Nils, 2026-10-31: it must
            // guide; v9 ended the search here with "Stopping. Tap to start again.").
            if time - since >= giveUpAfterGrab, let r = ref, let object,
               object.horizontalDistance(r) <= scale.handSized(0.04), r.y >= (object.supportHeight ?? r.y) {
                // Right above it: say so (Nils, v9.2) instead of guiding again to where the hand already is.
                // Then every `belowRepeat` s (20 s gaps were the longest silences in the sim).
                grabbingSince = time - giveUpAfterGrab + belowRepeat
                out.lines.append(SpokenLine(text: "It's right below your hand.", interrupt: false))
            } else if time - since >= giveUpAfterGrab {
                phase = .guiding
                resetGrasp()
                guide.release()
                lastGuideLine = time
                out.lines.append(SpokenLine(text: "Let's try again.", interrupt: false))
            }
        case .checking, .done, .gaveUp:
            break
        }
        out.phase = phase
        return out
    }

    /// A way around the obstacle at `point` on the blocked move: another axis of the remaining move, else
    /// straight up over it, else say where it is and guide on slowly (at most `maxDetours` per obstacle).
    private mutating func planAround(_ blocked: (StepGuide.Axis, SIMD3<Float>), offset o: BodyOffset, ref: SIMD3<Float>,
                                     right: SIMD3<Float>, time: Double, map: ObstacleMap?,
                                     hit: (BodyOffset, StepGuide.Axis, Float, SIMD3<Float>) -> SIMD3<Float>?,
                                     out: inout GuidanceOutput) {
        let (axis, point) = blocked
        let tol = guide.startTolerance
        var forward = simd_cross(SIMD3<Float>(0, 1, 0), right)
        forward = simd_length(forward) > 0 ? simd_normalize(forward) : forward
        guide.release()
        // Something dangerous (knife, flame, cactus, glass) is always gone around (Nils, v9.2: safety is a KPI
        // too; touching is fine for ordinary things only).
        if detours < maxDetours || isDangerous(near: point) && detours < Self.hazardDetours {
            var other = o
            switch axis {
            case .right: other.right = 0
            case .up: other.up = 0
            case .forward: other.forward = 0
            }
            let otherAxis = StepGuide.dominantAxis(other, tolerance: tol).0
            let value = StepGuide.value(other, otherAxis)
            // Not down: going lower beside something standing on the table does not get around it.
            if abs(value) >= tol, !(otherAxis == .up && value < 0), hit(other, otherAxis, scale.handSized(Self.pathClearance), .zero) == nil {
                let step: SIMD3<Float>
                switch otherAxis {
                case .right: step = right * value
                case .up: step = SIMD3(0, value, 0)
                case .forward: step = forward * value
                }
                detours += 1
                obstaclePlan = .detour(ref + step)
                return
            }
            // Beside it: shift the hand sideways a little and aim at a point of the object that is clear
            // (sim obstacle: a bottle 2.5 cm from the phone's near edge, the thumb landed on the bottle).
            if let object {
                let end = ref + right * o.right + SIMD3(0, o.up, 0) + forward * o.forward
                let axisMove: BodyOffset
                switch axis {
                case .right: axisMove = BodyOffset(right: o.right, up: 0, forward: 0)
                case .up: axisMove = BodyOffset(right: 0, up: o.up, forward: 0)
                case .forward: axisMove = BodyOffset(right: 0, up: 0, forward: o.forward)
                }
                // Across the blocked move; for a vertical move any horizontal direction, diagonals included
                // (the thumb sits 4–6 cm beside the index tip, so straight shifts were often not enough).
                let diagonals = [right + forward, right - forward, -right + forward, -right - forward].map { simd_normalize($0) }
                let sideways: [SIMD3<Float>] = axis == .right ? [forward, -forward] : axis == .forward ? [right, -right]
                    : [right, -right, forward, -forward] + diagonals
                // The side with fewer things first (Nils, v9.2: go around on the side with less in the way).
                let crowd: (SIMD3<Float>) -> Int = { d in
                    map?.points.filter { simd_dot($0 - ref, d) > 0 && simd_distance($0, ref) < 0.25 }.count ?? 0
                }
                let ordered = sideways.sorted { crowd($0) < crowd($1) }
                let steps = [scale.handSized(0.04), scale.handSized(0.07), scale.handSized(0.10)]
                    .flatMap { k in ordered.map { $0 * k } }
                    .filter { object.horizontalDistance(end + $0) <= scale.handSized(0.02) }
                for step in steps {
                    let sideMove = BodyOffset(right: simd_dot(step, right), up: 0, forward: simd_dot(step, forward))
                    let sideAxis: StepGuide.Axis = abs(sideMove.right) > abs(sideMove.forward) ? .right : .forward
                    if hit(sideMove, sideAxis, scale.handSized(Self.pathClearance), .zero) == nil,
                       hit(axisMove, axis, scale.handSized(Self.pathClearance), step) == nil {
                        detours += 1
                        goalShift += step
                        obstaclePlan = .detour(ref + step)
                        if abs(sideMove.right) >= abs(sideMove.forward) {
                            sayDetour("Go around it on your \(sideMove.right > 0 ? "right" : "left").", point: point, time: time, out: &out)
                        }
                        return
                    }
                }
            }
            // Back toward the body (where the hand came from) when it is right beside the obstacle.
            let back = BodyOffset(right: 0, up: 0, forward: -scale.handSized(0.08))
            if simd_distance(point, ref) < scale.handSized(Self.pathClearance) * 2,
               hit(back, .forward, scale.handSized(Self.pathClearance), .zero) == nil {
                detours += 1
                obstaclePlan = .detour(ref - forward * scale.handSized(0.08))
                return
            }
            // Over it: the highest obstacle point near the blocking one plus the clearance. Rising beside it
            // only needs the keypoint error as side clearance (a hand-sized 3 cm).
            if let map {
                let top = (map.points.filter { simd_distance($0, point) < 0.15 }.map(\.y).max() ?? point.y)
                    + scale.handSized(Self.pathClearance) + tol  // clear of it with a margin for keypoint noise
                let rise = top - ref.y
                if rise >= tol, rise <= scale.arm(0.30), hit(BodyOffset(right: 0, up: rise, forward: 0), .up, scale.handSized(0.03), .zero) == nil {
                    detours += 1
                    detourFloorY = top
                    floorObstacle = point
                    obstaclePlan = .detour(ref + SIMD3(0, rise, 0))
                    sayDetour("Lift your hand over it.", point: point, time: time, out: &out)
                    return
                }
            }
        }
        obstaclePlan = .warned(axis)
        warnedAt.append((axis, point, ref))
        // Said at most every `warnRepeat` s: the hand creeping at its edge re-plans every frame and said
        // "Go slowly." three times in half a second (sim obstacle).
        // Almost there: "at your fingers" comes next, a warning would only be cut off (sim obstacle).
        let danger = isDangerous(near: point)
        // A dangerous thing no way around: always say where it is, right after "Stop." too.
        guard danger && time - lastWarnLine >= obstacleLineGap
              || time - lastWarnLine >= warnRepeat && time - lastObstacleLine >= obstacleLineGap
                 && o.length > scale.handSized(0.06) else { return }
        lastWarnLine = time
        lastObstacleLine = time
        let side = simd_dot(point - ref, right)
        let thing = thingIs(near: point) ?? "Something is"
        let text: String
        if axis == .right || danger {
            // Moving sideways into it: where it is; passing it is up to the user's hand.
            text = "Careful. \(thing) on your \(side > 0 ? "right" : "left")."
        } else {
            // Ahead or below: pass it on the side the object is on (the next direction agrees), else away
            // from it, else the side with fewer things (Nils, v9.2).
            let goalSide = simd_dot(target + goalShift - point, right)
            let fewerRight: Bool
            if abs(goalSide) >= scale.handSized(0.04) {
                fewerRight = goalSide > 0
            } else if abs(side) >= scale.handSized(0.05) {
                fewerRight = side < 0
            } else {
                let count: (Float) -> Int = { sign in
                    map?.points.filter { simd_dot($0 - ref, right) * sign > 0 && simd_distance($0, ref) < 0.3 }.count ?? 0
                }
                fewerRight = count(1) <= count(-1)
            }
            text = "\(thing) ahead. Go around it on your \(fewerRight ? "right" : "left")."
        }
        out.lines = [SpokenLine(text: text, interrupt: true)]
    }

    /// "A bottle is ahead. Go around it on your right." The user remembers its shape and size once named
    /// (Nils, v9.2); unnamed: "Something's ahead."
    private mutating func sayDetour(_ action: String, point: SIMD3<Float>, time: Double, out: inout GuidanceOutput) {
        // Right after "Stop. A bottle is in the way." the thing was just named: the action alone.
        let named = time - obstacleStopAt < 3 ? "" : thingIs(near: point).map { "\($0) ahead. " } ?? "Something's ahead. "
        let text = named + action
        if let last = lastDetourLine, last.text == text, time - last.time < warnRepeat { return }
        // A new plan right after another line (the hand drifted, re-planned) changes silently; the next
        // direction says where to go. Two obstacle lines 0.1 s apart contradicted each other (sim obstacle).
        guard time - lastObstacleLine >= obstacleLineGap else { return }
        lastObstacleLine = time
        lastDetourLine = (text, time)
        out.lines = [SpokenLine(text: text, interrupt: false)]
    }

    /// The name Spark gave the thing at `point` (nearest named cluster within 15 cm), if any.
    private func obstacleName(near point: SIMD3<Float>) -> String? { namedThing(near: point)?.name }

    private func namedThing(near point: SIMD3<Float>) -> (centre: SIMD3<Float>, name: String, dangerous: Bool)? {
        obstacleNames.filter { simd_distance($0.centre, point) < 0.15 }
            .min { simd_distance($0.centre, point) < simd_distance($1.centre, point) }
    }

    private func isDangerous(near point: SIMD3<Float>) -> Bool { namedThing(near: point)?.dangerous ?? false }

    /// "A knife is" / "The other book is" (a second thing like the target, after the user chose).
    private func thingIs(near point: SIMD3<Float>) -> String? {
        guard let name = obstacleName(near: point) else { return nil }
        return name.hasPrefix("other ") ? "The \(name) is" : "A \(name) is"
    }

    /// Planned ways around one dangerous thing.
    public static let hazardDetours = 6

    /// Something dangerous Spark saw near the target (a flat knife is below the map's 3 cm floor): a few
    /// points there, named and gone around.
    public mutating func addHazard(at p: SIMD3<Float>, name: String) {
        var map = obstacles ?? ObstacleMap(points: [])
        let ring = (0..<8).map { i -> SIMD3<Float> in
            let a = Float(i) / 8 * 2 * .pi
            return p + SIMD3(0.025 * cos(a), 0.01, 0.025 * sin(a))
        }
        map.add([p, p + SIMD3(0, 0.02, 0)] + ring)
        obstacles = map
        obstacleNames.append((p, name, true))
    }

    /// The thing at `centre` is another one like the target (the user chose a different one): said as
    /// "the other <name>".
    public mutating func markOther(at centre: SIMD3<Float>, name: String) {
        obstacleNames.removeAll { simd_distance($0.centre, centre) < 0.05 }
        obstacleNames.append((centre, "other " + name, false))
    }

    /// Points in the map now (log).
    public var obstaclePointCount: Int { obstacles?.points.count ?? 0 }

    /// Things in the lock map, for the app to name with one Spark look at the lock photo.
    public var obstacleClusters: [ObstacleMap.Cluster] { obstacles?.clusters() ?? [] }

    /// Names for `obstacleClusters` (same order); nil or empty = unknown, said as "Something".
    public mutating func nameObstacles(_ names: [(centre: SIMD3<Float>, name: String)], dangerous: Set<String> = []) {
        let hazards = obstacleNames.filter(\.dangerous)
        obstacleNames = names.filter { !$0.name.isEmpty }.map { ($0.centre, $0.name, dangerous.contains($0.name)) } + hazards
    }

    /// Rolling scan (v9.2): a map built from the current frame (`ObstacleMap.scene`). The user's arm is
    /// removed around the visible hand and the hand's joints are carved; a cell joins the lock map only when
    /// the previous scan had it too. Without a visible hand the scan is skipped: the arm could be anywhere.
    public mutating func addScan(_ scan: ObstacleMap?, hand: HandKeypoints?, cameraTransform t: simd_float4x4) {
        guard let scan, let hand, let wrist = hand.joints[.wrist] ?? hand.joints[.middleMCP] ?? hand.reference else {
            lastScan = nil
            return
        }
        let camera = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        // A still hand is in two scans in a row, and its palm, fingers and a thick sleeve reach past a few cm
        // from the keypoints (T11 book burst: a quarter of each scan's points within 8 cm of the joints; the
        // map grew 573 -> 909 points in 10 s). The hand's shape from its measured size, plus a sleeve margin.
        var clean = scan.withoutArm(wrist: wrist, camera: camera, scale: scale, margin: scale.handSized(0.02))
        clean.carveHand(hand.joints, camera: camera, scale: scale)
        var map = obstacles ?? ObstacleMap(points: [])
        lastScan = map.merge(scan: clean, previous: lastScan)
        obstacles = map
    }

    private mutating func check(_ out: inout GuidanceOutput, _ reason: String) -> GuidanceOutput {
        clearContact()
        fingerHistory.removeAll()
        keepGoing = 0
        // Twice in a row "still there": the next pick-up is likely the same wrong thing. Stop the
        // check-and-guide-again cycle (sim wrong_object: six rounds of the same four lines).
        guard autoChecks < maxAutoChecks, stillThereStreak < 2 else {
            if !tapOnlySaid {
                tapOnlySaid = true
                out.lines.append(SpokenLine(text: "Double tap if you have it.", interrupt: false))
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
        // Kept longer than the window: a gripping hand is missed in most frames (sim grab_unasked).
        fingerHistory.removeAll { time - $0.time > max(distanceWindow, 1.0) }
    }

    /// Median of the window within `nearDistance`.
    /// Samples within `distanceWindow`; with fewer than 3 there (hand mostly missed), the last 3 of the
    /// last second.
    private var recentFingers: [(time: Double, distance: Float)] {
        guard let last = fingerHistory.last else { return [] }
        let recent = fingerHistory.filter { last.time - $0.time <= distanceWindow }
        return recent.count >= 3 ? recent : Array(fingerHistory.suffix(3))
    }

    private var heldNear: Bool {
        let pool = recentFingers
        guard pool.count >= 3 else { return false }
        return pool.map(\.distance).sorted()[pool.count / 2] <= nearDistance
    }

    private mutating func clearContact() {
        cameNear = false
        contactLowY = nil
        riseSince = nil
    }

    /// In contact (candidate), then the hand rose `riseDistance` above its lowest point for `riseHold`.
    private mutating func rose(_ hand: HandKeypoints, time: Double) -> Bool {
        guard cameNear, let y = hand.reference?.y else { riseSince = nil; return false }
        if heldNear || contactLowY == nil { contactLowY = min(contactLowY ?? y, y) }
        guard let low = contactLowY, y - low >= riseDistance else { riseSince = nil; return false }
        riseSince = riseSince ?? time
        return time - riseSince! >= riseHold
    }

    /// Every sample of a window that spans most of `distanceWindow` at least `leaveDistance` away.
    private var heldAway: Bool {
        guard let end = fingerHistory.last?.time else { return false }
        let window = fingerHistory.filter { end - $0.time <= distanceWindow }
        guard window.count >= 3, let first = window.first, end - first.time >= distanceWindow * 0.75 else { return false }
        return window.allSatisfy { $0.distance >= leaveDistance }
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

    /// "Stop. The book is at your fingers." Cups add where to feel; nothing about what is not confirmed.
    private var explorationLine: String {
        let name = targetName.lowercased()
        let hint = name.contains("cup") || name.contains("mug") ? " Feel for the side." : ""
        return "Stop. The \(targetName) is at your fingers.\(hint)"
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
        unsureAt = nil
        goalShift = .zero
        touched = false
        opposed = false
        graspPalm = nil
        grabbingSince = nil
        touchSince = nil
        clearContact()
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
        else if abs(o.right) < 0.15 { side = o.right > 0 ? "ahead, a little right" : "ahead, a little left" }
        else { side = o.right > 0 ? "to your right" : "to your left" }
        return "Found the \(name). \(side.prefix(1).uppercased() + side.dropFirst()), \(cm) centimetres."
    }
}
