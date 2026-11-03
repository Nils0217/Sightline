// labels: production, needs-review
// What SAM should look for when the user's word is not a thing it can see (Nils, 2026-11-02: "when i say vitamin,
// of course a bottle"). Spark answers once per word; the answer is kept in Documents/sam_names.json so the same
// word never costs a model call again. One line per word ever asked; nothing else is stored.

import Foundation
import SightlineCore

final class SAMNames {
    private(set) var names: [String: [String]] = [:]

    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("sam_names.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode([String: [String]].self, from: data) {
            names = saved
        }
    }

    private static func key(_ noun: String) -> String { noun.lowercased().trimmingCharacters(in: .whitespaces) }

    /// Spark's names for the word, best first; nil when it was never asked.
    func lookup(_ noun: String) -> [String]? { names[Self.key(noun)] }

    /// Keeps Spark's answer. An empty one (network or HTTP failure) is not kept, so the word is asked again next time.
    func store(_ noun: String, _ list: [String]) {
        guard !list.isEmpty else { return }
        names[Self.key(noun)] = list
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(names).write(to: Self.url, options: .atomic)
    }
}
