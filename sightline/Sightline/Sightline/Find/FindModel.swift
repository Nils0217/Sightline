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
// 2026-10-29 (after the 9d77d1e device test, docs/TEST_LOG.md): speech watchdog + audio session
// keeper, SAM empty output = "nothing found" (not an error), small objects tiled 2x2, strict hold
// check (reference photo + "is it still on the table"), scan says which way to turn and asks Spark
// for a guess when it gives up, room map ("scan the room"), and blind controls: every tap answers
// at once, double tap = status, long press = reset, haptics and earcons.

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
        case idle, listening, locating, searching, guiding, grabbing, verifying, done, mapping
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
    @ObservationIgnored private let audio = AudioSessionKeeper()
    @ObservationIgnored private let room = RoomMapStore()
    /// Waiting for ARKit to relocalize against the saved room map (since this date).
    @ObservationIgnored private var relocalizingSince: Date?
    /// The target as seen at lock (crop of the SAM box), for the strict hold check.
    @ObservationIgnored private var referenceCrop: Data?
    /// Room scan in progress ("scan the room").
    @ObservationIgnored private var mapPlanner: ScanPlanner?
    @ObservationIgnored private var mapInventory = RoomInventory(created: Date())
    @ObservationIgnored private var mapInFlight = 0
    @ObservationIgnored private var mapViews = 0
    @ObservationIgnored private var guide: GuidanceSession?
    @ObservationIgnored private var doneAt: Date?
    /// Keep-scanning state while the object is not in view (ScanPlanner decides when to call SAM).
    @ObservationIgnored private var scan: ScanPlanner?
    @ObservationIgnored private var scanInFlight = false
    @ObservationIgnored private var scanCalls = 0
    /// The current hold check came from GuidanceSession (hand left the object), not from a tap.
    @ObservationIgnored private var checkFromSession = false
    /// Where each object was last locked during this app launch (world space; not across launches:
    /// loading the G3 world map at start would block tracking in any other room).
    @ObservationIgnored private var lastSeen: [String: SIMD3<Float>] = [:]
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
        speaker.onEvent = { [weak self] event, text in self?.log(event, text) }
        audio.onEvent = { [weak self] event, detail in self?.log(event, detail) }
        audio.onReset = { [weak self] in self?.speaker.rebuild(reason: "audio reset") }
    }

    private static func trackingConfig() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = [.sceneDepth]
        return config
    }

    func start() {
        let config = Self.trackingConfig()
        if let map = room.load() {
            // Saved room map: relocalize against it; ingest() falls back after RoomMapStore.relocalizeTimeout.
            config.initialWorldMap = map
            relocalizingSince = Date()
            log("room_map_load", "\(room.inventory?.items.count ?? 0) items")
        }
        session.run(config)
        audio.start()
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

    /// Tap while guiding with the hand this close (or while grabbing) = "check what I'm holding".
    static let verifyTapRadius: Float = 0.25
    /// After an automatic "Got it", a tap within this many seconds checks the object instead of listening.
    static let verifyAfterDone: TimeInterval = 15

    /// The one big button: listen when idle, check the object when the hand is at it, stop otherwise.
    /// Every tap is answered at once (haptic, then a sound or words), 2026-10-29 blindfold test.
    func tap() {
        Haptics.tap()
        log("tap", phase.rawValue)
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
        case .guiding, .locating, .searching:
            finish(spoken: "Stopped. Tap to speak a command.", event: "stop")
        case .mapping:
            finishMapping(early: true)
        case .verifying:
            speaker.say("Still checking.")
        case .listening:
            break  // speaking now would be heard by the recogniser; the haptic is the answer
        }
    }

    /// Double tap: say where we are and what to do next.
    func speakStatus() {
        Haptics.tap()
        let line = statusLine()
        log("status", line)
        speaker.say(line, interrupt: true)
    }

    /// Long press: cancel everything and go back to idle.
    func reset() {
        Haptics.reset()
        sessionID += 1  // every pending task sees a new session and drops its result
        tones.stop()
        tones.earcon(.reset)
        processor.target = nil
        guide = nil
        scan = nil
        mapPlanner = nil
        candidates = []
        phase = .idle
        log("reset", "")
        speaker.say("Reset. Tap to speak a command.", interrupt: true)
    }

    func statusLine() -> String {
        let name = targetName ?? "object"
        switch phase {
        case .idle:
            return "Ready. Tap and say what to find." + (room.active ? " Room map is on." : "")
        case .listening:
            return "Listening."
        case .locating:
            return "Looking for the \(name)."
        case .searching:
            return "Searching for the \(name). \(scanCalls) views checked. Turn slowly. Tap to stop."
        case .guiding:
            guard let d = handDistance else { return "Guiding you to the \(name). I can't see your hand. Reach toward it. Tap to stop." }
            return "Guiding you to the \(name). Your hand is about \(max(1, Int((d * 10).rounded())) * 10) centimetres away."
        case .grabbing:
            return "Your hand is at the \(name). Grab it and lift it. Tap if you think you have it."
        case .verifying:
            return "Checking what you are holding."
        case .done:
            return "Done. You have the \(name). Tap to find something else."
        case .mapping:
            return "Scanning the room. \(mapViews) views, \(mapInventory.items.count) things so far. Turn slowly. Tap to finish."
        }
    }

    // MARK: Hold check (tap -> Muse Spark yes/no on the hand region)

    /// The user thinks they have it: photo of the next frame, crop around the hand, Spark (minimal) yes/no.
    private func startHoldCheck(fromSession: Bool = false) {
        checkFromSession = fromSession
        resumePhase = phase == .done ? .done : .grabbing
        phase = .verifying
        tones.stop()
        if !fromSession { speaker.say("Checking.", interrupt: true) }  // the session already said it
        log("hold_check", fromSession ? "hand left the object" : "tap")
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
        let reference = referenceCrop
        // The hand has moved away from where the object was: if SAM still sees it there, it was not taken.
        let handAway = checkFromSession || (handDistance ?? 0) > 0.12
        let original = target
        Task {
            async let spark = MuseAgent.verifyHolding(noun: noun, jpeg: crop, reference: reference, label: "hold_\(id)")
            async let there = handAway ? stillThere(noun, at: original, snapshot: s) : nil
            var result = (try? await spark).flatMap { $0 }
            let stillThere = await there
            guard id == sessionID, phase == .verifying else { return }
            log("hold_check_result", (result.map { $0 ? "yes" : "no" } ?? "unclear")
                + (reference == nil ? "" : " (with reference)") + " still_there \(stillThere.map { "\($0)" } ?? "not checked")")
            if stillThere == true && result != false {
                result = false
                log("hold_check_override", "object still where it was found")
            }
            if checkFromSession, var session = guide {
                checkFromSession = false
                let lines = session.resolveCheck(result, time: lastFrameTime)
                guide = session
                lines.forEach(say)
                switch session.phase {
                case .done: finish(spoken: nil, event: "hold_yes")
                case .grabbing: phase = .grabbing
                default: phase = .guiding
                }
                return
            }
            switch result {
            case true?:
                finish(spoken: "Yes, that's the \(noun). Well done.", event: "hold_yes")
            case false?:
                // Back to guiding from the hand prompt; the target stays where SAM put it.
                Haptics.warning()
                tones.earcon(.failure)
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

    /// One SAM call on the hold-check photo: is the object still where it was locked (within 5 cm)?
    /// nil = could not tell (target off-screen, no answer).
    private func stillThere(_ noun: String, at original: SIMD3<Float>?, snapshot s: FrameSnapshot) async -> Bool? {
        guard let original else { return nil }
        let c = DepthProjector.camera(fromWorld: original, cameraTransform: s.cameraTransform)
        let k = s.intrinsics  // raw camera image
        guard let p = DepthProjector.project(cameraPoint: c, intrinsics: k),
              p.x > 0, p.y > 0, p.x < k.imageSize.x, p.y < k.imageSize.y else { return nil }
        guard let response = try? await MetaAPI.segment(noun: noun, jpeg: s.jpeg, imageLabel: "still_\(sessionID)") else { return nil }
        let list = Self.candidates(from: SAMParser.parse(response.text), snapshot: s)
        return list.contains { simd_distance($0.world, original) < 0.05 }
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
        tones.earcon(.listening)
        phase = .listening
        let id = sessionID
        Task {
            try? await Task.sleep(for: .milliseconds(180))  // let the earcon end before the mic opens
            let heard = (try? await input.listenOnce()) ?? ""
            // The input engine may have changed the route: back to the loudspeaker before speaking.
            audio.apply()
            guard id == sessionID else { return }  // long-press reset while listening
            lastHeard = heard
            switch CommandParser.parse(heard) {
            case .find(let noun):
                startFind(noun)
            case .mapRoom:
                startMapping()
            case .stop:
                finish(spoken: "Stopped. Tap to speak a command.", event: "stop")
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
        scanCalls = 0
        scan = nil
        scanInFlight = false
        checkFromSession = false
        referenceCrop = nil
        mapPlanner = nil
        guide = nil
        guidePhase = "-"
        // A limited-tracking moment before this search must not trigger a re-lock (2026-10-28 log:
        // an extra SAM call 2 s into the search with tracking normal).
        wasTrackingLimited = false
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
        /// 3D shape + support plane (guidance to the nearest surface, fingertip grasp check).
        var object: ObjectModel?
        var obstacles: ObstacleMap?
    }

    /// Below this SAM confidence, Spark checks the crop before we trust it (the first device test
    /// locked a power bank for "phone" in a room with no phone).
    static let verifyBelow: Float = 0.75

    /// The current frame as a snapshot (retries while depth is missing).
    private func snapshot(longEdge: CGFloat = FrameSnapshot.longEdge) async -> FrameSnapshot? {
        for _ in 0..<10 {
            if let frame = session.currentFrame,
               let s = try? FrameSnapshot.make(from: frame, tracking: tracking, longEdge: longEdge) { return s }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    /// One SAM event on the current frame -> up to 4 candidates in 3D, most confident first.
    /// `scanning`: counted against the scan budget (ScanPlanner) instead of `maxSAMCalls`.
    /// Small objects (SmallObjects, e.g. keys): a 930 px photo cut into 2x2 tiles of ~512 px, one SAM
    /// call per tile in parallel (2026-10-29: the keys were 13x17 px at 512 px and SAM missed them).
    private func segment(_ noun: String, scanning: Bool = false) async -> Result<[Candidate], FindError> {
        guard scanning || samCalls < Self.maxSAMCalls else { return .failure(FindError("budget")) }
        let tiled = SmallObjects.isSmall(noun)
        guard let s = await snapshot(longEdge: tiled ? FrameSnapshot.tiledLongEdge : FrameSnapshot.longEdge) else {
            return .failure(FindError("no_frame"))
        }
        if scanning { scanCalls += 1 } else { samCalls += 1 }
        lastJPEG = s.jpeg
        do {
            let label = "find_\(sessionID)_\(samCalls + scanCalls)"
            var records: [SAMRecord]
            var samText: String
            var extra: [String: Any] = ["scanning": scanning]
            if tiled {
                let tiles = SmallObjects.tiles(for: s.imageSize)
                let texts = try await withThrowingTaskGroup(of: (Int, String).self) { group in
                    for (i, tile) in tiles.enumerated() {
                        let rect = CGRect(x: tile.origin.x, y: tile.origin.y, width: tile.size.x, height: tile.size.y)
                        guard let jpeg = Self.crop(s.jpeg, to: rect, margin: 0) else { continue }
                        group.addTask { (i, try await MetaAPI.segment(noun: noun, jpeg: jpeg, imageLabel: "\(label)_tile\(i)").text) }
                    }
                    var out = [String](repeating: "", count: tiles.count)
                    for try await (i, text) in group { out[i] = text }
                    return out
                }
                samText = texts.joined(separator: SmallObjects.separator)
                records = SmallObjects.parseTiled(samText, origins: tiles.map(\.origin), fullSize: s.imageSize)
                extra["tile_origins"] = tiles.map { [$0.origin.x, $0.origin.y] }
                extra["tile_size"] = [tiles[0].size.x, tiles[0].size.y]
            } else {
                samText = try await MetaAPI.segment(noun: noun, jpeg: s.jpeg, imageLabel: label).text
                records = SAMParser.parse(samText)
            }
            if samText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#tile", with: "").isEmpty {
                log("sam_empty", tiled ? "4 tiles, nothing found" : "nothing found")
            }
            let list = Self.candidates(from: records, snapshot: s)
            for c in list where c.recorded.reprojectsInsideMask == false {
                log("target_outside_mask", "id \(c.info.id)")
            }
            if let o = list.first?.object {
                extra["object_flat"] = o.isFlat
                extra["object_support_y"] = o.supportHeight ?? NSNull()
                extra["object_size_m"] = [o.size.x, o.size.y, o.size.z]
                extra["object_centre"] = [o.centre.x, o.centre.y, o.centre.z]
                extra["obstacle_points"] = list.first?.obstacles?.points.count ?? 0
            }
            record(kind: scanning ? "scan" : "sam", snapshot: s, samText: samText, candidates: list.map(\.recorded),
                   hand: nil, extra: extra)
            return list.isEmpty ? .failure(FindError("no_object")) : .success(list)
        } catch {
            // A real failure (HTTP, network); an empty SAM answer is not an error any more.
            log("api_error", error.localizedDescription)
            return .failure(FindError("api_error"))
        }
    }

    /// SAM records -> up to 4 candidates in 3D, most confident first; duplicates from overlapping
    /// tiles (same place within 4 cm) are dropped.
    nonisolated static func candidates(from records: [SAMRecord], snapshot s: FrameSnapshot) -> [Candidate] {
        let t = s.cameraTransform
        let camera = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        // SAM returns every instance, unsorted.
        let sorted = records.filter { ($0.confidence ?? 1) >= 0.3 }.sorted { ($0.confidence ?? 0) > ($1.confidence ?? 0) }
        var out: [Candidate] = []
        for r in sorted where out.count < 4 {
            guard let c = candidate(r, chosen: out.isEmpty, snapshot: s, camera: camera),
                  !out.contains(where: { simd_distance($0.world, c.world) < 0.04 }) else { continue }
            out.append(c)
        }
        return out
    }

    nonisolated private static func candidate(_ r: SAMRecord, chosen: Bool, snapshot s: FrameSnapshot,
                                              camera: SIMD3<Float>) -> Candidate? {
        let t = s.cameraTransform
        guard let raster = try? r.decodeMask() else { return nil }
        let mask = SourceMask(record: r, raster: raster)
        // Adaptive: small masks (keys, 13x17 px) lose every pixel to the default erosion.
        guard case .success(let hit) = MaskTarget.locateAdaptive(mask: mask, depth: s.depth, intrinsics: s.intrinsics) else { return nil }
        let check = MaskTarget.reprojectsInside(cameraPoint: hit.cameraPoint, mask: mask, intrinsics: s.intrinsics)
        let world = DepthProjector.world(fromCamera: hit.cameraPoint, cameraTransform: t)
        let info = AgentCandidate(id: r.id, confidence: r.confidence ?? 0,
                                  offset: BodyOffset(from: camera, to: world, cameraTransform: t),
                                  widthFraction: Float(r.right - r.left) / Float(r.sourceWidth),
                                  heightFraction: Float(r.bottom - r.top) / Float(r.sourceHeight))
        let box = CGRect(x: r.left, y: r.top, width: r.right - r.left, height: r.bottom - r.top)
        let recorded = RecordedCandidate(id: r.id, confidence: r.confidence ?? 0, world: world, cameraPoint: hit.cameraPoint,
                                         samples: hit.samples, depthSpread: hit.depthSpread, box: box, mask: mask,
                                         reprojected: check?.pixel, reprojectsInsideMask: check?.inside, chosen: chosen)
        let object = ObjectModel.build(mask: mask, depth: s.depth, intrinsics: s.intrinsics, cameraTransform: t)
        let obstacles = object.flatMap {
            ObstacleMap.build(mask: mask, depth: s.depth, intrinsics: s.intrinsics, cameraTransform: t, object: $0)
        }
        return Candidate(info: info, world: object?.centre ?? world, box: box, recorded: recorded,
                         object: object, obstacles: obstacles)
    }

    private func lock(noun: String) async {
        let id = sessionID
        let result = await segment(noun)
        guard id == sessionID, phase == .locating else { return }  // stopped meanwhile
        switch result {
        case .failure(let error):
            log("sam_lock_fail", error.reason)
            startScan(noun)
        case .success(let list):
            log("sam_lock", "\(list.count) candidates")
            await decide(list, noun: noun)
        }
    }

    /// SAM found something: pick it (fast path), ask Spark to choose (several), or check it (unsure).
    /// A "no" from the check goes back to scanning.
    private func decide(_ list: [Candidate], noun: String) async {
        let id = sessionID
        candidates = list
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
            if ok == false { startScan(noun) } else { select(list[0]) }
        } else {
            select(list[0])
        }
    }

    // MARK: Keep scanning (object not in view)

    /// Not found in this view: keep looking while the user turns, one SAM call per new steady view.
    private func startScan(_ noun: String) {
        var planner = ScanPlanner(time: lastFrameTime)
        planner.markSearched(cameraTransform: lastCamera)
        var text = ScanPlanner.startLine(noun)
        // Room map: say where it was last seen and turn the scan toward it first.
        if let item = room.item(for: noun) {
            planner.hint = item.world
            text = RoomInventory.hint(item, noun: noun, cameraTransform: lastCamera) + " " + text
            log("room_hint", "\(item.name) \(item.source) \(item.seen)")
        }
        scan = planner
        scanInFlight = false
        phase = .searching
        log("scan_start", "")
        say(SpokenLine(text: text, interrupt: true))
    }

    private func stepScan(_ f: FindFrame) {
        guard var planner = scan, let noun = targetName else { return }
        let step = planner.update(time: f.time, cameraTransform: f.cameraTransform, busy: scanInFlight, speaking: speaker.isSpeaking)
        scan = planner
        switch step {
        case .wait:
            break
        case .prompt:
            say(SpokenLine(text: planner.directionPrompt(cameraTransform: f.cameraTransform), interrupt: false))
        case .giveUp:
            var text = ScanPlanner.giveUpLine(noun)
            if let item = room.item(for: noun) {
                text = RoomInventory.hint(item, noun: noun, cameraTransform: f.cameraTransform) + " " + text
            } else if let p = lastSeen[noun] {
                text = Self.earlierLine(p, cameraTransform: f.cameraTransform) + " " + text
            }
            finish(spoken: text, event: "scan_give_up")
            suggestAfterGiveUp(noun)
        case .scan:
            scanInFlight = true
            tones.click()
            let id = sessionID
            Task {
                let result = await segment(noun, scanning: true)
                guard id == sessionID, phase == .searching else { return }
                scanInFlight = false
                switch result {
                case .success(let list):
                    log("scan_found", "\(list.count) candidates, sectors \(scan?.sectorsCovered ?? 0)")
                    scan = nil
                    phase = .locating
                    await decide(list, noun: noun)
                case .failure(let error):
                    log("scan_nothing", error.reason)
                }
            }
        }
    }

    /// After giving up: one Spark (minimal) guess from a wide photo, spoken if nothing else started.
    private func suggestAfterGiveUp(_ noun: String) {
        let id = sessionID
        Task {
            guard let s = await snapshot(),
                  let guess = try? await MuseAgent.suggest(noun: noun, jpeg: s.jpeg, label: "suggest_\(id)") else {
                log("spark_suggest", "none")
                return
            }
            log("spark_suggest", guess)
            guard id == sessionID, phase == .idle else { return }
            say(SpokenLine(text: "A guess: " + guess, interrupt: false))
        }
    }

    /// "Earlier, it was to your right, about 60 centimetres."
    nonisolated static func earlierLine(_ p: SIMD3<Float>, cameraTransform t: simd_float4x4) -> String {
        let found = GuidanceSession.whereIs(target: p, cameraTransform: t, name: "x")
        return "Earlier, " + found.replacingOccurrences(of: "Found the x. It's", with: "it was")
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
        Haptics.success()
        tones.earcon(.success)
        log("target", "id \(c.info.id) c \(c.info.confidence)")
        // What the object looked like here, for the strict hold check later.
        referenceCrop = lastJPEG.flatMap { Self.crop($0, to: c.box, margin: 0.3) }
        if let name = targetName {
            lastSeen[name] = c.world
            room.remember(name, at: c.world)
        }
        log("object", c.object.map { o in
            String(format: "%@ size %.0fx%.0fx%.0f cm support %@ obstacles %d", o.isFlat ? "flat" : "solid",
                   o.size.x * 100, o.size.y * 100, o.size.z * 100,
                   o.supportHeight.map { String(format: "%.2f", $0) } ?? "none", c.obstacles?.points.count ?? 0)
        } ?? "no model (centre only)")
        let session = GuidanceSession(targetName: targetName ?? "object", target: c.world, object: c.object,
                                      obstacles: c.obstacles, cameraTransform: lastCamera, time: lastFrameTime)
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
                // 2026-10-29: Spark called find_object five times on the same view. Not in view = scan
                // while the user turns, as for a parsed command; the agent is done.
                candidates = []
                log("agent_scan", error.reason)
                startScan(noun)
                return .ended
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
        checkRelocalization(f)
        if let capture = f.capture {
            record(kind: capture.kind, snapshot: capture.snapshot, samText: nil, candidates: [],
                   hand: RecordedHand(vision: f.handVision, world: f.hand?.joints ?? [:], depths: f.handDepths),
                   extra: ["hand_to_target_cm": handDistance.map { $0 * 100 } ?? -1,
                           "target_world": target.map { [$0.x, $0.y, $0.z] } ?? []])
            if capture.kind == "hold_check" { runHoldCheck(capture.snapshot, handVision: f.handVision) }
        }
        if phase == .searching {
            stepScan(f)
            return
        }
        if phase == .mapping {
            stepMapping(f)
            return
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
        if out.requestCheck {
            startHoldCheck(fromSession: true)
            return
        }
        switch out.phase {
        case .grabbing:
            phase = .grabbing
        case .checking:
            break
        case .done:
            finish(spoken: nil, event: "pickup")
        case .gaveUp:
            finish(spoken: "Stopping. Tap to start again.", event: "gave_up")
        case .waitingForHand, .guiding:
            break
        }
    }

    // MARK: Room map ("scan the room")

    /// Saved map: tracking "normal" = matched. Not matched within the timeout: fresh session, no map.
    private func checkRelocalization(_ f: FindFrame) {
        guard let since = relocalizingSince else { return }
        if f.tracking == "normal" {
            relocalizingSince = nil
            room.relocalized()
            log("room_map_relocalized", String(format: "%.1f s", Date().timeIntervalSince(since)))
        } else if Date().timeIntervalSince(since) > RoomMapStore.relocalizeTimeout {
            relocalizingSince = nil
            log("room_map_fallback", f.tracking)
            session.run(Self.trackingConfig(), options: [.resetTracking, .removeExistingAnchors])
        }
    }

    private func startMapping() {
        beginSession(name: nil)
        var planner = ScanPlanner(time: lastFrameTime)
        planner.budget = 12
        planner.minNewAngle = 30 * .pi / 180
        mapPlanner = planner
        mapInventory = RoomInventory(created: Date())
        mapInFlight = 0
        mapViews = 0
        phase = .mapping
        log("map_start", "")
        say(SpokenLine(text: "Scanning the room. Hold the phone at chest height and turn slowly in a full circle. "
                       + "Tap when you are done.", interrupt: true))
    }

    private func stepMapping(_ f: FindFrame) {
        guard var planner = mapPlanner else { return }
        let step = planner.update(time: f.time, cameraTransform: f.cameraTransform, busy: mapInFlight >= 2,
                                  speaking: speaker.isSpeaking)
        mapPlanner = planner
        switch step {
        case .wait:
            break
        case .prompt:
            say(SpokenLine(text: planner.directionPrompt(cameraTransform: f.cameraTransform), interrupt: false))
        case .giveUp:
            if mapInFlight == 0 { finishMapping(early: false) }
        case .scan:
            tones.click()
            mapInFlight += 1
            mapViews += 1
            let id = sessionID, view = mapViews
            Task {
                defer { if id == sessionID { mapInFlight -= 1 } }
                guard let s = await snapshot(),
                      let reply = try? await MuseAgent.listObjects(jpeg: s.jpeg, label: "room_\(id)_\(view)") else {
                    log("map_view_fail", "\(view)")
                    return
                }
                guard id == sessionID, phase == .mapping else { return }
                var names: [String] = []
                for o in RoomInventory.parseSparkObjects(reply) {
                    guard let p = RoomInventory.place(portrait: o.point, depth: s.depth, intrinsics: s.intrinsics,
                                                      cameraTransform: s.cameraTransform) else { continue }
                    mapInventory.remember(o.name, at: p, date: Date(), source: "room_scan")
                    names.append(o.name)
                }
                log("map_view", "\(view): " + names.joined(separator: " "))
                record(kind: "room", snapshot: s, samText: reply, candidates: [], hand: nil,
                       extra: ["room_objects": names])
            }
        }
    }

    /// Save the ARWorldMap and the inventory (overwrites the previous room map).
    private func finishMapping(early: Bool) {
        let id = sessionID
        let inventory = mapInventory
        mapPlanner = nil
        phase = .idle
        log("map_finish", "\(mapViews) views, \(inventory.items.count) items" + (early ? " (tap)" : ""))
        guard !inventory.items.isEmpty else {
            Haptics.warning()
            say(SpokenLine(text: "I didn't find anything to remember. Try again with more light.", interrupt: true))
            return
        }
        say(SpokenLine(text: "Saving the room.", interrupt: true))
        session.getCurrentWorldMap { map, error in
            nonisolated(unsafe) let map = map  // handed to the main actor once, never shared
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, id == self.sessionID else { return }
                guard let map else {
                    self.log("map_save_fail", message ?? "no map")
                    self.say(SpokenLine(text: "I couldn't save the room. Move the phone around a little more and try again.",
                                        interrupt: true))
                    return
                }
                do {
                    try self.room.save(map: map, inventory: inventory)
                    let names = Array(Set(inventory.items.map(\.name))).sorted().prefix(4)
                    self.log("map_saved", "\(inventory.items.count) items, \(map.anchors.count) anchors")
                    Haptics.success()
                    self.tones.earcon(.success)
                    self.say(SpokenLine(text: "Room saved. I remember \(inventory.items.count) things, including "
                                        + names.joined(separator: ", ") + ".", interrupt: true))
                } catch {
                    self.log("map_save_fail", error.localizedDescription)
                    self.say(SpokenLine(text: "I couldn't save the room.", interrupt: true))
                }
            }
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
        let fm = FileManager.default
        return [logURL, fm.fileExists(atPath: recorder.folder.path) ? recorder.folder : nil,
                fm.fileExists(atPath: ApiCallLog.url.path) ? ApiCallLog.url : nil,
                fm.fileExists(atPath: RoomMapStore.folder.appendingPathComponent("inventory.json").path)
                    ? RoomMapStore.folder.appendingPathComponent("inventory.json") : nil].compactMap { $0 }
    }

    /// `spoken` nil: the line was already said (GuidanceSession's "Got it").
    private func finish(spoken: String?, event: String) {
        tones.stop()
        processor.target = nil
        if ["pickup", "hold_yes"].contains(event) {
            Haptics.success()
            tones.earcon(.success)
            if let name = targetName, let target { room.remember(name, at: target) }
        } else {
            Haptics.warning()
            tones.earcon(.failure)
        }
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
