// labels: production, needs-review, sensitive
// Muse Voice Transcribe realtime (branch muse-voice, 2026-11-01, Nils: "open a new branch for muse voice,
// i want to test first"). One websocket per listen: handshake with the key, then 16-bit mono PCM at 24 kHz
// in 80 ms frames, ENDPOINTING mode, keywords (room names, target) and languageBias English.
// Request shape: docs/api-notes.md (Muse Voice Transcribe). Stop rule from docs/STT_EXPERIMENT.md ("smart"):
// end-of-turn, or a partial that ends a sentence (. ? !) unchanged 0.8 s, or any partial unchanged 3 s
// (short lines like "Stop" often get no end-of-turn). The key is never logged.

@preconcurrency import AVFoundation
import Foundation

nonisolated final class MuseStream: @unchecked Sendable {
    static let model = "muse-voice-transcribe-1.0"
    static let costPerSecond = 0.18 / 3600
    static let sentenceQuiet: TimeInterval = 0.8
    static let openQuiet: TimeInterval = 3.0
    static let shortReplies: Set<String> = ["stop", "yes", "no", "yeah", "nope", "is this it", "scan the room", "cancel", "okay"]

    enum State { case connecting, streaming, failed(String), closed }

    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!
    private var pending = Data()      // converted audio not yet sent (also the backlog before the handshake ack)
    private var _state: State = .connecting
    private var _text = ""
    private var _changedAt: Date?
    private var _complete = false
    private var _speechEndAt: Date?
    private(set) var startedAt = Date()
    private var bytesSent = 0
    private(set) var connectMS: Double?

    var state: State { lock.withLock { _state } }
    var text: String { lock.withLock { _text } }
    var isHealthy: Bool { lock.withLock { if case .failed = _state { return false }; return true } }

    /// Opens the socket and sends the handshake. Audio fed before the ack is held and sent after it.
    func start(key: String, keywords: [String]) {
        startedAt = Date()
        let ws = URLSession.shared.webSocketTask(with: URL(string: "wss://api.meta.ai/v1/asr/realtime")!)
        lock.withLock { task = ws }
        ws.resume()
        var hello: [String: Any] = ["authorization": ["accessToken": "Bearer " + key], "audioEncoding": "PCM_24KHZ",
                                    "model": Self.model, "mode": "ENDPOINTING", "languageBias": ["English"]]
        if !keywords.isEmpty { hello["keywords"] = Array(keywords.prefix(60)) }
        let json = String(data: (try? JSONSerialization.data(withJSONObject: hello)) ?? Data(), encoding: .utf8) ?? "{}"
        let t0 = Date()
        Task {
            do {
                try await ws.send(.string(json))
                let ack = try await ws.receive()
                guard case .string(let s) = ack, s.contains("sessionId") else { fail("bad handshake"); return }
                lock.withLock {
                    connectMS = Date().timeIntervalSince(t0) * 1000
                    if case .connecting = _state { _state = .streaming }
                }
                flush()
                await read(ws)
            } catch {
                fail("connect: \(error.localizedDescription)")
            }
        }
        // No ack within 2.5 s: give up so the caller can use the on-device result.
        Task {
            try? await Task.sleep(for: .milliseconds(2500))
            if case .connecting = state { fail("handshake timeout") }
        }
    }

    /// Microphone buffer (any format) -> 24 kHz Int16 mono, sent in 80 ms frames.
    func feed(_ buffer: AVAudioPCMBuffer) {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outFormat)
        }
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        // convert(to:error:) calls the input block synchronously on this thread, so these captures are safe.
        nonisolated(unsafe) let input = buffer
        nonisolated(unsafe) var used = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if used { status.pointee = .noDataNow; return nil }
            used = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let data = Data(bytes: ch[0], count: Int(out.frameLength) * 2)
        lock.withLock { pending.append(data) }
        flush()
    }

    private func flush() {
        var frames: [Data] = []
        let ws: URLSessionWebSocketTask? = lock.withLock {
            guard case .streaming = _state else { return nil }
            while pending.count >= 3840 {
                frames.append(pending.prefix(3840))
                pending.removeFirst(3840)
            }
            bytesSent += frames.count * 3840
            return task
        }
        guard let ws else { return }
        for f in frames { ws.send(.data(f)) { _ in } }
    }

    private func read(_ ws: URLSessionWebSocketTask) async {
        while true {
            guard let m = try? await ws.receive() else {
                lock.withLock { if case .streaming = _state { _state = .closed } }
                return
            }
            guard case .string(let s) = m, !s.contains("\"audioProgress\""),
                  let o = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any],
                  let type = o["type"] as? String else { continue }
            lock.withLock {
                switch type {
                case "transcript":
                    if let t = o["transcript"] as? String, !t.isEmpty, t != _text { _text = t; _changedAt = Date() }
                case "speechComplete":
                    if let t = o["transcript"] as? String, !t.isEmpty { _text = t }
                    _complete = true
                    _speechEndAt = _speechEndAt ?? Date()
                case "speechEnd":
                    _speechEndAt = Date()
                case "error":
                    _state = .failed("server: \(o["message"] as? String ?? "?")")
                default: break
                }
            }
        }
    }

    /// The smart stop rule: true once the user has finished speaking.
    func finished(now: Date = Date()) -> Bool {
        lock.withLock {
            if _complete { return true }
            guard let at = _changedAt else { return false }
            let trimmed = _text.trimmingCharacters(in: .whitespaces)
            // Muse often leaves a one-word command unpunctuated ("stop"): a known short reply also ends a turn.
            let bare = trimmed.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
            let ends = (trimmed.last.map { ".?!".contains($0) } ?? false) || Self.shortReplies.contains(bare)
            return now.timeIntervalSince(at) > (ends ? Self.sentenceQuiet : Self.openQuiet)
        }
    }

    /// Seconds since the text last changed (nil = nothing heard).
    var lastChange: Date? { lock.withLock { _changedAt } }

    private func fail(_ why: String) {
        lock.withLock {
            if case .failed = _state { return }
            _state = .failed(why)
        }
        lock.withLock { task }?.cancel(with: .goingAway, reason: nil)
    }

    /// Ends the stream and logs the call (audio seconds, as billed).
    func close(label: String) {
        let (ws, seconds) = lock.withLock { () -> (URLSessionWebSocketTask?, Double) in
            if case .streaming = _state { _state = .closed }
            return (task, Double(bytesSent) / 48000)
        }
        ws?.send(.string("{\"type\":\"endStream\"}")) { _ in }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            ws?.cancel(with: .normalClosure, reason: nil)
        }
        if seconds > 0 || connectMS != nil {
            ApiCallLog.append(image: label, model: Self.model, noun: "realtime", latencyMS: Date().timeIntervalSince(startedAt) * 1000,
                              cost: seconds * Self.costPerSecond)
        }
    }
}
