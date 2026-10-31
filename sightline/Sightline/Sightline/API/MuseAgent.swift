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

    /// The scan gave up: one short spoken suggestion of where to look, from a wide photo. nil = no idea.
    static func suggest(noun: String, jpeg: Data, label: String) async throws -> String? {
        let text = try await reply("A blind user is looking for their \(noun). An object detector looked around the room and "
                                   + "could not find it. This is their chest camera now. In one short sentence (at most 18 words) "
                                   + "tell them where it most likely is or where to check next, using left, right, ahead, "
                                   + "lower or higher and the furniture you see. If you can see it, say exactly where. "
                                   + "If you have no idea, answer: none.",
                                   noun: noun, images: [jpeg], effort: .minimal, label: label)
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty || clean.lowercased().hasPrefix("none") ? nil : clean
    }

    /// The object is not in the room map: which mapped item is it most likely near? Returns the item's
    /// number in `items` (RoomInventory.describe), nil = no idea. Effort medium (reasoning, once per search).
    static func guessNear(noun: String, items: String, label: String) async throws -> Int? {
        let text = try await reply("A blind user is looking for their \(noun). It is not in view and was never seen in "
                                   + "this room. These things were seen in the room (number. name: position relative to "
                                   + "the user):\n\(items)\nWhere is a \(noun) most likely to be? Answer only with the "
                                   + "number of the one thing it is most likely on, in or next to, or 'none' if no "
                                   + "item makes it likely.",
                                   noun: noun, images: [], effort: .medium, label: label)
        return AgentText.firstInteger(text)
    }

    /// Room scan: the objects a blind user might ask for in this photo, as
    /// `{"objects":[{"name":..,"x":..,"y":..}]}` (RoomInventory.parseSparkObjects).
    static func listObjects(jpeg: Data, label: String) async throws -> String {
        try await reply("You help a blind user remember where things are in their room. List up to 12 separate, movable "
                        + "objects in this photo that they might later ask for (for example keys, phone, cup, book, "
                        + "glasses, remote, bag, bottle). Skip furniture, walls and anything you are unsure about. "
                        + "For each, give a short common name and the centre of the object in the photo as x and y "
                        + "from 0 to 1 (x left to right, y top to bottom). Answer only with JSON: "
                        + #"{"objects":[{"name":"cup","x":0.42,"y":0.61}]}"#,
                        noun: "room_scan", images: [jpeg], effort: .medium, label: label)
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
