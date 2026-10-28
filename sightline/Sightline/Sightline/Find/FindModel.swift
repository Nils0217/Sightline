// labels: production, needs-review, important
// Find-and-grab session (PRD "Find and grab"):
//   tap -> listen -> parse noun locally -> say "Looking for the cup" at once -> SAM on the
//   current frame -> mask + LiDAR -> world target -> 30 Hz hand guidance (speech + tones)
//   -> "Now grab".
// Muse Spark (tool calling, Find/AgentTools) steps in only off the fast path: commands the local
// parser cannot read (effort minimal) and several plausible SAM matches (effort medium).
// Cloud is called only on events (lock, re-lock after tracking recovers); ≤ 5 SAM calls per
// find session. The guidance loop never waits on the network.

import ARKit
import AVFoundation
import Foundation
import Observation
import SightlineCore

@Observable
final class FindModel {
    enum Phase: String {
        case idle, listening, locating, guiding, done
    }

    static let maxSAMCalls = 5

    private(set) var phase = Phase.idle
    private(set) var targetName: String?
    private(set) var target: SIMD3<Float>?
    private(set) var tip: SIMD3<Float>?
    private(set) var handDistance: Float?
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
    @ObservationIgnored private var guidance = GuidanceController()
    @ObservationIgnored private var throttle = SpeechThrottle()
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
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default,
                                                         options: [.defaultToSpeaker, .duckOthers, .allowBluetoothA2DP])
        try? AVAudioSession.sharedInstance().setActive(true)
        Task {
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

    /// The one big button: listen when idle, stop when busy.
    func tap() {
        switch phase {
        case .idle, .done:
            listen()
        case .guiding, .locating:
            finish(spoken: "Stopped.", event: "stop")
        case .listening:
            break
        }
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
        guidance = GuidanceController()
        throttle = SpeechThrottle()
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
    }

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
        return records.compactMap { r in
            guard let raster = try? r.decodeMask(),
                  case .success(let hit) = MaskTarget.locate(mask: SourceMask(record: r, raster: raster),
                                                             depth: s.depth, intrinsics: s.intrinsics) else { return nil }
            let world = DepthProjector.world(fromCamera: hit.cameraPoint, cameraTransform: t)
            let info = AgentCandidate(id: r.id, confidence: r.confidence ?? 0,
                                      offset: BodyOffset(from: camera, to: world, cameraTransform: t),
                                      widthFraction: Float(r.right - r.left) / Float(r.sourceWidth),
                                      heightFraction: Float(r.bottom - r.top) / Float(r.sourceHeight))
            return Candidate(info: info, world: world)
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
            } else {
                select(list[0])
            }
        }
    }

    private func select(_ c: Candidate, intro: String? = nil) {
        target = c.world
        phase = .guiding
        log("target", "id \(c.info.id) c \(c.info.confidence)")
        let whereIs = GuidanceController.describe(target: c.world, cameraTransform: lastCamera, name: targetName ?? "object")
        speaker.say([intro, whereIs, "Reach out slowly."].compactMap { $0 }.joined(separator: " "), interrupt: true)
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
            if moved < 0.3 { target = nearest.world }
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
        tip = f.tip
        if f.tracking != "normal" { wasTrackingLimited = true }
        guard phase == .guiding, let target, let name = targetName else {
            handDistance = nil
            return
        }
        // Re-lock once tracking recovers (PRD: re-check when tracking confidence drops).
        if wasTrackingLimited && f.tracking == "normal" {
            wasTrackingLimited = false
            relock()
        }
        let offset = f.tip.map { BodyOffset(from: $0, to: target, cameraTransform: f.cameraTransform) }
        handDistance = offset?.length
        tones.update(distance: offset?.length)
        guard let cue = guidance.update(time: f.time, offset: offset, targetName: name) else { return }
        if throttle.shouldSpeak(cue, time: f.time, speaking: speaker.isSpeaking) {
            lastCue = cue.phrase
            log("cue", cue.phrase, distance: offset?.length)
            if cue.kind == .grab {
                finish(spoken: cue.phrase, event: "grab")
            } else {
                speaker.say(cue.phrase)
            }
        }
    }

    private func finish(spoken: String, event: String) {
        tones.stop()
        speaker.say(spoken, interrupt: true)
        log(event, spoken, distance: handDistance)
        phase = event == "grab" ? .done : .idle
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
    var tip: SIMD3<Float>?
}

/// Runs the fingertip pipeline on every second frame (~30 Hz) off the main thread.
nonisolated final class FindFrameProcessor: NSObject, ARSessionDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "sightline.find.frames", qos: .userInteractive)
    var onFrame: (@Sendable (FindFrame) -> Void)?
    private let locator = FingertipLocator()
    private var frameCount = 0

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameCount += 1
        guard frameCount % 2 == 0 else { return }
        let r = locator.locate(in: frame)
        onFrame?(FindFrame(time: frame.timestamp, tracking: FrameProcessor.describe(frame.camera.trackingState),
                           cameraTransform: frame.camera.transform, tip: r.tip))
    }
}
