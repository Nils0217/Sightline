// labels: production, needs-review, important
// Muse Spark as commander: the tool set it can call and the state it sees (AGENTS.md:
// "Muse reads live state only through tool calls"). Pure data + decisions so it is unit-tested;
// the network loop lives in the app (MuseAgent.swift).
//
// Spark is used only off the critical path:
//  - a command the local parser could not read ("I'm thirsty", "the green key")
//  - SAM found several plausible matches ("which cup?")
// Both at effort medium since the v5 test (Nils, 2026-10-29: understanding the user matters more
// than the second it costs; "only very simple language works" came from our limits, not the model).

import Foundation
import simd

/// One SAM instance placed in the user's body frame.
public struct AgentCandidate: Codable, Sendable, Equatable {
    public var id: String
    /// The phrase SAM was asked for ("water bottle", "green key"); candidates of several find_object
    /// calls stay selectable together.
    public var name: String
    public var confidence: Float
    /// Centimetres from the phone (≈ chest), body frame.
    public var rightCM: Int
    public var upCM: Int
    public var forwardCM: Int
    /// Box size on the uploaded image, as a fraction of its width/height (rough apparent size).
    public var widthFraction: Float
    public var heightFraction: Float

    enum CodingKeys: String, CodingKey {
        case id, name, confidence
        case rightCM = "right_cm", upCM = "up_cm", forwardCM = "forward_cm"
        case widthFraction = "width_fraction", heightFraction = "height_fraction"
    }

    public init(id: String, name: String = "", confidence: Float, offset: BodyOffset, widthFraction: Float, heightFraction: Float) {
        self.id = id
        self.name = name
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
    /// Phrases find_object already tried on this view with nothing found.
    public var notFound: [String]
    /// The saved room map, if any: "name: x m right, y m forward" lines relative to the user now.
    public var roomItems: [String]

    enum CodingKeys: String, CodingKey {
        case phase, candidates, tracking
        case userSaid = "user_said", targetName = "target_name", samCallsLeft = "sam_calls_left"
        case notFound = "not_found", roomItems = "room_items"
    }

    public init(phase: String, userSaid: String, targetName: String?, candidates: [AgentCandidate],
                samCallsLeft: Int, tracking: String, notFound: [String] = [], roomItems: [String] = []) {
        self.phase = phase
        self.userSaid = userSaid
        self.targetName = targetName
        self.candidates = candidates
        self.samCallsLeft = samCallsLeft
        self.tracking = tracking
        self.notFound = notFound
        self.roomItems = roomItems
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
    /// Candidate id plus an optional sentence spoken as guidance starts.
    case selectTarget(String, say: String?)
    case say(String)
    case askUser(String)
    /// Not in this view: the user turns while the app keeps looking (ends the agent).
    case scanFor(String)
    /// "Scan the room" (ends the agent).
    case mapRoom
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
        case "find_object": return text("noun", max: 60).map { .findObject($0.lowercased()) }
        case "scan_for": return text("noun", max: 60).map { .scanFor($0.lowercased()) }
        case "map_room": return .mapRoom
        case "select_target": return text("candidate_id", max: 8).map { .selectTarget($0, say: text("say", max: 200)) }
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
        tool("get_state", "Live state: what the user said, the target name, every candidate found so far (with the phrase it was found for and its place relative to the user's chest: right/up/forward in cm), phrases already tried with nothing found, the saved room map, tracking.", [:], []),
        tool("find_object", "Look for an object in the current camera view with an open-vocabulary segmenter (SAM). Give the object with the details the user gave: colour, material, markings, size, e.g. 'green key', 'key with an orange tag', 'white electric toothbrush', 'water bottle'. Returns all candidates found so far; call it several times to see which of several possible objects are here.",
             ["noun": ["type": "string", "description": "Noun phrase with the user's details, up to 8 words"]], ["noun"]),
        tool("select_target", "Lock one candidate as the target and start hand guidance. Ends your turn.",
             ["candidate_id": ["type": "string"],
              "say": ["type": "string", "description": "Optional short sentence spoken as guidance starts. No directions (left, right, ahead): the guidance says those."]], ["candidate_id"]),
        tool("say", "Speak one short sentence to the user.",
             ["text": ["type": "string"]], ["text"]),
        tool("ask_user", "Ask the user a short question and wait for the spoken answer, returned as the result.",
             ["question": ["type": "string"]], ["question"]),
        tool("scan_for", "The object is not in this view: ask the user to turn slowly while the app keeps looking for it. Ends your turn.",
             ["noun": ["type": "string", "description": "Noun phrase to look for, with the user's details"]], ["noun"]),
        tool("map_room", "The user wants to scan or map the room (e.g. 'scan the room', even if misheard as 'scanner room'). Ends your turn.", [:], []),
        tool("stop", "End the search.", [:], []),
    ] }

    public static let instructions = """
        You are Sightline, a voice assistant that helps a blind person find and pick up things at home. \
        You act only through tools; the user hears what you say and answers by voice. \
        Understand what the user means, even when it is indirect, misheard by speech recognition, or describes \
        the object by colour, material, markings or what it is for. \
        Positions are in cm relative to the phone on the user's chest: right_cm > 0 is to their right, \
        up_cm > 0 is higher, forward_cm is distance ahead. \
        How to work: \
        (1) A clear object ("my green key", "the white toothbrush"): find_object with the user's own details, \
        then select_target. Keep colours and markings in the phrase; the segmenter understands them. \
        (2) A need, not an object ("I'm thirsty", "I want to read"): first find out what is really here. \
        Call find_object for each likely kind of object (for thirst: water bottle, cup, glass, can) and look at \
        room_items. Then ask_user, offering only the options that were actually found, with where they are \
        ("I can see a water bottle on your left and a cup ahead. Which one?"). Things in room_items that are not in \
        view are options too ("your black bottle is behind you"); scan_for one if the user picks it. After the \
        answer, select_target. \
        (3) Several candidates of the same kind: after each find_object you get a photo with every candidate boxed \
        and labelled with its candidate_id. Tell them apart by how they look first: colour, see-through or not, \
        shape, size, what is in them, what is on them; then where they are ("a small clear glass with water, or a \
        tall brown paper cup?"). If the user asks what is different, answer with how they look. If you cannot tell \
        from the photo, say so and offer the nearer one. \
        (4) Nothing found here: if room_items lists it, or find_object returns room_map, it is in another part \
        of the room: call scan_for at once (it turns the user toward where it was saved). Do not keep calling \
        find_object on this view for things the room map has elsewhere. When room_items has no directions yet, \
        say what it was on and next to ("Your tumbler was on the desk, next to the laptop."); the user may know \
        where that is. \
        A candidate with confidence 0.5 or more is usually right; do not drop it for a different object \
        unless the user rejects it. Do not call find_object again for a phrase in not_found; use scan_for. \
        Say everything the simplest way a blind person can act on at once: plain spoken words, the most \
        useful thing first (one difference between options, not every detail), nothing extra, one direction \
        at most. Say "not sure" instead of guessing. Never give medical advice. \
        Do not put directions in select_target's say; the guidance gives them. \
        Finish with select_target, scan_for, map_room, or stop after telling the user why.
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

/// Text rules for what the agent says (pure, so the core tests cover them).
public enum AgentText {
    /// v5: the agent said "on your right" and the guidance then said "a little to the left". Directions
    /// come only from geometry: clauses with one are cut, the rest is kept ("Got it, the blue cup." from
    /// "Got it, the blue cup, on your right."). "the right cup" (= correct) is not a direction.
    public static func withoutDirections(_ text: String) -> String? {
        let always: Set<String> = ["ahead", "behind", "front", "above", "below", "under", "beside"]
        func directional(_ clause: Substring) -> Bool {
            let w = clause.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            if w.contains(where: always.contains) { return true }
            return w.indices.contains { i in
                guard w[i] == "left" || w[i] == "right" else { return false }
                let before = i > 0 ? w[i - 1] : ""
                return ["your", "the", "to", "on", "a", "little", "far"].contains(before) && !(before == "the" && i + 1 < w.count
                    && !["of", "side", "and"].contains(w[i + 1]))
            }
        }
        var kept: [String] = []
        var clause = ""
        for ch in text {
            clause.append(ch)
            if ",.;!?".contains(ch) {
                if !directional(Substring(clause)) { kept.append(clause) }
                clause = ""
            }
        }
        if !clause.isEmpty, !directional(Substring(clause)) { kept.append(clause) }
        var out = kept.joined().trimmingCharacters(in: .whitespaces)
        while let last = out.last, ",;".contains(last) { out.removeLast() }
        if out.isEmpty { return nil }
        if let last = out.last, !".!?".contains(last) { out.append(".") }
        return out
    }

    /// First whole number anywhere in a reply ("3", "Item 3.", "I think 3"); nil for "none"
    /// (Muse review 2026-10-30: only leading digits were read).
    public static func firstInteger(_ text: String) -> Int? {
        guard let r = text.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(text[r])
    }
}
