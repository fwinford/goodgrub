//
//  ScreenshotAssistanceRuntime.swift
//  CommonPlateios
//
// W4-S3: the one shared Screenshot Assistance runtime, generic over a workflow
// adapter (`ScreenshotWorkflow`). It owns provider routing, local
// capability/qualification enforcement, the analysis lifecycle mechanics (it
// owns the attempt fence), the deadline on a local attempt, and the enforcement
// that no external transfer can begin without a single-use, current, exactly
// bound per-attempt permission. It accepts the complete ORDERED
// screenshot selection as one logical input and owns no workflow policy and no
// schema: eligibility, derived evidence, raw output shapes, validation, what an
// outcome may change, what the UI says, and when an external attempt is offered
// belong to the workflow adapter and the consuming store.
import Foundation

enum ScreenshotAssistanceDefaults {
    /// Finite bound on one local attempt so the manual form is never left
    /// waiting on the model. Engineering-owned; has not yet been derived from
    /// physical-device measurement (no production combination is qualified, so
    /// no production attempt reaches it).
    nonisolated static let localAttemptTimeout: Duration = .seconds(20)
}

/// A workflow evaluation stamped with the ATTEMPT that produced it. Only
/// `ScreenshotAssistanceRuntime.evaluate(_:for:)` can create one, so the token
/// it carries is the token of the attempt whose selection was evaluated: an
/// evaluation can never be paired with another attempt's token, another
/// fence's token, or a retired generation's, because the runtime compares the
/// two when it mints a transfer permission.
struct ScreenshotAttemptEvaluation<Derived> {
    /// The attempt this evaluation was produced for.
    let token: ScreenshotSelectionToken
    fileprivate let workflowEvaluation: ScreenshotWorkflowEvaluation<Derived>

    fileprivate init(token: ScreenshotSelectionToken, workflowEvaluation: ScreenshotWorkflowEvaluation<Derived>) {
        self.token = token
        self.workflowEvaluation = workflowEvaluation
    }

    /// The workflow-admitted screenshots, in selection order.
    var selection: ScreenshotSelection { workflowEvaluation.selection }
    /// The workflow's derived data.
    var derived: Derived { workflowEvaluation.derived }
}

/// The one-use flag behind a permission. A reference so that every copy of a
/// permission value shares the SAME use: copying a permission can never mint a
/// second transfer.
private final class ScreenshotExternalTransferUse {
    private var isConsumed = false

    var isUnused: Bool { !isConsumed }

    /// `true` exactly once.
    func consume() -> Bool {
        guard !isConsumed else { return false }
        isConsumed = true
        return true
    }
}

/// The requester's explicit permission for ONE external-AI transfer of the
/// currently selected screenshot set (the `Use external AI` tap). Minted only by
/// `ScreenshotAssistanceRuntime.authorizeExternalTransfer(for:evaluation:)`, and
/// it captures the attempt token it was granted for and the exact
/// attempt-stamped evaluation (the admitted screenshots and their derived data)
/// that was authorized, whose own origin token equals that token. `runExternal`
/// sends exactly that evaluation, only while the token is still current and only
/// once: a permission is never persisted, reused, or applicable to any other
/// selection or attempt.
///
/// A struct over a shared use flag rather than a generic class: a generic class
/// with its own deinit crashed the Swift 6.3 release optimizer
/// (`EarlyPerfInliner`) on the x86_64 simulator slice.
struct ScreenshotExternalTransferPermission<Workflow: ScreenshotWorkflow> {
    let token: ScreenshotSelectionToken
    fileprivate let evaluation: ScreenshotAttemptEvaluation<Workflow.Derived>
    private let use = ScreenshotExternalTransferUse()

    fileprivate init(token: ScreenshotSelectionToken, evaluation: ScreenshotAttemptEvaluation<Workflow.Derived>) {
        self.token = token
        self.evaluation = evaluation
    }

    fileprivate var isUnused: Bool { use.isUnused }

    /// `true` exactly once, across every copy of this permission.
    fileprivate func consume() -> Bool {
        use.consume()
    }
}

@MainActor
final class ScreenshotAssistanceRuntime<Workflow: ScreenshotWorkflow> {
    typealias Evaluation = ScreenshotAttemptEvaluation<Workflow.Derived>

    private let workflow: Workflow
    private let localProvider: (any ScreenshotLocalProvider<Workflow>)?
    private let externalProvider: any ScreenshotExternalProvider<Workflow>
    private let qualification: ScreenshotQualificationRegistry
    private let environment: ScreenshotDeviceEnvironment
    private let localAttemptTimeout: Duration

    /// The attempt fence (generation identity, cancellation, stale-result
    /// fencing) belongs to the runtime, and a consumer uses THIS fence. Every
    /// token it mints identifies it, which is what lets the runtime itself
    /// refuse a permission for a stale attempt or for another runtime's attempt.
    let fence = ScreenshotAttemptFence()

    /// `nil` qualification/environment resolve to the production values inside
    /// the initializer (default-argument expressions are not main-actor
    /// isolated, and these production values are).
    init(
        workflow: Workflow,
        localProvider: (any ScreenshotLocalProvider<Workflow>)?,
        externalProvider: any ScreenshotExternalProvider<Workflow>,
        qualification: ScreenshotQualificationRegistry? = nil,
        environment: ScreenshotDeviceEnvironment? = nil,
        localAttemptTimeout: Duration = ScreenshotAssistanceDefaults.localAttemptTimeout
    ) {
        self.workflow = workflow
        self.localProvider = localProvider
        self.externalProvider = externalProvider
        self.qualification = qualification ?? .production
        self.environment = environment ?? .current
        self.localAttemptTimeout = localAttemptTimeout
    }

    /// Deliberately explicit. With this project's default MainActor isolation
    /// (`SWIFT_DEFAULT_ACTOR_ISOLATION`), the compiler-synthesized deinit of ANY
    /// generic class crashes the Swift 6.3 release optimizer (`EarlyPerfInliner`,
    /// unbounded recursion in `isCallerAndCalleeLayoutConstraintsCompatible`) on
    /// every architecture, the device build included. Debug builds never notice.
    /// An explicit deinit avoids it here; the Release build is what catches it.
    deinit {}

    // MARK: - Evaluation (workflow policy, deterministic, on-device)

    /// Runs the workflow's eligibility policy and evidence derivation over the
    /// complete ordered selection of the attempt `token` identifies, and stamps
    /// the result with that token. `nil` means the whole selection is
    /// workflow-ineligible: no provider of either class may be invoked and no
    /// external-AI offer may be made for it. Nothing here leaves the device.
    func evaluate(_ selection: ScreenshotSelection, for token: ScreenshotSelectionToken) async -> Evaluation? {
        guard let evaluation = await workflow.evaluate(selection) else { return nil }
        return ScreenshotAttemptEvaluation(token: token, workflowEvaluation: evaluation)
    }

    // MARK: - Local

    /// Capability is two independent facts: is the model available, and is
    /// this exact combination qualified. Unknown combinations are not
    /// qualified.
    func localCapability() -> ScreenshotLocalCapability {
        guard let localProvider else {
            return ScreenshotLocalCapability(
                availability: .unavailable(.osTooOld),
                qualification: .notQualified
            )
        }
        return ScreenshotLocalCapability(
            availability: localProvider.availability(),
            qualification: localQualification(of: localProvider)
        )
    }

    /// Whether this provider's exact combination — workflow, provider, evidence
    /// strategy, the build-derived implementation fingerprint, OS major.minor,
    /// device — is in the closed qualification registry. Decided from CommonPlate's own registry alone; the provider is
    /// asked for its (static) identity and declared strategy, nothing more.
    private func localQualification(of provider: any ScreenshotLocalProvider<Workflow>) -> ScreenshotLocalQualification {
        qualification.qualification(
            for: ScreenshotQualificationKey(
                workflow: workflow.identity,
                provider: provider.identity,
                inputMode: provider.inputMode,
                implementationFingerprint: ScreenshotQualificationFingerprint.current
            ),
            environment: environment
        )
    }

    /// One local attempt. Never touches the network and never falls back to
    /// the external provider; the caller decides what an unavailable, failed,
    /// or empty result means.
    ///
    /// Qualification is decided FIRST. A provider whose exact combination is not
    /// qualified is not invoked and is not even asked whether it is available:
    /// with the empty production registry, no local model (Foundation Models
    /// included) is consulted at all. Availability is asked only of a
    /// qualified provider, and never substitutes for qualification.
    func runLocal(_ evaluation: Evaluation) async -> ScreenshotAnalysisAttemptResult<Workflow.Outcome> {
        guard let localProvider else { return .localUnavailable(.osTooOld) }
        guard localQualification(of: localProvider) == .qualified else {
            return .localUnavailable(nil)
        }
        switch localProvider.availability() {
        case .unavailable(let reason):
            return .localUnavailable(reason)
        case .available:
            break
        }

        do {
            try Task.checkCancellation()
            let input = ScreenshotProviderInput<Workflow>(
                selection: evaluation.selection,
                derived: evaluation.derived
            )
            let result = try await Self.withDeadline(localAttemptTimeout) {
                try await localProvider.extract(input)
            }
            try Task.checkCancellation()
            switch workflow.validateLocal(result, evaluation: evaluation.workflowEvaluation, strategy: localProvider.inputMode) {
            case .valid(let outcome, let evidence):
                return .completed(ScreenshotValidatedAnalysis(outcome: outcome, evidence: evidence))
            case .invalid:
                return .failed(ScreenshotAnalysisFailure.invalidProviderOutput)
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(error)
        }
    }

    // MARK: - External

    /// Mints the single-use permission for ONE external transfer of exactly
    /// `evaluation`, for exactly `token`. The consuming store calls this only
    /// from the requester's explicit `Use external AI` action for the currently
    /// selected screenshot set. Returns `nil`, minting nothing, unless `token`
    /// was minted by THIS runtime's fence, is still current, AND is the very
    /// attempt `evaluation` was produced for: an evaluation from another
    /// attempt, another fence, or a retired generation cannot be authorized
    /// under this token.
    func authorizeExternalTransfer(
        for token: ScreenshotSelectionToken,
        evaluation: Evaluation
    ) -> ScreenshotExternalTransferPermission<Workflow>? {
        guard fence.isCurrent(token), evaluation.token == token else { return nil }
        return ScreenshotExternalTransferPermission(token: token, evaluation: evaluation)
    }

    /// One external attempt, of exactly the evaluation `permission` captured.
    ///
    /// Everything that can refuse the transfer is decided here, in this order,
    /// with nothing sent and nothing observable done:
    /// 1. the permission is unused, its token is still current on this
    ///    runtime's fence, it is bound to the attempt its evaluation came from,
    ///    and it is consumed (`permissionUnavailable`) — so from here on ANY
    ///    refusal has spent it: one tap authorizes one transfer attempt;
    /// 2. participant authority, read NOW from `authority`, still exists
    ///    (`authorityUnavailable`);
    /// 3. the caller was not cancelled.
    /// Only then is the provider invoked. The result is re-validated by the
    /// workflow before it can become applyable. Whether a result that returns
    /// after the attempt was retired may still be used is the consuming store's
    /// decision.
    func runExternal(
        authority: @MainActor () -> String?,
        permission: ScreenshotExternalTransferPermission<Workflow>
    ) async throws -> ScreenshotValidatedAnalysis<Workflow.Outcome> {
        let evaluation = permission.evaluation
        guard permission.isUnused,
              fence.isCurrent(permission.token),
              evaluation.token == permission.token,
              permission.consume() else {
            throw ScreenshotAnalysisFailure.permissionUnavailable
        }
        guard let credential = authority() else {
            throw ScreenshotAnalysisFailure.authorityUnavailable
        }
        try Task.checkCancellation()
        let input = ScreenshotProviderInput<Workflow>(
            selection: evaluation.selection,
            derived: evaluation.derived
        )
        let result = try await externalProvider.analyze(input, authority: credential)
        try Task.checkCancellation()
        switch workflow.validateExternal(result, evaluation: evaluation.workflowEvaluation, strategy: externalProvider.inputMode) {
        case .valid(let outcome, let evidence):
            return ScreenshotValidatedAnalysis(outcome: outcome, evidence: evidence)
        case .invalid:
            throw ScreenshotAnalysisFailure.invalidProviderOutput
        }
    }

    // MARK: - Deadline

    /// Orchestration that regains control at whichever comes FIRST — the
    /// provider completing, the deadline, or the caller's task being cancelled —
    /// without waiting for the provider to cooperate.
    ///
    /// A structured construct (`TaskGroup`, `async let`) cannot do this: it does
    /// not return until every child has finished, so a provider that ignores
    /// cancellation would hold the runtime and the store hostage past the
    /// deadline. Instead the provider runs as an
    /// UNSTRUCTURED task that nothing awaits; a timer task races it; and a
    /// one-shot settlement resumes a checked continuation exactly once with
    /// whichever result arrives first. Cancelling the losing tasks is only a
    /// hint. A late provider completion finds the settlement already spent and
    /// is dropped: it has no path back to any state, popup, or proposal.
    ///
    /// This does NOT terminate the provider's computation. It bounds how long
    /// CommonPlate waits on it, and it fences the result.
    private static func withDeadline<Value>(
        _ timeout: Duration,
        operation: @escaping () async throws -> Value
    ) async throws -> Value {
        let settlement = ScreenshotDeadlineSettlement<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard settlement.install(continuation) else { return }
                let provider = Task {
                    do {
                        settlement.settle(.success(try await operation()))
                    } catch {
                        settlement.settle(.failure(error))
                    }
                }
                let timer = Task {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    settlement.settle(.failure(ScreenshotAnalysisFailure.timedOut))
                }
                settlement.attach {
                    provider.cancel()
                    timer.cancel()
                }
            }
        } onCancel: {
            settlement.settle(.failure(CancellationError()))
        }
    }
}

/// The one-shot state behind `withDeadline`: the first `settle` wins, later ones
/// (a late provider completion, a cancellation after the deadline) are no-ops.
/// Lock-protected and free of actor isolation so the cancellation handler can
/// settle it from any context without a hop; it never touches app state.
nonisolated final class ScreenshotDeadlineSettlement<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var isSettled = false
    private var continuation: CheckedContinuation<Value, Error>?
    /// Held only when settlement beat installation (the caller was already
    /// cancelled on entry).
    private var earlyResult: Result<Value, Error>?
    private var cancelHints: [() -> Void] = []

    /// `false` (having resumed `continuation` with the early result) when the
    /// settlement was already spent, so the caller starts no work at all.
    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if isSettled, let earlyResult {
            lock.unlock()
            continuation.resume(with: earlyResult)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    /// Registers the cancellation hint for the tasks this settlement races. If
    /// it is already settled the hint fires immediately.
    func attach(_ hint: @escaping () -> Void) {
        lock.lock()
        if isSettled {
            lock.unlock()
            hint()
            return
        }
        cancelHints.append(hint)
        lock.unlock()
    }

    func settle(_ result: Result<Value, Error>) {
        lock.lock()
        guard !isSettled else {
            lock.unlock()
            return
        }
        isSettled = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { earlyResult = result }
        let hints = cancelHints
        cancelHints = []
        lock.unlock()
        continuation?.resume(with: result)
        for hint in hints { hint() }
    }
}
