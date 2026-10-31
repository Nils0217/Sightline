// labels: production, needs-review
// Local parsing of a spoken command into a target noun phrase, so the first SAM call does not
// wait for Muse Spark (G4 decision, docs/SPIKE.md). Spark is only asked when this returns nil.

import Foundation

public enum Command: Equatable, Sendable {
    /// "find the cup" -> .find("cup")
    case find(String)
    case stop
    /// "scan the room": one-time room map (objects + positions) for later hints.
    case mapRoom
}

public enum CommandParser {
    private static let stopWords: Set<String> = ["stop", "cancel", "never mind", "nevermind", "done"]
    private static let mapWords = ["scan the room", "map the room", "scan my room", "map my room", "learn the room",
                                   "remember the room", "scan room", "map room"]
    /// Longest first so "where is my" wins over "where is".
    private static let leads = [
        "can you help me find", "help me find", "can you find", "could you find", "please find",
        "i'm looking for", "i am looking for", "look for", "where's my", "where is my", "where are my",
        "where's the", "where is the", "where are the", "where's", "where is", "where are",
        "guide me to", "take me to", "get me", "find me", "find", "locate", "grab", "get",
    ]
    private static let articles: Set<String> = ["the", "my", "a", "an", "some", "your", "that", "this"]
    private static let fillers: Set<String> = ["please", "for", "me", "now", "thanks", "thank", "you", "sightline", "hey"]

    public static func parse(_ transcript: String) -> Command? {
        var text = transcript.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.letters.union(.whitespaces).union(CharacterSet(charactersIn: "'")).inverted)
            .joined(separator: " ")
        text = text.split(separator: " ").joined(separator: " ")
        if text.hasPrefix("hey sightline ") { text.removeFirst("hey sightline ".count) }
        if text.hasPrefix("sightline ") { text.removeFirst("sightline ".count) }
        guard !text.isEmpty else { return nil }
        if stopWords.contains(text) { return .stop }
        // "scan the room for my keys" is a search, not a room map (Muse review 2026-10-30).
        if let r = text.range(of: " for "), text.contains("room"), text.contains("scan") || text.hasPrefix("map") {
            return parse("find " + text[r.upperBound...])
        }
        // v5 test: "scan the room" came back as "Scanner room".
        if mapWords.contains(where: { text.contains($0) })
            || (text.split(separator: " ").contains("room") && (text.contains("scan") || text.hasPrefix("map"))) { return .mapRoom }

        guard let lead = leads.first(where: { text == $0 || text.hasPrefix($0 + " ") }) else { return nil }
        var words = text.dropFirst(lead.count).split(separator: " ").map(String.init)
        while let first = words.first, articles.contains(first) || fillers.contains(first) { words.removeFirst() }
        while let last = words.last, fillers.contains(last) || last == "is" || last == "are" { words.removeLast() }
        // "where is the cup on the table" -> keep the head noun phrase only.
        if let cut = words.firstIndex(where: { ["on", "in", "near", "from", "at", "please"].contains($0) }) {
            words = Array(words[..<cut])
        }
        guard !words.isEmpty, words.count <= 4 else { return nil }
        return .find(words.joined(separator: " "))
    }
}
