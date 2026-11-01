// labels: production, needs-review, important
// Stop-and-go cues for the current approach waypoint. GuidanceSession checks the active and
// next instruction axes before permitting motion. Proximity requests tactile exploration,
// not a claim of contact or a command to grip. Legacy state names are retained for callers.

import simd

public struct StepGuide: Sendable {
    public enum Axis: String, Sendable { case right, up, forward }

    public enum State: Equatable, Sendable {
        /// Waiting for a still hand before the next instruction.
        case ready
        /// Instruction given; silent until the axis is reached or the hand stops short.
        case moving(Axis, sign: Float, issuedAt: Double)
        /// At the object; the caller watches for the pick-up.
        case grabbing
    }

    /// 3D hand-to-target distance that counts as at the object (hand point may be the palm).
    public var grabRadius: Float = 0.04
    /// An axis is "reached" when its remaining offset is below this.
    public var axisTolerance: Float = 0.03
    /// A new instruction on an axis needs at least this much offset (hysteresis against axisTolerance;
    /// v6 run 2: "A little right." / "Stop." five times while the offset sat at 3–4 cm).
    public var startTolerance: Float = 0.05
    /// Hand speed below this (m/s) counts as still.
    public var stillSpeed: Float = 0.04
    /// Must be still this long before a new instruction.
    public var stillTime: Double = 0.6
    /// No hand for this long before saying so.
    public var noHandGrace: Double = 2.5
    /// Minimum gap between two "can't see your hand" messages.
    public var noHandRepeat: Double = 10
    /// Hand stopped short of the goal: re-instruct after this long since the instruction.
    public var stalledAfter: Double = 1.5

    public private(set) var state = State.ready
    /// Remaining offset at which the current move is done. A small final move ("A little left.", all
    /// axes under `startTolerance`) runs to 1 cm: stopping it at `axisTolerance` stopped it at once and
    /// "A little left." / "Stop." repeated seven times (sim target_bias, 2026-10-31).
    private var stopAt: Float = 0.03
    private var lastSeen: Double?
    /// Recent (time, offset) samples for the speed estimate.
    private var history: [(Double, BodyOffset)] = []
    /// Speed is measured over this window, not frame to frame: hand keypoints jitter a few mm per
    /// frame, which at 30 Hz reads as ~0.3 m/s and the hand never looked still (found in SightlineSim).
    public var speedWindow: Double = 0.3
    private var stillSince: Double?
    private var lastNoHandCue: Double?
    /// Previous instruction, so a repeat after stopping short says "Keep going down." (2026-10-28
    /// recording: "Down, about 40 centimetres." four times while the hand crept down 5–10 cm each time).
    private var lastInstruction: (axis: Axis, sign: Float)?

    public init() {}

    /// - Parameter canInstruct: false while speech is playing; new instructions wait (Stop/Grab never do).
    public mutating func update(time: Double, offset: BodyOffset?, canInstruct: Bool = true) -> GuidanceCue? {
        guard state != .grabbing else { return nil }
        guard let offset else { return noHand(time) }
        let speed = trackSpeed(time: time, offset: offset)
        lastSeen = time
        let still = stillSince.map { time - $0 >= stillTime } ?? false

        if offset.length <= grabRadius {
            state = .grabbing
            return GuidanceCue(kind: .grab, phrase: "Stop. It's at your fingers.", key: "grab")
        }

        switch state {
        case .grabbing:
            return nil
        case .moving(let axis, let sign, var issuedAt):
            // The "stopped short" clock starts when the instruction has been heard, not queued.
            if !canInstruct { issuedAt = time; state = .moving(axis, sign: sign, issuedAt: time) }
            if Self.value(offset, axis) * sign <= stopAt {
                state = .ready
                stillSince = nil  // wait for the hand to settle after "Stop."
                return GuidanceCue(kind: .stop, phrase: "Stop.", key: "stop")
            }
            if canInstruct && still && speed < stillSpeed && time - issuedAt >= stalledAfter {
                return instruct(offset, time: time)
            }
            return nil
        case .ready:
            return still && canInstruct ? instruct(offset, time: time) : nil
        }
    }

    /// The caller lost the target (e.g. stopped); start over.
    public mutating func reset() { self = StepGuide() }

    /// The caller decided the hand is at the object (fingertips on its surface).
    public mutating func markGrabbing() { state = .grabbing }

    /// The hand left without taking it: back to giving instructions.
    public mutating func release() {
        state = .ready
        stillSince = nil
        lastInstruction = nil
    }

    /// The phrase for a move, without changing state ("Right, 20 centimetres." / "A little right.").
    public static func phrase(axis: Axis, value v: Float) -> String {
        let word: String
        switch (axis, v >= 0) {
        case (.right, true): word = "right"
        case (.right, false): word = "left"
        case (.up, true): word = "up"
        case (.up, false): word = "down"
        case (.forward, true): word = "forward"
        case (.forward, false): word = "back"
        }
        let cm = Int((abs(v) * 100).rounded())
        return cm < 6 ? "A little \(word)." : "\(word.prefix(1).uppercased() + word.dropFirst()), \(GuidanceController.rounded(cm)) centimetres."
    }

    /// A move the caller has just said itself (silence watchdog).
    public mutating func resume(axis: Axis, sign: Float, time: Double, value: Float) {
        lastInstruction = (axis, sign)
        stopAt = abs(value) < startTolerance ? min(axisTolerance, 0.01) : axisTolerance
        state = .moving(axis, sign: sign, issuedAt: time)
    }

    private mutating func instruct(_ o: BodyOffset, time: Double) -> GuidanceCue {
        let (axis, v) = Self.dominantAxis(o, tolerance: startTolerance)
        let sign: Float = v >= 0 ? 1 : -1
        let repeated = lastInstruction.map { $0.axis == axis && $0.sign == sign } ?? false
        lastInstruction = (axis, sign)
        stopAt = abs(v) < startTolerance ? min(axisTolerance, 0.01) : axisTolerance
        state = .moving(axis, sign: sign, issuedAt: time)
        let cm = Int((abs(v) * 100).rounded())
        // v9 (Nils, 2026-10-31: "the voice instruction is crumbled"): one short phrase per cue.
        let word: String
        switch (axis, v >= 0) {
        case (.right, true): word = "right"
        case (.right, false): word = "left"
        case (.up, true): word = "up"
        case (.up, false): word = "down"
        case (.forward, true): word = "forward"
        case (.forward, false): word = "back"
        }
        let phrase: String
        if cm < 6 { phrase = "A little \(word)." }
        else if repeated { phrase = "Keep going \(word)." }
        else { phrase = "\(word.prefix(1).uppercased() + word.dropFirst()), \(GuidanceController.rounded(cm)) centimetres." }
        return GuidanceCue(kind: .move, phrase: phrase, key: "\(word)-\(GuidanceController.rounded(cm))", repeated: repeated)
    }

    /// Left/right first, then forward/back, then up/down (Nils, 2026-10-30: the palm only steers
    /// left/right; "down" first kept a hand on the table waiting while the object was ahead-right).
    static func dominantAxis(_ o: BodyOffset, tolerance: Float) -> (Axis, Float) {
        if abs(o.right) >= tolerance { return (.right, o.right) }
        if abs(o.forward) >= tolerance { return (.forward, o.forward) }
        if abs(o.up) >= tolerance { return (.up, o.up) }
        // All small but not yet at the object: the largest one.
        return [(Axis.right, o.right), (.forward, o.forward), (.up, o.up)].max { abs($0.1) < abs($1.1) }!
    }

    static func value(_ o: BodyOffset, _ axis: Axis) -> Float {
        switch axis {
        case .right: o.right
        case .up: o.up
        case .forward: o.forward
        }
    }

    /// Vision misses single frames; shorter gaps than this keep the speed history.
    public var dropoutTolerance: Double = 0.5

    private mutating func noHand(_ time: Double) -> GuidanceCue? {
        if let seen = lastSeen, time - seen < dropoutTolerance { return nil }
        stillSince = nil
        history.removeAll()
        if let seen = lastSeen, time - seen < noHandGrace { return nil }
        if lastSeen == nil, lastNoHandCue == nil { lastNoHandCue = time; return nil }  // grace from the start too
        if let said = lastNoHandCue, time - said < noHandRepeat { return nil }
        lastNoHandCue = time
        return GuidanceCue(kind: .noHand, phrase: "I can't see your hand. Keep it in front of you, below the phone.", key: "nohand")
    }

    private mutating func trackSpeed(time: Double, offset: BodyOffset) -> Float {
        history.append((time, offset))
        while history.count > 2, time - history[1].0 >= speedWindow { history.removeFirst() }
        guard let (t0, prev) = history.first, time - t0 >= speedWindow * 0.5 else { stillSince = nil; return .infinity }
        let d = SIMD3(offset.right - prev.right, offset.up - prev.up, offset.forward - prev.forward)
        let speed = simd_length(d) / Float(time - t0)
        if speed < stillSpeed {
            if stillSince == nil { stillSince = time }
        } else {
            stillSince = nil
        }
        return speed
    }
}

/// OBSOLETE since v9.1 (2026-10-31): no longer used by GuidanceSession (a single depth pixel cannot tell a
/// lift from a push; SpotEvidence now records the whole visible footprint). Kept for its tests.
/// Local pick-up check: once the hand has been near the target, the LiDAR depth where the object
/// sat jumps *farther* (the table or floor behind it) when the object is lifted away.
public struct PickupDetector: Sendable {
    /// Depth must be this much farther than the object was.
    public var farther: Float = 0.04
    /// For this long (accumulated, decays when not seen).
    public var hold: Double = 0.5
    /// The hand must have been within this distance in the last `recentWindow` seconds.
    public var nearHand: Float = 0.2
    public var recentWindow: Double = 4

    private var lastNear: Double?
    private var accumulated: Double = 0
    private var lastTime: Double?

    public init() {}

    /// - Parameters:
    ///   - depthDelta: measured depth at the target pixel minus the target's expected depth (m); nil if not measurable.
    ///   - handDistance: hand-to-target distance, nil if no hand.
    public mutating func update(time: Double, depthDelta: Float?, handDistance: Float?) -> Bool {
        defer { lastTime = time }
        if let h = handDistance, h <= nearHand { lastNear = time }
        let dt = lastTime.map { min(time - $0, 0.2) } ?? 0
        guard let near = lastNear, time - near <= recentWindow, let delta = depthDelta else {
            accumulated = max(0, accumulated - dt)
            return false
        }
        accumulated = delta >= farther ? accumulated + dt : max(0, accumulated - dt)
        return accumulated >= hold
    }
}

/// Picking something up, whatever it is (Nils, 2026-10-30 v7: "用戶一抓起任何東西要馬上啟動判定").
/// Hand shape cannot tell a grip on the device (camera from above, fingertip depth jumps; v6/v7
/// recordings), so this watches the palm, whose joints track well:
///   armed : the palm stays within `lowAbove` of the table for `dwell` (reaching and taking hold)
///   lift  : then rises `rise` above its lowest point for `riseHold` -> "lift"
///   lost  : or the hand disappears for `lostAfter` while armed (fingers around an object hide it)
/// -> "hand_lost_low". Disarmed after firing until the palm is low again.
/// OBSOLETE since v9.1 (2026-10-31): not object-centred. A hand that rested near the table and came
/// back up triggered a check without ever reaching the object (Nils). Kept for its tests.
public struct LiftDetector: Sendable {
    public var lowAbove: Float = 0.09  // palm over a gripped phone: 5–8 cm above the table
    public var dwell: Double = 0.4
    public var rise: Float = 0.05
    public var riseHold: Double = 0.15
    public var lostAfter: Double = 0.8

    private var lowSince: Double?
    private var lowStartY: Float?
    private var armed = false
    private var lowest: Float = .infinity
    private var riseSince: Double?
    private var lastSeen: Double?

    public init() {}

    public mutating func disarm() {
        armed = false
        lowSince = nil
        riseSince = nil
        lowest = .infinity
    }

    /// - Returns: the reason when a pick-up is seen this frame, else nil.
    public mutating func update(time: Double, palmY: Float?, tableY: Float) -> String? {
        guard let y = palmY else {
            if armed, let seen = lastSeen, time - seen >= lostAfter {
                disarm()
                return "hand_lost_low"
            }
            return nil
        }
        lastSeen = time
        // Above the surface, not below it (sim late_hand: a hand in the lap, rising into view).
        if y <= tableY + lowAbove && y >= tableY - 0.02 {
            // Resting there, not passing through (a hand coming up from the lap crosses this band).
            if let start = lowStartY, abs(y - start) > 0.03, !armed { lowSince = nil }
            if lowSince == nil { lowStartY = y }
            let since = lowSince ?? time
            lowSince = since
            if time - since >= dwell { armed = true }
        } else if !armed {
            lowSince = nil
        }
        guard armed else { return nil }
        lowest = min(lowest, y)
        if y >= lowest + rise {
            let since = riseSince ?? time
            riseSince = since
            if time - since >= riseHold {
                disarm()
                return "lift"
            }
        } else {
            riseSince = nil
        }
        return nil
    }
}
