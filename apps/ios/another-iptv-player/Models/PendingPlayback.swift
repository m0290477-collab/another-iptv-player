import Foundation

enum PendingPlayback {
    static let defaultsKey = "intents.pendingPlayback"

    static func store(_ values: [String: String]) {
        UserDefaults.standard.set(values, forKey: defaultsKey)
    }

    /// Reads AND clears the pending request (consume-once).
    static func consume() -> [String: String]? {
        guard let values = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]
        else { return nil }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        return values
    }
}
