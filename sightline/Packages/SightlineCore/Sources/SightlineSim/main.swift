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
    /// True object position (world, m). Camera on the chest at y = 1.3, looking along −z.
    var object = SIMD3<Float>(0.15, 0.85, -0.55)
    /// Where the user first holds the hand when asked (world, m).
    var handStart = SIMD3<Float>(-0.05, 1.0, -0.25)
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
    return list
}()

// MARK: - Camera

struct Camera {
    let transform: simd_float4x4
    var position: SIMD3<Float> { SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z) }
    var xAxis: SIMD3<Float> { SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z) }
    var lookAxis: SIMD3<Float> { -SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z) }

    init(height: Float, tiltDown a: Float) {
        transform = simd_float4x4(columns: (
            SIMD4(1, 0, 0, 0),
            SIMD4(0, cos(a), -sin(a), 0),
            SIMD4(0, sin(a), cos(a), 0),
            SIMD4(0, height, 0, 1)))
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
    var promptsHeard = 0

    mutating func hear(_ text: String, time: Double, scenario: Scenario) {
        pending.append((time + scenario.userReaction, text))
    }

    mutating func react(time: Double, scenario sc: Scenario, rng: inout RNG, target: SIMD3<Float>) {
        while let first = pending.first, first.at <= time {
            pending.removeFirst()
            act(on: first.text, scenario: sc, rng: &rng, time: time, target: target)
        }
    }

    private mutating func act(on text: String, scenario sc: Scenario, rng: inout RNG, time: Double, target: SIMD3<Float>) {
        if text.hasPrefix("Hold your hand") || text.hasPrefix("I lost your hand") || text.hasPrefix("I can't see") {
            promptsHeard += 1
            if sc.handOutOfViewFirst && promptsHeard == 1 {
                plan = .raising(SIMD3(-0.1, 0.55, -0.15))  // too low and too close: out of view
            } else {
                plan = .raising(sc.handStart + SIMD3(rng.gauss(0.04), rng.gauss(0.04), rng.gauss(0.04)))
            }
            return
        }
        if text.hasPrefix("Stop. It's at your hand") { plan = .grabbing(at: time + 0.8); return }
        if text == "Stop." { plan = .idle; return }
        if text.hasPrefix("Got it") || text.hasPrefix("Tap the screen") { plan = .holding; return }
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
        guard let (_, dir) = words.first(where: { lower.hasPrefix($0.0) || lower.hasPrefix("a little \($0.0)") }) else { return nil }
        if lower.hasPrefix("a little") { return (dir, 0.04) }
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
                // Reach to the object from wherever the palm is (fingers close around it if near).
                let d = target - palm
                if simd_length(d) < 0.12 { lifted = true; plan = .holding }
                else { plan = .idle }  // too far to feel it: the user waits for more guidance
            }
        case .holding:
            if lifted { palm = target + SIMD3(0, 0.15, 0.1) }
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
    var transcript: [String]
}

func run(_ sc: Scenario, seed: UInt64, maxTime: Double = 60) -> RunResult {
    var rng = RNG(state: seed)
    let cam = Camera(height: 1.3, tiltDown: sc.cameraTiltDown)
    // Where the app believes the target is: the perception bias at the target's depth, plus any target-only bias.
    let believedTarget = cam.perceived(sc.object, biasPerMetre: sc.biasPerMetre) + cam.xAxis * sc.targetOnlyBias
    var session = GuidanceSession(targetName: "phone", target: believedTarget, cameraTransform: cam.transform, time: 0)
    var speech = SpeechChannel()
    var user = SimUser(palm: SIMD3(0.05, 0.7, 0.05))  // hand down at the side, out of view
    var log: [String] = []
    var keypointSum = 0, frames = 0
    var missAtGrab: Float?
    let dt = 1.0 / 30

    func note(_ t: Double, _ s: String) { log.append(String(format: "%6.2f  %@", t, s)) }
    for line in session.opening { speech.say(line, time: 0); note(0, "SAY  \(line.text)") }

    var t = 0.0
    var outcome = "timeout"
    while t < maxTime {
        t += dt
        for heard in speech.tick(time: t) { user.hear(heard, time: t, scenario: sc); note(t, "     heard: \(heard)") }
        if speech.currentText == "Stop." || speech.currentText?.hasPrefix("Stop. It's") == true,
           !user.pending.contains(where: { $0.text == speech.currentText }) {
            // Short commands are acted on while being spoken.
            user.hear(speech.currentText!, time: t - sc.userReaction + 0.3, scenario: sc)
        }
        user.react(time: t, scenario: sc, rng: &rng, target: sc.object)
        user.step(dt: Float(dt), scenario: sc, time: t, target: sc.object)

        // Perception: keypoints the camera sees this frame.
        var hand: HandKeypoints?
        if !rng.chance(sc.handDropout) {
            var seen: [HandJoint: SIMD3<Float>] = [:]
            for (j, p) in handJoints(palm: user.palm) where cam.sees(p) {
                if let hide = sc.tipHidden[j], rng.chance(hide) { continue }
                let noisy = p + SIMD3(rng.gauss(sc.jointNoise), rng.gauss(sc.jointNoise), rng.gauss(sc.jointNoise))
                seen[j] = cam.perceived(noisy, biasPerMetre: sc.biasPerMetre)
            }
            if seen.count >= 4 { hand = HandKeypoints(joints: seen) }
        }
        if let h = hand { keypointSum += h.keypointCount; frames += 1 }

        // LiDAR at the target pixel: object surface (0), the hand in front (negative), or the table once lifted.
        var depthDelta: Float? = rng.gauss(0.005)
        if user.lifted { depthDelta = 0.3 + rng.gauss(0.01) }
        else if simd_length(user.palm - sc.object) < 0.1, cam.depth(user.palm) < cam.depth(sc.object) { depthDelta = -0.1 }

        let out = session.update(time: t, hand: hand, cameraTransform: cam.transform,
                                 targetDepthDelta: depthDelta, speaking: speech.speaking)
        for line in out.lines {
            speech.say(line, time: t)
            note(t, "SAY  \(line.text)" + (line.interrupt ? "  [interrupts]" : ""))
            if line.text.hasPrefix("Stop. It's") { missAtGrab = simd_length(user.palm - sc.object) }
        }
        if out.phase == .done { outcome = "done"; break }
        if out.phase == .gaveUp { outcome = "gave up"; break }
    }
    let ok = outcome == "done" && user.lifted
    note(t, "END  \(outcome); true palm-object at grab: " + (missAtGrab.map { String(format: "%.1f cm", $0 * 100) } ?? "-"))
    return RunResult(success: ok, outcome: outcome, seconds: t, lines: speech.started.count, cutOff: speech.cut,
                     trueMissAtGrab: missAtGrab, keypointsSeen: frames == 0 ? 0 : Double(keypointSum) / Double(frames),
                     transcript: log)
}

// MARK: - CLI

var args = Array(CommandLine.arguments.dropFirst())
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

print("scenario         ok    median_s  lines  cut  miss_cm  keypoints  note")
for sc in chosen {
    let seeds: [UInt64] = seed.map { [$0] } ?? (1...UInt64(runs)).map { $0 }
    let results = seeds.map { run(sc, seed: $0) }
    if verbose { for r in results { print("--- \(sc.name)"); r.transcript.forEach { print($0) } } }
    func median(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.sorted()[v.count / 2] }
    let ok = results.filter(\.success)
    let misses = results.compactMap(\.trueMissAtGrab).map { Double($0) * 100 }
    print(sc.name.padding(toLength: 16, withPad: " ", startingAt: 0) + String(format: " %2d/%-2d %8.1f  %5.1f  %3.1f  %7.1f  %9.1f  %@",
                 ok.count, results.count, median(ok.map(\.seconds)),
                 median(results.map { Double($0.lines) }), median(results.map { Double($0.cutOff) }),
                 median(misses), median(results.map(\.keypointsSeen)), sc.note as NSString))
}
