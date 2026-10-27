//
//  ParticipantIdentityStore.swift
//  CommonPlateios
//
// Coordinates ParticipantVerificationService and installation-local storage,
// and updates state only after confirmed backend responses (W3-I1). Owns no
// SwiftUI screen; views call its operation-specific methods.
import Combine
import Foundation

/// The remembered identity, in the form a screen may render.
///
/// `masked` is the only spelling any view shows. The full principal stays
/// available for the things that need it — prefilling nothing, comparing
/// nothing, just the Change Email flow's own confirmation and the account
/// deletion code screen (Faith 2026-10-25) — and the credential
/// is not here at all: it lives in private store state so it cannot reach
/// view-readable observable state, exactly like the raw claim token.
struct ParticipantIdentityPresentation: Equatable {
    let principal: String
    let masked: String
    let verifiedAt: Date
}

/// Where a verification flow currently is. `nil` is not a stage — a store with
/// no flow running has `flow == nil` — because "no flow" and "a flow at its
/// first step" are different things: only the second may show a form.
enum ParticipantVerificationStage: Equatable {
    /// Collecting the address. Reached by the first gate, and by Change Email.
    case enteringEmail
    /// A code has been mailed. Carries the backend's own deadlines rather than
    /// any locally computed ones.
    case awaitingCode(email: String, expiresAt: Date, resendAvailableAt: Date)
}

/// Why a verification flow is running. The two are not interchangeable: a
/// replacement must leave the current identity intact until it succeeds, and a
/// first verification has nothing to protect.
enum ParticipantVerificationPurpose: Equatable {
    case firstVerification
    case emailReplacement
}

/// The exact participant action that opened a first-verification flow.
///
/// This is deliberately operation identity, not navigation identity and not a
/// generic "resume after verification" flag. A requester operation carries a
/// fresh UUID; a helper operation carries both a fresh UUID and the exact
/// request it intends to claim. Only the initiating destination holds the same
/// value, so another mounted screen cannot consume identity becoming available.
enum ParticipantVerificationContinuation: Equatable {
    case requestCreation(operationID: UUID)
    case claim(requestID: String, operationID: UUID)
}

struct ParticipantVerificationFlow: Equatable {
    let purpose: ParticipantVerificationPurpose
    var stage: ParticipantVerificationStage
}

/// Copy-bearing presentation of a verification failure. The stable backend code
/// stays on the service error; only the sentence lives here.
enum ParticipantVerificationPresentationError: Equatable {
    case ineligibleEmail
    case resendTooSoon
    case codeIncorrect
    case codeExpired
    case codeNotRequested
    case attemptsExceeded
    case temporarilyUnavailable
    case replacementBlocked

    var message: String {
        switch self {
        case .ineligibleEmail:
            return "Enter a valid NYU email address."
        case .resendTooSoon:
            return "We just sent a code. Check your email, then try again in a moment."
        case .codeIncorrect:
            return "That code is incorrect. Check your email and try again."
        case .codeExpired:
            return "That code has expired. Send a new one."
        case .codeNotRequested:
            return "Send a code to this email first."
        case .attemptsExceeded:
            return "Too many incorrect codes. Send a new code to try again."
        case .temporarilyUnavailable:
            return "We couldn’t verify your email right now. Please try again in a moment."
        case .replacementBlocked:
            return "You can’t change your email while you have unfinished requests or helping."
        }
    }

    static func map(_ error: Error) -> ParticipantVerificationPresentationError {
        guard let serviceError = error as? ParticipantVerificationError else {
            return .temporarilyUnavailable
        }
        switch serviceError {
        case .ineligibleEmail:
            return .ineligibleEmail
        case .resendTooSoon:
            return .resendTooSoon
        case .codeIncorrect:
            return .codeIncorrect
        case .codeExpired:
            return .codeExpired
        case .codeNotRequested:
            return .codeNotRequested
        case .attemptsExceeded:
            return .attemptsExceeded
        case .temporarilyUnavailable, .couldNotReachBackend:
            return .temporarilyUnavailable
        case .replacementBlocked:
            return .replacementBlocked
        }
    }
}

/// W4-B1: why Change Email was refused. `blockers` is empty only when the
/// backend refused without a reason this app could read; the notice then gives
/// the general guidance.
struct EmailReplacementBlock: Equatable {
    let blockers: [EmailReplacementBlocker]
}

@MainActor
final class ParticipantIdentityStore: ObservableObject {
    /// The remembered verified identity, or `nil` when this installation has
    /// none. Presentation state: the backend remains authoritative, and
    /// `discardRejectedIdentity()` is how its verdict gets applied here.
    @Published private(set) var identity: ParticipantIdentityPresentation?

    /// The verification flow currently running, if any.
    @Published private(set) var flow: ParticipantVerificationFlow?

    /// One operation-scoped continuation at most. It survives code errors and
    /// retries, is consumed once after successful verification, and is retired
    /// by cancellation, abandonment, or a destination mismatch.
    @Published private(set) var pendingContinuation: ParticipantVerificationContinuation?

    @Published private(set) var isRequestingCode = false
    @Published private(set) var isSubmittingCode = false
    @Published private(set) var isCheckingReplacement = false
    @Published private(set) var replacementBlock: EmailReplacementBlock?
    @Published private(set) var replacementCheckFailed = false
    @Published private(set) var verificationError: ParticipantVerificationPresentationError?
    @Published private(set) var isRemovingIdentity = false
    @Published private(set) var removalFailed = false

    /// Records that the backend refused a stored identity. The verification UI
    /// intentionally presents no revocation notice; no production caller
    /// currently acknowledges this retained store-level signal.
    @Published private(set) var wasIdentityRevoked = false

    var isVerified: Bool { identity != nil }

    private let service: ParticipantVerificationService
    private let storage: ParticipantIdentityStorage
    private let now: () -> Date

    /// The bearer credential. Private, and never published: view-readable state
    /// must not be able to leak it into a screenshot, a log, or a diagnostic
    /// dump — the same boundary `RequestStore` keeps around the raw claim token.
    private var authority: String?
    private var pendingVerifiedReplacement: VerifiedParticipantIdentity?
    private var verificationGeneration = UUID()
    /// Normalized emails for which the CURRENT flow has itself confirmed
    /// sending a code (via `requestCode` or `resendCode` succeeding), never
    /// merely inferred from a `resendTooSoon` refusal. Reset whenever a flow
    /// starts or ends. See the `resendTooSoon` handling in `requestCode(for:)`.
    private var confirmedCodeEmails: Set<String> = []
    private var deletionFrozen = false
    /// A deletion record exists for this installation. Ordinary use continues,
    /// but the identity it is bound to may not be replaced or removed.
    private var deletionHeld = false
    private var installationAssociationCompleted: () -> Void = {}
    private var pendingReplacementEmailProvider: () -> String? = { nil }
    private var prepareInstallationReplacement: (String) -> Void = { _ in }
    private var installationAssociation: (String?) async throws -> Void = { _ in
        throw ParticipantVerificationError.temporarilyUnavailable
    }

    func configureInstallationAssociation(
        pendingReplacementEmail: @escaping () -> String? = { nil },
        prepareReplacement: @escaping (String) -> Void = { _ in },
        onIdentityCommitted: @escaping () -> Void = {},
        _ action: @escaping (String?) async throws -> Void
    ) {
        installationAssociation = action
        installationAssociationCompleted = onIdentityCommitted
        pendingReplacementEmailProvider = pendingReplacementEmail
        prepareInstallationReplacement = prepareReplacement
    }

    var replacementRecoveryEmail: String? {
        guard flow?.purpose == .emailReplacement else { return nil }
        return pendingReplacementEmailProvider()
    }

    func resumePendingInstallationReplacement() {
        guard pendingReplacementEmailProvider() != nil else { return }
        beginEmailReplacement()
    }

    init(
        service: ParticipantVerificationService,
        storage: ParticipantIdentityStorage,
        now: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.storage = storage
        self.now = now
        restoreRememberedIdentity()
    }

    /// The credential a participant action presents, or `nil` when this
    /// installation has none. `RequestStore` reads this and nothing else about
    /// identity, so the request flow cannot fabricate one.
    func currentAuthority() -> String? {
        deletionFrozen ? nil : authority
    }

    func deletionAuthority(participantID: String) -> String? {
        guard let authority,
              ParticipantAuthorityShape.participantIdentifier(ofAuthority: authority) == participantID else { return nil }
        return authority
    }

    func hasDifferentParticipant(than participantID: String) -> Bool {
        guard let authority,
              let current = ParticipantAuthorityShape.participantIdentifier(ofAuthority: authority) else { return false }
        return current != participantID
    }

    func prepareDeletion() throws -> (participantID: String, binding: String) {
        guard !deletionFrozen, !deletionHeld, flow == nil, !isRemovingIdentity, !isCheckingReplacement,
              let authority,
              let id = ParticipantAuthorityShape.participantIdentifier(ofAuthority: authority) else {
            throw ParticipantDeletionError.identityChanged
        }
        return (id, try storage.deletionBinding(participantID: id))
    }

    func holdForDeletion() {
        deletionHeld = true
    }

    func freezeForDeletion() {
        deletionHeld = true
        deletionFrozen = true
        cancelVerification()
    }

    func restoreAfterCanceledDeletion() {
        deletionFrozen = false
        deletionHeld = false
    }

    func fenceCompletedDeletion(participantID: String) {
        deletionFrozen = true
        cancelVerification()
        if let authority,
           ParticipantAuthorityShape.participantIdentifier(ofAuthority: authority) == participantID {
            self.authority = nil
            identity = nil
        }
    }

    func cleanupCompletedDeletion(participantID: String, binding: String) throws -> CompletedIdentityCleanup {
        try storage.deleteCompletedIdentity(participantID: participantID, installationBinding: binding)
    }

    // MARK: - Remembered identity

    /// Restores a same-install identity at launch. Missing or unusable stored
    /// state simply leaves the app unverified — it is never repaired, guessed
    /// at, or partially restored.
    private func restoreRememberedIdentity() {
        guard let record = storage.loadValidIdentity() else {
            identity = nil
            authority = nil
            return
        }
        identity = Self.presentation(for: record)
        authority = record.authority
    }

    /// Applies a backend refusal of the stored credential.
    ///
    /// This is the only path by which client state loses an identity it did not
    /// itself replace, and it exists because the backend is authoritative: a
    /// credential it will not accept is not an identity, whatever this
    /// installation remembers. Any flow in progress is left alone — a
    /// replacement that is mid-verification is not invalidated by the old
    /// identity being refused.
    func discardRejectedIdentity() {
        guard !deletionFrozen, !deletionHeld else { return }
        guard identity != nil || authority != nil else { return }
        storage.clear()
        identity = nil
        authority = nil
        wasIdentityRevoked = true
    }

    /// Explicit participant-initiated local identity forgetting (W3-I4),
    /// distinct from `discardRejectedIdentity()`, which records a backend
    /// refusal in `wasIdentityRevoked`. The current verification UI shows no
    /// revocation notice; this participant-initiated removal likewise raises
    /// no refusal signal. Removal-safety gating (an active reservation,
    /// in-flight fulfillment, or an unresolved W3-D1 create) is the caller's
    /// responsibility; this clears only the installation-local participant
    /// credential and its presentation, reusing the same `storage.clear()`
    /// call `discardRejectedIdentity()` already uses. Guarded by
    /// `flow == nil` like `beginEmailReplacement()`, matching the existing
    /// precedent that Remove Email is never offered while a flow is running.
    func removeIdentity(ifSafe: () -> Bool = { true }) async {
        guard !deletionFrozen, !deletionHeld, flow == nil, !isRemovingIdentity,
              identity != nil || authority != nil else { return }
        guard ifSafe() else {
            removalFailed = true
            return
        }
        let expectedAuthority = authority
        isRemovingIdentity = true
        removalFailed = false
        defer { isRemovingIdentity = false }
        do {
            try await installationAssociation(nil)
        } catch {
            removalFailed = true
            return
        }
        guard flow == nil, authority == expectedAuthority, ifSafe() else {
            removalFailed = true
            return
        }
        installationAssociationCompleted()
        storage.clear()
        identity = nil
        authority = nil
    }

    // MARK: - Verification flow

    /// Opens the verification flow for a participant action that needs it.
    /// Idempotent while a flow is already running, so a second gated tap does
    /// not restart the student's progress.
    func beginVerificationIfNeeded() {
        guard !deletionFrozen, !isVerified, flow == nil, pendingContinuation == nil else { return }
        verificationGeneration = UUID()
        confirmedCodeEmails = []
        flow = ParticipantVerificationFlow(
            purpose: .firstVerification,
            stage: .enteringEmail
        )
        verificationError = nil
    }

    /// Opens first verification for one exact mutation. A competing operation
    /// cannot replace an in-progress one, even if both screens are mounted.
    @discardableResult
    func beginVerification(
        for continuation: ParticipantVerificationContinuation
    ) -> Bool {
        guard !deletionFrozen, !isVerified, flow == nil, pendingContinuation == nil else {
            return false
        }
        pendingContinuation = continuation
        verificationGeneration = UUID()
        confirmedCodeEmails = []
        flow = ParticipantVerificationFlow(
            purpose: .firstVerification,
            stage: .enteringEmail
        )
        verificationError = nil
        return true
    }

    /// One-use handoff after verified identity exists. Equality is the whole
    /// authorization: a request-A continuation cannot be consumed by request B,
    /// and a duplicate callback loses because the value is cleared atomically
    /// on the main actor before the mutation task starts.
    func consumeContinuation(
        _ continuation: ParticipantVerificationContinuation
    ) -> Bool {
        guard isVerified,
              flow == nil,
              pendingContinuation == continuation else {
            return false
        }
        pendingContinuation = nil
        return true
    }

    /// Retires only the caller's own continuation. A stale destination cannot
    /// cancel a newer flow it does not own.
    func retireContinuation(
        _ continuation: ParticipantVerificationContinuation
    ) {
        guard pendingContinuation == continuation else { return }
        pendingContinuation = nil
        if flow?.purpose == .firstVerification {
            flow = nil
            confirmedCodeEmails = []
            verificationError = nil
            isRequestingCode = false
            isSubmittingCode = false
        }
    }

    /// Opens the Change Email flow. The current identity stays active and
    /// usable throughout: nothing is cleared here, and only a successful
    /// replacement verification changes it.
    func beginEmailReplacement() {
        guard !deletionFrozen, !deletionHeld, flow == nil, pendingContinuation == nil,
              !isRemovingIdentity else { return }
        verificationGeneration = UUID()
        pendingVerifiedReplacement = nil
        confirmedCodeEmails = []
        flow = ParticipantVerificationFlow(
            purpose: .emailReplacement,
            stage: .enteringEmail
        )
        verificationError = nil
    }

    /// W4-B1: Change Email entry point. Reads the backend's current
    /// eligibility first and opens the flow only when nothing blocks it. A
    /// blocked or unreadable answer never opens the flow and never touches the
    /// identity; the screen only learns it through `replacementBlock` or
    /// `replacementCheckFailed`. Read-only: no request or reservation changes.
    func startEmailReplacement() async {
        guard !deletionFrozen, !deletionHeld, flow == nil, pendingContinuation == nil, !isCheckingReplacement,
              let authority else { return }
        isCheckingReplacement = true
        replacementBlock = nil
        replacementCheckFailed = false
        defer { isCheckingReplacement = false }
        do {
            let blockers = try await service.readEmailReplacementEligibility(authority: authority)
            guard flow == nil, self.authority == authority else { return }
            if blockers.isEmpty {
                beginEmailReplacement()
            } else {
                replacementBlock = EmailReplacementBlock(blockers: blockers)
            }
        } catch is CancellationError {
            return
        } catch ParticipantVerificationError.replacementBlocked {
            replacementBlock = EmailReplacementBlock(blockers: [])
        } catch {
            replacementCheckFailed = true
        }
    }

    func dismissReplacementNotice() {
        replacementBlock = nil
        replacementCheckFailed = false
    }

    /// The credential Change Email sends so the backend can recognize a
    /// replacement; first-time verification never sends one.
    private var replacingAuthority: String? {
        flow?.purpose == .emailReplacement ? authority : nil
    }

    /// The backend refused the running replacement for unfinished activity.
    /// Closes the flow, keeps the identity, and surfaces the notice with the
    /// freshest blockers (an unreadable list still blocks).
    private func refuseReplacementForActivity(generation: UUID) async {
        var blockers: [EmailReplacementBlocker] = []
        if let authority {
            blockers = (try? await service.readEmailReplacementEligibility(authority: authority)) ?? []
        }
        guard generation == verificationGeneration,
              flow?.purpose == .emailReplacement else { return }
        flow = nil
        confirmedCodeEmails = []
        verificationError = nil
        replacementBlock = EmailReplacementBlock(blockers: blockers)
    }

    /// Abandons the running flow. A replacement abandoned here leaves the
    /// existing identity exactly as it was — abandonment is not a decision to
    /// stop being verified.
    func cancelVerification() {
        verificationGeneration = UUID()
        flow = nil
        confirmedCodeEmails = []
        pendingContinuation = nil
        verificationError = nil
        isRequestingCode = false
        isSubmittingCode = false
        pendingVerifiedReplacement = nil
    }

    /// Clears the retained backend-refusal signal. The current verification UI
    /// presents no revocation notice, and no production caller invokes this.
    func acknowledgeRevocationNotice() {
        wasIdentityRevoked = false
    }

    /// Requests the emailed code for `email`. Refuses an obviously ineligible
    /// address locally, before spending a request on it; the backend remains
    /// authoritative and applies the identical allowlist.
    func requestCode(for email: String) async {
        guard !isRequestingCode, !isSubmittingCode else { return }
        guard flow != nil else {
            verificationError = .temporarilyUnavailable
            return
        }
        let normalized = NYUEmailPolicy.normalize(email)
        guard NYUEmailPolicy.isAllowed(normalized) else {
            verificationError = .ineligibleEmail
            return
        }
        if let target = replacementRecoveryEmail, target != normalized {
            verificationError = .temporarilyUnavailable
            return
        }

        isRequestingCode = true
        let generation = verificationGeneration
        verificationError = nil
        defer {
            if generation == verificationGeneration { isRequestingCode = false }
        }

        do {
            let challenge = try await service.startVerification(
                email: normalized,
                replacingAuthority: replacingAuthority
            )
            guard generation == verificationGeneration, flow != nil else { return }
            confirmedCodeEmails.insert(normalized)
            flow?.stage = .awaitingCode(
                email: normalized,
                expiresAt: challenge.expiresAt,
                resendAvailableAt: challenge.resendAvailableAt
            )
        } catch is CancellationError {
            return
        } catch ParticipantVerificationError.replacementBlocked {
            guard generation == verificationGeneration,
                  flow?.purpose == .emailReplacement else { return }
            await refuseReplacementForActivity(generation: generation)
        } catch ParticipantVerificationError.resendTooSoon(let reopensAt) {
            guard generation == verificationGeneration, flow != nil else { return }
            // Only trust `resendTooSoon` as "a code I already have is live"
            // when THIS flow itself already confirmed sending one to this
            // exact address (e.g. the student backed out of the code screen
            // and re-entered the same address) — never on a flow's first-ever
            // `requestCode` call. Otherwise the cooldown may belong to an
            // older, possibly-expired or never-received attempt from a
            // different session/device, and jumping straight to code entry
            // would falsely claim "Code sent" and could strand the student on
            // an unusable screen with no code to find and resend blocked.
            guard replacementRecoveryEmail == nil, confirmedCodeEmails.contains(normalized) else {
                verificationError = .resendTooSoon
                return
            }
            // That earlier code is still the live one, so let them enter it
            // instead of stranding them on the email field. The backend still
            // decides whether it is valid; no identity exists until a redeem
            // succeeds. Expiry is not shown, so a lower bound is enough: a 10
            // minute code refused inside its 60 second cooldown has at least
            // 9 minutes left.
            let now = Date()
            flow?.stage = .awaitingCode(
                email: normalized,
                expiresAt: now.addingTimeInterval(9 * 60),
                resendAvailableAt: reopensAt ?? now.addingTimeInterval(60)
            )
        } catch {
            guard generation == verificationGeneration, flow != nil else { return }
            verificationError = ParticipantVerificationPresentationError.map(error)
        }
    }

    /// Backs out of the code step to the email step of the same flow, so a
    /// mistyped address can be corrected. Purely local: nothing is sent, no
    /// code or address is kept, the flow's purpose and any pending
    /// continuation are untouched, and the identity (verified or not) is not
    /// changed. A code already mailed stays the backend's to accept or expire.
    /// Refused while a request or redeem is in flight.
    func returnToEmailEntry() {
        guard case .awaitingCode? = flow?.stage,
              !isRequestingCode, !isSubmittingCode else { return }
        flow?.stage = .enteringEmail
        verificationError = nil
    }

    /// Resends the code for the address already being verified. A refusal
    /// inside the cooldown is reported and changes nothing — deliberately not
    /// retried, because the point of the cooldown is that one address is not
    /// mailed repeatedly.
    func resendCode() async {
        guard case .awaitingCode(let email, _, _)? = flow?.stage else { return }
        guard !isRequestingCode, !isSubmittingCode else { return }

        isRequestingCode = true
        let generation = verificationGeneration
        verificationError = nil
        defer {
            if generation == verificationGeneration { isRequestingCode = false }
        }

        do {
            let challenge = try await service.startVerification(
                email: email,
                replacingAuthority: replacingAuthority
            )
            guard generation == verificationGeneration,
                  case .awaitingCode(let current, _, _)? = flow?.stage,
                  current == email else { return }
            confirmedCodeEmails.insert(email)
            flow?.stage = .awaitingCode(
                email: email,
                expiresAt: challenge.expiresAt,
                resendAvailableAt: challenge.resendAvailableAt
            )
        } catch is CancellationError {
            return
        } catch ParticipantVerificationError.replacementBlocked {
            guard generation == verificationGeneration,
                  flow?.purpose == .emailReplacement else { return }
            await refuseReplacementForActivity(generation: generation)
        } catch {
            guard generation == verificationGeneration,
                  case .awaitingCode? = flow?.stage else { return }
            verificationError = ParticipantVerificationPresentationError.map(error)
        }
    }

    /// Submits a code. Returns `true` only after the backend has established
    /// authority *and* it has been remembered — the one signal a caller may
    /// treat as "this student is now verified".
    ///
    /// Every failure path returns `false` and leaves the previous identity, if
    /// any, exactly as it was. A replacement that fails, expires, or is refused
    /// does not destroy the identity it was replacing.
    @discardableResult
    func submitCode(_ code: String) async -> Bool {
        guard case .awaitingCode(let email, _, _)? = flow?.stage else { return false }
        guard !isRequestingCode, !isSubmittingCode else { return false }

        isSubmittingCode = true
        let generation = verificationGeneration
        verificationError = nil
        defer {
            if generation == verificationGeneration { isSubmittingCode = false }
        }

        do {
            let verified: VerifiedParticipantIdentity
            if let pendingVerifiedReplacement, pendingVerifiedReplacement.principal == email {
                verified = pendingVerifiedReplacement
            } else {
                verified = try await service.redeemVerification(
                    email: email,
                    code: code.trimmingCharacters(in: .whitespacesAndNewlines),
                    replacingAuthority: replacingAuthority
                )
                if generation == verificationGeneration, flow?.purpose == .emailReplacement {
                    pendingVerifiedReplacement = verified
                }
            }
            guard generation == verificationGeneration,
                  case .awaitingCode(let current, _, _)? = flow?.stage,
                  current == email else {
                // The flow was cancelled or restarted under this call. The
                // backend did verify, but applying it now would replace an
                // identity the student has since moved away from.
                return false
            }
            if flow?.purpose == .emailReplacement {
                prepareInstallationReplacement(verified.principal)
                try await installationAssociation(verified.authority)
                guard generation == verificationGeneration,
                      case .awaitingCode(let current, _, _)? = flow?.stage,
                      current == email else { return false }
            }
            guard adopt(verified) else {
                verificationError = .temporarilyUnavailable
                return false
            }
            return true
        } catch is CancellationError {
            return false
        } catch ParticipantVerificationError.replacementBlocked {
            guard generation == verificationGeneration,
                  flow?.purpose == .emailReplacement else { return false }
            await refuseReplacementForActivity(generation: generation)
            return false
        } catch {
            guard generation == verificationGeneration,
                  case .awaitingCode? = flow?.stage else { return false }
            verificationError = ParticipantVerificationPresentationError.map(error)
            return false
        }
    }

    /// Writes the confirmed identity, then publishes it.
    ///
    /// Storage first, deliberately. If persisting failed after the app had
    /// already started acting verified, the student would be verified until the
    /// next launch and silently not afterwards; this way the remembered state
    /// and the in-memory state come from the same successful write.
    ///
    /// The previous credential is replaced, not merged — a Change Email leaves
    /// no way to keep acting as the old principal — while requests and claims
    /// already created stay bound to whoever created them, because those
    /// bindings live on the backend and nothing here touches them.
    @discardableResult
    private func adopt(_ verified: VerifiedParticipantIdentity) -> Bool {
        let record = ParticipantIdentityRecord(
            principal: NYUEmailPolicy.normalize(verified.principal),
            authority: verified.authority,
            verifiedAt: now()
        )
        guard storage.save(record) else { return false }
        authority = record.authority
        if flow?.purpose == .emailReplacement { installationAssociationCompleted() }
        flow = nil
        confirmedCodeEmails = []
        // Publish identity last. A destination observing this change can now
        // consume its continuation immediately; it never sees verified
        // presentation paired with a still-running flow.
        identity = Self.presentation(for: record)
        verificationError = nil
        wasIdentityRevoked = false
        pendingVerifiedReplacement = nil
        return true
    }

    private static func presentation(
        for record: ParticipantIdentityRecord
    ) -> ParticipantIdentityPresentation {
        ParticipantIdentityPresentation(
            principal: record.principal,
            masked: maskedAddress(record.principal),
            verifiedAt: record.verifiedAt
        )
    }

    /// A recognizable but not fully spelled-out address.
    ///
    /// Enough for the student to confirm *which* of their addresses this is —
    /// the whole point of showing it — without printing a full address onto a
    /// screen someone may be reading over their shoulder. The domain stays
    /// intact because it is not the identifying part and hiding it would make
    /// the line useless for telling `@nyu.edu` from `@stern.nyu.edu`.
    static func maskedAddress(_ principal: String) -> String {
        let normalized = NYUEmailPolicy.normalize(principal)
        guard let separator = normalized.lastIndex(of: "@"),
              separator != normalized.startIndex else {
            return normalized
        }
        let local = String(normalized[normalized.startIndex..<separator])
        let domain = String(normalized[separator...])
        let visibleCount = local.count > 2 ? 2 : 1
        let visible = String(local.prefix(visibleCount))
        let hidden = String(repeating: "•", count: max(local.count - visibleCount, 1))
        return "\(visible)\(hidden)\(domain)"
    }
}
