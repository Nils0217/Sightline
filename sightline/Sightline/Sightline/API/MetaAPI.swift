// labels: production, needs-review, important
// Meta Model API client (Responses API, https://api.meta.ai/v1). Request shapes as verified
// in docs/api-notes.md. Every call is appended to Documents/api_calls.csv (same columns as
// the repo's logs/api_calls.csv) so it can be merged after a device session.

import Foundation

nonisolated struct SAMResponse: Sendable {
    var text: String
    var latencyMS: Double
}

nonisolated enum MetaAPIError: LocalizedError {
    case missingKey
    case http(Int, String)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .missingKey: "No API key. Run tools/ios_secrets.sh, then rebuild."
        case .http(let code, let body): "HTTP \(code): \(body.prefix(200))"
        case .emptyOutput: "SAM returned no text."
        }
    }
}

nonisolated enum MetaAPI {
    static let baseURL = URL(string: "https://api.meta.ai/v1")!
    static let samModel = "sam-3.1"
    static let samCostPerImage = 0.0025

    /// Text-prompted segmentation of one JPEG. Streamed, with confidences.
    static func segment(noun: String, jpeg: Data, imageLabel: String) async throws -> SAMResponse {
        guard let key = APIKey.value else { throw MetaAPIError.missingKey }
        let body: [String: Any] = [
            "model": samModel,
            "input": [[
                "type": "message",
                "role": "user",
                "content": [
                    ["type": "input_text", "text": noun],
                    ["type": "input_image", "image_url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"],
                ],
            ]],
            "stream": true,
            "metadata": ["include_confidence": "true"],
        ]
        var request = URLRequest(url: baseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let start = Date()
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line; if errorBody.count > 500 { break } }
            ApiCallLog.append(image: imageLabel, model: samModel, noun: noun,
                              latencyMS: Date().timeIntervalSince(start) * 1000, cost: 0)
            throw MetaAPIError.http(status, errorBody)
        }

        // Server-sent events: collect output_text deltas; prefer the final `done` text if present.
        var deltas = ""
        var doneText: String?
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            if type == "response.output_text.delta", let delta = event["delta"] as? String {
                deltas += delta
            } else if type == "response.output_text.done", let text = event["text"] as? String {
                doneText = (doneText ?? "") + text
            }
        }
        let latency = Date().timeIntervalSince(start) * 1000
        ApiCallLog.append(image: imageLabel, model: samModel, noun: noun, latencyMS: latency, cost: samCostPerImage)
        let text = doneText ?? deltas
        guard !text.isEmpty else { throw MetaAPIError.emptyOutput }
        return SAMResponse(text: text, latencyMS: latency)
    }
}

/// Documents/api_calls.csv, header identical to logs/api_calls.csv.
nonisolated enum ApiCallLog {
    static let header = "timestamp,image,model,noun,latency_ms,input_tokens,output_tokens,est_cost_usd"
    private static let lock = NSLock()

    static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("api_calls.csv")
    }

    static func append(image: String, model: String, noun: String, latencyMS: Double, cost: Double) {
        lock.withLock {
            let row = [ISO8601DateFormatter().string(from: Date()), image, model, noun.replacingOccurrences(of: ",", with: " "),
                       String(format: "%.0f", latencyMS), "", "", String(format: "%.4f", cost)].joined(separator: ",")
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                try? (header + "\n").write(to: url, atomically: true, encoding: .utf8)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data((row + "\n").utf8))
                try? handle.close()
            }
        }
    }
}
