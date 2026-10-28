// labels: production, needs-review, important
// The local part of one find-and-grab session, from "target locked" to "got it", as a pure state
// machine so the Mac simulator (SightlineSim) and the app run the same logic.
//
//   announce : "Found the phone. It's ahead, a little right, about 50 centimetres."
//              "Hold your hand out in front of the camera, at chest height."
//   waitHand : repeats the hand prompt every 7 s; on a steady hand -> "I see your hand."
//   guiding  : StepGuide stop-and-go on the palm centre
//   grabbing : "Stop. It's at your hand. Grab it." -> PickupDetector -> "Got it. Well done."
// Nothing here talks to the network.

import Foundation
import simd

public struct SpokenLine: Sendable, Equatable {
    public var text: String
    /// Cut off whatever is being said ("Stop.", "Grab it").
    public var interrupt: Bool
}

public struct GuidanceOutput: Sendable {
    public var lines: [SpokenLine] = []
    /// Hand-to-target distance for the proximity tones; nil = silent.
    public var toneDistance: Float?
    public var phase: GuidanceSession.Phase
    public var handDistance: Float?
}

public struct GuidanceSession: Sendable {
    public enum Phase: String, Sendable {
        case waitingForHand, guiding, grabbing, done, gaveUp
    }

    public let targetName: String
    public private(set) var target: SIMD3<Float>
    public private(set) var phase = Phase.waitingForHand

    public var handPromptEvery: Double = 7
    public var handSteadyFor: Double = 0.3
    public var grabNudgeAfter: Double = 8
    public var giveUpAfterGrab: Double = 20

    private var guide: StepGuide
    private var pickup = PickupDetector()
    private var handSince: Double?
    private var lastHandPrompt: Double
    private var grabbingSince: Double?
    private var nudged = false
    /// Low-pass filtered hand reference point; keypoint jitter otherwise reads as motion.
    private var smoothed: SIMD3<Float>?
    private var smoothedAt: Double?
    public var smoothingTime: Double = 0.15

    /// Starts the session; `opening` holds the lines to say right away.
    public init(targetName: String, target: SIMD3<Float>, cameraTransform: simd_float4x4, time: Double) {
        self.targetName = targetName
        self.target = target
        var g = StepGuide()
        g.grabRadius = 0.07  // palm centre sits a few cm off the object surface when grasping
        guide = g
        lastHandPrompt = time
        opening = [
            SpokenLine(text: Self.whereIs(target: target, cameraTransform: cameraTransform, name: targetName), interrupt: true),
            SpokenLine(text: Self.handPrompt, interrupt: false),
        ]
    }

    public private(set) var opening: [SpokenLine]

    static let handPrompt = "Hold your hand out in front of the camera, at chest height."

    /// Target moved (re-lock).
    public mutating func moveTarget(to p: SIMD3<Float>) { target = p }

    public mutating func update(time: Double, hand: HandKeypoints?, cameraTransform t: simd_float4x4,
                                targetDepthDelta: Float?, speaking: Bool) -> GuidanceOutput {
        let ref = smooth(hand?.reference, time: time)
        let offset = ref.map { BodyOffset(from: $0, to: target, cameraTransform: t) }
        var out = GuidanceOutput(phase: phase, handDistance: offset?.length)

        if phase == .guiding || phase == .grabbing,
           pickup.update(time: time, depthDelta: targetDepthDelta, handDistance: offset?.length) {
            phase = .done
            out.lines.append(SpokenLine(text: "Got it. Well done.", interrupt: true))
            out.phase = phase
            return out
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
                    out.lines.append(SpokenLine(text: Self.handPrompt, interrupt: false))
                }
            }
        case .guiding:
            out.toneDistance = offset.map(\.length).flatMap { $0 <= ProximityTone.maxDistance ? $0 : nil }
            if let cue = guide.update(time: time, offset: offset, canInstruct: !speaking) {
                switch cue.kind {
                case .noHand:
                    out.lines.append(SpokenLine(text: "I lost your hand. Hold it in front of the camera.", interrupt: false))
                case .stop:
                    out.lines.append(SpokenLine(text: cue.phrase, interrupt: true))
                case .grab:
                    phase = .grabbing
                    grabbingSince = time
                    out.lines.append(SpokenLine(text: cue.phrase, interrupt: true))
                case .move:
                    out.lines.append(SpokenLine(text: cue.phrase, interrupt: false))
                }
            }
        case .grabbing:
            let since = grabbingSince ?? time
            if !nudged && time - since >= grabNudgeAfter && !speaking {
                nudged = true
                out.lines.append(SpokenLine(text: "Tap the screen when you have it.", interrupt: false))
            }
            if time - since >= giveUpAfterGrab { phase = .gaveUp }
        case .done, .gaveUp:
            break
        }
        out.phase = phase
        return out
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
