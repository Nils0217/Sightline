// labels: production, needs-review, important
// Stop-and-go hand guidance (replaces GuidanceController's continuous cues after the first
// device test, 2026-10-28: constant centimetre updates while the hand moved were noise).
//
//   hand still  -> one instruction: "Right, about 20 centimetres."
//   hand moving -> silent (tones only)
//   reached / overshot that axis -> "Stop."
//   hand still again -> next instruction, until the hand is at the object -> "Stop. Grab it."
// "I can't see your hand" only after a grace period, and rarely.

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
    public var grabRadius: Float = 0.06
    /// An axis is "reached" when its remaining offset is below this.
    public var axisTolerance: Float = 0.03
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
            return GuidanceCue(kind: .grab, phrase: "Stop. It's at your hand. Grab it.", key: "grab")
        }

        switch state {
        case .grabbing:
            return nil
        case .moving(let axis, let sign, var issuedAt):
            // The "stopped short" clock starts when the instruction has been heard, not queued.
            if !canInstruct { issuedAt = time; state = .moving(axis, sign: sign, issuedAt: time) }
            if Self.value(offset, axis) * sign <= axisTolerance {
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

    private mutating func instruct(_ o: BodyOffset, time: Double) -> GuidanceCue {
        let (axis, v) = Self.dominantAxis(o, tolerance: axisTolerance)
        let sign: Float = v >= 0 ? 1 : -1
        let repeated = lastInstruction.map { $0.axis == axis && $0.sign == sign } ?? false
        lastInstruction = (axis, sign)
        state = .moving(axis, sign: sign, issuedAt: time)
        let cm = Int((abs(v) * 100).rounded())
        let word: String
        switch (axis, v >= 0) {
        case (.right, true): word = "Right"
        case (.right, false): word = "Left"
        case (.up, true): word = "Up"
        case (.up, false): word = "Down"
        case (.forward, true): word = "Forward"
        case (.forward, false): word = "Back"
        }
        let phrase: String
        if cm < 6 { phrase = "A little \(word.lowercased())." }
        else if repeated { phrase = "Keep going \(word.lowercased())." }
        else { phrase = "\(word), about \(GuidanceController.rounded(cm)) centimetres." }
        return GuidanceCue(kind: .move, phrase: phrase, key: "\(word)-\(GuidanceController.rounded(cm))")
    }

    /// Largest lateral correction first; forward only once the hand is lined up.
    static func dominantAxis(_ o: BodyOffset, tolerance: Float) -> (Axis, Float) {
        let lateral: (Axis, Float) = abs(o.right) >= abs(o.up) ? (.right, o.right) : (.up, o.up)
        if abs(lateral.1) >= tolerance && abs(lateral.1) >= abs(o.forward) * 0.5 { return lateral }
        return (.forward, o.forward)
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
