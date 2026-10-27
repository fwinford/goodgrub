import Combine
import Foundation

/// Which adopted CP9 surface (Figma board `1151:7504`) is showing. Every
/// modal returns to the app on Close; only completion/cleanup is full-screen.
enum ParticipantDeletionRoute: Equatable {
    /// C: an open request must be withdrawn first. No operation exists.
    case openRequest
    /// E/F: deletion must wait; the participant may start it now.
    case wait
    /// H: a started operation is still waiting.
    case inProgress
    /// I: the operation is ready (or past challenge) — the full-page hub.
    case ready
    /// J/K: code entry, then the final irreversible action.
    case verify
    /// Inline status: entry errors, unavailable recovery, unresolved completion.
    case status
}

enum ParticipantDeletionRowState: Equatable {
    case none, inProgress, readyToDelete
}

@MainActor
final class ParticipantDeletionStore: ObservableObject {
    @Published private(set) var route: ParticipantDeletionRoute?
    @Published private(set) var status: ParticipantDeletionStatus?
    @Published private(set) var isBusy = false
    @Published private(set) var isUnresolved = false
    @Published private(set) var isCompleted = false
    @Published private(set) var cleanupFailed = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var codeRequestFailed = false

    private let service: RequestService
    private let identity: ParticipantIdentityStore
    private let secureStorage: ParticipantDeletionSecureStorage
    private let freeze: ParticipantDeletionFreeze
    private let cleanup: ParticipantDeletionCleanup
    private let networkFence: ParticipantDeletionNetworkFence
    private let onboarding: OnboardingPresentationStore
    private let fenceNotificationIntents: () -> Void
    private let retirePresentation: () -> Void
    private let handoff: () -> Void
    private var record: ParticipantDeletionRecord? {
        didSet { hasRecord = record != nil }
    }
    @Published private(set) var hasRecord = false
    /// True while B → Delete Account is creating the operation and requesting
    /// the code, so the page behind does not flash a deletion status row.
    @Published private var isStartingVerification = false
    /// A B → Delete Account attempt that failed before J opened; closing its
    /// error cancels the attempt rather than leaving a status row behind.
    private var cancelsOnClose = false
    private var generation = UUID()
    private var failClosed = false
    private var surfacedGeneration: Int?
    private var lastAction: (() async -> Void)?

    var isPresented: Bool { route != nil || isCompleted || cleanupFailed }
    var isFullScreen: Bool { isCompleted || cleanupFailed }
    var canRetry: Bool { errorMessage != nil && lastAction != nil && !isBusy }
    var rowState: ParticipantDeletionRowState {
        guard let record, !isStartingVerification else { return .none }
        switch (record.stage, status?.phase) {
        case (.active, .ready?) where !freeze.isPresent: return .readyToDelete
        case (.active, .ready?): return .none
        // Verification is transient (leaving it cancels), so the page behind
        // J/K keeps the ordinary Delete row.
        case (.active, .challengeIssued?), (.active, .authorized?): return .none
        default: return .inProgress
        }
    }

    var maskedEmail: String? { identity.identity?.masked }
    /// Deletion code screen only (Faith 2026-10-25): the participant's own
    /// full address, so they know which inbox to check.
    var verificationEmail: String? { identity.identity?.principal }
    var canCancel: Bool {
        record?.stage == .active && !isBusy && !isCompleted
    }
    var canComplete: Bool {
        record?.stage == .active && record?.capability?.isEmpty == false && status?.phase == .authorized
    }

    /// Close on any modal or the I page. Never touches the record or freeze.
    func close() {
        guard !isFullScreen else { return }
        route = nil
        errorMessage = nil
        lastAction = nil
        if cancelsOnClose, record != nil {
            Task { await self.cancelFailedStart() }
        }
    }

    /// Keep My Account on the request blocker: an existing operation is
    /// cancelled authoritatively; otherwise there is nothing to undo.
    func keepAccount() async {
        guard !isFullScreen else { return }
        if record != nil {
            await cancel()
        } else {
            close()
        }
    }

    private func cancelFailedStart() async {
        await cancel()
        errorMessage = nil
        lastAction = nil
    }

    func retry() async {
        guard let action = lastAction, !isBusy else { return }
        await action()
    }

    init(
        service: RequestService,
        identity: ParticipantIdentityStore,
        secureStorage: ParticipantDeletionSecureStorage,
        defaults: UserDefaults,
        networkFence: ParticipantDeletionNetworkFence,
        onboarding: OnboardingPresentationStore,
        fenceNotificationIntents: @escaping () -> Void,
        retirePresentation: @escaping () -> Void,
        handoff: @escaping () -> Void
    ) {
        self.service = service
        self.identity = identity
        self.secureStorage = secureStorage
        self.freeze = ParticipantDeletionFreeze(defaults: defaults)
        self.cleanup = ParticipantDeletionCleanup(defaults: defaults)
        self.networkFence = networkFence
        self.onboarding = onboarding
        self.fenceNotificationIntents = fenceNotificationIntents
        self.retirePresentation = retirePresentation
        self.handoff = handoff
        switch secureStorage.load() {
        case .record(let restored):
            identity.holdForDeletion()
            let phase = restored.status?.phase
            let frozen = freeze.isPresent || restored.stage != .active ||
                phase == .challengeIssued || phase == .authorized
            if frozen {
                networkFence.setFrozen(true)
                identity.freezeForDeletion()
            }
            do {
                if frozen { try freeze.write(restored.context.freezeID) }
                record = restored
                status = restored.status
                isUnresolved = restored.stage == .completing
                if restored.stage == .completing { route = .status }
            } catch {
                failClosed(Self.recoveryUnavailable)
            }
        case .unavailable:
            failClosed(Self.recoveryUnavailable)
        case .absent:
            if freeze.isPresent { failClosed(Self.recoveryUnavailable) }
        }
    }

    private static let recoveryUnavailable =
        "Account deletion recovery is unavailable on this device. Your account status has not been confirmed."

    private func failClosed(_ message: String) {
        failClosed = true
        route = .status
        errorMessage = message
        networkFence.setFrozen(true)
        identity.freezeForDeletion()
    }

    /// Privacy & Safety row tap when a deletion already exists (G). Returns
    /// `false` when there is none, so the caller presents the B confirmation.
    func openExisting() async -> Bool {
        if failClosed {
            route = .status
            errorMessage = Self.recoveryUnavailable
            lastAction = nil
            return true
        }
        guard let record else { return false }
        switch record.stage {
        case .completing:
            route = .status
            await recover()
        case .completedCleanupPending:
            resumeCleanup()
        case .active:
            if hasAbandonedVerification {
                await cancel()
                if record != nil { route = .status }
                return record != nil
            }
            route = surfaceRoute(for: status?.phase) ?? .inProgress
            await refresh()
        }
        return true
    }

    /// Launch, foreground and Privacy & Safety appearance. Silent: errors
    /// never pop a modal here. Surfaces I once per readiness generation. A
    /// verification left unfinished (J/K not visible) is never reopened; it
    /// is canceled authoritatively so the next attempt starts again at B.
    func reconcile() async {
        guard !isBusy, let record else { return }
        if record.stage != .active || route != nil {
            await refresh()
            return
        }
        await refresh()
        if route == nil { errorMessage = nil; lastAction = nil }
        if route == nil, hasAbandonedVerification {
            await cancel()
            errorMessage = nil
            lastAction = nil
            return
        }
        if route == nil, let status, surfaceRoute(for: status.phase) == .ready,
           surfacedGeneration != status.readinessGeneration {
            surfacedGeneration = status.readinessGeneration
            route = .ready
        }
    }

    /// The freeze is written only when a code is requested, so a frozen
    /// active record is a started verification even after the backend has
    /// demoted an expired challenge/authorization back to `ready`.
    private var hasAbandonedVerification: Bool {
        guard record?.stage == .active else { return false }
        return status?.phase == .challengeIssued || status?.phase == .authorized || freeze.isPresent
    }

    /// J/K close. Leaving verification cancels the deletion authoritatively;
    /// a failed cancel stays visible with Try Again, and Close leaves the
    /// remaining cancel to the next reconcile.
    func abandonVerification() async {
        guard route == .verify, !isBusy else { return }
        await cancel()
        if record != nil { route = .status }
    }

    private func surfaceRoute(for phase: ParticipantDeletionPhase?) -> ParticipantDeletionRoute? {
        switch phase {
        case .ready?: return .ready
        case .challengeIssued?, .authorized?: return .verify
        case .waiting?: return .inProgress
        default: return nil
        }
    }

    /// B → Delete Account. Read-only eligibility first: no record, operation
    /// or freeze exists unless the participant may start deletion. When the
    /// participant is eligible immediately, the code is requested and J opens
    /// directly; I is only for a participant who had to wait.
    func begin() async {
        // A repeated B tap while a deletion surface is up must never cancel
        // and recreate the live verification behind it.
        guard !isBusy, !failClosed, route == nil else { return }
        if record != nil, hasAbandonedVerification || cancelsOnClose {
            // Only reachable after a failed verification cancel left the record.
            await cancel()
            guard record == nil else {
                route = .status
                return
            }
        }
        guard record == nil else { return }
        lastAction = { [weak self] in await self?.begin() }
        var startedImmediately = false
        isStartingVerification = true
        defer { settleStartAttempt() }
        await perform(presenting: .status) {
            guard let authority = self.identity.currentAuthority() else {
                throw ParticipantDeletionError.identityChanged
            }
            let eligibility = try await self.service.deletionEligibility(authority: authority)
            // Decision 10: requester and helper/pickup blockers share one
            // "finish your request first" modal; only `unknown` can wait.
            if eligibility.categories.contains(.activeRequest)
                || eligibility.categories.contains(.activeHelpingOrPickup) {
                self.route = .openRequest
            } else if !eligibility.eligible {
                self.route = .wait
            } else {
                self.lastAction = { [weak self] in await self?.resumeStart() }
                try await self.createAndStart()
                startedImmediately = true
            }
            self.lastAction = nil
        }
        if startedImmediately { await continueToVerification() }
    }

    private func resumeStart() async {
        isStartingVerification = true
        defer { settleStartAttempt() }
        var started = false
        await perform {
            try await self.createAndStart()
            started = true
            self.lastAction = nil
        }
        if started { await continueToVerification() }
    }

    /// After an immediate attempt: success or a blocker route clears the
    /// suppression; a failure that left a record keeps the Delete row and
    /// marks the attempt to be canceled when its error is closed.
    private func settleStartAttempt() {
        if record != nil, route == .status {
            cancelsOnClose = true
        } else {
            cancelsOnClose = false
            isStartingVerification = false
        }
    }

    private func continueToVerification() async {
        isStartingVerification = true
        defer { settleStartAttempt() }
        guard status?.phase == .ready else {
            route = surfaceRoute(for: status?.phase) ?? .inProgress
            return
        }
        await requestCode()
        if status?.phase == .challengeIssued, errorMessage == nil {
            route = .verify
        } else {
            lastAction = { [weak self] in await self?.continueToVerification() }
            if route == nil { route = .status }
        }
    }

    /// E/F → Start Account Deletion. Returns to Privacy & Safety (G row).
    func startDeletion() async {
        guard !isBusy, route == .wait, !failClosed else { return }
        lastAction = { [weak self] in await self?.startDeletion() }
        await perform {
            try await self.createAndStart()
            self.lastAction = nil
            self.route = nil
        }
    }

    private func createAndStart() async throws {
        if record == nil {
            let owner = try identity.prepareDeletion()
            let context = ParticipantDeletionContext(
                freezeID: UUID().uuidString, participantID: owner.participantID,
                identityBinding: owner.binding, origin: service.operationAuthorityOrigin,
                operationID: nil, namespace: nil, attestedLedger: nil
            )
            let value = ParticipantDeletionRecord(context: context, stage: .active, status: nil, capability: nil)
            try secureStorage.save(value)
            record = value
            identity.holdForDeletion()
        }
        guard let record, record.context.operationID == nil else { return }
        let current = try await service.startDeletion(authority: authority(for: record.context))
        try apply(current)
    }

    /// Establishes the installation freeze durably before any challenge is
    /// requested; it persists until authoritative cancellation or completion.
    private func establishFreeze() throws {
        guard let record else { throw ParticipantDeletionError.storageUnavailable }
        try freeze.write(record.context.freezeID)
        networkFence.setFrozen(true)
        identity.freezeForDeletion()
    }

    func refresh() async {
        guard !isBusy, let record else { return }
        lastAction = { [weak self] in await self?.refresh() }
        if record.stage == .completedCleanupPending {
            resumeCleanup()
            return
        }
        if record.stage == .completing {
            await recover()
            return
        }
        await perform {
            try self.secureStorage.save(record)
            let authority = try self.authority(for: record.context)
            if let operationID = record.context.operationID, let namespace = record.context.namespace {
                let current = try await self.service.deletionStatus(
                    operationID: operationID, namespace: namespace, authority: authority
                )
                try self.apply(current)
            } else {
                _ = try await self.service.deletionEligibility(authority: authority)
                let current = try await self.service.startDeletion(authority: authority)
                try self.apply(current)
            }
            try self.settleRoute()
        }
    }

    /// Keeps the visible surface consistent with authoritative phase, and
    /// releases locally only on an authoritative cancellation.
    private func settleRoute() throws {
        switch status?.phase {
        case .canceled?:
            try releaseCanceled()
        case .waiting?:
            if route == .ready || route == .verify { route = .inProgress }
        case .ready?:
            if route == .inProgress || route == .verify { route = .ready }
        case .challengeIssued?, .authorized?:
            if route == .inProgress { route = .verify }
        case .completed?, nil:
            break
        }
    }

    /// I → Verify It's You.
    func openVerification() async {
        guard let phase = status?.phase, record?.stage == .active else { return }
        switch phase {
        case .ready:
            await requestCode()
            if status?.phase == .challengeIssued { route = .verify }
        case .challengeIssued, .authorized:
            route = .verify
        default:
            break
        }
    }

    func requestCode() async {
        guard let status, status.phase == .ready || status.phase == .challengeIssued,
              record?.stage == .active else { return }
        let isInitialRequest = status.phase == .ready
        lastAction = { [weak self] in await self?.requestCode() }
        await perform {
            guard let context = self.record?.context else { throw ParticipantDeletionError.storageUnavailable }
            try self.establishFreeze()
            let current = try await self.service.challengeDeletion(
                status: status, authority: self.authority(for: context)
            )
            try self.apply(current)
        }
        if isInitialRequest {
            codeRequestFailed = errorMessage != nil
            if codeRequestFailed {
                route = .status
            } else if self.status?.phase == .challengeIssued {
                route = .verify
            }
        }
    }

    func redeem(code: String) async {
        guard let status, status.phase == .challengeIssued, record?.stage == .active else { return }
        lastAction = nil
        await perform {
            guard let context = self.record?.context else { throw ParticipantDeletionError.storageUnavailable }
            let result = try await self.service.redeemDeletion(
                status: status, code: code, authority: self.authority(for: context)
            )
            try self.apply(result.status, capability: result.capability)
        }
    }

    func cancel() async {
        guard canCancel else { return }
        lastAction = { [weak self] in await self?.cancel() }
        await perform {
            // A start response may have been lost. Resolve it first (start is
            // create-or-reconcile); absence of a local id never means no
            // backend operation.
            try await self.createAndStart()
            guard let record = self.record,
                  let operationID = record.context.operationID,
                  let namespace = record.context.namespace else {
                throw ParticipantDeletionError.unresolved
            }
            let canceled = try await self.service.cancelDeletion(
                operationID: operationID, namespace: namespace,
                authority: self.authority(for: record.context)
            )
            guard canceled.phase == .canceled else { throw ParticipantDeletionError.invalidResponse }
            try self.apply(canceled)
            try self.releaseCanceled()
        }
    }

    private func releaseCanceled() throws {
        guard let record, record.stage == .active, status?.phase == .canceled else {
            throw ParticipantDeletionError.unresolved
        }
        try freeze.remove(record.context.freezeID)
        try secureStorage.remove()
        self.record = nil
        isBusy = false
        generation = UUID()
        identity.restoreAfterCanceledDeletion()
        networkFence.setFrozen(false)
        cancelsOnClose = false
        isStartingVerification = false
        route = nil
        lastAction = nil
        status = nil
    }

    func complete() async {
        guard let record, record.stage == .active, let status,
              status.phase == .authorized, let capability = record.capability else { return }
        lastAction = { [weak self] in await self?.refresh() }
        await perform {
            let authority = try self.authority(for: record.context)
            var prepared = record
            var matching: String?
            for ledger in self.cleanup.recordedLedgers().sorted() {
                if try await self.service.compareDeletionLedger(
                    status: status, recordedLedger: ledger, authority: authority
                ) {
                    guard matching == nil || matching == ledger else {
                        throw ParticipantDeletionError.invalidResponse
                    }
                    matching = ledger
                }
            }
            prepared.context.attestedLedger = matching
            prepared.stage = .completing
            try self.secureStorage.save(prepared)
            self.record = prepared
            self.isUnresolved = true
            self.lastAction = { [weak self] in await self?.recover() }
            do {
                try await self.service.completeDeletion(
                    status: status, capability: capability, authority: authority
                )
            } catch {
                // Only CP8's explicit no-commit decisions release the final
                // transmission barrier. Transport/generic failures never do.
                if case APIClientError.apiError(let code, _) = error,
                   ["DELETION_OPERATION_STALE", "DELETION_NOT_READY",
                    "DELETION_AUTHORIZATION_EXPIRED", "DELETION_CAPABILITY_INVALID",
                    "DELETION_BLOCKED"].contains(code) {
                    prepared.stage = .active
                    prepared.capability = nil
                    try self.secureStorage.save(prepared)
                    self.record = prepared
                    self.isUnresolved = false
                    self.lastAction = { [weak self] in await self?.refresh() }
                } else {
                    self.route = .status
                }
                throw error
            }
            try self.learnCompletion()
        }
    }

    func recover() async {
        guard let record, record.stage == .completing,
              let operationID = record.context.operationID,
              let namespace = record.context.namespace,
              let capability = record.capability else { return }
        lastAction = { [weak self] in await self?.recover() }
        await perform {
            guard record.context.origin == self.service.operationAuthorityOrigin else {
                throw ParticipantDeletionError.identityChanged
            }
            try await self.service.recoverDeletion(
                operationID: operationID, namespace: namespace, capability: capability
            )
            try self.learnCompletion()
        }
    }

    func resumeCleanup() {
        guard !isBusy, record?.stage == .completedCleanupPending else { return }
        do {
            try finishCleanup()
        } catch {
            cleanupFailed = true
            errorMessage = "Your account was deleted, but cleanup on this device is incomplete. Retry local cleanup before continuing."
        }
    }

    func done() {
        guard isCompleted, !isBusy, !cleanupFailed else { return }
        // The checked reset has already completed under the startup barrier.
        // Done invokes the same accepted seam idempotently, then publishes it.
        do {
            try onboarding.resetFirstUsePresentationChecked()
            isCompleted = false
            route = nil
            handoff()
        } catch {
            errorMessage = "The Welcome screen could not be reset on this device. Please try Done again."
        }
    }

    private func learnCompletion() throws {
        guard let record else { throw ParticipantDeletionError.storageUnavailable }
        fenceNotificationIntents()
        identity.fenceCompletedDeletion(participantID: record.context.participantID)
        if !identity.hasDifferentParticipant(than: record.context.participantID) { retirePresentation() }
        let journal = record.cleanupJournal
        self.record = journal
        status = nil
        do {
            try secureStorage.save(journal)
        } catch {
            // Do not intentionally retain a bearer for local cleanup.
            try secureStorage.remove()
            cleanupFailed = true
            throw error
        }
        try finishCleanup()
    }

    private func finishCleanup() throws {
        guard let journal = record, journal.stage == .completedCleanupPending,
              journal.isValid else { throw ParticipantDeletionError.storageUnavailable }
        fenceNotificationIntents()
        identity.fenceCompletedDeletion(participantID: journal.context.participantID)
        let foreignParticipant = identity.hasDifferentParticipant(than: journal.context.participantID)
        if !foreignParticipant { retirePresentation() }
        // A prior journal replacement may have failed: re-establish only the
        // already-known-completed, bearer-free journal before cleanup retry.
        try secureStorage.save(journal)
        _ = try cleanup.run(journal: journal, retireUnboundPresentation: false)
        let identityResult = try identity.cleanupCompletedDeletion(
            participantID: journal.context.participantID, binding: journal.context.identityBinding
        )
        guard case .record(let persisted) = secureStorage.load(),
              persisted == journal, persisted.capability == nil else {
            throw ParticipantDeletionError.storageUnavailable
        }
        if foreignParticipant || identityResult == .preservedForeign {
            try freeze.remove(journal.context.freezeID)
            try secureStorage.remove()
            record = nil
            identity.restoreAfterCanceledDeletion()
            networkFence.setFrozen(false)
            route = nil
            cleanupFailed = false
            isUnresolved = false
            errorMessage = nil
            return
        }
        try ParticipantLocalPresentationStorage.retire(
            defaults: cleanup.defaults, generation: journal.context.freezeID
        )
        try onboarding.resetFirstUsePresentationChecked()
        try freeze.remove(journal.context.freezeID)
        try secureStorage.remove()
        self.record = nil
        cleanupFailed = false
        isUnresolved = false
        errorMessage = nil
        lastAction = nil
        route = nil
        isCompleted = true
    }

    private func authority(for context: ParticipantDeletionContext) throws -> String {
        guard context.origin == service.operationAuthorityOrigin,
              let authority = identity.deletionAuthority(participantID: context.participantID) else {
            throw ParticipantDeletionError.identityChanged
        }
        return authority
    }

    private func apply(_ status: ParticipantDeletionStatus, capability: String? = nil) throws {
        guard var value = record, value.stage == .active else { throw ParticipantDeletionError.unresolved }
        _ = try status.validated(operationID: value.context.operationID, namespace: value.context.namespace)
        let previousStatus = value.status
        value.context.operationID = status.operationId
        value.context.namespace = status.namespaceBinding
        value.status = status.withoutCapability()
        if status.phase == .authorized {
            value.capability = capability ??
                (previousStatus?.phase == .authorized &&
                 previousStatus?.readinessGeneration == status.readinessGeneration &&
                 previousStatus?.authorization == status.authorization ? value.capability : nil)
        } else {
            value.capability = nil
        }
        try secureStorage.save(value)
        record = value
        self.status = value.status
    }

    private func perform(
        presenting fallback: ParticipantDeletionRoute? = nil,
        _ operation: () async throws -> Void
    ) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        codeRequestFailed = false
        let expected = generation
        defer { if generation == expected { isBusy = false } }
        do {
            try await operation()
        } catch {
            if generation == expected {
                if record?.stage == .completedCleanupPending { cleanupFailed = true }
                errorMessage = message(for: error)
                if route == nil, let fallback { route = fallback }
            }
        }
    }

    private func message(for error: Error) -> String {
        if cleanupFailed {
            return "Your account was deleted, but cleanup on this device is incomplete. Retry local cleanup before continuing."
        }
        if isUnresolved {
            return "We could not confirm whether account deletion completed. Check deletion status; do not start another deletion."
        }
        if case APIClientError.apiError(let code, let message) = error {
            if code == "DELETION_CHALLENGE_COOLDOWN" {
                return "Please wait a moment before trying again."
            }
            return message
        }
        return "Account deletion is temporarily unavailable. Your account has not been confirmed deleted."
    }
}
