// labels: production, needs-review, important
// Hand-to-target guidance: the 30 Hz local loop's decision logic. Pure, no ARKit, unit-tested.
//
// Body frame: the phone is worn on the chest facing forward, so "forward" is the camera's viewing
// direction flattened onto the floor, "up" is world up (gravity), "right" = forward x up.

import simd

public struct BodyOffset: Sendable, Equatable {
    /// Metres, target minus hand, in the user's body frame.
    public var right: Float
    public var up: Float
    public var forward: Float
    public var length: Float { simd_length(SIMD3(right, up, forward)) }

    public init(right: Float, up: Float, forward: Float) {
        self.right = right
        self.up = up
        self.forward = forward
    }

    /// `cameraTransform` is `ARCamera.transform`. Camera looks along its −z axis.
    public init(from hand: SIMD3<Float>, to target: SIMD3<Float>, cameraTransform t: simd_float4x4) {
        let up = SIMD3<Float>(0, 1, 0)
        var forward = -SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        forward.y = 0
        // Camera pointing straight down: fall back to the camera's top edge direction.
        if simd_length(forward) < 1e-3 { forward = SIMD3(t.columns.1.x, 0, t.columns.1.z) }
        forward = simd_normalize(forward)
        let right = simd_cross(forward, up)
        let d = target - hand
        self.init(right: simd_dot(d, right), up: simd_dot(d, up), forward: simd_dot(d, forward))
    }
}

/// What the guidance loop wants to say. `key` identifies the instruction for de-duplication.
public struct GuidanceCue: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case noHand, move, stop, grab
    }
    public var kind: Kind
    public var phrase: String
    public var key: String
    /// Same axis and direction as the previous instruction ("Keep going down."), whatever the wording.
    public var repeated = false
}

/// Continuous cues, one per correction. **Obsolete for the find flow** since the 2026-10-28 device
/// test (too talkative); FindModel uses `StepGuide`. Kept for `describe`, `rounded` and tests.
public struct GuidanceController: Sendable {
    /// Inside this 3D distance the hand counts as at the object.
    public var grabRadius: Float = 0.04
    /// Must stay inside `grabRadius` this long before "Now grab".
    public var grabHold: Double = 0.3
    /// Axis offsets below this are not mentioned.
    public var axisTolerance: Float = 0.03
    /// No valid hand for this long -> ask the user to show the hand.
    public var noHandAfter: Double = 1.0

    private var insideSince: Double?
    private var lastHandTime: Double?

    public init() {}

    /// - Parameters: `offset` nil when there is no valid fingertip this frame.
    public mutating func update(time: Double, offset: BodyOffset?, targetName: String) -> GuidanceCue? {
        guard let offset else {
            insideSince = nil
            if let last = lastHandTime, time - last < noHandAfter { return nil }
            return GuidanceCue(kind: .noHand, phrase: "Hold your hand out in front of you.", key: "nohand")
        }
        lastHandTime = time
        if offset.length <= grabRadius {
            let since = insideSince ?? time
            insideSince = since
            if time - since >= grabHold {
                return GuidanceCue(kind: .grab, phrase: "Now grab.", key: "grab")
            }
            return nil
        }
        insideSince = nil
        return Self.moveCue(offset, tolerance: axisTolerance)
    }

    /// Names the single largest correction. Forward/back is said last when the others are small,
    /// because reaching forward blindly is how things get knocked over.
    static func moveCue(_ o: BodyOffset, tolerance: Float) -> GuidanceCue {
        let lateral = [("right", o.right), ("up", o.up)]
        let worstLateral = lateral.max { abs($0.1) < abs($1.1) }!
        let axis: (String, Float)
        if abs(worstLateral.1) >= tolerance && abs(worstLateral.1) >= abs(o.forward) * 0.5 {
            axis = worstLateral
        } else {
            axis = ("forward", o.forward)
        }
        let cm = Int((abs(axis.1) * 100).rounded())
        let word: String
        switch (axis.0, axis.1 >= 0) {
        case ("right", true): word = "Right"
        case ("right", false): word = "Left"
        case ("up", true): word = "Higher"
        case ("up", false): word = "Lower"
        case (_, true): word = "Forward"
        default: word = "Back"
        }
        let phrase = cm < 6 ? "A little \(word.lowercased())." : "\(word), \(Self.rounded(cm)) centimetres."
        return GuidanceCue(kind: .move, phrase: phrase, key: "\(word)-\(Self.rounded(cm))")
    }

    /// Spoken distances: whole cm under 10, then steps of 5.
    static func rounded(_ cm: Int) -> Int {
        cm < 10 ? cm : Int((Double(cm) / 5).rounded()) * 5
    }

    /// First sentence after lock: where the object is relative to the body.
    public static func describe(target: SIMD3<Float>, cameraTransform t: simd_float4x4, name: String) -> String {
        let camera = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let o = BodyOffset(from: camera, to: target, cameraTransform: t)
        let ahead = Int((max(o.forward, 0) * 100 / 10).rounded()) * 10
        var side = ""
        if abs(o.right) >= 0.1 { side = o.right > 0 ? ", to your right" : ", to your left" }
        else if abs(o.right) >= 0.04 { side = o.right > 0 ? ", slightly right" : ", slightly left" }
        return "Found the \(name), about \(max(ahead, 10)) centimetres ahead\(side)."
    }
}

/// Decides when the next spoken cue may start, so speech never piles up.
public struct SpeechThrottle: Sendable {
    /// Minimum gap between the start of two cues.
    public var minInterval: Double = 1.2
    /// The same instruction is repeated only after this long.
    public var repeatInterval: Double = 3.0
    private var lastTime: Double?
    private var lastKey: String?

    public init() {}

    public mutating func shouldSpeak(_ cue: GuidanceCue, time: Double, speaking: Bool) -> Bool {
        // "Now grab" interrupts anything.
        if cue.kind == .grab || cue.kind == .stop { return commit(cue, time) }
        if speaking { return false }
        if let last = lastTime {
            if time - last < minInterval { return false }
            if cue.key == lastKey && time - last < repeatInterval { return false }
        }
        return commit(cue, time)
    }

    private mutating func commit(_ cue: GuidanceCue, _ time: Double) -> Bool {
        if cue.kind == .grab && lastKey == "grab" { return false }
        lastTime = time
        lastKey = cue.key
        return true
    }
}

/// Parking-sensor style tones: closer = faster and higher. Only near the object.
public enum ProximityTone {
    /// Seconds between beeps for a hand-to-target distance in metres; nil = silent (too far).
    public static func interval(distance: Float) -> Double? {
        guard distance <= maxDistance else { return nil }
        let d = Double(max(distance, 0.04))
        return 0.1 + (d - 0.04) / (Double(maxDistance) - 0.04) * (0.8 - 0.1)
    }

    /// Hz, 880 at the object down to 440 at `maxDistance`.
    public static func frequency(distance: Float) -> Double {
        let d = Double(min(max(distance, 0.04), maxDistance))
        return 880 - (d - 0.04) / (Double(maxDistance) - 0.04) * 440
    }

    /// Silent beyond this (m). Was 0.6; lowered after "too noisy" (2026-10-28).
    public static let maxDistance: Float = 0.4
}
