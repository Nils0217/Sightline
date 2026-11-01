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

enum HoldFault { case none, wrongObject, handOnly, objectOnly, slideOnly }

struct Scenario {
    var holdFault = HoldFault.none
    var name: String
    var note: String
    /// Where the object stands on the table (world x, z; table top y = 0.8). Camera on the chest at
    /// y = 1.3, looking along −z (yaw 0).
    var objectXZ = SIMD2<Float>(0.15, -0.55)
    var kind = ObjectKind.phone
    /// Something standing between the hand and the object (bottle-sized), world x, z.
    var obstacleXZ: SIMD2<Float>?
    /// Things on the table beside the path (world x, z), cup-sized: must not stop the hand.
    var clutterXZ: [SIMD2<Float>] = []
    /// The user's hand and arm are already out (on the table, right of the object) in the lock frame.
    var armAtLock = false
    /// Put down after the lock photo: only the rolling scan can see it (v9.2).
    var lateObstacleXZ: SIMD2<Float>?
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
    /// Hold check (v6): chance SAM misses the object on the check photo, and chance Spark answers wrongly.
    var samMiss: Float = 0.15
    var sparkWrong: Float = 0.1
    /// v6 run (2026-10-30): the user grabs as soon as the palm is within this distance of the object,
    /// without waiting for "Grab it". nil = waits.
    var grabsUnasked: Float?
    /// Chance the hand is missed in a frame while it grips the object (fingers wrapped around a phone).
    var gripDropout: Float = 0

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
    s = Scenario(name: "bottle_centered", note: "bottle after facing it and starting a new search")
    s.kind = .bottle; s.objectXZ = SIMD2(0, -0.5)
    list.append(s)
    s = Scenario(name: "loose_grip", note: "no thumb opposition: needs the Spark check")
    s.looseGrip = true
    list.append(s)
    s = Scenario(name: "obstacle", note: "a bottle stands between hand and phone (warning expected)")
    s.obstacleXZ = SIMD2(0.05, -0.42)
    list.append(s)
    s = Scenario(name: "clutter", note: "cups 22 cm either side of the path, noisy table, flying pixels")
    s.clutterXZ = [SIMD2(-0.12, -0.5), SIMD2(0.4, -0.45)]
    list.append(s)
    s = Scenario(name: "arm_at_lock", note: "hand and arm already resting on the table in the lock photo")
    s.armAtLock = true
    list.append(s)
    s = Scenario(name: "late_obstacle", note: "a bottle put down between hand and phone after the lock photo (rolling scan)")
    s.lateObstacleXZ = SIMD2(0.05, -0.42)
    list.append(s)
    s = Scenario(name: "not_in_view", note: "phone 70° to the right: scan while the user turns")
    s.startYaw = -70
    list.append(s)
    s = Scenario(name: "spark_wrong", note: "Spark says the wrong thing half the time (v5 6.1): SAM layer decides")
    s.sparkWrong = 0.5
    list.append(s)
    s = Scenario(name: "sam_blind", note: "SAM misses the object on 60% of check photos")
    s.samMiss = 0.6
    list.append(s)
    s = Scenario(name: "grab_unasked", note: "v6 run: grabs on their own 15 cm away, hand missed 80% while gripping")
    s.grabsUnasked = 0.15
    s.gripDropout = 0.8
    list.append(s)
    for (name, fault, note) in [("wrong_object", HoldFault.wrongObject, "reference identity differs"),
                                 ("hand_only", HoldFault.handOnly, "hand moves while target stays on table"),
                                 ("object_only", HoldFault.objectOnly, "object moves while observed hand stays still"),
                                 ("slide_only", HoldFault.slideOnly, "correct target slides without rising from support")] {
        var negative = Scenario(name: name, note: note)
        negative.holdFault = fault; negative.samMiss = 0; negative.sparkWrong = 0
        list.append(negative)
    }
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

/// The lock frame's depth points as the app sees them (v9.1): the table with 7 mm noise, the object,
/// the scenario's obstacle and clutter, the user's arm if it is out, and isolated flying pixels. The app
/// and the simulator both turn them into a map with `ObstacleMap.scene`. Before v9.1 the simulator handed
/// the session a clean bottle-only map, while the device used a live frame with the user's own arm in it.
func lockScene(_ sc: Scenario, cam: Camera, rng: inout RNG, live: [HandJoint: SIMD3<Float>]? = nil) -> [SIMD3<Float>] {
    var pts: [SIMD3<Float>] = []
    let c = sc.object
    for i in stride(from: Float(-0.7), through: 0.7, by: 0.02) {
        for k in stride(from: Float(-0.7), through: 0.4, by: 0.02) {
            pts.append(SIMD3(c.x + i, tableY + rng.gauss(0.007), c.z + k))
        }
    }
    pts += objectPoints(sc)
    func cylinder(_ xz: SIMD2<Float>, height: Float) {
        for i in 0...12 { for a in 0..<10 {
            let ang = Float(a) / 10 * 2 * .pi
            pts.append(SIMD3(xz.x + 0.035 * cos(ang), tableY + 0.01 + Float(i) / 12 * height, xz.y + 0.035 * sin(ang)))
        } }
    }
    if let o = sc.obstacleXZ { cylinder(o, height: 0.22) }
    if live != nil, let o = sc.lateObstacleXZ { cylinder(o, height: 0.22) }
    for o in sc.clutterXZ { cylinder(o, height: 0.10) }
    if let joints = live {
        // Rolling scan: the user's hand and arm where they are now, wrist to the right shoulder.
        pts += joints.sorted { $0.key.rawValue < $1.key.rawValue }.map(\.value)  // fixed order: same run every launch
        if let wrist = joints[.wrist] {
            let shoulder = SIMD3<Float>(0.18, 1.35, 0.05)
            for i in 0...30 {
                let p = wrist + (shoulder - wrist) * Float(i) / 30
                for a in 0..<6 { let ang = Float(a) / 6 * 2 * .pi; pts.append(p + SIMD3(0.04 * cos(ang), 0.04 * sin(ang), 0)) }
            }
        }
    } else if sc.armAtLock {
        // Palm on the table 25 cm right of the object; forearm and upper arm up to the right shoulder.
        let palm = SIMD3(c.x + 0.25, tableY + 0.03, c.z + 0.1)
        pts += handJoints(palm: palm).values
        let shoulder = SIMD3<Float>(0.18, 1.35, 0.05)
        for i in 0...30 {
            let p = palm + (shoulder - palm) * Float(i) / 30
            for a in 0..<6 { let ang = Float(a) / 6 * 2 * .pi; pts.append(p + SIMD3(0.04 * cos(ang), 0.04 * sin(ang), 0)) }
        }
    }
    for _ in 0..<60 {  // flying pixels: single points in the air around the object
        pts.append(c + SIMD3(rng.uniform(-0.4, 0.4), rng.uniform(0, 0.3), rng.uniform(-0.4, 0.3)))
    }
    return pts.filter { cam.sees($0) }.map { cam.perceived($0, biasPerMetre: sc.biasPerMetre) }
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
    var verificationOffset = SIMD3<Float>.zero
    var verificationGoal = SIMD3<Float>.zero
    var pending: [(at: Double, text: String)] = []
    var lifted = false
    var gripped = false
    var groped = false
    var lift: Float = 0
    var promptsHeard = 0
    /// Holding it after "Not sure": double taps for a check.
    var wantsCheck = false
    var doubleTaps = 0
    /// Body yaw (radians, + = right), same convention as Camera.
    var facing: Float = 0
    /// Still to turn (radians, + = right) after "Turn a little to your left/right, to face it."
    var turnLeft: Float = 0

    mutating func hear(_ text: String, time: Double, scenario: Scenario) {
        pending.append((time + scenario.userReaction, text))
    }

    /// Joints as the hand really is: open hand around the palm, or gripping the (lifted) object.
    func joints(_ sc: Scenario) -> [HandJoint: SIMD3<Float>] { gripped ? gripJoints(sc, lift: lift).mapValues { $0 + verificationOffset } : handJoints(palm: palm) }

    mutating func react(time: Double, scenario sc: Scenario, rng: inout RNG, target: SIMD3<Float>) {
        while let first = pending.first, first.at <= time {
            pending.removeFirst()
            act(on: first.text, scenario: sc, rng: &rng, time: time, target: target)
        }
    }

    private mutating func act(on text: String, scenario sc: Scenario, rng: inout RNG, time: Double, target: SIMD3<Float>) {
        if text.hasPrefix("Good. Hold your hand") || text.hasPrefix("Hold your hand") || text.hasPrefix("Reach your hand") || text.hasPrefix("I lost your hand")
            || text.hasPrefix("I can't see") || text.hasPrefix("I need to see your hand") {
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
        if text.hasPrefix("Turn a little to your") {
            // Turns roughly toward the object (±25 % of the true angle), not past a full stop.
            let want = atan2(target.x, -target.z) - facing
            turnLeft = want * (1 + rng.uniform(-0.25, 0.25))
            return
        }
        if text.hasPrefix("Stop. The ") || text.hasPrefix("Stop. It's at your hand") { plan = .grabbing(at: time + 0.8); return }
        if text.hasPrefix("It's right below your hand") { plan = .grabbing(at: time + 0.8); return }
        if text.hasPrefix("Stop your hand") || text.hasPrefix("Stop. Something") || text.hasPrefix("Stop. A ") || text == "Hold still." { plan = .idle; return }
        if text.hasPrefix("Go slowly") || text.hasPrefix("Careful.") || text.contains(" ahead. Go around") || text.contains("is ahead.") || text.hasPrefix("Something's ahead.")
            || text.hasPrefix("Go around it") || text.hasPrefix("Lift your hand over") { return }  // knows where it is; waits for the next direction
        if text.hasPrefix("Move your hand and the object") {
            let direction: SIMD3<Float>
            if text.contains(" right,") { direction = [1, 0, 0] }
            else if text.contains(" left,") { direction = [-1, 0, 0] }
            else if text.contains(" back,") { direction = [0, 0, 1] }
            else { direction = [0, 0, -1] }
            // One bounded step from the initial hold, never cumulative lifting.
            verificationGoal = direction * 0.04
            if gripped { plan = .holding }
            return
        }
        if text.hasPrefix("I cannot confirm") || text.hasPrefix("Confirmed.") { return }
        if text == "Stop." { groped = false }
        if text == "Stop." { plan = .idle; return }
        if text.hasPrefix("Got it") || text.hasPrefix("Tap the screen") || text == "Checking." { return }
        if text.hasPrefix("I don't think you have") || text.hasSuffix("is still there.") { gripped = false; lifted = false; lift = 0; return }
        // "Not sure. Double tap if you have it.": someone holding it double taps.
        // At most twice: a real user gives up on double tapping after that. In the fault scenarios the
        // user does not really hold the target (wrong object, nothing moved, ...), so they never claim it:
        // those runs test the automatic check alone, and a self-confirmation there would hide a miss.
        if text.hasPrefix("Not sure") || text.hasPrefix("Double tap") {
            if doubleTaps < 2, gripped && lifted, sc.holdFault == .none { doubleTaps += 1; wantsCheck = true }
            return
        }
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
        let lower = text.lowercased().replacingOccurrences(of: "move your hand ", with: "")
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
            if gripped, lift < 0.2 { lift = min(0.2, lift + 0.13 * dt); if lift > 0.02 { lifted = true } }
            let delta = verificationGoal - verificationOffset
            if simd_length(delta) > 0 { verificationOffset += simd_normalize(delta) * min(simd_length(delta), 0.08 * dt) }
        case .idle:
            break
        }
        if let reach = sc.grabsUnasked, !gripped {
            switch plan {
            case .idle, .moving:
                let pts = objectPoints(sc)
                if pts.contains(where: { simd_distance($0, palm) < reach }) { gripped = true; plan = .holding }
            default: break
            }
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
    /// Episodes in which a hand joint went into the obstacle or a clutter cup (would knock it).
    var hits = 0
    /// Meaningless-situation detectors (v9.1): longest silence while guiding or grabbing (s), and a line
    /// said 3+ times within 10 s (chatter loop).
    var longestSilence: Double = 0
    var loops = 0
}

func run(_ sc: Scenario, seed: UInt64, maxTime: Double = 150) -> RunResult {
    var rng = RNG(state: seed)
    var yaw = sc.startYaw * .pi / 180
    var cam = Camera(height: 1.3, tiltDown: sc.cameraTiltDown, yaw: yaw)
    var speech = SpeechChannel()
    var user = SimUser(palm: SIMD3(0.05, 0.7, 0.05))  // hand down at the side, out of view
    var log: [String] = []
    var keypointSum = 0, frames = 0
    var missAtGrab: Float?
    var warnings = 0, scans = 0, checks = 0
    var hits = 0, touchingObstacle = false, guidedMove = false
    let dt = 1.0 / 30
    var t = 0.0
    var outcome = "timeout"

    func note(_ t: Double, _ s: String) { log.append(String(format: "%6.2f  %@", t, s)) }
    var said: [(time: Double, text: String, phase: GuidanceSession.Phase)] = []
    var sayPhase = GuidanceSession.Phase.waitingForHand
    func say(_ line: SpokenLine, _ t: Double) {
        said.append((t, line.text, sayPhase))
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
                if heard.hasPrefix("Turn right slowly") { turning = 1 }
                if heard.hasPrefix("Turn left slowly") { turning = -1 }
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
                say(SpokenLine(text: planner.directionPrompt(cameraTransform: cam.transform), interrupt: false), t)
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
    let camPos = SIMD3(cam.transform.columns.3.x, cam.transform.columns.3.y, cam.transform.columns.3.z)
    let obstacles = ObstacleMap.scene(lockScene(sc, cam: cam, rng: &rng), object: object, camera: camPos)
    var session = GuidanceSession(targetName: sc.kind.rawValue, target: object.centre, object: object, obstacles: obstacles,
                                  cameraTransform: cam.transform, time: t, reachProfile: ReachProfile(maximumDistance: 0.50))  // a typical measured reach; distance no longer ends a search
    for line in session.opening { say(line, t) }
    // As the app: one Spark look names the things in the lock map (simulated: always right).
    func nameThings() {
        session.nameObstacles(session.obstacleClusters.map { c in
            let things = (sc.obstacleXZ.map { [($0, "bottle")] } ?? []) + (sc.lateObstacleXZ.map { [($0, "bottle")] } ?? [])
                + sc.clutterXZ.map { ($0, "cup") }
            let name = things.first { simd_length(SIMD2(c.centre.x, c.centre.z) - $0.0) < 0.08 }?.1 ?? ""
            return (c.centre, name)
        })
    }
    nameThings()
    var lastRolling = t
    var pendingCheck: (due: Double, held: Bool, atSpot: Bool?, spark: Bool?)?
    var frozenFaultHand: HandKeypoints?
    var faultStartedAt: Double?
    var unclear = 0
    var claimed = false

    /// One check photo, as the app does it: SAM (where is it now) + Spark (is the hand holding it).
    func captureCheck(hand: HandKeypoints?) -> (held: Bool, atSpot: Bool?, spark: Bool?) {
        checks += 1
        let holding = user.gripped && user.lifted
        let now: SIMD3<Float>
        switch sc.holdFault {
        case .handOnly, .wrongObject: now = sc.object  // the target stays where it was
        case .slideOnly: now = sc.object + user.verificationOffset
        default: now = sc.object + SIMD3<Float>(0, holding ? user.lift : 0, 0) + user.verificationOffset
        }
        let samSees = !rng.chance(sc.samMiss) && cam.sees(now)
        let points = objectPoints(sc).map { cam.perceived($0 + (now - sc.object), biasPerMetre: sc.biasPerMetre) }
        let near = samSees && HoldContact.near(hand: hand, points: points, centre: now)
        let (held, atSpot) = HoldGeometry.classify(candidate: samSees ? now : nil, original: sc.object, supported: true, nearHand: near)
        // Spark: is the hand holding that object (true only for a real lift of the target).
        let truth = holding && [.none].contains(sc.holdFault)
        let spark = rng.chance(sc.sparkWrong) ? !truth : truth
        note(t, "CHECK sam \(samSees) near \(near) held \(held) atSpot \(atSpot.map(String.init) ?? "nil") spark \(spark)")
        return (held, atSpot, spark)
    }

    while t < maxTime {
        t += dt
        live(sc.object)
        if user.turnLeft != 0 {
            // 25°/s, the same speed as the scan turn.
            let step = min(abs(user.turnLeft), 25 * .pi / 180 * Float(dt)) * (user.turnLeft > 0 ? 1 : -1)
            user.turnLeft -= step
            yaw += step
            user.facing = yaw
            cam = Camera(height: 1.3, tiltDown: sc.cameraTiltDown, yaw: yaw)
        }

        // Perception: keypoints the camera sees this frame.
        var hand: HandKeypoints?
        if !rng.chance(sc.handDropout), !(user.gripped && rng.chance(sc.gripDropout)) {
            var seen: [HandJoint: SIMD3<Float>] = [:]
            // Sorted so the random draws come in the same order every launch (Dictionary order is random).
            for (j, p) in user.joints(sc).sorted(by: { $0.key.rawValue < $1.key.rawValue }) where cam.sees(p) {
                if let hide = sc.tipHidden[j], rng.chance(hide) { continue }
                let noisy = p + SIMD3(rng.gauss(sc.jointNoise), rng.gauss(sc.jointNoise), rng.gauss(sc.jointNoise))
                seen[j] = cam.perceived(noisy, biasPerMetre: sc.biasPerMetre)
            }
            if seen.count >= 2 { hand = HandKeypoints(joints: seen) }  // matches HandKeypointLocator.minJoints
        }
        if let h = hand { keypointSum += h.keypointCount; frames += 1 }

        // LiDAR at the target pixel: object surface (0), the hand in front (negative), or what is
        // behind once lifted: the table, only as far as the object was thick.
        var depthDelta: Float? = rng.gauss(0.005)
        if user.lifted { depthDelta = (sc.kind == .bottle ? 0.25 : sc.kind.size.y) + rng.gauss(0.005) }
        else if simd_length(user.palm - sc.object) < 0.1, cam.depth(user.palm) < cam.depth(sc.object) { depthDelta = -0.1 }

        if sc.holdFault == .objectOnly, session.phase == .checking || pendingCheck != nil {
            if frozenFaultHand == nil { frozenFaultHand = hand }
            hand = frozenFaultHand
        }
        if sc.holdFault == .slideOnly, user.gripped {
            faultStartedAt = faultStartedAt ?? t
            user.verificationOffset = SIMD3(min(0.08, Float(t - (faultStartedAt ?? t)) * 0.04), 0, 0)
            hand = HandKeypoints(joints: gripJoints(sc, lift: 0).mapValues { $0 + user.verificationOffset })
        }
        // Ground truth: did a joint go into the obstacle / a cup (the sim has no collision response)?
        let solids = (sc.obstacleXZ.map { [($0, Float(0.23))] } ?? []) + (sc.lateObstacleXZ.map { [($0, Float(0.23))] } ?? [])
            + sc.clutterXZ.map { ($0, Float(0.11)) }
        let inside = solids.contains { xz, height in
            user.joints(sc).values.contains { j in
                simd_length(SIMD2(j.x, j.z) - xz) < 0.045 && j.y < tableY + height
            }
        }
        // Counted once guidance has given a direction: the user placing the hand at the start is not guided.
        if inside && !touchingObstacle && guidedMove {
            hits += 1
            let j = user.joints(sc).first { j in solids.contains { simd_length(SIMD2(j.value.x, j.value.z) - $0.0) < 0.045 && j.value.y < tableY + $0.1 } }
            note(t, "HIT obstacle " + (j.map { String(format: "%@ %.2f,%.2f,%.2f map pts within 6 cm: %d", $0.key.rawValue, $0.value.x, $0.value.y, $0.value.z,
                                                     session.obstaclePoints(near: $0.value, radius: 0.06)) } ?? ""))
        }
        touchingObstacle = inside
        let observed = hand
        // Rolling scan about once a second while guiding, as the app does.
        if t - lastRolling >= 1, session.phase == .guiding {
            lastRolling = t
            let pts = lockScene(sc, cam: cam, rng: &rng, live: user.joints(sc))
            session.addScan(ObstacleMap.scene(pts, object: object, camera: camPos), hand: hand, cameraTransform: cam.transform)
            nameThings()
        }
        sayPhase = session.phase
        let out = session.update(time: t, hand: hand, cameraTransform: cam.transform,
                                 targetDepthDelta: depthDelta, speaking: speech.speaking)
        for line in out.lines {
            say(line, t)
            if line.text.hasPrefix("Stop. The ") { missAtGrab = object.distanceToSurface(user.palm) }
            if line.text.contains("in the way") { warnings += 1 }
            if SimUser.parseMove(line.text) != nil { guidedMove = true }
        }
        let slideCheck = sc.holdFault == .slideOnly && user.gripped && simd_length(user.verificationOffset) >= 0.05
            && session.phase != .checking && pendingCheck == nil && checks == 0
        if user.wantsCheck, session.phase == .guiding || session.phase == .grabbing, pendingCheck == nil {
            user.wantsCheck = false
            session.beginManualCheck()  // double tap: "I have it"
            claimed = true
            let c = captureCheck(hand: observed)
            pendingCheck = (t + 2, c.held, c.atSpot, c.spark)
        } else if out.requestCheck || slideCheck, pendingCheck == nil {
            if !out.requestCheck { session.beginManualCheck() }
            let c = captureCheck(hand: observed)
            pendingCheck = (t + 2, c.held, c.atSpot, c.spark)
        }
        if let c = pendingCheck, t >= c.due {
            pendingCheck = nil
            let (result, reason) = HoldDecision.decide(held: c.held, atSpot: c.atSpot, spark: c.spark)
            note(t, "DECIDE \(result.map(String.init) ?? "nil") \(reason.rawValue)")
            // As in the app: a double tap that the photo cannot settle is the user's own confirmation.
            if result == nil, claimed { outcome = "self_confirmed"; note(t, "USER CONFIRMED"); break }
            claimed = false
            if result == nil { unclear += 1 }
            session.resolveCheck(result, time: t).forEach { say($0, t) }
        }
        if session.endReason != nil { outcome = "ended"; break }
        if session.phase == .done { outcome = "done"; break }
        if session.phase == .gaveUp { outcome = "gave up"; break }
    }
    if outcome != "done", outcome != "self_confirmed", unclear > 0 { outcome = "uncertain" }
    // A fault run is never a success by self-confirmation (see the double-tap rule above).
    let ok = (outcome == "done" || (outcome == "self_confirmed" && sc.holdFault == .none)) && user.lifted
    note(t, "END  \(outcome); palm to surface at grab: " + (missAtGrab.map { String(format: "%.1f cm", $0 * 100) } ?? "-"))
    // Silence: gaps between lines while the session was guiding or grabbing (the user is left waiting).
    var silence = 0.0
    for (a, b) in zip(said, said.dropFirst()) where a.phase == .guiding || a.phase == .grabbing {
        silence = max(silence, b.time - a.time)
    }
    if let last = said.last, last.phase == .guiding || last.phase == .grabbing, outcome == "timeout" { silence = max(silence, t - last.time) }
    var loops = 0
    for (i, a) in said.enumerated() where a.text != "Stop." {  // "Stop." ends each step: normal
        let same = said[i...].prefix { $0.time - a.time <= 10 }.filter { $0.text == a.text }.count
        if same >= 3 { loops += 1 }
    }
    return RunResult(success: ok, outcome: outcome, seconds: t, lines: speech.started.count, cutOff: speech.cut,
                     trueMissAtGrab: missAtGrab, keypointsSeen: frames == 0 ? 0 : Double(keypointSum) / Double(frames),
                     warnings: warnings, scans: scans, checks: checks, transcript: log, hits: hits,
                     longestSilence: silence, loops: loops)
}

// MARK: - CLI

var args = Array(CommandLine.arguments.dropFirst())
if args.first == "replay" {
    guard args.count >= 2 else { print("usage: SightlineSim replay <diagnostics folder>"); exit(1) }
    Replay.run(folder: args[1])
    exit(0)
}
let verbose = args.contains("-v")
let flagged = args.contains("--flagged")
args.removeAll { $0 == "-v" || $0 == "--flagged" }
var seed: UInt64?
var runs = 20
if let i = args.firstIndex(of: "--seed"), i + 1 < args.count { seed = UInt64(args[i + 1]); args.removeSubrange(i...i + 1) }
if let i = args.firstIndex(of: "--runs"), i + 1 < args.count { runs = Int(args[i + 1]) ?? runs; args.removeSubrange(i...i + 1) }
let chosen = args.isEmpty ? scenarios : scenarios.filter { args.contains($0.name) }
if chosen.isEmpty {
    print("Unknown scenario. Available: " + scenarios.map(\.name).joined(separator: ", "))
    exit(1)
}

print("Synthetic results only; ended (out of reach / blocked) is reported separately from a completed grasp.")
print("ok counts self_confirmed (double tap the photo could not settle); self = how many of ok")
print("wrong_object / hand_only / object_only / slide_only: ok means a wrong \"Got it\" (should be 0/20)")
print("hits = times a hand went into the obstacle or a cup (ground truth; should be 0)")
print("silent = runs with > 12 s of silence while guiding/grabbing; loop = runs with a line said 3+ times in 10 s")
print("scenario         ok   self ended  unclear median_s  lines  miss_cm  keypts  warn  hits silent loop  scans  checks  note")
for sc in chosen {
    let seeds: [UInt64] = seed.map { [$0] } ?? (1...UInt64(runs)).map { $0 }
    let results = seeds.map { run(sc, seed: $0) }
    if verbose { for r in results { print("--- \(sc.name)"); r.transcript.forEach { print($0) } } }
    // --flagged: transcripts of runs with a meaningless situation only.
    if flagged {
        for (i, r) in results.enumerated() where r.longestSilence > 12 || r.loops > 0 || r.hits > 0 {
            print(String(format: "--- %@ seed %d silence %.1f loops %d hits %d", sc.name, i + 1, r.longestSilence, r.loops, r.hits))
            r.transcript.filter { $0.contains("SAY") || $0.contains("HIT") || $0.contains("END") }.forEach { print($0) }
        }
    }
    func median(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.sorted()[v.count / 2] }
    let ok = results.filter(\.success)
    let misses = results.compactMap(\.trueMissAtGrab).map { Double($0) * 100 }
    print(sc.name.padding(toLength: 16, withPad: " ", startingAt: 0) + String(format: " %2d/%-2d %4d %4d  %4d  %8.1f  %5.1f  %7.1f  %6.1f  %4.1f  %4d  %4d  %4d  %5.1f  %6.1f  %@",
                 ok.count, results.count, results.filter { $0.outcome == "self_confirmed" && $0.success }.count,
                 results.filter { $0.outcome == "ended" }.count, results.filter { $0.outcome == "uncertain" }.count, median(ok.map(\.seconds)), median(results.map { Double($0.lines) }),
                 median(misses), median(results.map(\.keypointsSeen)), median(results.map { Double($0.warnings) }),
                 results.filter { $0.hits > 0 }.count, results.filter { $0.longestSilence > 12 }.count,
                 results.filter { $0.loops > 0 }.count, median(results.map { Double($0.scans) }), median(results.map { Double($0.checks) }), sc.note as NSString))
}
