//
//  PushInstallationStorage.swift
//  CommonPlateios
//
// Local identity and reconciliation state for push (Week 3 Day 6 Slice 6A).
//
// App-local `UserDefaults` holds installation continuity and reconciliation
// state, including only the intended email for interrupted replacement.
// Participant bearer credentials remain in identity storage's Keychain, never
// here. Reinstalling must produce a new installation.
//
// The credential proves only continuity of calls from this installation. The
// confirmed-enabled flag is presentation/reconciliation state, not
// independent backend truth: it is set only after a successful
// synchronization call, exactly like `AlertSignupPresentationStorage`'s
// record is written only after a confirmed accepted response.
import Foundation

protocol PushInstallationStorage {
    var pendingReplacementEmail: String? { get }
    func setPendingReplacementEmail(_ email: String?)
    var hasPendingAssociationChange: Bool { get }
    func setPendingAssociationChange(_ pending: Bool)
    /// Returns this installation's credential, generating and persisting one
    /// on first access if none exists yet. Stable for the app installation's
    /// lifetime; deleting and reinstalling the app removes it.
    func installationCredential() -> String

    /// The push-enabled state last confirmed by the backend, or `nil` if this
    /// installation has never completed a synchronization call.
    var lastConfirmedPushEnabled: Bool? { get }

    /// Records the backend's confirmed state after a successful
    /// synchronization. The only writer of this value.
    func recordConfirmedPushEnabled(_ enabled: Bool)

    /// The moment CommonPlate most recently opened Settings for permission
    /// recovery, or `nil` while no recovery is pending. Set the instant
    /// `Open Settings` is tapped, cleared once that flow resolves (success
    /// or failure), once permission reads `.notDetermined` again, or once
    /// `PushSubscriptionStore` finds it older than its accepted recovery
    /// lifetime. This storage layer has no time-based logic of its own — it
    /// only records and returns the timestamp; `PushSubscriptionStore` is
    /// the sole judge of freshness. This is the one signal that distinguishes
    /// an ordinary screen visit, which must never treat a bare denied read as
    /// something to act on, from an actual pending recovery, where a
    /// permission change should be picked up automatically. Persisted
    /// because going to Settings and back — and the recovery window itself —
    /// are not guaranteed to keep the process alive in memory.
    var settingsRecoveryIntentStartedAt: Date? { get }

    func setSettingsRecoveryIntentStartedAt(_ date: Date?)

    /// The desired push state (`true` = enable, `false` = disable) of a
    /// synchronization attempt whose outcome is unresolved — the request may
    /// have reached the backend, but this installation never received and
    /// validated a usable response. `nil` while nothing is unresolved.
    ///
    /// Persisted so the ambiguity survives relaunch: the whole point is that
    /// `PushSubscriptionStore` must not fabricate On or Off, and must not
    /// silently resolve one way or the other on its own — only an explicit
    /// retry through `PushSubscriptionStore.retryAmbiguousSync()`, reasserting
    /// this exact same desired state, may resolve it.
    var pendingAmbiguousDesiredEnabled: Bool? { get }

    func setPendingAmbiguousDesiredEnabled(_ desired: Bool?)
}

/// `UserDefaults`-backed storage, matching
/// `UserDefaultsAlertSignupPresentationStorage`: the app has no other
/// preference mechanism to reuse, and neither value here is a secret in the
/// sense the Keychain exists for.
struct UserDefaultsPushInstallationStorage: PushInstallationStorage {
    private static let pendingReplacementEmailKey = "com.commonplate.push.pendingReplacementEmail"
    private static let mutationVersionKey = "com.commonplate.push.mutationVersion"
    private static let pendingAssociationKey = "com.commonplate.push.pendingAssociationChange"
    private static let credentialKey = "com.commonplate.push.installationCredential"
    private static let confirmedEnabledKey = "com.commonplate.push.lastConfirmedEnabled"
    private static let settingsRecoveryIntentStartedAtKey = "com.commonplate.push.settingsRecoveryIntentStartedAt"
    private static let pendingAmbiguousDesiredEnabledKey = "com.commonplate.push.pendingAmbiguousDesiredEnabled"

    private let defaults: UserDefaults
    private let localPresentation: ParticipantLocalPresentationStorage

    init(defaults: UserDefaults) {
        self.defaults = defaults
        localPresentation = ParticipantLocalPresentationStorage(defaults: defaults)
    }

    var pendingReplacementEmail: String? {
        guard localPresentation.isCurrent else { return nil }
        return defaults.string(forKey: localPresentation.key(Self.pendingReplacementEmailKey))
    }

    func setPendingReplacementEmail(_ email: String?) {
        guard localPresentation.isCurrent, !ParticipantDeletionFreeze(defaults: defaults).isPresent else { return }
        let key = localPresentation.key(Self.pendingReplacementEmailKey)
        if let email { defaults.set(email, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    @MainActor
    func nextMutationVersion() -> Int {
        let current = defaults.integer(forKey: Self.mutationVersionKey)
        precondition(current >= 0 && current < 9_007_199_254_740_991, "Invalid Push mutation version")
        let next = current + 1
        defaults.set(next, forKey: Self.mutationVersionKey)
        return next
    }

    var hasPendingAssociationChange: Bool {
        guard localPresentation.isCurrent else { return false }
        return defaults.bool(forKey: localPresentation.key(Self.pendingAssociationKey))
    }

    func setPendingAssociationChange(_ pending: Bool) {
        guard localPresentation.isCurrent, !ParticipantDeletionFreeze(defaults: defaults).isPresent else { return }
        defaults.set(pending, forKey: localPresentation.key(Self.pendingAssociationKey))
    }

    func installationCredential() -> String {
        if let existing = defaults.string(forKey: Self.credentialKey) {
            return existing
        }
        let generated = InstallationCredentialGenerator.generate()
        defaults.set(generated, forKey: Self.credentialKey)
        return generated
    }

    var lastConfirmedPushEnabled: Bool? {
        // `UserDefaults.bool(forKey:)` returns `false` for an absent key, so
        // presence is checked separately: "never synchronized" and
        // "confirmed off" must not collapse into the same value.
        guard defaults.object(forKey: Self.confirmedEnabledKey) != nil else {
            return nil
        }
        return defaults.bool(forKey: Self.confirmedEnabledKey)
    }

    func recordConfirmedPushEnabled(_ enabled: Bool) {
        guard localPresentation.isCurrent, !ParticipantDeletionFreeze(defaults: defaults).isPresent else { return }
        defaults.set(enabled, forKey: Self.confirmedEnabledKey)
    }

    // An absent key, or a value that was somehow stored as something other
    // than a `Date`, both correctly read as `nil` — "no recovery pending" —
    // through the same `as?` cast, with no separate malformed-state handling
    // needed.
    var settingsRecoveryIntentStartedAt: Date? {
        defaults.object(forKey: Self.settingsRecoveryIntentStartedAtKey) as? Date
    }

    func setSettingsRecoveryIntentStartedAt(_ date: Date?) {
        guard localPresentation.isCurrent, !ParticipantDeletionFreeze(defaults: defaults).isPresent else { return }
        guard let date else {
            defaults.removeObject(forKey: Self.settingsRecoveryIntentStartedAtKey)
            return
        }
        defaults.set(date, forKey: Self.settingsRecoveryIntentStartedAtKey)
    }

    var pendingAmbiguousDesiredEnabled: Bool? {
        guard defaults.object(forKey: Self.pendingAmbiguousDesiredEnabledKey) != nil else {
            return nil
        }
        return defaults.bool(forKey: Self.pendingAmbiguousDesiredEnabledKey)
    }

    func setPendingAmbiguousDesiredEnabled(_ desired: Bool?) {
        guard localPresentation.isCurrent, !ParticipantDeletionFreeze(defaults: defaults).isPresent else { return }
        guard let desired else {
            defaults.removeObject(forKey: Self.pendingAmbiguousDesiredEnabledKey)
            return
        }
        defaults.set(desired, forKey: Self.pendingAmbiguousDesiredEnabledKey)
    }
}

/// Cryptographically random credential generation, shared by whichever
/// storage implementation needs to mint one. `src/installationCredential.ts`
/// is this value's backend counterpart: 32 random bytes, base64url-encoded,
/// no padding.
enum InstallationCredentialGenerator {
    static let byteCount = 32

    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        // `errSecSuccess` is effectively guaranteed on-device; a failure here
        // would mean the platform's secure random source itself is
        // unavailable, which nothing in this app can meaningfully recover
        // from.
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed unexpectedly")
        return Data(bytes).base64URLEncodedString()
    }
}

private extension Data {
    /// Standard base64, remapped to the unpadded URL-safe alphabet the
    /// backend's `isValidRawInstallationCredential` expects.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
