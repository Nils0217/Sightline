// labels: production, needs-review, important
// Muse Spark as commander: the tool set it can call and the state it sees (AGENTS.md:
// "Muse reads live state only through tool calls"). Pure data + decisions so it is unit-tested;
// the network loop lives in the app (MuseAgent.swift).
//
// Spark is used only off the critical path:
//  - a command the local parser could not read ("I'm thirsty") -> effort minimal
//  - SAM found several plausible matches ("which cup?")        -> effort medium

import Foundation
import simd

/// One SAM instance placed in the user's body frame.
public struct AgentCandidate: Codable, Sendable, Equatable {
    public var id: String
    public var confidence: Float
    /// Centimetres from the phone (≈ chest), body frame.
    public var rightCM: Int
    public var upCM: Int
    public var forwardCM: Int
    /// Box size on the uploaded image, as a fraction of its width/height (rough apparent size).
    public var widthFraction: Float
    public var heightFraction: Float

    enum CodingKeys: String, CodingKey {
        case id, confidence
        case rightCM = "right_cm", upCM = "up_cm", forwardCM = "forward_cm"
        case widthFraction = "width_fraction", heightFraction = "height_fraction"
    }

    public init(id: String, confidence: Float, offset: BodyOffset, widthFraction: Float, heightFraction: Float) {
        self.id = id
        self.confidence = (confidence * 100).rounded() / 100
        rightCM = Int((offset.right * 100).rounded())
        upCM = Int((offset.up * 100).rounded())
        forwardCM = Int((offset.forward * 100).rounded())
        self.widthFraction = (widthFraction * 100).rounded() / 100
        self.heightFraction = (heightFraction * 100).rounded() / 100
    }
}

/// What `get_state()` returns.
public struct AgentState: Codable, Sendable, Equatable {
    public var phase: String
    public var userSaid: String
    public var targetName: String?
    public var candidates: [AgentCandidate]
    public var samCallsLeft: Int
    public var tracking: String

    enum CodingKeys: String, CodingKey {
        case phase, candidates, tracking
        case userSaid = "user_said", targetName = "target_name", samCallsLeft = "sam_calls_left"
    }

    public init(phase: String, userSaid: String, targetName: String?, candidates: [AgentCandidate],
                samCallsLeft: Int, tracking: String) {
        self.phase = phase
        self.userSaid = userSaid
        self.targetName = targetName
        self.candidates = candidates
        self.samCallsLeft = samCallsLeft
        self.tracking = tracking
    }

    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? String(data: encoder.encode(self), encoding: .utf8)) ?? "{}"
    }
}

/// A tool call from Spark, validated.
public enum AgentAction: Equatable, Sendable {
    case getState
    case findObject(String)
    case selectTarget(String)
    case say(String)
    case askUser(String)
    case stop

    /// Parses a `function_call` (name + JSON `arguments`). nil = unknown tool or bad arguments.
    public static func parse(name: String, arguments: String) -> AgentAction? {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        func text(_ key: String, max: Int) -> String? {
            guard let v = (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !v.isEmpty, v.count <= max else { return nil }
            return v
        }
        switch name {
        case "get_state": return .getState
        case "find_object": return text("noun", max: 40).map { .findObject($0.lowercased()) }
        case "select_target": return text("candidate_id", max: 8).map { .selectTarget($0) }
        case "say": return text("text", max: 200).map { .say($0) }
        case "ask_user": return text("question", max: 200).map { .askUser($0) }
        case "stop": return .stop
        default: return nil
        }
    }
}

public enum AgentTools {
    /// Responses API `tools` array (flat function format, docs/api-notes.md).
    public static var definitions: [[String: Any]] { [
        tool("get_state", "Live state: what the user said, the target name, SAM candidates placed relative to the user's chest (right/up/forward in cm), SAM calls left, tracking.", [:], []),
        tool("find_object", "Segment an object by a short noun phrase on the current camera frame (costs one SAM call). Returns the candidates found.",
             ["noun": ["type": "string", "description": "1-3 word noun phrase, e.g. 'water bottle'"]], ["noun"]),
        tool("select_target", "Lock one candidate as the target and start hand guidance. Ends your turn.",
             ["candidate_id": ["type": "string"]], ["candidate_id"]),
        tool("say", "Speak one short sentence to the user (blind; plain words, no visual references like colours unless they asked).",
             ["text": ["type": "string"]], ["text"]),
        tool("ask_user", "Ask the user a short question and wait for the spoken answer, returned as the result.",
             ["question": ["type": "string"]], ["question"]),
        tool("stop", "End the search.", [:], []),
    ] }

    public static let instructions = """
        You are Sightline, a voice guide that helps a blind person find and grab objects at home. \
        You act only through tools. The phone is worn on the chest; positions are in cm relative to it: \
        right_cm > 0 is to the user's right, up_cm > 0 is higher, forward_cm is distance ahead. \
        Rules: keep spoken sentences under 15 words; say "not sure" instead of guessing; never give medical advice; \
        never describe the scene at length. Pick a target only if it clearly matches what the user wants; \
        if two candidates are equally plausible, ask_user which one using left/right/near/far, not colours. \
        Finish by calling select_target, or stop after telling the user why.
        """

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String]) -> [String: Any] {
        ["type": "function", "name": name, "description": description,
         "parameters": ["type": "object", "properties": properties, "required": required]]
    }

    /// Several SAM instances are close enough in confidence that picking the top one is a guess.
    public static func isAmbiguous(_ confidences: [Float], margin: Float = 0.15, floor: Float = 0.4) -> Bool {
        let plausible = confidences.filter { $0 >= floor }.sorted(by: >)
        guard plausible.count >= 2 else { return false }
        return plausible[0] - plausible[1] < margin
    }
}
