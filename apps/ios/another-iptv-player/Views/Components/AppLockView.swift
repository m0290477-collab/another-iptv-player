import LocalAuthentication
import SwiftUI

/// Build 61 (B15, W1): the app-open lock screen.
///
/// Rendered by `ContentView` INSTEAD of the whole app (gate,
/// onboarding and dashboards are not in the hierarchy at all while
/// locked — nothing renders behind this screen). Unlock paths, both
/// always offered when available:
///   - the system device-owner prompt (Face ID / Touch ID with the
///     device passcode fallback built into the same prompt), and
///   - the app PIN, when the user set one (`AppLockService` stores
///     only a salted hash in the Keychain).
/// The device-passcode path stays visible even in PIN mode, so a
/// forgotten app PIN can never lock the user out.
struct AppLockView: View {
    @ObservedObject private var lock = AppLockService.shared

    @State private var pin = ""
    @State private var showError = false
    @State private var didAutoPrompt = false
    @State private var isAuthenticating = false

    private var hasPIN: Bool { AppLockService.hasPIN }
    private var canUseDeviceAuth: Bool { lock.canUseDeviceOwnerAuthentication() }

    private var deviceAuthTitle: String {
        switch lock.biometryType {
        case .faceID: return L("applock.unlock_faceid")
        case .touchID: return L("applock.unlock_touchid")
        default: return L("applock.unlock_passcode")
        }
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 44))
                    .foregroundColor(AppTheme.accent)
                Text(L("applock.locked_title"))
                    .font(.title3.weight(.bold))
                Text(L("applock.locked_desc"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if canUseDeviceAuth {
                    Button {
                        Task { await runDeviceAuth() }
                    } label: {
                        Text(deviceAuthTitle)
                            .font(.headline)
                            .foregroundColor(.black)
                            .frame(maxWidth: 260)
                            .padding(.vertical, 12)
                            .background(AppTheme.accent)
                            .cornerRadius(AppTheme.cornerRadius)
                    }
                    .buttonStyle(.plain)
                    .disabled(isAuthenticating)
                }

                if hasPIN {
                    if canUseDeviceAuth {
                        Text(L("applock.pin_or"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    SecureField(L("applock.pin_enter"), text: $pin)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .multilineTextAlignment(.center)
                        .font(.title3.monospacedDigit())
                        .padding(12)
                        .background(AppTheme.elevated)
                        .cornerRadius(AppTheme.cornerRadius)
                        .frame(maxWidth: 220)
                    if showError {
                        Text(L("applock.pin_wrong"))
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    Button {
                        if AppLockService.verifyPIN(pin) {
                            pin = ""
                            showError = false
                            lock.unlock()
                        } else {
                            showError = true
                            pin = ""
                        }
                    } label: {
                        Text(L("applock.unlock"))
                            .font(.headline)
                            .foregroundColor(.black)
                            .frame(maxWidth: 220)
                            .padding(.vertical, 12)
                            .background(AppTheme.accent)
                            .cornerRadius(AppTheme.cornerRadius)
                    }
                    .buttonStyle(.plain)
                    .disabled(pin.count < 4)
                    .opacity(pin.count < 4 ? 0.45 : 1)
                }

                Text(L("applock.passcode_note"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .padding(24)
        }
        .onAppear {
            // One automatic system prompt per lock engagement; if
            // the user cancels it, the buttons above stay available
            // and nothing re-prompts behind their back.
            guard !didAutoPrompt else { return }
            didAutoPrompt = true
            if canUseDeviceAuth {
                Task { await runDeviceAuth() }
            }
        }
    }

    private func runDeviceAuth() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        let success = await lock.authenticateWithDeviceOwner(reason: L("applock.locked_desc"))
        isAuthenticating = false
        if success { lock.unlock() }
    }
}

/// Set / change the APP PIN (W1). Mirrors the parental
/// `PINSetupSheet`'s shape but verifies and stores through
/// `AppLockService` — the two PINs are fully independent.
struct AppPINSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onDone: () -> Void

    @State private var current = ""
    @State private var newPIN = ""
    @State private var confirmPIN = ""
    @State private var errorText: String?

    private var hasExistingPIN: Bool { AppLockService.hasPIN }

    var body: some View {
        NavigationStack {
            Form {
                if hasExistingPIN {
                    Section {
                        SecureField(L("applock.pin_enter_current"), text: $current)
                            .keyboardType(.numberPad)
                    }
                }
                Section {
                    SecureField(L("applock.pin_enter_new"), text: $newPIN)
                        .keyboardType(.numberPad)
                    SecureField(L("applock.pin_confirm_new"), text: $confirmPIN)
                        .keyboardType(.numberPad)
                }
                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
            .cinematicScrollBackground()
            .navigationTitle(L("applock.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.save")) { save() }
                }
            }
        }
    }

    private func save() {
        if hasExistingPIN, !AppLockService.verifyPIN(current) {
            errorText = L("applock.pin_wrong")
            return
        }
        let digits = newPIN.trimmingCharacters(in: .whitespaces)
        guard (4...6).contains(digits.count), digits.allSatisfy(\.isNumber) else {
            errorText = L("applock.pin_wrong")
            return
        }
        guard digits == confirmPIN.trimmingCharacters(in: .whitespaces) else {
            errorText = L("applock.pin_mismatch")
            return
        }
        if AppLockService.setPIN(digits) {
            onDone()
            dismiss()
        } else {
            errorText = L("common.unknown_error")
        }
    }
}

/// Verify-the-current-app-PIN sheet, used before removing the PIN
/// (the app-lock counterpart of the parental `PINEntrySheet`).
struct AppPINEntrySheet: View {
    let onSuccess: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var showError = false

    var body: some View {
        VStack {
            HStack {
                Button(L("common.cancel")) { dismiss() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 30))
                    .foregroundColor(AppTheme.accent)
                Text(L("applock.pin_enter"))
                    .font(.headline)
                SecureField(L("applock.pin_enter"), text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .multilineTextAlignment(.center)
                    .font(.title3.monospacedDigit())
                    .padding(12)
                    .background(AppTheme.elevated)
                    .cornerRadius(AppTheme.cornerRadius)
                    .frame(maxWidth: 220)
                if showError {
                    Text(L("applock.pin_wrong"))
                        .font(.caption)
                        .foregroundColor(.red)
                }
                Button {
                    if AppLockService.verifyPIN(code) {
                        dismiss()
                        onSuccess()
                    } else {
                        showError = true
                        code = ""
                    }
                } label: {
                    Text(L("applock.unlock"))
                        .font(.headline)
                        .foregroundColor(.black)
                        .frame(maxWidth: 220)
                        .padding(.vertical, 12)
                        .background(AppTheme.accent)
                        .cornerRadius(AppTheme.cornerRadius)
                }
                .buttonStyle(.plain)
                .disabled(code.count < 4)
                .opacity(code.count < 4 ? 0.45 : 1)
            }
            .padding(24)
            Spacer()
        }
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background.ignoresSafeArea())
    }
}
