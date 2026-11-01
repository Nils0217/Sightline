// labels: spike, needs-review, sensitive
// Speech-to-text experiment (2026-11-01): Apple on-device recognition (what the app uses now)
// vs Muse Voice Transcribe realtime (ENDPOINTING) and file (PUSH_TO_TALK), on spike/stt/corpus.
// Every clip is streamed at real-time pace like a microphone; every event is recorded with
// its time from the clip start, so stop rules can be compared offline (analyze.py).
// Key: read from the gitignored Secrets.plist or META_MODEL_API_KEY; never printed.
// Each Muse call is logged to logs/api_calls.csv ($0.18 per audio hour).
// Usage (from sightline/): stt_bench <apple|muse_rt|muse_file> <out.jsonl> [limit]

import AVFoundation
import Foundation
import Speech

// Run from sightline/.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
// STT_CORPUS=tts runs the spoken-line round trip (make_tts_corpus.py) instead.
let corpusName = ProcessInfo.processInfo.environment["STT_CORPUS"] ?? "corpus"
let corpusDir = root.appendingPathComponent("spike/stt/\(corpusName)")
let model = "muse-voice-transcribe-1.0"
// BENCH_KEYWORDS="a,b,c" replaces the default bias list (e.g. the room inventory names).
let keywords = ProcessInfo.processInfo.environment["BENCH_KEYWORDS"].map { $0.split(separator: ",").map(String.init) } ?? ["find", "Sightline"]

func apiKey() -> String {
    if let d = NSDictionary(contentsOf: root.appendingPathComponent("Sightline/Sightline/Secrets.plist")),
       let k = d["META_MODEL_API_KEY"] as? String, !k.isEmpty { return k }
    if let k = ProcessInfo.processInfo.environment["META_MODEL_API_KEY"], !k.isEmpty { return k }
    fatalError("Missing META_MODEL_API_KEY")
}

struct Clip { let file: String; let clipS: Double }

func loadCorpus() -> [Clip] {
    let text = try! String(contentsOf: root.appendingPathComponent("spike/stt/\(corpusName).csv"), encoding: .utf8)
    var lines = text.split(whereSeparator: \.isNewline).map(String.init)
    let head = lines.removeFirst().split(separator: ",").map(String.init)
    let fi = head.firstIndex(of: "file")!, ci = head.firstIndex(of: "clip_s")!
    // No commas inside file names or clip_s; the text column may hold quoted commas, so index from both ends.
    return lines.map { l in
        let parts = l.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        return Clip(file: parts[fi], clipS: Double(parts[parts.count - (head.count - ci)])!)
    }
}

/// Raw 16-bit PCM from the WAV "data" chunk.
func pcm(_ url: URL) -> Data {
    let d = try! Data(contentsOf: url)
    var i = 12
    while i + 8 <= d.count {
        let id = String(data: d[i..<i + 4], encoding: .ascii)!
        let size = Int(d[i + 4]) | Int(d[i + 5]) << 8 | Int(d[i + 6]) << 16 | Int(d[i + 7]) << 24
        if id == "data" { return d[(i + 8)..<min(d.count, i + 8 + size)] }
        i += 8 + size + (size & 1)
    }
    fatalError("no data chunk in \(url.lastPathComponent)")
}

final class Timeline: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [[String: Any]] = []
    let start = Date()
    func add(_ kind: String, _ fields: [String: Any] = [:]) {
        var e = fields; e["t"] = (Date().timeIntervalSince(start) * 1000).rounded() / 1000; e["kind"] = kind
        lock.withLock { events.append(e) }
    }
    var all: [[String: Any]] { lock.withLock { events } }
}

let logLock = NSLock()
func logCall(_ clip: String, _ mode: String, latencyMs: Double, audioS: Double) {
    logLock.withLock {
        let url = root.appendingPathComponent("logs/api_calls.csv")
        let ts = ISO8601DateFormatter().string(from: Date())
        let row = "\(ts),\(clip),\(model),\(mode),\(Int(latencyMs)),0,0,\(String(format: "%.6f", audioS * 0.18 / 3600))\n"
        let h = try! FileHandle(forWritingTo: url); h.seekToEndOfFile(); h.write(row.data(using: .utf8)!); try? h.close()
    }
}

// MARK: Apple on-device, same request settings as SpeechInput.swift.
func runApple(_ clip: Clip) async -> [String: Any] {
    let tl = Timeline()
    let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    let req = SFSpeechAudioBufferRecognitionRequest()
    req.shouldReportPartialResults = true
    if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
    req.contextualStrings = ["find", "Sightline", "where is my"]
    let done = DispatchSemaphore(value: 0)
    let task = rec.recognitionTask(with: req) { result, error in
        if let result {
            tl.add("partial", ["text": result.bestTranscription.formattedString, "final": result.isFinal])
            if result.isFinal { done.signal() }
        } else if let error { tl.add("error", ["message": error.localizedDescription]); done.signal() }
    }
    let file = try! AVAudioFile(forReading: corpusDir.appendingPathComponent(clip.file))
    let fmt = file.processingFormat
    let chunk = AVAudioFrameCount(fmt.sampleRate * 0.08)
    while file.framePosition < file.length {
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk)!
        try! file.read(into: buf, frameCount: chunk)
        req.append(buf)
        try? await Task.sleep(for: .milliseconds(80))
    }
    tl.add("audio_end")
    req.endAudio()
    _ = await Task.detached { done.wait(timeout: .now() + 5) }.value
    task.cancel()
    return ["engine": "apple", "file": clip.file, "on_device": rec.supportsOnDeviceRecognition, "events": tl.all]
}

// MARK: Muse realtime, ENDPOINTING.
func runMuseRT(_ clip: Clip, key: String) async -> [String: Any] {
    let tl = Timeline()
    let ws = URLSession.shared.webSocketTask(with: URL(string: "wss://api.meta.ai/v1/asr/realtime")!)
    ws.resume()
    let hello: [String: Any] = ["authorization": ["accessToken": "Bearer " + key], "audioEncoding": "PCM_24KHZ",
                                "model": model, "mode": "ENDPOINTING", "keywords": keywords, "languageBias": ["English"]]
    let sent = Date()
    do {
        try await ws.send(.string(String(data: try JSONSerialization.data(withJSONObject: hello), encoding: .utf8)!))
        let ack = try await ws.receive()
        if case .string(let s) = ack, s.contains("sessionId") { tl.add("ack", ["ms": Date().timeIntervalSince(sent) * 1000]) }
        else { tl.add("error", ["message": "bad ack: \(ack)"]); return ["engine": "muse_rt", "file": clip.file, "events": tl.all] }
    } catch { tl.add("error", ["message": "\(error)"]); return ["engine": "muse_rt", "file": clip.file, "events": tl.all] }
    let streamStart = Date()
    let reader = Task {
        while true {
            guard let m = try? await ws.receive() else { tl.add("closed", ["code": ws.closeCode.rawValue]); return }
            // Event times are from tl.start; analyze.py subtracts stream_offset_s. audioProgress is dropped (one per frame).
            if case .string(let s) = m, !s.contains("\"audioProgress\"") { tl.add("msg", ["raw": s]) }
        }
    }
    let data = pcm(corpusDir.appendingPathComponent(clip.file))
    var i = data.startIndex
    var next = Date()
    while i < data.endIndex {
        let j = min(i + 3840, data.endIndex)
        try? await ws.send(.data(data[i..<j]))
        i = j
        next = next.addingTimeInterval(0.08)
        let wait = next.timeIntervalSinceNow
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
    }
    tl.add("audio_end")
    try? await ws.send(.string("{\"type\":\"endStream\"}"))
    let closer = Task { try? await Task.sleep(for: .seconds(10)); ws.cancel(with: .normalClosure, reason: nil) }
    await reader.value
    closer.cancel()
    logCall(clip.file, "realtime ENDPOINTING", latencyMs: Date().timeIntervalSince(sent) * 1000, audioS: clip.clipS)
    // Timeline times start at tl.start (just before the handshake); store the offset to the first frame.
    return ["engine": "muse_rt", "file": clip.file, "stream_offset_s": streamStart.timeIntervalSince(tl.start), "events": tl.all]
}

// MARK: Muse file, PUSH_TO_TALK (the app would upload after its own end-of-speech).
func runMuseFile(_ clip: Clip, key: String) async -> [String: Any] {
    let wav = try! Data(contentsOf: corpusDir.appendingPathComponent(clip.file))
    let b = "sightline-\(UUID().uuidString)"
    var body = Data()
    let reqJSON = try! JSONSerialization.data(withJSONObject: ["model": model, "audioEncoding": "WAV", "mode": "PUSH_TO_TALK", "keywords": keywords])
    body.append("--\(b)\r\nContent-Disposition: form-data; name=\"request\"\r\nContent-Type: application/json\r\n\r\n".data(using: .utf8)!)
    body.append(reqJSON)
    body.append("\r\n--\(b)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
    body.append(wav)
    body.append("\r\n--\(b)--\r\n".data(using: .utf8)!)
    var r = URLRequest(url: URL(string: "https://api.meta.ai/v1/asr/transcribe")!)
    r.httpMethod = "POST"
    r.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
    r.setValue("application/json", forHTTPHeaderField: "Accept")
    r.setValue("multipart/form-data; boundary=\(b)", forHTTPHeaderField: "Content-Type")
    let t0 = Date()
    do {
        let (d, resp) = try await URLSession.shared.upload(for: r, from: body)
        let ms = Date().timeIntervalSince(t0) * 1000
        logCall(clip.file, "file PUSH_TO_TALK", latencyMs: ms, audioS: clip.clipS)
        let o = (try? JSONSerialization.jsonObject(with: d)) ?? String(data: d, encoding: .utf8) ?? ""
        return ["engine": "muse_file", "file": clip.file, "status": (resp as! HTTPURLResponse).statusCode, "ms": ms, "body": o]
    } catch { return ["engine": "muse_file", "file": clip.file, "error": "\(error)"] }
}

@main struct Bench {
    static func main() async {
        let args = CommandLine.arguments
        let engine = args[1], out = URL(fileURLWithPath: args[2])
        var clips = loadCorpus()
        if args.count > 3 { clips = Array(clips.prefix(Int(args[3])!)) }
        // BENCH_IDS="cmd_key,cmd_mug" keeps only those lines.
        if let ids = ProcessInfo.processInfo.environment["BENCH_IDS"]?.split(separator: ",").map(String.init) {
            clips = clips.filter { c in ids.contains { c.file.hasPrefix($0 + "__") } }
        }
        if engine == "apple" {
            let ok = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
            guard ok else { print("speech recognition not authorised"); exit(1) }
        }
        let key = engine == "apple" ? "" : apiKey()
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let h = try! FileHandle(forWritingTo: out)
        // Apple runs one at a time: 4 parallel on-device tasks gave "No speech detected" on 205 of 304 clips.
        let width = engine == "apple" ? 1 : 8
        await withTaskGroup(of: [String: Any].self) { g in
            var it = clips.makeIterator(); var n = 0
            func add(_ c: Clip) {
                g.addTask {
                    switch engine {
                    case "apple": return await runApple(c)
                    case "muse_rt": return await runMuseRT(c, key: key)
                    default: return await runMuseFile(c, key: key)
                    }
                }
            }
            for _ in 0..<width { if let c = it.next() { add(c) } }
            while let r = await g.next() {
                h.write(try! JSONSerialization.data(withJSONObject: r)); h.write("\n".data(using: .utf8)!)
                n += 1; if n % 20 == 0 { print(engine, n, "/", clips.count) }
                if let c = it.next() { add(c) }
            }
        }
        try? h.close()
        print(engine, "done")
    }
}
