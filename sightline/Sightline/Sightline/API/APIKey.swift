// labels: production, needs-review, sensitive
// Reads the Meta Model API key from the gitignored Secrets.plist (written by tools/ios_secrets.sh),
// falling back to the process environment (Xcode scheme). Never log or display the key.

import Foundation

nonisolated enum APIKey {
    static let name = "META_MODEL_API_KEY"

    static var value: String? {
        if let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
           let dict = NSDictionary(contentsOf: url) as? [String: Any],
           let key = dict[name] as? String, !key.isEmpty {
            return key
        }
        let env = ProcessInfo.processInfo.environment[name]
        return env?.isEmpty == false ? env : nil
    }
}
