// labels: production, needs-review, important
// Find-and-grab session (PRD "Find and grab"):
//   tap -> listen -> parse noun locally -> say "Looking for the cup" at once -> SAM on the
//   current frame -> mask + LiDAR -> world target -> GuidanceSession (SightlineCore, same code
//   as the Mac simulator): where the object is -> "Hold your hand out" -> "I see your hand" ->
//   stop-and-go steps on the palm centre (six-point hand) -> "Grab it" -> pick-up -> "Got it."
// Recording mode (DiagnosticRecorder) saves photo + SAM + overlay on every SAM call and on hand
// events, for diagnosing the device left bias offline.
// Muse Spark (tool calling, Find/AgentTools) steps in only off the fast path: commands the local
// parser cannot read (effort minimal) and several plausible SAM matches (effort medium).
// Cloud is called only on events (lock, re-lock after tracking recovers); ≤ 5 SAM calls per
// find session. The guidance loop never waits on the network.

import ARKit
import AVFoundation
import Foundation
import Observation
import RealityKit
import SightlineCore
import UIKit

@Observable
final class FindModel {
    enum Phase: String {
        case idle, listening, locating, guiding, grabbing, verifying, done
    }

    static let maxSAMCalls = 5

    private(set) var phase = Phase.idle
    private(set) var targetName: String?
    private(set) var target: SIMD3<Float>?
    /// Palm-centre reference point (red dot) and visible fingertips (small dots), world space.
    private(set) var palm: SIMD3<Float>?
    private(set) var fingertips: [SIMD3<Float>] = []
    private(set) var handDistance: Float?
    /// "6/6" etc.: how many of the six keypoints are visible, or the reason none are.
    private(set) var handStatus = "-"
    private(set) var guidePhase = "-"
    private(set) var recordings = 0
    private(set) var lastHeard = ""
    private(set) var lastCue = ""
    private(set) var tracking = "-"
    private(set) var samCalls = 0
    private(set) var logURL: URL?

    let session = ARSession()
    @ObservationIgnored private let processor = FindFrameProcessor()
    @ObservationIgnored private let speaker = Speaker()
    @ObservationIgnored private let tones = TonePlayer()
    @ObservationIgnored private let input = SpeechInput()
    @ObservationIgnored private var guide: GuidanceSession?
    @ObservationIgnored private var doneAt: Date?
    @ObservationIgnored private var resumePhase = Phase.grabbing
    @ObservationIgnored private var lastFrameTime: Double = 0
    @ObservationIgnored private let recorder = DiagnosticRecorder()
    @ObservationIgnored weak var arView: ARView?
    @ObservationIgnored private var lastCamera = matrix_identity_float4x4
    @ObservationIgnored private var sessionStart: Date?
    @ObservationIgnored private var wasTrackingLimited = false
    @ObservationIgnored private var logRows: [String] = []
    @ObservationIgnored private var sessionID = 0
    @ObservationIgnored private var candidates: [Candidate] = []
    @ObservationIgnored private var lastJPEG: Data?

    init() {
        processor.onFrame = { [weak self] f in
            guard let model = self else { return }
            Task { @MainActor in model.ingest(f) }
        }
        session.delegate = processor
        session.delegateQueue = processor.queue
    }

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = [.sceneDepth]
        session.run(config)
        Task {
            // Off the main thread: setActive can block the UI.
            await Task.detached {
                let audio = AVAudioSession.sharedInstance()
                try? audio.setCategory(.playAndRecord, mode: .default,
                                       options: [.defaultToSpeaker, .duckOthers, .allowBluetoothA2DP])
                try? audio.setActive(true)
            }.value
            if await SpeechInput.requestAuthorization() {
                speaker.say("Sightline ready. Tap the screen and say what to find.")
            } else {
                speaker.say("Sightline needs microphone and speech permission. Please allow them in Settings.")
            }
        }
    }

    func pause() {
        session.pause()
        tones.stop()
        speaker.stop()
    }

    /// Tap while guiding with the hand this close (or while grabbing) = "check what I'm holding".
    static let verifyTapRadius: Float = 0.25
    /// After an automatic "Got it", a tap within this many seconds checks the object instead of listening.
    static let verifyAfterDone: TimeInterval = 15

    /// The one big button: listen when idle, check the object when the hand is at it, stop otherwise.
    func tap() {
        switch phase {
        case .idle:
            listen()
        case .done:
            if let at = doneAt, Date().timeIntervalSince(at) < Self.verifyAfterDone, targetName != nil {
                startHoldCheck()
            } else {
                listen()
            }
        case .grabbing:
            startHoldCheck()
        case .guiding where (handDistance ?? .infinity) <= Self.verifyTapRadius:
            startHoldCheck()
        case .guiding, .locating:
            finish(spoken: "Stopped.", event: "stop")
        case .listening, .verifying:
            break
        }
    }

    // MARK: Hold check (tap -> Muse Spark yes/no on the hand region)

    /// The user thinks they have it: photo of the next frame, crop around the hand, Spark (minimal) yes/no.
    private func startHoldCheck() {
        resumePhase = phase == .done ? .done : .grabbing
        phase = .verifying
        tones.stop()
        speaker.say("Checking.", interrupt: true)
        log("hold_check", "")
        processor.requestCapture("hold_check")
        // No photo (e.g. no depth this frame) or Spark too slow: give the button back.
        let id = sessionID
        Task {
            try? await Task.sleep(for: .seconds(25))
            guard id == sessionID, phase == .verifying else { return }
            log("hold_check_result", "timeout")
            say(SpokenLine(text: "I'm not sure. Hold it in front of the camera and tap again.", interrupt: true))
            phase = resumePhase
        }
    }

    private func runHoldCheck(_ s: FrameSnapshot, handVision: [HandJoint: SIMD2<Float>]) {
        guard let noun = targetName else { return }
        let id = sessionID
        let crop = Self.handRegion(handVision, snapshot: s).flatMap { Self.crop(s.jpeg, to: $0, margin: 0.8) } ?? s.jpeg
        Task {
            let answer = try? await MuseAgent.verifyHolding(noun: noun, jpeg: crop, label: "hold_\(id)")
            guard id == sessionID, phase == .verifying else { return }
            let result = answer.flatMap { $0 }
            log("hold_check_result", result.map { $0 ? "yes" : "no" } ?? "unclear")
            switch result {
            case true?:
                finish(spoken: "Yes, that's the \(noun). Well done.", event: "hold_yes")
            case false?:
                // Back to guiding from the hand prompt; the target stays where SAM put it.
                say(SpokenLine(text: "That doesn't look like the \(noun). Put it down, and I'll guide you again.", interrupt: true))
                guide = target.map { GuidanceSession(targetName: noun, target: $0, cameraTransform: lastCamera, time: lastFrameTime) }
                processor.target = target
                phase = .guiding
            case nil:
                say(SpokenLine(text: "I'm not sure. Hold it in front of the camera and tap again.", interrupt: true))
                phase = resumePhase
            }
        }
    }

    /// Bounding box of the Vision hand joints on the uploaded image, nil without joints.
    nonisolated static func handRegion(_ joints: [HandJoint: SIMD2<Float>], snapshot s: FrameSnapshot) -> CGRect? {
        let px = joints.values.map { DiagnosticRecorder.portraitPixel(vision: $0, snapshot: s) }
        guard px.count >= 3, let minX = px.map(\.x).min(), let maxX = px.map(\.x).max(),
              let minY = px.map(\.y).min(), let maxY = px.map(\.y).max() else { return nil }
        return CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
    }

    // MARK: Command

    private func listen() {
        speaker.stop()
        tones.stop()
        phase = .listening
        Task {
            let heard = (try? await input.listenOnce()) ?? ""
            lastHeard = heard
            switch CommandParser.parse(heard) {
            case .find(let noun):
                startFind(noun)
            case .stop:
                finish(spoken: "Stopped.", event: "stop")
            case nil where heard.isEmpty:
                phase = .idle
                speaker.say("I didn't hear anything. Tap and try again.")
            case nil:
                startAgent(heard: heard)
            }
        }
    }

    private func beginSession(name: String?) {
        sessionID += 1
        targetName = name
        target = nil
        candidates = []
        samCalls = 0
        guide = nil
        guidePhase = "-"
        processor.target = nil
        sessionStart = Date()
        phase = .locating
    }

    private func startFind(_ noun: String) {
        beginSession(name: noun)
        log("command", noun)
        // Instant local cue (G4): the user hears something before any network call.
        speaker.say("Looking for the \(noun).")
        Task { await lock(noun: noun) }
    }

    /// The local parser could not read the command ("I'm thirsty"): Muse Spark (minimal) decides.
    private func startAgent(heard: String) {
        beginSession(name: nil)
        log("command_agent", heard)
        speaker.say("One moment.")
        Task {
            await runAgent(prompt: "The user said: \"\(heard)\". Work out which object they want, find it and select it. "
                           + "If it is not a request to find an object, say so briefly and stop.",
                           jpeg: nil, effort: .minimal)
        }
    }

    // MARK: Cloud (event-triggered)

    struct Candidate: Sendable {
        var info: AgentCandidate
        var world: SIMD3<Float>
        /// SAM box on the uploaded image (pixels), for the verification crop.
        var box: CGRect
        var recorded: RecordedCandidate
    }

    /// Below this SAM confidence, Spark checks the crop before we trust it (the first device test
    /// locked a power bank for "phone" in a room with no phone).
    static let verifyBelow: Float = 0.75

    /// One SAM call on the current frame -> up to 4 candidates in 3D, most confident first.
    private func segment(_ noun: String) async -> Result<[Candidate], FindError> {
        guard samCalls < Self.maxSAMCalls else { return .failure(FindError("budget")) }
        var snapshot: FrameSnapshot?
        for _ in 0..<10 {
            if let frame = session.currentFrame, let s = try? FrameSnapshot.make(from: frame, tracking: tracking) {
                snapshot = s
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard let s = snapshot else { return .failure(FindError("no_frame")) }
        samCalls += 1
        lastJPEG = s.jpeg
        do {
            let response = try await MetaAPI.segment(noun: noun, jpeg: s.jpeg, imageLabel: "find_\(sessionID)_\(samCalls)")
            let list = Self.candidates(from: response.text, snapshot: s)
            for c in list where c.recorded.reprojectsInsideMask == false {
                log("target_outside_mask", "id \(c.info.id)")
            }
            record(kind: "sam", snapshot: s, samText: response.text, candidates: list.map(\.recorded), hand: nil)
            return list.isEmpty ? .failure(FindError("no_object")) : .success(list)
        } catch {
            return .failure(FindError("api_error"))
        }
    }

    nonisolated static func candidates(from text: String, snapshot s: FrameSnapshot) -> [Candidate] {
        let t = s.cameraTransform
        let camera = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        // SAM returns every instance, unsorted.
        let records = SAMParser.parse(text).filter { ($0.confidence ?? 1) >= 0.3 }
            .sorted { ($0.confidence ?? 0) > ($1.confidence ?? 0) }.prefix(4)
        return records.enumerated().compactMap { index, r in
            guard let raster = try? r.decodeMask() else { return nil }
            let mask = SourceMask(record: r, raster: raster)
            guard case .success(let hit) = MaskTarget.locate(mask: mask, depth: s.depth, intrinsics: s.intrinsics) else { return nil }
            let check = MaskTarget.reprojectsInside(cameraPoint: hit.cameraPoint, mask: mask, intrinsics: s.intrinsics)
            let world = DepthProjector.world(fromCamera: hit.cameraPoint, cameraTransform: t)
            let info = AgentCandidate(id: r.id, confidence: r.confidence ?? 0,
                                      offset: BodyOffset(from: camera, to: world, cameraTransform: t),
                                      widthFraction: Float(r.right - r.left) / Float(r.sourceWidth),
                                      heightFraction: Float(r.bottom - r.top) / Float(r.sourceHeight))
            let box = CGRect(x: r.left, y: r.top, width: r.right - r.left, height: r.bottom - r.top)
            let recorded = RecordedCandidate(id: r.id, confidence: r.confidence ?? 0, world: world, cameraPoint: hit.cameraPoint,
                                             samples: hit.samples, depthSpread: hit.depthSpread, box: box, mask: mask,
                                             reprojected: check?.pixel, reprojectsInsideMask: check?.inside, chosen: index == 0)
            return Candidate(info: info, world: world, box: box, recorded: recorded)
        }
    }

    private func lock(noun: String) async {
        let id = sessionID
        let result = await segment(noun)
        guard id == sessionID, phase == .locating else { return }  // stopped meanwhile
        switch result {
        case .failure(let error):
            log("sam_lock_fail", error.reason)
            phase = .idle
            speaker.say("I can't see the \(noun). Turn slowly, then tap and ask again.", interrupt: true)
        case .success(let list):
            candidates = list
            log("sam_lock", "\(list.count) candidates")
            if AgentTools.isAmbiguous(list.map(\.info.confidence)) {
                speaker.say("I see more than one \(noun). Checking.")
                await runAgent(prompt: "The user said: \"\(lastHeard)\". SAM found several \(noun) candidates "
                               + "(call get_state; the photo is what the chest camera sees). Select the one they mean, or ask them.",
                               jpeg: lastJPEG, effort: .medium)
            } else if list[0].info.confidence < Self.verifyBelow {
                speaker.say("Checking.")
                let ok = await verify(noun: noun, candidate: list[0])
                guard id == sessionID, phase == .locating else { return }
                log("verify", "c \(list[0].info.confidence) -> \(ok.map { $0 ? "yes" : "no" } ?? "error")")
                if ok == false {
                    phase = .idle
                    speaker.say("I can't see the \(noun). Turn slowly, then tap and ask again.", interrupt: true)
                } else {
                    select(list[0])
                }
            } else {
                select(list[0])
            }
        }
    }

    /// Muse Spark (minimal) yes/no on a crop around the SAM box. nil = could not check.
    private func verify(noun: String, candidate c: Candidate) async -> Bool? {
        guard let jpeg = lastJPEG, let crop = Self.crop(jpeg, to: c.box, margin: 0.3) else { return nil }
        return try? await MuseAgent.verify(noun: noun, jpeg: crop, label: "verify_\(sessionID)")
    }

    nonisolated static func crop(_ jpeg: Data, to box: CGRect, margin: CGFloat) -> Data? {
        guard let image = UIImage(data: jpeg)?.cgImage else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let rect = box.insetBy(dx: -box.width * margin, dy: -box.height * margin).intersection(bounds).integral
        guard !rect.isEmpty, let cropped = image.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped).jpegData(compressionQuality: 0.85)
    }

    private func select(_ c: Candidate, intro: String? = nil) {
        target = c.world
        processor.target = c.world
        phase = .guiding
        log("target", "id \(c.info.id) c \(c.info.confidence)")
        let session = GuidanceSession(targetName: targetName ?? "object", target: c.world,
                                      cameraTransform: lastCamera, time: lastFrameTime)
        guide = session
        guidePhase = session.phase.rawValue
        if let intro { say(SpokenLine(text: intro, interrupt: true)) }
        for (i, line) in session.opening.enumerated() {
            say(SpokenLine(text: line.text, interrupt: line.interrupt && i == 0 && intro == nil))
        }
    }

    private func say(_ line: SpokenLine) {
        lastCue = line.text
        log("say", line.text + (line.interrupt ? " [interrupts]" : ""), distance: handDistance)
        speaker.say(line.text, interrupt: line.interrupt)
    }

    /// Tracking recovered: re-run SAM and follow the nearest candidate if the object moved a little.
    private func relock() {
        guard let noun = targetName, let current = target else { return }
        let id = sessionID
        Task {
            let result = await segment(noun)
            guard id == sessionID, phase == .guiding else { return }
            guard case .success(let list) = result,
                  let nearest = list.min(by: { simd_distance($0.world, current) < simd_distance($1.world, current) }) else {
                log("sam_relock_fail", "")
                return
            }
            let moved = simd_distance(nearest.world, current)
            log("sam_relock", String(format: "moved %.1f cm", moved * 100))
            if moved < 0.3 {
                target = nearest.world
                processor.target = nearest.world
                guide?.moveTarget(to: nearest.world)
            }
        }
    }

    // MARK: Muse Spark commander (tool calling)

    private enum ToolResult {
        case output(String)
        case ended
    }

    private func runAgent(prompt: String, jpeg: Data?, effort: MuseAgent.Effort) async {
        let id = sessionID
        // State goes into the first message so Spark does not spend a turn on get_state.
        var history = MuseAgent.userMessage(AgentTools.instructions + "\n\n" + prompt
                                            + "\n\nCurrent state (same as get_state): " + agentState().json(), jpeg: jpeg)
        for turnIndex in 0..<6 {
            let turn: SparkTurn
            do {
                turn = try await MuseAgent.respond(history: history, effort: effort, label: "agent_\(id)_\(turnIndex)")
            } catch {
                log("agent_error", error.localizedDescription)
                guard id == sessionID else { return }
                phase = .idle
                speaker.say("Sorry, I'm not sure. Tap and try again.", interrupt: true)
                return
            }
            guard id == sessionID, phase == .locating else { return }
            if turn.calls.isEmpty {
                // tool_choice is always auto: a plain text reply ends the turn.
                log("agent_text", turn.text)
                phase = .idle
                speaker.say(turn.text.isEmpty ? "Sorry, I'm not sure. Tap and try again." : turn.text)
                return
            }
            var outputs: [[String: Any]] = []
            for call in turn.calls {
                log("agent_tool", "\(call.name) \(call.arguments)")
                guard let action = AgentAction.parse(name: call.name, arguments: call.arguments) else {
                    outputs.append(MuseAgent.toolOutput(callID: call.callID, output: #"{"error":"unknown tool or bad arguments"}"#))
                    continue
                }
                switch await perform(action) {
                case .output(let text):
                    outputs.append(MuseAgent.toolOutput(callID: call.callID, output: text))
                case .ended:
                    return
                }
                guard id == sessionID, phase == .locating else { return }
            }
            history += turn.calls.map(MuseAgent.callItem) + outputs
        }
        log("agent_turn_limit", "")
        phase = .idle
        speaker.say("Sorry, I'm not sure. Tap and try again.")
    }

    private func perform(_ action: AgentAction) async -> ToolResult {
        switch action {
        case .getState:
            return .output(agentState().json())
        case .findObject(let noun):
            targetName = noun
            speaker.say("Looking for the \(noun).")
            switch await segment(noun) {
            case .success(let list):
                candidates = list
                return .output(agentState().json())
            case .failure(let error):
                candidates = []
                return .output("{\"error\":\"\(error.reason)\"}")
            }
        case .selectTarget(let candidateID, let sentence):
            guard let c = candidates.first(where: { $0.info.id == candidateID }) else {
                return .output(#"{"error":"unknown candidate_id"}"#)
            }
            select(c, intro: sentence)
            return .ended
        case .say(let text):
            speaker.say(text)
            return .output("ok")
        case .askUser(let question):
            speaker.say(question, interrupt: true)
            try? await Task.sleep(for: .milliseconds(150))
            while speaker.isSpeaking { try? await Task.sleep(for: .milliseconds(100)) }
            let answer = (try? await input.listenOnce()) ?? ""
            log("agent_answer", answer)
            return .output(answer.isEmpty ? "(no answer)" : answer)
        case .stop:
            log("agent_stop", "")
            phase = .idle
            tones.stop()
            return .ended
        }
    }

    private func agentState() -> AgentState {
        AgentState(phase: phase.rawValue, userSaid: lastHeard, targetName: targetName,
                   candidates: candidates.map(\.info), samCallsLeft: Self.maxSAMCalls - samCalls, tracking: tracking)
    }

    // MARK: Local loop (~30 Hz)

    private func ingest(_ f: FindFrame) {
        tracking = f.tracking
        lastCamera = f.cameraTransform
        lastFrameTime = f.time
        palm = f.hand?.reference
        fingertips = f.hand.map { Array($0.tips.values) } ?? []
        handStatus = f.hand.map { "\($0.keypointCount)/6" } ?? (f.handFail ?? "-")
        if f.tracking != "normal" { wasTrackingLimited = true }
        if let capture = f.capture {
            record(kind: capture.kind, snapshot: capture.snapshot, samText: nil, candidates: [],
                   hand: RecordedHand(vision: f.handVision, world: f.hand?.joints ?? [:], depths: f.handDepths),
                   extra: ["hand_to_target_cm": handDistance.map { $0 * 100 } ?? -1,
                           "target_world": target.map { [$0.x, $0.y, $0.z] } ?? []])
            if capture.kind == "hold_check" { runHoldCheck(capture.snapshot, handVision: f.handVision) }
        }
        guard phase == .guiding || phase == .grabbing, var session = guide else {
            handDistance = nil
            return
        }
        // Re-lock once tracking recovers (PRD: re-check when tracking confidence drops).
        if phase == .guiding && wasTrackingLimited && f.tracking == "normal" {
            wasTrackingLimited = false
            relock()
        }
        let out = session.update(time: f.time, hand: f.hand, cameraTransform: f.cameraTransform,
                                 targetDepthDelta: f.targetDepthDelta, speaking: speaker.isSpeaking)
        guide = session
        guidePhase = out.phase.rawValue
        handDistance = out.handDistance
        tones.update(distance: out.toneDistance)
        for line in out.lines {
            say(line)
            // Snapshot the hand at the moments that tell us most about the hand-point bias.
            if line.text == "I see your hand." { processor.requestCapture("hand_seen") }
            if line.text.hasPrefix("Stop. It's at your hand") { processor.requestCapture("grab") }
        }
        switch out.phase {
        case .grabbing:
            phase = .grabbing
        case .done:
            finish(spoken: nil, event: "pickup")
        case .gaveUp:
            finish(spoken: "Stopping. Tap to start again.", event: "gave_up")
        case .waitingForHand, .guiding:
            break
        }
    }

    private func record(kind: String, snapshot: FrameSnapshot, samText: String?, candidates: [RecordedCandidate],
                        hand: RecordedHand?, extra: [String: Any] = [:]) {
        let write: (UIImage?) -> Void = { [weak self] screen in
            guard let self else { return }
            let prefix = recorder.record(kind: kind, snapshot: snapshot, noun: targetName, samText: samText,
                                         candidates: candidates, hand: hand, screen: screen, extra: extra)
            recordings += 1
            log("recorded", prefix)
        }
        if let arView { arView.snapshot(saveToHDR: false) { write($0) } } else { write(nil) }
    }

    /// Log CSV and the diagnostics folder of this launch, for the Export button.
    var exportURLs: [URL] {
        [logURL, FileManager.default.fileExists(atPath: recorder.folder.path) ? recorder.folder : nil].compactMap { $0 }
    }

    /// `spoken` nil: the line was already said (GuidanceSession's "Got it").
    private func finish(spoken: String?, event: String) {
        tones.stop()
        processor.target = nil
        if let spoken { speaker.say(spoken, interrupt: true) }
        log(event, spoken ?? "", distance: handDistance)
        phase = ["pickup", "done_tap", "hold_yes"].contains(event) ? .done : .idle
        doneAt = event == "pickup" ? Date() : nil
    }

    // MARK: Log

    /// One CSV per app launch, rewritten after every event (cumulative); export once at the end.
    private func log(_ event: String, _ detail: String, distance: Float? = nil) {
        let elapsed = sessionStart.map { String(format: "%.2f", Date().timeIntervalSince($0)) } ?? ""
        let row = [ISO8601DateFormatter().string(from: Date()), "\(sessionID)", elapsed, event,
                   targetName ?? "", detail.replacingOccurrences(of: ",", with: ";"),
                   distance.map { String(format: "%.1f", $0 * 100) } ?? "", "\(samCalls)", tracking].joined(separator: ",")
        logRows.append(row)
        let url = logURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("find_log_\(Int(Date().timeIntervalSince1970)).csv")
        let header = "timestamp,session,elapsed_s,event,target,detail,hand_to_target_cm,sam_calls,tracking_state"
        try? (([header] + logRows).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        logURL = url
    }
}

nonisolated struct FindError: Error, Sendable {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

nonisolated struct FindFrame: Sendable {
    var time: Double
    var tracking: String
    var cameraTransform: simd_float4x4
    /// Six-point hand in world space; nil when not usable this frame (see `handFail`).
    var hand: HandKeypoints?
    var handVision: [HandJoint: SIMD2<Float>]
    var handDepths: [HandJoint: Float]
    var handFail: String?
    /// Set on the frame after `requestCapture`: the photo of this exact frame, for the recorder.
    var capture: (kind: String, snapshot: FrameSnapshot)?
    /// LiDAR depth at the target's pixel minus the target's own depth; > 0 = something farther
    /// is visible there now (object lifted away). nil when the target is off-screen or unreadable.
    var targetDepthDelta: Float?
}

/// Runs the six-point hand pipeline on every second frame (≤ 30 Hz) off the main thread; drops frames
/// while busy (FrameGate) so ARKit never waits on us.
nonisolated final class FindFrameProcessor: NSObject, ARSessionDelegate, @unchecked Sendable {
    private let gate = FrameGate(label: "sightline.find.frames")
    var queue: DispatchQueue { gate.delegateQueue }
    var onFrame: (@Sendable (FindFrame) -> Void)?
    private let locator = HandKeypointLocator()
    private var frameCount = 0

    // Written from the main actor, read on `queue`.
    private let lock = NSLock()
    private var _target: SIMD3<Float>?
    var target: SIMD3<Float>? {
        get { lock.withLock { _target } }
        set { lock.withLock { _target = newValue } }
    }
    private var _capture: String?

    /// The next processed frame also carries its photo (FrameSnapshot) under this kind.
    func requestCapture(_ kind: String) { lock.withLock { _capture = kind } }
    private func takeCapture() -> String? { lock.withLock { defer { _capture = nil }; return _capture } }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameCount += 1
        guard frameCount % 2 == 0 else { return }
        gate.submit(frame) { [self] frame in
            let r = locator.locate(in: frame)
            let tracking = FrameProcessor.describe(frame.camera.trackingState)
            let capture = takeCapture().flatMap { kind in
                (try? FrameSnapshot.make(from: frame, tracking: tracking)).map { (kind: kind, snapshot: $0) }
            }
            onFrame?(FindFrame(time: frame.timestamp, tracking: tracking, cameraTransform: frame.camera.transform,
                               hand: r.keypoints, handVision: r.vision, handDepths: r.depths, handFail: r.failReason,
                               capture: capture,
                               targetDepthDelta: target.flatMap { depthDelta(at: $0, frame: frame) }))
        }
    }

    /// Median LiDAR depth (medium+ confidence) in a 5x5 window at the target's pixel, minus the target's depth.
    private func depthDelta(at target: SIMD3<Float>, frame: ARFrame) -> Float? {
        guard let data = frame.sceneDepth, let depth = DepthImageReader.read(data) else { return nil }
        let t = frame.camera.transform
        let c = DepthProjector.camera(fromWorld: target, cameraTransform: t)
        let rawSize = SIMD2(Float(frame.camera.imageResolution.width), Float(frame.camera.imageResolution.height))
        let k = CameraIntrinsics(matrix: frame.camera.intrinsics, imageSize: rawSize)
            .scaled(to: SIMD2(Float(depth.width), Float(depth.height)))
        guard let p = DepthProjector.project(cameraPoint: c, intrinsics: k) else { return nil }
        let cx = Int(p.x.rounded()), cy = Int(p.y.rounded())
        var values: [Float] = []
        for y in (cy - 2)...(cy + 2) where y >= 0 && y < depth.height {
            for x in (cx - 2)...(cx + 2) where x >= 0 && x < depth.width {
                let i = y * depth.width + x
                let d = depth.depth[i]
                guard d.isFinite, d > 0, (depth.confidence?[i] ?? 2) >= 1 else { continue }
                values.append(d)
            }
        }
        guard values.count >= 8, let median = Stats.median(values) else { return nil }
        return median - (-c.z)
    }
}
