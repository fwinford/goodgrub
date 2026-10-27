//
//  PushSubscriptionStore.swift
//  CommonPlateios
//
// The one state owner for CommonPlate push-notification preference (Week 3
// Day 6 Slice 6A.2). Coordinates installation identity, Apple's notification
// permission, APNs device-token registration, and backend synchronization
// through `InstallationPushService`.
//
// Deliberately separate from `AlertSubscriptionStore` and `RequestStore`: per
// the Week 3 Day 6 cross-slice contract, email alerts and push notifications
// are independent controls with no shared state, error semantics, or backend
// endpoint. This sends no notification and never touches email state.
//
// `state` is truthful by construction. It becomes `.on` only after Apple
// permission allows notifications, an APNs token was received, and the
// backend confirmed `enabled: true` — never optimistically. Turning push off
// follows the same rule in reverse: `.off` is shown only after the backend
// confirms `enabled: false`, and a failed disable preserves the last
// confirmed `.on` state rather than claiming delivery stopped.
import Combine
import Foundation
import UserNotifications

/// What the push control shows. Internal state names only — user-facing copy
/// belongs to the view, exactly like `AlertSignupPhase`/`AlertSignupFailure`.
enum PushPreferenceState: Equatable {
    case off
    case settingUp
    case on
    case denied
    case failed
    /// An enable or disable call may have reached the backend, but this
    /// installation never received and validated a usable response. `On` and
    /// `Off` are both withheld; `desiredEnabled` is the declarative state the
    /// unresolved attempt asked for, and the only thing `retryAmbiguousSync()`
    /// may reassert. Never entered or left by any automatic reconciliation —
    /// only an explicit attempt (the original call, or a later explicit
    /// retry) can resolve it.
    case ambiguous(desiredEnabled: Bool)
}

enum PushSyncFailure: Equatable {
    case couldNotEnable
    case couldNotDisable
}

@MainActor
final class PushSubscriptionStore: ObservableObject {
    @Published private(set) var state: PushPreferenceState
    @Published private(set) var failure: PushSyncFailure?

    private let service: InstallationPushService
    private let installationStorage: PushInstallationStorage
    private let authorizationCoordinator: PushAuthorizationCoordinator
    private let remoteNotificationRegistrar: RemoteNotificationRegistering
    private let settingsOpener: PushSettingsOpener
    private let registrationTimeout: Duration
    private let participantAuthorityProvider: () -> String?
    private var mutationInFlight = false
    private var confirmedAssociationClear = false
    private var failureBeforeAssociation: PushSyncFailure?
    private var associationRecovery: () async -> Void = {}
    private var preparedReplacementEmail: String?
    private var retiredForDeletion = false

    func retireForCompletedDeletion() {
        retiredForDeletion = true
        preparedReplacementEmail = nil
        associationRecovery = {}
    }

    /// How long a Settings-recovery intent stays actionable after `Open
    /// Settings` is tapped. Bounds the accepted "return shortly after
    /// enabling permission" flow: a person who abandons that Settings visit
    /// and only grants permission much later — through this flow or any
    /// unrelated one — must take a fresh explicit in-app action rather than
    /// have CommonPlate silently enable push on some later, unconnected app
    /// open. A defensive implementation boundary around the already-accepted
    /// Settings excursion, not a notification-delivery guarantee.
    static let settingsRecoveryIntentLifetime: TimeInterval = 10 * 60

    /// Every dependency is injected with no default, matching
    /// `AlertSubscriptionStore`: no caller — and no test — can reach the
    /// developer's real `UserDefaults` or Apple's real notification system by
    /// omission.
    init(
        service: InstallationPushService,
        installationStorage: PushInstallationStorage,
        authorizationCoordinator: PushAuthorizationCoordinator,
        remoteNotificationRegistrar: RemoteNotificationRegistering,
        settingsOpener: PushSettingsOpener,
        registrationTimeout: Duration = .seconds(20),
        participantAuthorityProvider: @escaping () -> String? = { nil }
    ) {
        self.service = service
        self.installationStorage = installationStorage
        self.authorizationCoordinator = authorizationCoordinator
        self.remoteNotificationRegistrar = remoteNotificationRegistrar
        self.settingsOpener = settingsOpener
        self.registrationTimeout = registrationTimeout
        self.participantAuthorityProvider = participantAuthorityProvider
        if installationStorage.hasPendingAssociationChange {
            self.state = .failed
            self.failure = .couldNotEnable
            return
        }

        // An unresolved prior attempt takes priority over everything else: it
        // must survive relaunch exactly as it was, presenting neither On nor
        // Off, until an explicit retry resolves it. Checked before the
        // ordinary confirmed-state restoration below, so a relaunch never
        // silently reverts an unresolved choice to a stale confirmed value.
        if let pendingDesired = installationStorage.pendingAmbiguousDesiredEnabled {
            self.state = .ambiguous(desiredEnabled: pendingDesired)
            return
        }

        // A previously confirmed installation starts in a checking state
        // rather than claiming `.on` before this launch has reconfirmed it —
        // and rather than showing `.off` and flashing back to `.on` a moment
        // later. `refreshAuthorizationStatus()` resolves this on first
        // appearance; nothing here starts async work from `init` itself.
        self.state = installationStorage.lastConfirmedPushEnabled == true ? .settingUp : .off
    }

    var isBusy: Bool {
        state == .settingUp
    }

    // MARK: - Permission lifecycle

    /// Called when the push control first appears and whenever the app or
    /// that screen becomes active again — never on launch alone, and never
    /// from a background timer. This is also what dismissing the CommonPlate
    /// explanation (`Not now`, navigating back) ultimately runs into: nothing
    /// calls this store when the explanation is merely shown or dismissed —
    /// so the guarantee that a bare denied read is never acted on without a
    /// pending recovery intent is what keeps that dismissal from ever landing
    /// on the Settings-recovery card by accident, however many times the
    /// screen reappears.
    func refreshAuthorizationStatus(now: Date = Date()) async {
        guard !retiredForDeletion, !mutationInFlight,
              !installationStorage.hasPendingAssociationChange,
              let authority = participantAuthorityProvider() else { return }
        // An unresolved ambiguous outcome is never automatically retried or
        // silently resolved by an ordinary lifecycle refresh — only an
        // explicit `retryAmbiguousSync()` call may act on it.
        if case .ambiguous = state { return }

        let status = await authorizationCoordinator.currentAuthorizationStatus()
        guard !retiredForDeletion, !mutationInFlight,
              !installationStorage.hasPendingAssociationChange,
              participantAuthorityProvider() == authority else { return }

        if failure != nil {
            switch status {
            case .authorized, .provisional, .ephemeral:
                break
            default:
                if state == .on { state = .denied }
            }
            return
        }

        switch status {
        case .denied:
            if hasFreshRecoveryIntent(now: now) {
                // Sent to Settings, still denied on return, and within the
                // accepted recovery window: stay in recovery and wait for a
                // later activation to try again. Left in place (not
                // consumed) so that later activation can still find it.
                if state != .denied { state = .denied }
                return
            }
            if installationStorage.lastConfirmedPushEnabled == true {
                // A previously-on installation whose permission was revoked
                // is proactively surfaced and reconciled toward the backend,
                // regardless of whether anyone asked — this is genuine news.
                if state != .denied { state = .denied }
                await reconcileRevokedPermissionIfNeeded()
                return
            }
            // Never confirmed on, and nobody asked CommonPlate to act on
            // Apple's permission right now. A bare denied read here is not
            // itself news: treating it as such would show the recovery card
            // for an ordinary screen visit, or for dismissing the
            // explanation, exactly as if the person had gone through
            // `Open Settings` when they never did. Preserve whatever the
            // last backend-confirmed state was.
            return
        case .authorized, .provisional, .ephemeral:
            if hasFreshRecoveryIntent(now: now) {
                // Consumed before starting the async work below, so a
                // repeated foreground event during setup — or a second
                // activation after this one already began — can never start
                // a duplicate recovery attempt from the same intent.
                consumeRecoveryIntent()
                await registerAndSynchronize(requestingPermission: false)
            } else if installationStorage.lastConfirmedPushEnabled == true, state != .on {
                await registerAndSynchronize(requestingPermission: false)
            } else if state == .denied {
                // Permission was restored outside any recovery this store
                // initiated, and this installation was never confirmed on:
                // wait for an explicit enable rather than turning push on
                // unasked.
                state = .off
            }
        case .notDetermined:
            consumeRecoveryIntent()
            if state == .denied || state == .failed {
                state = .off
            }
        @unknown default:
            // Conservative: an authorization status this code does not
            // recognize must not be treated as fully enabled. Only surface
            // it, though, under the same conditions a genuine denial would.
            if hasFreshRecoveryIntent(now: now) || installationStorage.lastConfirmedPushEnabled == true {
                if state != .denied { state = .denied }
            }
        }
    }

    // MARK: - Enabling

    /// Called only after the person taps `Enable notifications` in the
    /// CommonPlate explanation — never automatically, and never from
    /// `.denied` (that state's only recovery action is `openSystemSettings`).
    func enable() async {
        guard state == .off || state == .failed else { return }
        await registerAndSynchronize(requestingPermission: true)
    }

    private func registerAndSynchronize(requestingPermission: Bool) async {
        guard !retiredForDeletion else { return }
        guard !mutationInFlight, !installationStorage.hasPendingAssociationChange,
              let authority = participantAuthorityProvider() else {
            failure = .couldNotEnable
            state = .failed
            return
        }
        mutationInFlight = true
        defer { mutationInFlight = false }
        // Captured before `.settingUp` overwrites it: whether this attempt is
        // resolving a previously ambiguous enable governs every failure
        // branch below. A fresh failure from `.off`/`.failed` may safely show
        // `.failed` (nothing was left unresolved); a failure while retrying an
        // ambiguous attempt must never downgrade — the earlier unresolved
        // mutation is still exactly as unresolved as it was.
        let cameFromAmbiguousEnable: Bool
        if case .ambiguous(true) = state {
            cameFromAmbiguousEnable = true
        } else {
            cameFromAmbiguousEnable = false
        }

        failure = nil
        state = .settingUp

        do {
            let status = await authorizationCoordinator.currentAuthorizationStatus()
            guard !retiredForDeletion else { return }
            switch status {
            case .notDetermined:
                guard requestingPermission else {
                    failEnable(cameFromAmbiguous: cameFromAmbiguousEnable)
                    return
                }
                let granted: Bool
                do {
                    granted = try await authorizationCoordinator.requestAuthorization()
                } catch {
                    guard !retiredForDeletion else { return }
                    failEnable(cameFromAmbiguous: cameFromAmbiguousEnable)
                    return
                }
                guard !retiredForDeletion else { return }
                guard granted else {
                    state = .denied
                    return
                }
            case .denied:
                state = .denied
                return
            case .authorized, .provisional, .ephemeral:
                // Permission was already granted from an earlier launch or
                // Settings visit; no second system prompt is possible or
                // needed.
                break
            @unknown default:
                state = .denied
                return
            }
        }

        let token: String
        do {
            token = try await remoteNotificationRegistrar.registerAndAwaitToken(timeout: registrationTimeout)
        } catch {
            guard !retiredForDeletion else { return }
            failEnable(cameFromAmbiguous: cameFromAmbiguousEnable)
            return
        }

        guard !retiredForDeletion else { return }
        guard participantAuthorityProvider() == authority,
              !installationStorage.hasPendingAssociationChange else {
            failEnable(cameFromAmbiguous: cameFromAmbiguousEnable)
            return
        }
        let credential = installationStorage.installationCredential()
        do {
            let confirmedEnabled = try await service.synchronizeEnabled(
                credential: credential,
                apnsToken: token,
                environment: .current
            )
            guard !retiredForDeletion else { return }
            guard participantAuthorityProvider() == authority else {
                installationStorage.setPendingAssociationChange(true)
                state = .failed
                failure = .couldNotEnable
                return
            }
            installationStorage.recordConfirmedPushEnabled(confirmedEnabled)
            installationStorage.setPendingAmbiguousDesiredEnabled(nil)
            state = confirmedEnabled ? .on : .off
        } catch InstallationPushSyncError.ambiguousOutcome {
            guard !retiredForDeletion else { return }
            installationStorage.setPendingAmbiguousDesiredEnabled(true)
            state = .ambiguous(desiredEnabled: true)
        } catch {
            guard !retiredForDeletion else { return }
            failEnable(cameFromAmbiguous: cameFromAmbiguousEnable)
        }
    }

    /// The one place a non-ambiguous enable failure is applied: `.failed` for
    /// an ordinary attempt, or — while resolving a previously ambiguous
    /// enable — a return to the same unresolved `.ambiguous(true)` rather
    /// than a claim that the earlier unresolved mutation is now known to have
    /// failed, which this new, separate failure does not establish.
    private func failEnable(cameFromAmbiguous: Bool) {
        if cameFromAmbiguous {
            state = .ambiguous(desiredEnabled: true)
            failure = .couldNotEnable
        } else {
            state = .failed
            failure = .couldNotEnable
        }
    }

    // MARK: - Disabling

    /// Explicit user action only. Never optimistic: `.off` is shown only
    /// after the backend confirms it, and a failed attempt preserves the
    /// last confirmed `.on` state rather than claiming delivery stopped.
    func disable() async {
        guard state == .on else { return }
        await performDisable(cameFromAmbiguous: false)
    }

    private func performDisable(cameFromAmbiguous: Bool) async {
        guard !retiredForDeletion, !mutationInFlight else { return }
        mutationInFlight = true
        defer { mutationInFlight = false }
        failure = nil
        state = .settingUp

        let credential = installationStorage.installationCredential()
        do {
            let confirmedEnabled = try await service.synchronizeDisabled(credential: credential)
            guard !retiredForDeletion else { return }
            installationStorage.recordConfirmedPushEnabled(confirmedEnabled)
            installationStorage.setPendingAmbiguousDesiredEnabled(nil)
            state = confirmedEnabled ? .on : .off
        } catch InstallationPushSyncError.ambiguousOutcome {
            guard !retiredForDeletion else { return }
            installationStorage.setPendingAmbiguousDesiredEnabled(false)
            state = .ambiguous(desiredEnabled: false)
        } catch {
            guard !retiredForDeletion else { return }
            // A definitive (non-ambiguous) disable failure while resolving a
            // previously ambiguous disable must not claim the earlier
            // unresolved mutation is now known to have failed — it stays
            // exactly as unresolved as it was. Only a fresh, ordinary disable
            // may fall back to the last confirmed On.
            if cameFromAmbiguous {
                state = .ambiguous(desiredEnabled: false)
            } else {
                state = .on
            }
            failure = .couldNotDisable
        }
    }

    /// Explicit recovery from `.ambiguous`. Reasserts only the same
    /// declarative desired state the unresolved attempt already asked for —
    /// never the opposite — through the same synchronization contract as an
    /// ordinary enable or disable. Never called automatically.
    func retryAmbiguousSync() async {
        guard case .ambiguous(let desiredEnabled) = state else { return }
        if desiredEnabled {
            await registerAndSynchronize(requestingPermission: false)
        } else {
            await performDisable(cameFromAmbiguous: true)
        }
    }

    func retryUpdate() async {
        if installationStorage.hasPendingAssociationChange {
            await associationRecovery()
            return
        }
        if case .ambiguous = state {
            await retryAmbiguousSync()
        } else if failure == .couldNotDisable {
            await performDisable(cameFromAmbiguous: false)
        } else {
            await enable()
        }
    }

    func configureAssociationRecovery(_ action: @escaping () async -> Void) {
        associationRecovery = action
    }

    func prepareParticipantReplacement(email: String) {
        guard !retiredForDeletion else { return }
        preparedReplacementEmail = email
    }

    var pendingReplacementEmail: String? {
        installationStorage.hasPendingAssociationChange
            ? installationStorage.pendingReplacementEmail : nil
    }

    func synchronizeParticipantAssociation(authority: String?) async throws {
        guard !retiredForDeletion else { throw CancellationError() }
        guard !mutationInFlight else {
            throw ParticipantVerificationError.temporarilyUnavailable
        }
        mutationInFlight = true
        let previousState = state
        let wasPending = installationStorage.hasPendingAssociationChange
        let previousPendingEmail = installationStorage.pendingReplacementEmail
        if !wasPending { failureBeforeAssociation = failure }
        if authority == nil {
            installationStorage.setPendingReplacementEmail(nil)
        } else if let preparedReplacementEmail {
            installationStorage.setPendingReplacementEmail(preparedReplacementEmail)
        }
        preparedReplacementEmail = nil
        installationStorage.setPendingAssociationChange(true)
        state = .settingUp
        defer { mutationInFlight = false }
        do {
            let enabled = try await service.synchronizeAssociation(
                credential: installationStorage.installationCredential(),
                authority: authority
            )
            guard !retiredForDeletion else { throw CancellationError() }
            installationStorage.recordConfirmedPushEnabled(enabled)
            confirmedAssociationClear = authority == nil
            failure = nil
            state = .failed
        } catch InstallationPushSyncError.ambiguousOutcome {
            guard !retiredForDeletion else { throw CancellationError() }
            state = .failed
            failure = .couldNotEnable
            throw ParticipantVerificationError.temporarilyUnavailable
        } catch {
            guard !retiredForDeletion else { throw CancellationError() }
            if !wasPending {
                installationStorage.setPendingAssociationChange(false)
                installationStorage.setPendingReplacementEmail(nil)
                state = previousState
            } else {
                installationStorage.setPendingReplacementEmail(previousPendingEmail)
                state = .failed
                failure = .couldNotEnable
            }
            throw error
        }
    }

    func completeParticipantAssociationChange() {
        guard !retiredForDeletion else { return }
        installationStorage.setPendingAssociationChange(false)
        installationStorage.setPendingReplacementEmail(nil)
        if confirmedAssociationClear {
            installationStorage.setPendingAmbiguousDesiredEnabled(nil)
        }
        failure = confirmedAssociationClear ? nil : failureBeforeAssociation
        if let desired = installationStorage.pendingAmbiguousDesiredEnabled {
            state = .ambiguous(desiredEnabled: desired)
        } else if failure != nil {
            state = .failed
        } else {
            state = installationStorage.lastConfirmedPushEnabled == true ? .settingUp : .off
        }
    }

    // MARK: - Recovery

    /// Never invoked except by an explicit `Open Settings` tap. Records the
    /// pending recovery intent's start time first, so a permission change
    /// picked up on a later activation within `settingsRecoveryIntentLifetime`
    /// — even after this process was suspended and relaunched while Settings
    /// was open — completes registration automatically instead of silently
    /// doing nothing.
    func openSystemSettings(now: Date = Date()) {
        guard !retiredForDeletion, state == .denied else { return }
        installationStorage.setSettingsRecoveryIntentStartedAt(now)
        settingsOpener.openSettings()
    }

    /// Whether a Settings-recovery intent is currently pending and still
    /// within its accepted lifetime. A stale intent — none exists, the
    /// stored value cannot be read as a `Date`, its start time is in the
    /// future, or more than `settingsRecoveryIntentLifetime` has elapsed —
    /// is cleared here as a side effect, so it never lingers to be found
    /// fresh by mistake on some later, unconnected check.
    private func hasFreshRecoveryIntent(now: Date) -> Bool {
        guard let startedAt = installationStorage.settingsRecoveryIntentStartedAt else {
            return false
        }
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed >= 0, elapsed <= Self.settingsRecoveryIntentLifetime else {
            installationStorage.setSettingsRecoveryIntentStartedAt(nil)
            return false
        }
        return true
    }

    /// The one place a pending recovery intent is cleared because it was
    /// actually acted on (or because permission returned to
    /// `.notDetermined`, which invalidates it) — as opposed to
    /// `hasFreshRecoveryIntent`'s clearing of a merely stale one. Called
    /// before starting the async registration work it authorizes, so a
    /// repeated foreground event cannot consume — and act on — the same
    /// intent twice.
    private func consumeRecoveryIntent() {
        installationStorage.setSettingsRecoveryIntentStartedAt(nil)
    }

    /// A revoked permission must not silently leave the backend believing
    /// push is still enabled. A failed reconciliation attempt here is not
    /// itself reported to the person; it is retried the next time
    /// `refreshAuthorizationStatus()` runs — the next app activation or
    /// screen visit — rather than through a background worker.
    private func reconcileRevokedPermissionIfNeeded() async {
        guard !retiredForDeletion, !mutationInFlight, !installationStorage.hasPendingAssociationChange,
              installationStorage.lastConfirmedPushEnabled != false else { return }
        mutationInFlight = true
        defer { mutationInFlight = false }
        let credential = installationStorage.installationCredential()
        do {
            let confirmedEnabled = try await service.synchronizeDisabled(credential: credential)
            guard !retiredForDeletion else { return }
            installationStorage.recordConfirmedPushEnabled(confirmedEnabled)
        } catch InstallationPushSyncError.ambiguousOutcome {
            guard !retiredForDeletion else { return }
            installationStorage.setPendingAmbiguousDesiredEnabled(false)
            state = .ambiguous(desiredEnabled: false)
        } catch {
            guard !retiredForDeletion else { return }
            failure = .couldNotDisable
        }
    }
}
