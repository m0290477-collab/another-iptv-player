import Foundation
import Security

/// Round 15 (C3): the parental PIN, stored ONLY in the Keychain —
/// never in UserDefaults, never in the database, never exported by
/// either backup flow. The PIN guards three things (C5): turning OFF
/// the adult-content filter, confirming Delete Account, and — when
/// the separate "Lock settings with PIN" toggle is on — opening
/// either Settings screen. It also stands behind the locked
/// (adult-filtered) categories in spirit: the filter itself stays
/// the existing per-playlist `filterAdultContent` flag; the PIN is
/// what prevents casually switching that filter off.
enum PINStore {
    private static let service = "com.irqus.superx.parental-pin"
    private static let account = "pin"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static var hasPIN: Bool {
        var query = baseQuery
        query[kSecReturnData as String] = false
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// The stored PIN, read only for verification — never displayed
    /// anywhere and never written to a log.
    private static func storedPIN() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let pin = String(data: data, encoding: .utf8) else { return nil }
        return pin
    }

    static func verify(_ candidate: String) -> Bool {
        guard let stored = storedPIN(), !stored.isEmpty else { return false }
        // Constant-shape comparison is unnecessary here (local UI
        // gate, not a network verifier); a plain equality check on
        // the trimmed candidate is the honest implementation.
        return stored == candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    static func setPIN(_ pin: String) -> Bool {
        let trimmed = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        // Replace any existing item (set == change).
        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func clearPIN() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
