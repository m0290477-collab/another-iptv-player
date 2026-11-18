import Foundation

/// Round 12 (point 6, owner's explicit order — supersedes the
/// round-10/11 exclusion of STRONG's activation card): the values
/// shown on the Settings Activation card.
///
/// Honest by construction: the app is free forever and has no
/// activation backend, so "Activated / Lifetime Subscription" is a
/// statement about the app itself, and the Device ID / PIN are real
/// values the app generates ONCE and persists — stable across
/// launches, unique per install, copyable from the card. Nothing is
/// read from the device's hardware identifiers and nothing is sent
/// anywhere. The values live in UserDefaults like the app's other
/// preferences; they identify this install, not an account, so
/// Delete Account (playlists + app data) leaves them untouched.
enum DeviceActivationStore {
    private static let deviceIdKey = "activation.device_id.v1"
    private static let pinKey = "activation.pin.v1"

    /// MAC-style identifier ("XX:XX:XX:XX:XX:XX", uppercase hex),
    /// generated from random bytes on first read and persisted.
    static var deviceID: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: deviceIdKey), !existing.isEmpty {
            return existing
        }
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<6).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &rng) }
        let value = bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
        defaults.set(value, forKey: deviceIdKey)
        return value
    }

    /// Six-digit PIN, derived deterministically from the Device ID
    /// (FNV-1a over its UTF-8 bytes, folded into 000000–999999) and
    /// persisted. Deterministic derivation means the PIN can never
    /// drift away from the Device ID it belongs to.
    static var pin: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: pinKey), !existing.isEmpty {
            return existing
        }
        let value = Self.derivePin(from: deviceID)
        defaults.set(value, forKey: pinKey)
        return value
    }

    private static func derivePin(from deviceID: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in deviceID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%06d", Int(hash % 1_000_000))
    }
}
