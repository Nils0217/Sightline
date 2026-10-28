// labels: testing, needs-review, important
// Mac-side simulator of the local find-and-grab loop (Nils, 2026-10-28: "write simulation code,
// testing on the phone wastes time"). Runs the real GuidanceSession / StepGuide / PickupDetector
// against a synthetic world, a simulated camera (Vision-like hand keypoints, LiDAR-like depth),
// a simulated speech channel and a simulated blind user who follows what they hear.
//
// No network: SAM and Spark are not called. The target position is given (as if SAM had locked).
// It cannot find bugs in the real ARKit/Vision coordinate mapping (the device "left bias"); for
// that, record real frames and replay them. It *can* show what a given bias does to guidance.
//
//   swift run SightlineSim                       # all scenarios, 20 runs each, summary table
//   swift run SightlineSim normal --seed 3 -v    # one run with the full spoken transcript
//   swift run SightlineSim replay <folder>       # object model + grasp check on a device recording
//
// Output goes to stdout only; nothing is written to disk.

import Foundation
import simd
import SightlineCore

// MARK: - Random

struct RNG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform(_ a: Float = 0, _ b: Float = 1) -> Float {
        a + (b - a) * Float(next() >> 40) / Float(1 << 24)
    }
    mutating func gauss(_ sigma: Float) -> Float {
        let u1 = max(uniform(), 1e-6), u2 = uniform()
        return sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
    mutating func chance(_ p: Float) -> Bool { uniform() < p }
}

// MARK: - Scenario

struct Scenario {
    var name: String
    var note: String
    /// Where the object stands on the table (world x, z; table top y = 0.8). Camera on the chest at
    /// y = 1.3, looking along −z (yaw 0).
    var objectXZ = SIMD2<Float>(0.15, -0.55)
    var kind = ObjectKind.phone
    /// Something standing between the hand and the object (bottle-sized), world x, z.
    var obstacleXZ: SIMD2<Float>?
    /// Camera yaw (degrees, + = right) at the start; the object may be out of view (scan phase).
    var startYaw: Float = 0
    /// How the user holds the hand when first asked (world, m), relative to straight ahead.
    var handStart = SIMD3<Float>(-0.05, 1.0, -0.3)
    var cameraTiltDown: Float = 35 * .pi / 180
    /// Per-tip chance a fingertip is hidden in a frame (index first, as on the device).
    var tipHidden: [HandJoint: Float] = [.indexTip: 0.1, .thumbTip: 0.1, .middleTip: 0.1, .ringTip: 0.15, .littleTip: 0.2]
    /// Chance the whole hand is missed in a frame.
    var handDropout: Float = 0.03
    var jointNoise: Float = 0.006
    /// Lateral perception bias in the camera's x (negative = left), per metre of depth:
    /// a principal-point error shifts points by depth * Δcx / fx. Applied to hand and target alike.
    var biasPerMetre: Float = 0
    /// Constant lateral bias (m, negative = left), e.g. a wrong mask→3D mapping on the target only.
    var targetOnlyBias: Float = 0
    /// How exactly the user follows a distance: 0.3 = ±30 %.
    var userDistanceError: Float = 0.25
    var userSpeed: Float = 0.15
    var userReaction: Double = 0.6
    /// The user only lifts the hand into view after the second prompt.
    var handOutOfViewFirst = false
    /// The user's grip is loose: no thumb opposite the fingers (only a Spark check can confirm).
    var looseGrip = false

    var object: SIMD3<Float> { SIMD3(objectXZ.x, tableY + kind.size.y / 2, objectXZ.y) }
}

let tableY: Float = 0.8

enum ObjectKind: String {
    case phone, ruler, bottle
    /// Width (x), height (y), depth (z), metres.
    var size: SIMD3<Float> {
        switch self {
        case .phone: SIMD3(0.075, 0.008, 0.15)
        case .ruler: SIMD3(0.03, 0.003, 0.2)
        case .bottle: SIMD3(0.075, 0.24, 0.075)
        }
    }
}

let scenarios: [Scenario] = {
    var list: [Scenario] = []
    list.append(Scenario(name: "normal", note: "baseline"))
    var s = Scenario(name: "index_hidden", note: "index tip hidden 70% of frames (device failure 2a)")
    s.tipHidden[.indexTip] = 0.7; s.tipHidden[.middleTip] = 0.4
    list.append(s)
    s = Scenario(name: "shared_bias", note: "hand AND target shifted left 5 cm per metre of depth")
    s.biasPerMetre = -0.05
    list.append(s)
    s = Scenario(name: "target_bias", note: "only the target shifted 6 cm left (mask→3D bug)")
    s.targetOnlyBias = -0.06
    list.append(s)
    s = Scenario(name: "sloppy_user", note: "user misjudges distances ±50%, slower")
    s.userDistanceError = 0.5; s.userSpeed = 0.1; s.userReaction = 1.0
    list.append(s)
    s = Scenario(name: "late_hand", note: "hand out of view until the prompt repeats")
    s.handOutOfViewFirst = true
    list.append(s)
    s = Scenario(name: "flaky_tracking", note: "hand missed in 25% of frames, noisy joints")
    s.handDropout = 0.25; s.jointNoise = 0.012
    list.append(s)
    s = Scenario(name: "ruler", note: "flat 3 mm ruler: lift seen only by grip + leaving")
    s.kind = .ruler
    list.append(s)
    s = Scenario(name: "bottle_side", note: "tall bottle, approached and gripped from the side")
    s.kind = .bottle; s.objectXZ = SIMD2(0.2, -0.5)
    list.append(s)
    s = Scenario(name: "loose_grip", note: "no thumb opposition: needs the Spark check")
    s.looseGrip = true
    list.append(s)
    s = Scenario(name: "obstacle", note: "a bottle stands between hand and phone (warning expected)")
    s.obstacleXZ = SIMD2(0.05, -0.42)
    list.append(s)
    s = Scenario(name: "not_in_view", note: "phone 70° to the right: scan while the user turns")
    s.startYaw = -70
    list.append(s)
    return list
}()

// MARK: - Camera

struct Camera {
    let transform: simd_float4x4
    var position: SIMD3<Float> { SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z) }
    var xAxis: SIMD3<Float> { SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z) }
    var lookAxis: SIMD3<Float> { -SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z) }

    /// `yaw` radians, + = turned right.
    init(height: Float, tiltDown a: Float, yaw: Float = 0) {
        let tilt = simd_float4x4(columns: (
            SIMD4(1, 0, 0, 0),
            SIMD4(0, cos(a), -sin(a), 0),
            SIMD4(0, sin(a), cos(a), 0),
            SIMD4(0, 0, 0, 1)))
        var m = simd_float4x4(simd_quatf(angle: -yaw, axis: SIMD3(0, 1, 0))) * tilt
        m.columns.3 = SIMD4(0, height, 0, 1)
        transform = m
    }

    func depth(_ p: SIMD3<Float>) -> Float { simd_dot(p - position, lookAxis) }

    /// Inside a portrait iPhone wide-camera field of view (~50° x 65°) and beyond 15 cm.
    func sees(_ p: SIMD3<Float>) -> Bool {
        let d = depth(p)
        guard d > 0.15 else { return false }
        let rel = p - position
        let x = simd_dot(rel, xAxis) / d
        let y = simd_dot(rel, simd_cross(xAxis, lookAxis)) / d
        return abs(x) < tan(25 * .pi / 180) && abs(y) < tan(32 * .pi / 180)
    }

    /// What the depth pipeline reports for a true point, with a lateral bias proportional to depth.
    func perceived(_ p: SIMD3<Float>, biasPerMetre: Float) -> SIMD3<Float> {
        p + xAxis * (biasPerMetre * depth(p))
    }
}

// MARK: - Hand geometry

/// The six keypoints the app uses, around a true palm centre, fingers pointing forward and a bit down.
func handJoints(palm: SIMD3<Float>) -> [HandJoint: SIMD3<Float>] {
    let f = SIMD3<Float>(0, -0.2, -1) / simd_length(SIMD3<Float>(0, -0.2, -1))
    let r = SIMD3<Float>(1, 0, 0)
    return [
        .wrist: palm - f * 0.05,
        .indexMCP: palm + f * 0.04 - r * 0.025, .middleMCP: palm + f * 0.045 - r * 0.005,
        .ringMCP: palm + f * 0.04 + r * 0.015, .littleMCP: palm + f * 0.035 + r * 0.035,
        .thumbTip: palm + f * 0.05 - r * 0.07,
        .indexTip: palm + f * 0.11 - r * 0.03, .middleTip: palm + f * 0.12 - r * 0.005,
        .ringTip: palm + f * 0.11 + r * 0.02, .littleTip: palm + f * 0.09 + r * 0.04,
    ]
}

/// Visible-surface points of a box-shaped object (top face; for tall ones also the face toward the user).
func objectPoints(_ sc: Scenario) -> [SIMD3<Float>] {
    let c = sc.object, h = sc.kind.size / 2
    var pts: [SIMD3<Float>] = []
    for i in 0...8 {
        for k in 0...8 {
            let x = c.x - h.x + Float(i) / 8 * 2 * h.x, z = c.z - h.z + Float(k) / 8 * 2 * h.z
            pts.append(SIMD3(x, c.y + h.y, z))
            if sc.kind == .bottle { pts.append(SIMD3(x, c.y - h.y + Float(k) / 8 * 2 * h.y, c.z + h.z)) }
        }
    }
    return pts
}

/// Joints of a hand gripping the object: thumb on its left side, fingers on its right, palm above.
func gripJoints(_ sc: Scenario, lift: Float) -> [HandJoint: SIMD3<Float>] {
    let c = sc.object + SIMD3(0, lift, 0), h = sc.kind.size / 2
    let side: Float = sc.kind == .bottle ? 0 : h.y + 0.005  // flat: fingertips on the edges at table level
    let palm = c + SIMD3(0.01, max(h.y, 0.02) + 0.03, 0.03)
    var j: [HandJoint: SIMD3<Float>] = [
        .wrist: palm + SIMD3(0.01, 0.01, 0.06), .indexMCP: palm + SIMD3(0.02, 0, -0.02), .middleMCP: palm + SIMD3(0.005, 0, -0.025),
        .ringMCP: palm + SIMD3(-0.01, 0, -0.02), .littleMCP: palm + SIMD3(-0.025, 0, -0.015),
        .indexTip: c + SIMD3(h.x + 0.008, -side * 0, -0.02), .middleTip: c + SIMD3(h.x + 0.008, 0, 0),
        .ringTip: c + SIMD3(h.x + 0.008, 0, 0.02), .littleTip: c + SIMD3(h.x + 0.006, 0, 0.035),
    ]
    j[.thumbTip] = sc.looseGrip ? c + SIMD3(h.x * 0.3, h.y + 0.04, 0.05) : c + SIMD3(-h.x - 0.008, 0, 0)
    return j
}

// MARK: - Speech channel

struct SpeechChannel {
    struct Utterance { var text: String; var start: Double; var end: Double }
    private(set) var current: Utterance?
    private var queue: [String] = []
    private(set) var started: [Utterance] = []
    private(set) var cut = 0

    /// AVSpeechSynthesizer at 0.95x: roughly 2.6 words per second plus a short lead-in.
    static func duration(_ text: String) -> Double {
        0.25 + Double(text.split(separator: " ").count) / 2.6
    }

    mutating func say(_ line: SpokenLine, time: Double) {
        if line.interrupt {
            if let c = current, c.end > time { cut += 1 }
            current = nil
            queue.removeAll()
        }
        queue.append(line.text)
    }

    var speaking: Bool { current != nil || !queue.isEmpty }

    /// Returns lines that finished this tick (what the user has heard).
    mutating func tick(time: Double) -> [String] {
        var heard: [String] = []
        if let c = current, time >= c.end { heard.append(c.text); current = nil }
        if current == nil, !queue.isEmpty {
            let text = queue.removeFirst()
            let u = Utterance(text: text, start: time, end: time + Self.duration(text))
            current = u
            started.append(u)
        }
        return heard
    }

    /// "Stop." is acted on as soon as it starts, not when it ends.
    var currentText: String? { current?.text }
}

// MARK: - Simulated user

struct SimUser {
    enum Plan { case idle, raising(SIMD3<Float>), moving(SIMD3<Float>), grabbing(at: Double), holding }
    var palm: SIMD3<Float>
    var plan = Plan.idle
    var pending: [(at: Double, text: String)] = []
    var lifted = false
    var gripped = false
    var groped = false
    var lift: Float = 0
    var promptsHeard = 0
    /// Body yaw (radians, + = right), same convention as Camera.
    var facing: Float = 0

    mutating func hear(_ text: String, time: Double, scenario: Scenario) {
        pending.append((time + scenario.userReaction, text))
    }

    /// Joints as the hand really is: open hand around the palm, or gripping the (lifted) object.
    func joints(_ sc: Scenario) -> [HandJoint: SIMD3<Float>] { gripped ? gripJoints(sc, lift: lift) : handJoints(palm: palm) }

    mutating func react(time: Double, scenario sc: Scenario, rng: inout RNG, target: SIMD3<Float>) {
        while let first = pending.first, first.at <= time {
            pending.removeFirst()
            act(on: first.text, scenario: sc, rng: &rng, time: time, target: target)
        }
    }

    private mutating func act(on text: String, scenario sc: Scenario, rng: inout RNG, time: Double, target: SIMD3<Float>) {
        if text.hasPrefix("Hold your hand") || text.hasPrefix("Reach your hand") || text.hasPrefix("I lost your hand")
            || text.hasPrefix("I can't see") {
            promptsHeard += 1
            if sc.handOutOfViewFirst && promptsHeard == 1 {
                plan = .raising(SIMD3(-0.1, 0.55, -0.15))  // too low and too close: out of view
            } else {
                // "Reach forward and down, toward it": start lower and further out, roughly toward the object.
                var start = sc.handStart
                if text.hasPrefix("Reach") {
                    // Partly toward the object, as seen from where the body now faces.
                    let toward = simd_quatf(angle: facing, axis: SIMD3(0, 1, 0)).act(target)
                    start = SIMD3(toward.x * 0.4, 0.92, -0.38)
                }
                // In front of the body: rotate by the way the user now faces (after turning to scan).
                start = simd_quatf(angle: -facing, axis: SIMD3(0, 1, 0)).act(start)
                plan = .raising(start + SIMD3(rng.gauss(0.04), rng.gauss(0.04), rng.gauss(0.04)))
            }
            return
        }
        if text.hasPrefix("Stop. It's at your hand") { plan = .grabbing(at: time + 0.8); return }
        if text == "Stop." { groped = false }
        if text == "Stop." { plan = .idle; return }
        if text.hasPrefix("Got it") || text.hasPrefix("Tap the screen") || text == "Checking." { return }
        if text.hasPrefix("I don't think you have") { gripped = false; lifted = false; lift = 0; return }
        if let (dir, dist) = Self.parseMove(text) {
            let d = dist * (1 + rng.uniform(-sc.userDistanceError, sc.userDistanceError))
            // People drift a little off the axis they were told.
            let drift = SIMD3(rng.gauss(0.01), rng.gauss(0.01), rng.gauss(0.01))
            plan = .moving(palm + dir * d + drift)
        }
    }

    /// "Right, about 20 centimetres." / "A little up." -> (world direction, metres).
    static func parseMove(_ text: String) -> (SIMD3<Float>, Float)? {
        let words: [(String, SIMD3<Float>)] = [("right", [1, 0, 0]), ("left", [-1, 0, 0]), ("up", [0, 1, 0]),
                                               ("down", [0, -1, 0]), ("forward", [0, 0, -1]), ("back", [0, 0, 1])]
        let lower = text.lowercased()
        guard let (_, dir) = words.first(where: { lower.hasPrefix($0.0) || lower.hasPrefix("a little \($0.0)")
            || lower.hasPrefix("keep going \($0.0)") }) else { return nil }
        if lower.hasPrefix("a little") { return (dir, 0.04) }
        if lower.hasPrefix("keep going") { return (dir, 0.08) }
        let cm = lower.split(whereSeparator: { !$0.isNumber }).first.flatMap { Float($0) } ?? 5
        return (dir, cm / 100)
    }

    mutating func step(dt: Float, scenario sc: Scenario, time: Double, target: SIMD3<Float>) {
        switch plan {
        case .raising(let goal), .moving(let goal):
            let d = goal - palm
            let step = sc.userSpeed * dt * (isRaising ? 2 : 1)
            if simd_length(d) <= step { palm = goal; plan = .idle } else { palm += simd_normalize(d) * step }
        case .grabbing(let at):
            if time >= at {
                // Feel for it from wherever the palm is: within reach of the surface -> grip it.
                // Fingertips touching it count too: people feel it with whatever touches first.
                let pts = objectPoints(sc)
                let near = handJoints(palm: palm).values.map { j in pts.map { simd_distance($0, j) }.min()! }.min()!
                let surface = pts.min { simd_distance($0, palm) < simd_distance($1, palm) }!
                if simd_distance(surface, palm) < 0.12 || near < 0.04 { gripped = true; plan = .holding }
                else if !groped {
                    // Can't feel it: reach out a few cm toward it once, then wait for guidance.
                    groped = true
                    plan = .moving(palm + simd_normalize(surface - palm) * 0.06)
                    pending.append((time + 0.5, "Stop. It's at your hand. Grab it."))
                } else { plan = .idle }
            }
        case .holding:
            // Lift it toward the body over ~1.5 s.
            if gripped, lift < 0.2 { lift += 0.13 * dt; if lift > 0.02 { lifted = true } }
        case .idle:
            break
        }
    }

    private var isRaising: Bool { if case .raising = plan { true } else { false } }
}

// MARK: - Run

struct RunResult {
    var success: Bool
    var outcome: String
    var seconds: Double
    var lines: Int
    var cutOff: Int
    var trueMissAtGrab: Float?
    var keypointsSeen: Double
    var warnings: Int
    var scans: Int
    var checks: Int
    var transcript: [String]
}

func run(_ sc: Scenario, seed: UInt64, maxTime: Double = 90) -> RunResult {
    var rng = RNG(state: seed)
    var yaw = sc.startYaw * .pi / 180
    var cam = Camera(height: 1.3, tiltDown: sc.cameraTiltDown, yaw: yaw)
    var speech = SpeechChannel()
    var user = SimUser(palm: SIMD3(0.05, 0.7, 0.05))  // hand down at the side, out of view
    var log: [String] = []
    var keypointSum = 0, frames = 0
    var missAtGrab: Float?
    var warnings = 0, scans = 0, checks = 0
    let dt = 1.0 / 30
    var t = 0.0
    var outcome = "timeout"

    func note(_ t: Double, _ s: String) { log.append(String(format: "%6.2f  %@", t, s)) }
    func say(_ line: SpokenLine, _ t: Double) {
        speech.say(line, time: t)
        note(t, "SAY  \(line.text)" + (line.interrupt ? "  [interrupts]" : ""))
    }
    /// One frame of hearing + acting + moving; returns lines heard.
    func live(_ target: SIMD3<Float>) {
        for heard in speech.tick(time: t) { user.hear(heard, time: t, scenario: sc); note(t, "     heard: \(heard)") }
        if speech.currentText == "Stop." || speech.currentText?.hasPrefix("Stop. It's") == true,
           !user.pending.contains(where: { $0.text == speech.currentText }) {
            // Short commands are acted on while being spoken.
            user.hear(speech.currentText!, time: t - sc.userReaction + 0.3, scenario: sc)
        }
        user.react(time: t, scenario: sc, rng: &rng, target: target)
        user.step(dt: Float(dt), scenario: sc, time: t, target: target)
    }

    // --- Scan phase: the object is not in view at lock. The user turns when asked (25°/s, right
    // to +110°, then back left); SAM (simulated, 1.5 s) finds it when it is in the frame.
    if !cam.sees(sc.object) {
        var planner = ScanPlanner(time: 0)
        planner.markSearched(cameraTransform: cam.transform)
        say(SpokenLine(text: ScanPlanner.startLine("phone"), interrupt: true), 0)
        var turning: Float = 0
        var pendingScan: (due: Double, found: Bool)?
        var found = false
        while t < maxTime && !found {
            t += dt
            for heard in speech.tick(time: t) {
                note(t, "     heard: \(heard)")
                if heard.hasPrefix("I don't see") || heard.hasPrefix("Still looking") { turning = turning == 0 ? 1 : turning }
            }
            if turning != 0 {
                yaw += turning * 25 * .pi / 180 * Float(dt)
                if yaw > 110 * .pi / 180 { turning = -1 }
                if yaw < -110 * .pi / 180 { turning = 1 }
                cam = Camera(height: 1.3, tiltDown: sc.cameraTiltDown, yaw: yaw)
            }
            if let p = pendingScan, t >= p.due {
                pendingScan = nil
                if p.found { found = true; note(t, "SAM  found"); break }
                note(t, "SAM  nothing")
            }
            switch planner.update(time: t, cameraTransform: cam.transform, busy: pendingScan != nil, speaking: speech.speaking) {
            case .scan:
                scans += 1
                note(t, String(format: "SCAN at yaw %.0f°", yaw * 180 / .pi))
                pendingScan = (t + 1.5, cam.sees(sc.object))
            case .prompt:
                say(SpokenLine(text: ScanPlanner.promptLine, interrupt: false), t)
            case .giveUp:
                say(SpokenLine(text: ScanPlanner.giveUpLine("phone"), interrupt: true), t)
                note(t, "END  not found")
                return RunResult(success: false, outcome: "not found", seconds: t, lines: speech.started.count, cutOff: speech.cut,
                                 trueMissAtGrab: nil, keypointsSeen: 0, warnings: 0, scans: scans, checks: 0, transcript: log)
            case .wait:
                break
            }
        }
        // The user stops turning on "Found the ..." (next line); the camera now faces the object.
    }

    // --- Lock: object model and obstacles as the app would build them (with the scenario's biases).
    user.facing = yaw
    let shift = cam.xAxis * sc.targetOnlyBias
    let seenPoints = objectPoints(sc).map { cam.perceived($0, biasPerMetre: sc.biasPerMetre) + shift }
    let object = ObjectModel(points: seenPoints, supportHeight: tableY, isFlat: sc.kind != .bottle)
    let obstacles = sc.obstacleXZ.map { o in
        ObstacleMap(points: (0...6).flatMap { i in (0...3).map { k in
            SIMD3(o.x - 0.035 + Float(k) * 0.023, tableY + 0.03 + Float(i) * 0.035, o.y + 0.035) } })
    }
    var session = GuidanceSession(targetName: "phone", target: object.centre, object: object, obstacles: obstacles,
                                  cameraTransform: cam.transform, time: t)
    for line in session.opening { say(line, t) }
    var pendingCheck: (due: Double, answer: Bool)?

    while t < maxTime {
        t += dt
        live(sc.object)

        // Perception: keypoints the camera sees this frame.
        var hand: HandKeypoints?
        if !rng.chance(sc.handDropout) {
            var seen: [HandJoint: SIMD3<Float>] = [:]
            // Sorted so the random draws come in the same order every launch (Dictionary order is random).
            for (j, p) in user.joints(sc).sorted(by: { $0.key.rawValue < $1.key.rawValue }) where cam.sees(p) {
                if let hide = sc.tipHidden[j], rng.chance(hide) { continue }
                let noisy = p + SIMD3(rng.gauss(sc.jointNoise), rng.gauss(sc.jointNoise), rng.gauss(sc.jointNoise))
                seen[j] = cam.perceived(noisy, biasPerMetre: sc.biasPerMetre)
            }
            if seen.count >= 4 { hand = HandKeypoints(joints: seen) }
        }
        if let h = hand { keypointSum += h.keypointCount; frames += 1 }

        // LiDAR at the target pixel: object surface (0), the hand in front (negative), or what is
        // behind once lifted: the table, only as far as the object was thick.
        var depthDelta: Float? = rng.gauss(0.005)
        if user.lifted { depthDelta = (sc.kind == .bottle ? 0.25 : sc.kind.size.y) + rng.gauss(0.005) }
        else if simd_length(user.palm - sc.object) < 0.1, cam.depth(user.palm) < cam.depth(sc.object) { depthDelta = -0.1 }

        let out = session.update(time: t, hand: hand, cameraTransform: cam.transform,
                                 targetDepthDelta: depthDelta, speaking: speech.speaking)
        for line in out.lines {
            say(line, t)
            if line.text.hasPrefix("Stop. It's") { missAtGrab = object.distanceToSurface(user.palm) }
            if line.text.hasPrefix("Careful") { warnings += 1 }
        }
        if out.requestCheck {
            // Muse Spark yes/no on a photo of the hand: ~2 s, answers truthfully here.
            checks += 1
            pendingCheck = (t + 2, user.gripped && user.lifted)
        }
        if let c = pendingCheck, t >= c.due {
            pendingCheck = nil
            note(t, "SPARK \(c.answer ? "yes" : "no")")
            for line in session.resolveCheck(c.answer, time: t) { say(line, t) }
        }
        if session.phase == .done { outcome = "done"; break }
        if session.phase == .gaveUp { outcome = "gave up"; break }
    }
    let ok = outcome == "done" && user.lifted
    note(t, "END  \(outcome); palm to surface at grab: " + (missAtGrab.map { String(format: "%.1f cm", $0 * 100) } ?? "-"))
    return RunResult(success: ok, outcome: outcome, seconds: t, lines: speech.started.count, cutOff: speech.cut,
                     trueMissAtGrab: missAtGrab, keypointsSeen: frames == 0 ? 0 : Double(keypointSum) / Double(frames),
                     warnings: warnings, scans: scans, checks: checks, transcript: log)
}

// MARK: - CLI

var args = Array(CommandLine.arguments.dropFirst())
if args.first == "replay" {
    guard args.count >= 2 else { print("usage: SightlineSim replay <diagnostics folder>"); exit(1) }
    Replay.run(folder: args[1])
    exit(0)
}
let verbose = args.contains("-v")
args.removeAll { $0 == "-v" }
var seed: UInt64?
var runs = 20
if let i = args.firstIndex(of: "--seed"), i + 1 < args.count { seed = UInt64(args[i + 1]); args.removeSubrange(i...i + 1) }
if let i = args.firstIndex(of: "--runs"), i + 1 < args.count { runs = Int(args[i + 1]) ?? runs; args.removeSubrange(i...i + 1) }
let chosen = args.isEmpty ? scenarios : scenarios.filter { args.contains($0.name) }
if chosen.isEmpty {
    print("Unknown scenario. Available: " + scenarios.map(\.name).joined(separator: ", "))
    exit(1)
}

print("scenario         ok    median_s  lines  miss_cm  keypts  warn  scans  checks  note")
for sc in chosen {
    let seeds: [UInt64] = seed.map { [$0] } ?? (1...UInt64(runs)).map { $0 }
    let results = seeds.map { run(sc, seed: $0) }
    if verbose { for r in results { print("--- \(sc.name)"); r.transcript.forEach { print($0) } } }
    func median(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.sorted()[v.count / 2] }
    let ok = results.filter(\.success)
    let misses = results.compactMap(\.trueMissAtGrab).map { Double($0) * 100 }
    print(sc.name.padding(toLength: 16, withPad: " ", startingAt: 0) + String(format: " %2d/%-2d %8.1f  %5.1f  %7.1f  %6.1f  %4.1f  %5.1f  %6.1f  %@",
                 ok.count, results.count, median(ok.map(\.seconds)), median(results.map { Double($0.lines) }),
                 median(misses), median(results.map(\.keypointsSeen)), median(results.map { Double($0.warnings) }),
                 median(results.map { Double($0.scans) }), median(results.map { Double($0.checks) }), sc.note as NSString))
}
