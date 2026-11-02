// labels: production, needs-review, important
// One Muse Spark turn over the Responses API with function tools (shapes: docs/api-notes.md,
// https://dev.meta.ai/docs/tool-calling). The tool loop itself runs in FindModel, which owns
// the state the tools act on. Every call is logged to Documents/api_calls.csv.
//
// We resend the whole history each turn instead of using `previous_response_id`: measured
// 2026-10-28 (spike/agent_spike.py), follow-up turns took 9–30 s with previous_response_id and
// 1–4 s with the history resent.

import Foundation
import SightlineCore

nonisolated struct SparkCall: Sendable {
    var callID: String
    var name: String
    var arguments: String
}

nonisolated struct SparkTurn: Sendable {
    var responseID: String
    var calls: [SparkCall]
    var text: String
}

nonisolated enum MuseAgent {
    static let model = "muse-spark-1.3"
    static let inputPerM = 1.25
    static let outputPerM = 4.25

    enum Effort: String, Sendable {
        case minimal, medium
        /// Reasoning tokens count toward the cap (G4: minimal used ≤ 300, medium up to ~2000).
        var maxOutputTokens: Int { self == .minimal ? 1024 : 4096 }
    }

    /// First item of the history: the user message (text + optional JPEG).
    static func userMessage(_ text: String, jpeg: Data?) -> [[String: Any]] {
        userMessage(text, images: jpeg.map { [$0] } ?? [])
    }

    /// Text followed by several JPEGs in order (e.g. reference photo, then the current one).
    static func userMessage(_ text: String, images: [Data]) -> [[String: Any]] {
        var content: [[String: Any]] = [["type": "input_text", "text": text]]
        for jpeg in images {
            content.append(["type": "input_image", "image_url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"])
        }
        return [["type": "message", "role": "user", "content": content]]
    }

    static func toolOutput(callID: String, output: String) -> [String: Any] {
        ["type": "function_call_output", "call_id": callID, "output": output]
    }

    /// Echo of a call for the history; every output's call_id must match one of these, in order.
    static func callItem(_ c: SparkCall) -> [String: Any] {
        ["type": "function_call", "call_id": c.callID, "name": c.name, "arguments": c.arguments]
    }

    /// Yes/no check: is the object in the drawn box a `noun`? Effort minimal (fast path). nil = unclear answer.
    static func verify(noun: String, jpeg: Data, label: String) async throws -> Bool? {
        // v7: SAM boxed a green book under a white tube; on a small crop Spark said no. The app now sends the
        // whole photo with the box drawn (FindModel.verify).
        try await yesNo("A blind user asked for: \(noun). An object detector drew a green box on this photo. Is the thing "
                        + "inside the green box a \(noun), even if it is partly covered by other things? "
                        + "Answer with one word: yes or no.", noun: noun, jpeg: jpeg, label: label)
    }

    /// Identity only. Geometry and shared movement are evaluated independently on the device.
    static func verifyObjectIdentity(noun: String, jpeg: Data, reference: Data, label: String) async throws -> Bool? {
        try await yesNo("The user asked for their \(noun). Image 1 is the reference object. "
            + "Image 2 has a green box around one candidate. Is that boxed candidate the same object as image 1, "
            + "including the requested distinguishing details? Decide identity only; the grip or thumb may be hidden. "
            + "Do not infer identity from hand position. Answer yes, no, or unsure.",
            noun: noun, images: [reference, jpeg], label: label)
    }

    /// "I think I have it": is the hand holding the object. With `reference` (the object as seen at
    /// lock), Spark must match that same object, and touching is not enough. 2026-10-29: "holding or
    /// touching a book" said yes to a hand on a USB hub next to the book (the crop showed the book).
    static func verifyHolding(noun: String, jpeg: Data, reference: Data?, label: String) async throws -> Bool? {
        guard let reference else {
            return try await yesNo("This photo is from a chest camera of a blind user who asked for: \(noun). "
                                   + "Is their hand holding a \(noun) (gripping it, not just touching or near it)? "
                                   + "Answer with one word: yes or no.", noun: noun, images: [jpeg], label: label)
        }
        return try await yesNo("A blind user asked for their \(noun). Image 1 shows that \(noun) where it was found. "
                               + "Image 2 is from their chest camera now. Is their hand holding that same object from image 1 "
                               + "(gripping it, not just touching it or something next to it)? Answer with one word: yes or no.",
                               noun: noun, images: [reference, jpeg], label: label)
    }

    /// Nils, 2026-11-01: no word caps; ask for the simplest reply instead.
    static let simplest = "Say it the simplest way a blind person can act on at once: plain spoken words, the most useful "
        + "thing first, nothing extra, one direction at most, no lists, no button names. "

    /// The held-up look could not tell (case 2): how to bring it into view, or what is in the hand. "" = no answer.
    static func describeHeld(noun: String, jpeg: Data, reference: Data?, label: String) async throws -> String {
        let ref = reference == nil ? "" : "Image 1 shows their \(noun) where it was found. "
        let now = reference == nil ? "The photo" : "Image 2"
        return try await reply("A blind user asked for their \(noun) and is holding something up to their chest camera; the app "
                               + "could not tell if it is the \(noun). " + ref + now + " is the camera now. If what they hold is "
                               + "not in the photo, cut off, too close or too dark, tell them how to move it so the camera sees it "
                               + "(left, right, up, down, closer, further). Otherwise tell them what you see in their hand: its "
                               + "colour, shape, size and any words on it, and whether it looks like their \(noun). " + simplest,
                               noun: noun, images: (reference.map { [$0] } ?? []) + [jpeg], effort: .minimal, label: label)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The scan gave up: one short spoken suggestion of where to look, from a wide photo. nil = no idea.
    static func suggest(noun: String, jpeg: Data, label: String) async throws -> String? {
        let text = try await reply("A blind user is looking for their \(noun). An object detector looked around the room and "
                                   + "could not find it. This is their chest camera now. In one sentence "
                                   + "tell them where it most likely is or where to check next, using left, right, ahead, "
                                   + "lower or higher and the furniture you see. If you can see it, say exactly where. "
                                   + "If you have no idea, answer: none. " + simplest,
                                   noun: noun, images: [jpeg], effort: .minimal, label: label)
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty || clean.lowercased().hasPrefix("none") ? nil : clean
    }

    /// The object is not in the room map: which mapped item is it most likely near? Returns the item's
    /// number in `items` (RoomInventory.describe), nil = no idea. Effort medium (reasoning, once per search).
    static func guessNear(noun: String, items: String, label: String) async throws -> Int? {
        let text = try await reply("A blind user is looking for their \(noun). It is not in view and was never seen in "
                                   + "this room. These things were seen in the room (number. name: where it is, what it "
                                   + "stands on and what is next to it):\n\(items)\nWhere is a \(noun) most likely to be? Answer only with the "
                                   + "number of the one thing it is most likely on, in or next to, or 'none' if no "
                                   + "item makes it likely.",
                                   noun: noun, images: [], effort: .medium, label: label)
        return AgentText.firstInteger(text)
    }

    /// Room scan: the objects a blind user might ask for in this photo, as
    /// `{"objects":[{"name":..,"x":..,"y":..}]}` (RoomInventory.parseSparkObjects).
    static func listObjects(jpeg: Data, label: String) async throws -> String {
        // 2026-11-01 (Nils: let the LLM infer from related things): furniture is listed too, as fixed landmarks for
        // aligning the map on a later launch, and each object says what it stands on.
        try await reply("You help a blind user remember where things are in their room. List up to 12 separate, movable "
                        + "objects in this photo that they might later ask for (for example keys, phone, cup, book, "
                        + "glasses, remote, bag, bottle), and up to 4 big things that do not move (desk, table, shelf, "
                        + "lamp, bed, sofa, sink, fridge, TV, door) with \"fixed\": true. Skip walls and anything you "
                        + "are unsure about. For each, give a short common name and the centre of it in the photo as x and y "
                        + "from 0 to 1 (x left to right, y top to bottom); for a movable object also what it stands on "
                        + "(\"on\": \"desk\") when you can see it. Answer only with JSON: "
                        + #"{"objects":[{"name":"cup","x":0.42,"y":0.61,"on":"desk"},{"name":"desk","x":0.5,"y":0.8,"fixed":true}]}"#,
                        noun: "room_scan", images: [jpeg], effort: .medium, label: label)
    }

    /// What one look at the photo around the target says (v9.2): names for the numbered marks, which of them
    /// are dangerous, which look like the target itself, and dangerous things anywhere near it (a knife lying
    /// flat is too low for the depth map). Nils: touching ordinary things is fine, dangerous ones must be seen.
    struct LookAround: Sendable {
        var names: [Int: String] = [:]
        var dangerous: Set<Int> = []
        var sameKind: Set<Int> = []
        /// Name and position on the photo (0–1, x left to right, y top to bottom).
        var hazards: [(name: String, x: Float, y: Float)] = []
    }

    /// One call per search, effort minimal, never on the guidance loop. Throws on a network failure.
    static func lookAround(jpeg: Data, count: Int, noun: String, label: String) async throws -> LookAround? {
        let marks = count == 0 ? "There are no numbered marks. "
            : "Numbered red circles 1 to \(count) mark things standing near it. "
        let text = try await reply("This photo is from a blind user's chest camera. They are reaching for their \(noun), "
                                   + "boxed in green. " + marks
                                   + "1) For each number, give the short common name of the thing under that circle (one or "
                                   + "two words); leave out circles on nothing, on the table, or on a hand or arm. "
                                   + "2) List the numbers that are dangerous to touch: sharp, hot, burning, spiky, broken glass, "
                                   + "or a blade. 3) List the numbers that are another \(noun) (the same kind of thing). "
                                   + "4) List anything dangerous to touch anywhere near the green box that has no number "
                                   + "(for example a knife, scissors, a lit candle, a lighter, a cactus, an iron), with the centre "
                                   + "as x and y from 0 to 1 (x left to right, y top to bottom). "
                                   + #"Answer only with JSON: {"names":{"1":"bottle"},"dangerous":[],"same":[],"hazards":[{"name":"knife","x":0.4,"y":0.7}]}"#,
                                   noun: "look_around", images: [jpeg], effort: .minimal, label: label)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let data = String(text[start...end]).data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var out = LookAround()
        for (k, v) in json["names"] as? [String: Any] ?? [:] {
            if let i = Int(k), let name = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !name.isEmpty, name.split(separator: " ").count <= 3 { out.names[i] = name }
        }
        func ints(_ key: String) -> Set<Int> {
            Set((json[key] as? [Any] ?? []).compactMap { ($0 as? Int) ?? ($0 as? String).flatMap { Int($0) } })
        }
        out.dangerous = ints("dangerous")
        out.sameKind = ints("same")
        for h in json["hazards"] as? [[String: Any]] ?? [] {
            guard let name = (h["name"] as? String)?.lowercased(), let x = (h["x"] as? NSNumber)?.floatValue,
                  let y = (h["y"] as? NSNumber)?.floatValue, (0...1).contains(x), (0...1).contains(y) else { continue }
            out.hazards.append((name, x, y))
        }
        return out
    }

    /// Several things like the target: one turn of a short talk to find out which one the user means. The
    /// photo marks the locked one "A" and the others 1, 2, ... Returns what to say and, once clear, the choice.
    static func whichOne(noun: String, jpeg: Data, others: Int, transcript: [String], label: String) async throws -> (say: String, choice: String?) {
        let talk = transcript.isEmpty ? "Nothing has been said yet." : "Conversation so far:\n" + transcript.joined(separator: "\n")
        let text = try await reply("A blind user asked for their \(noun). On this chest-camera photo the app found one marked A, "
                                   + "and \(others) more things that may also be a \(noun), marked with numbers. \(talk)\n"
                                   + "If it is not yet clear which one they want, ask one short question that tells them apart "
                                   + "by what a blind person can know: where it is (left, right, nearer, further), size, shape, "
                                   + "what it is made of or what is in it, or a colour they may know. Once it "
                                   + "is clear, say a short confirmation. " + simplest
                                   + #"Answer only with JSON: {"say":"...","choice":null} with choice "A" or the number once clear."#,
                                   noun: "which_one", images: [jpeg], effort: .minimal, label: label)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let data = String(text[start...end]).data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ("", nil) }
        let say = (json["say"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let choice = (json["choice"] as? String) ?? (json["choice"] as? Int).map(String.init)
        return (say, choice?.uppercased())
    }

    /// The hand has been out of view a while and the user said something (v9.2, Nils: "I need to see your hand
    /// to guide you", user: ..., LLM: ...). One short spoken answer. `transcript` holds earlier turns.
    static func handHelp(noun: String, said: String, transcript: [String], label: String) async throws -> String {
        let earlier = transcript.isEmpty ? "" : "Conversation so far:\n" + transcript.joined(separator: "\n") + "\n"
        return try await reply("You are the voice of an app that guides a blind user's hand to their \(noun). The phone hangs on "
                               + "their chest, camera facing forward and down. The camera cannot see their hand now, so the "
                               + "step-by-step guidance is paused until it can. The hand must be in front of them, below the "
                               + "phone, roughly toward the \(noun), and not behind or covered by the object. "
                               + earlier + "The user just said: \"\(said)\"\n"
                               + "Help them get their hand back in view, or answer what they asked. " + simplest,
                               noun: noun, images: [], effort: .minimal, label: label)
    }

    private static func yesNo(_ prompt: String, noun: String, jpeg: Data, label: String) async throws -> Bool? {
        try await yesNo(prompt, noun: noun, images: [jpeg], label: label)
    }

    private static func yesNo(_ prompt: String, noun: String, images: [Data], label: String) async throws -> Bool? {
        let text = try await reply(prompt, noun: noun, images: images, effort: .minimal, label: label)
        // First word decides ("No." / "Yes, ..."); "not sure" is not a no.
        let first = text.lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init)
        if first == "yes" { return true }
        if first == "no" { return false }
        return nil
    }

    /// One plain Spark turn (no tools), logged. Returns "" on a non-200 answer.
    private static func reply(_ prompt: String, noun: String, images: [Data], effort: Effort, label: String) async throws -> String {
        guard let key = APIKey.value else { throw MetaAPIError.missingKey }
        let body: [String: Any] = [
            "model": model,
            "input": userMessage(prompt, images: images),
            "reasoning": ["effort": effort.rawValue],
            "max_output_tokens": effort.maxOutputTokens,
        ]
        var request = URLRequest(url: MetaAPI.baseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20
        let start = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let usage = json["usage"] as? [String: Any]
        let inTok = usage?["input_tokens"] as? Int ?? 0, outTok = usage?["output_tokens"] as? Int ?? 0
        ApiCallLog.append(image: label, model: "\(model)/\(effort.rawValue)", noun: noun,
                          latencyMS: Date().timeIntervalSince(start) * 1000,
                          cost: Double(inTok) / 1e6 * inputPerM + Double(outTok) / 1e6 * outputPerM,
                          inputTokens: inTok, outputTokens: outTok)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return "" }
        var text = ""
        for item in json["output"] as? [[String: Any]] ?? [] where item["type"] as? String == "message" {
            for part in item["content"] as? [[String: Any]] ?? [] { text += part["text"] as? String ?? "" }
        }
        return text
    }

    static func respond(history: [[String: Any]], effort: Effort, label: String) async throws -> SparkTurn {
        guard let key = APIKey.value else { throw MetaAPIError.missingKey }
        let body: [String: Any] = [
            "model": model,
            "input": history,
            "tools": AgentTools.definitions,
            "parallel_tool_calls": false,
            "reasoning": ["effort": effort.rawValue],
            "max_output_tokens": effort.maxOutputTokens,
        ]

        var request = URLRequest(url: MetaAPI.baseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 40

        let start = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let latency = Date().timeIntervalSince(start) * 1000
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let usage = json["usage"] as? [String: Any]
        let inTok = usage?["input_tokens"] as? Int ?? 0
        let outTok = usage?["output_tokens"] as? Int ?? 0
        ApiCallLog.append(image: label, model: "\(model)/\(effort.rawValue)", noun: "agent", latencyMS: latency,
                          cost: Double(inTok) / 1e6 * inputPerM + Double(outTok) / 1e6 * outputPerM,
                          inputTokens: inTok, outputTokens: outTok)
        guard status == 200 else {
            throw MetaAPIError.http(status, String(decoding: data.prefix(300), as: UTF8.self))
        }

        var calls: [SparkCall] = []
        var text = ""
        for item in json["output"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "function_call":
                if let id = item["call_id"] as? String, let name = item["name"] as? String {
                    calls.append(SparkCall(callID: id, name: name, arguments: item["arguments"] as? String ?? "{}"))
                }
            case "message":
                for part in item["content"] as? [[String: Any]] ?? [] where part["type"] as? String == "output_text" {
                    text += part["text"] as? String ?? ""
                }
            default:
                break
            }
        }
        return SparkTurn(responseID: json["id"] as? String ?? "", calls: calls,
                         text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
