import Combine
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import UIKit

/// Build 61 (B15, W1): the optional app-open lock.
///
/// When the user turns it on (Settings ▸ Parental ▸ App Lock), the
/// app renders NOTHING but the lock screen at cold start and on
/// every return from the background, until the user unlocks with
/// either:
///   1. LocalAuthentication's `.deviceOwnerAuthentication` policy —
///      biometrics when available, with the DEVICE PASSCODE always
///      offered as the fallback inside the same system prompt, or
///   2. an app PIN the user sets. Only a salted SHA-256 hash of the
///      PIN is stored, in a device-only Keychain item (never
///      plaintext, never UserDefaults, never synchronizable, never
///      part of iCloud sync or backups).
///
/// The user can NEVER be permanently locked out:
///   - the device-passcode path is always offered alongside the PIN;
///   - if at lock time NO unlock method exists at all (the device
///     has no passcode set and no app PIN is stored), the lock
///     disables itself instead of trapping the user (see
///     `engageLock()`).
///
/// This PIN is the APP lock only. It is deliberately separate from
/// the parental PIN (`PINStore`, which locks categories and
/// settings inside the app): different Keychain service, different
/// settings section labels, and the two never verify against each
/// other.
///
/// Triggers: cold start (the initial `isLocked` value) and return
/// from the background. Locking is driven by the background
/// notifications, NOT by resign-active, so the LocalAuthentication
/// prompt itself (which resigns active) can never re-lock the app
/// mid-unlock. There is no grace period: backgrounding locks
/// immediately.
@MainActor
final class AppLockService: ObservableObject {
    static let shared = AppLockService()

    /// UserDefaults flag for the Settings toggle. Deliberately NOT
    /// in `ICloudSyncService`'s KVS whitelist and NOT in the backup
    /// preference keys: lock state never leaves this device.
    static let enabledKey = "applock.enabled"

    @Published private(set) var isLocked: Bool = false

    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    private init() {
        // Cold start: locked from the very first frame when enabled
        // (ContentView renders only the lock screen while locked).
        engageLock()
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.engageLock() }
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Covers any path that missed the background
            // notification; a no-op when already locked/unlocked
            // in this foreground session.
            Task { @MainActor in self?.engageLockIfBackgrounded() }
        }
    }

    /// True between a backgrounding and the next successful unlock.
    private var needsUnlockOnForeground = false

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    // MARK: - Lock engagement

    /// Locks now if the lock is enabled and at least one unlock
    /// method exists. The no-method case fails OPEN (lock disabled)
    /// rather than trapping the user — see the type documentation.
    func engageLock() {
        guard Self.isEnabled else {
            isLocked = false
            needsUnlockOnForeground = false
            return
        }
        if Self.hasPIN || canUseDeviceOwnerAuthentication() {
            isLocked = true
            needsUnlockOnForeground = true
        } else {
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            isLocked = false
            needsUnlockOnForeground = false
            Log.error("AppLock", "No unlock method available (no device passcode, no app PIN) — app lock disabled itself rather than locking the user out")
        }
    }

    private func engageLockIfBackgrounded() {
        guard needsUnlockOnForeground else { return }
        engageLock()
    }

    func unlock() {
        isLocked = false
        needsUnlockOnForeground = false
    }

    // MARK: - Device-owner authentication (biometrics + passcode)

    /// Whether the `.deviceOwnerAuthentication` policy can run at
    /// all on this device (biometrics enrolled OR a device passcode
    /// set). When this is false and no app PIN exists, the lock must
    /// not engage.
    func canUseDeviceOwnerAuthentication() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    /// The biometry this device would use, for the unlock button's
    /// label. `.none` means passcode-only.
    var biometryType: LABiometryType {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return context.biometryType
    }

    /// Runs the system prompt. The policy is
    /// `.deviceOwnerAuthentication` (never biometrics-only), so the
    /// device passcode fallback is always reachable from the same
    /// prompt — that is what makes permanent lockout impossible for
    /// a user with a device passcode.
    func authenticateWithDeviceOwner(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    // MARK: - App PIN (salted SHA-256 hash, Keychain only)

    private static let keychainService = "com.irqus.superx.app-lock"
    private static let keychainAccount = "pin-hash"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
    }

    static var hasPIN: Bool {
        var query = baseQuery
        query[kSecReturnData as String] = false
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Stored payload: "v1$<base64 salt>$<base64 SHA-256(salt‖PIN)>".
    private static func storedPayload() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let payload = String(data: data, encoding: .utf8) else { return nil }
        return payload
    }

    private static func hash(pin: String, salt: Data) -> Data {
        var data = salt
        data.append(Data(pin.utf8))
        return Data(SHA256.hash(data: data))
    }

    static func verifyPIN(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let payload = storedPayload() else { return false }
        let parts = payload.split(separator: "$", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "v1",
              let salt = Data(base64Encoded: String(parts[1])),
              let expected = Data(base64Encoded: String(parts[2])) else { return false }
        return hash(pin: trimmed, salt: salt) == expected
    }

    @discardableResult
    static func setPIN(_ pin: String) -> Bool {
        let trimmed = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 16, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { return false }
        let payload = "v1$\(salt.base64EncodedString())$\(hash(pin: trimmed, salt: salt).base64EncodedString())"
        guard let data = payload.data(using: .utf8) else { return false }
        // Replace any existing item (set == change). The item is
        // device-only: `kSecAttrSynchronizable` is never set, and
        // the accessibility class pins it to this device, so the
        // hash can never ride iCloud Keychain or a device restore.
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
