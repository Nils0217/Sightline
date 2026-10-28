// labels: production, needs-review, important
// One Muse Spark turn over the Responses API with function tools (shapes: docs/api-notes.md,
// https://dev.meta.ai/docs/tool-calling). The tool loop itself runs in FindModel, which owns
// the state the tools act on. Every call is logged to Documents/api_calls.csv.

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

    /// First turn: the user message (text + optional JPEG). Later turns: `function_call_output`
    /// items plus `previousResponseID`, so the server keeps the history.
    static func userMessage(_ text: String, jpeg: Data?) -> [[String: Any]] {
        var content: [[String: Any]] = [["type": "input_text", "text": text]]
        if let jpeg {
            content.append(["type": "input_image", "image_url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"])
        }
        return [["type": "message", "role": "user", "content": content]]
    }

    static func toolOutput(callID: String, output: String) -> [String: Any] {
        ["type": "function_call_output", "call_id": callID, "output": output]
    }

    static func respond(input: [[String: Any]], previousResponseID: String?, effort: Effort,
                        label: String) async throws -> SparkTurn {
        guard let key = APIKey.value else { throw MetaAPIError.missingKey }
        var body: [String: Any] = [
            "model": model,
            "input": input,
            "tools": AgentTools.definitions,
            "parallel_tool_calls": false,
            "reasoning": ["effort": effort.rawValue],
            "max_output_tokens": effort.maxOutputTokens,
        ]
        if let previousResponseID { body["previous_response_id"] = previousResponseID }

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
