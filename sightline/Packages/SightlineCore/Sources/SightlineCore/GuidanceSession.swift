// labels: production, needs-review, important
// The local part of one find-and-grab session, from "target locked" to "got it", as a pure state
// machine so the Mac simulator (SightlineSim) and the app run the same logic.
//
//   announce : "Found the phone. It's ahead, a little to the right, about 50 centimetres."
//              "Reach your hand forward and down, toward it."
//   waitHand : repeats the hand prompt after 7 s of silence; on a steady hand -> "I see your hand."
//   guiding  : StepGuide stop-and-go, palm centre -> nearest point of the object's surface
//              (ObjectModel), with a warning when something stands in the straight path
//   grabbing : fingertips on the surface or palm within 7 cm -> "Stop. It's at your hand. Grab it."
//   pick-up  : thumb opposite the fingers, then the hand leaves  -> "Got it."
//              any other hand leaving after "Grab it"              -> checking (app asks Spark yes/no;
//                fingertip depth on a glossy phone was too poor to tell touch from no touch, 2026-10-28)
//              tall objects: LiDAR sees the table where it stood   -> "Got it." (PickupDetector)
// Nothing here talks to the network.

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
    /// Palm to the goal (nearest surface point, or the centre without an object model).
    public var handDistance: Float?
    public var grasp: GraspAssessment?
    /// True once when the session wants the app to check the held object (photo -> Spark yes/no);
    /// answer with `resolveCheck`.
    public var requestCheck = false
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
    /// The hand counts as gone from the object beyond this palm distance from where it grasped.
    public var leaveDistance: Float = 0.10
    public var obstacleRepeat: Double = 10
    /// Fingertip contact must hold this long before "Grab it" (measurement noise, SightlineSim).
    public var touchHold: Double = 0.3
    /// After "Grab it", nothing happening this long with the hand off the object -> guide again.
    public var regrabAfter: Double = 5

    private var guide: StepGuide
    private var pickup = PickupDetector()
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
    /// Low-pass filtered hand reference point; keypoint jitter otherwise reads as motion.
    private var smoothed: SIMD3<Float>?
    private var smoothedAt: Double?
    public var smoothingTime: Double = 0.15

    public private(set) var opening: [SpokenLine]
    let handPrompt: String

    /// Starts the session; `opening` holds the lines to say right away.
    public init(targetName: String, target: SIMD3<Float>, object: ObjectModel? = nil, obstacles: ObstacleMap? = nil,
                cameraTransform: simd_float4x4, time: Double) {
        self.targetName = targetName
        self.object = object
        let goal = object?.centre ?? target
        self.target = goal
        self.obstacles = obstacles
        var g = StepGuide()
        g.grabRadius = 0.07  // palm centre sits a few cm off the surface when the fingers are on it
        guide = g
        lastHandPrompt = time
        let camera = SIMD3(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        // The 2026-10-28 recording: "at chest height" put the hand 14 cm from the lens, then it took
        // four "Down" steps. Aim the first reach at the object's height instead.
        let prompt = goal.y < camera.y - 0.2
            ? "Reach your hand forward and down, toward it."
            : "Hold your hand out in front of you, toward it."
        handPrompt = prompt
        opening = [
            SpokenLine(text: Self.whereIs(target: goal, cameraTransform: cameraTransform, name: targetName), interrupt: true),
            SpokenLine(text: prompt, interrupt: false),
        ]
    }

    /// Target moved (re-lock).
    public mutating func moveTarget(to p: SIMD3<Float>) {
        object = object?.moved(by: p - target)
        target = p
    }

    /// Answer to `requestCheck`: true = holding it, false = not it, nil = could not tell.
    public mutating func resolveCheck(_ ok: Bool?, time: Double) -> [SpokenLine] {
        guard phase == .checking else { return [] }
        switch ok {
        case true?:
            phase = .done
            return [SpokenLine(text: "Got it. Well done.", interrupt: true)]
        case false?:
            phase = .guiding
            resetGrasp()
            guide.release()
            return [SpokenLine(text: "I don't think you have the \(targetName) yet. I'll guide you again.", interrupt: true)]
        case nil:
            phase = .grabbing
            grabbingSince = time
            return [SpokenLine(text: "I'm not sure you have it. Tap the screen if you do.", interrupt: true)]
        }
    }

    public mutating func update(time: Double, hand: HandKeypoints?, cameraTransform t: simd_float4x4,
                                targetDepthDelta: Float?, speaking: Bool) -> GuidanceOutput {
        let ref = smooth(hand?.reference, time: time)
        let goal = ref.map { object?.nearestSurfacePoint(to: $0) ?? target } ?? target
        let offset = ref.map { BodyOffset(from: $0, to: goal, cameraTransform: t) }
        let grasp = hand.flatMap { h in object.map { GraspAssessment.assess(h, object: $0) } }
        var out = GuidanceOutput(phase: phase, handDistance: offset?.length, grasp: grasp)

        if phase == .guiding || phase == .grabbing,
           pickup.update(time: time, depthDelta: targetDepthDelta, handDistance: offset?.length) {
            return finish(&out, "Got it. Well done.")
        }

        switch phase {
        case .waitingForHand:
            if ref != nil {
                let since = handSince ?? time
                handSince = since
                if time - since >= handSteadyFor && !speaking {
                    phase = .guiding
                    out.lines.append(SpokenLine(text: "I see your hand.", interrupt: false))
                }
            } else {
                handSince = nil
                if speaking { lastHandPrompt = time }  // the repeat gap counts from the end of speech
                if !speaking && time - lastHandPrompt >= handPromptEvery {
                    lastHandPrompt = time
                    out.lines.append(SpokenLine(text: handPrompt, interrupt: false))
                }
            }
        case .guiding:
            out.toneDistance = offset.map(\.length).flatMap { $0 <= ProximityTone.maxDistance ? $0 : nil }
            if grasp?.touching == true { touchSince = touchSince ?? time } else { touchSince = nil }
            if let since = touchSince, time - since >= touchHold {
                guide.markGrabbing()
                startGrabbing(time: time, palm: ref)
                out.lines.append(SpokenLine(text: "Stop. It's at your hand. Grab it.", interrupt: true))
                break
            }
            if let cue = guide.update(time: time, offset: offset, canInstruct: !speaking) {
                switch cue.kind {
                case .noHand:
                    out.lines.append(SpokenLine(text: "I lost your hand. Hold it in front of the camera.", interrupt: false))
                case .stop:
                    out.lines.append(SpokenLine(text: cue.phrase, interrupt: true))
                case .grab:
                    startGrabbing(time: time, palm: ref)
                    out.lines.append(SpokenLine(text: cue.phrase, interrupt: true))
                case .move:
                    if let ref, let warning = obstacleWarning(from: ref, to: goal, cameraTransform: t, time: time) {
                        out.lines.append(SpokenLine(text: warning, interrupt: false))
                    }
                    out.lines.append(SpokenLine(text: cue.phrase, interrupt: false))
                }
            }
        case .grabbing:
            if let grasp {
                if grasp.touching { touched = true; graspPalm = ref ?? graspPalm }
                if grasp.opposed { opposed = true; graspPalm = ref ?? graspPalm }
            }
            let anchor = graspPalm ?? goal
            if let ref, simd_distance(ref, anchor) >= leaveDistance, grasp?.touching != true {
                if opposed { return finish(&out, "Got it. Well done.") }
                phase = .checking
                out.requestCheck = true
                out.lines.append(SpokenLine(text: "Checking.", interrupt: true))
                break
            }
            let since = grabbingSince ?? time
            // Told to grab, but the hand sits off the object and nothing happens: it could not feel it.
            if time - since >= regrabAfter, !touched, !opposed, grasp?.touching != true, (offset?.length ?? 0) > 0.05 {
                phase = .guiding
                resetGrasp()
                guide.release()
                break
            }
            if !nudged && time - since >= grabNudgeAfter && !speaking {
                nudged = true
                out.lines.append(SpokenLine(text: "Tap the screen when you have it, and I'll check it.", interrupt: false))
            }
            if time - since >= giveUpAfterGrab { phase = .gaveUp }
        case .checking, .done, .gaveUp:
            break
        }
        out.phase = phase
        return out
    }

    private mutating func finish(_ out: inout GuidanceOutput, _ text: String) -> GuidanceOutput {
        phase = .done
        out.lines.append(SpokenLine(text: text, interrupt: true))
        out.phase = phase
        return out
    }

    private mutating func startGrabbing(time: Double, palm: SIMD3<Float>?) {
        phase = .grabbing
        grabbingSince = time
        nudged = false
        graspPalm = palm
    }

    private mutating func resetGrasp() {
        touched = false
        opposed = false
        graspPalm = nil
        grabbingSince = nil
        touchSince = nil
    }

    private mutating func obstacleWarning(from hand: SIMD3<Float>, to goal: SIMD3<Float>, cameraTransform t: simd_float4x4,
                                          time: Double) -> String? {
        guard time - lastObstacleWarning >= obstacleRepeat, let p = obstacles?.blocking(from: hand, to: goal) else { return nil }
        lastObstacleWarning = time
        let o = BodyOffset(from: hand, to: p, cameraTransform: t)
        let side = abs(o.right) < 0.04 ? "ahead of your hand" : (o.right > 0 ? "to the right of your hand" : "to the left of your hand")
        return "Careful, something is in the way, \(side)."
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
