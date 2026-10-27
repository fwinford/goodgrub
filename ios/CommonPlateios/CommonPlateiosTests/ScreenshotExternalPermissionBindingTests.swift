//
//  ScreenshotExternalPermissionBindingTests.swift
//  CommonPlateiosTests
//
// W4-S3 Finding 3 and the rereview fixes: the SHARED RUNTIME itself enforces
// that an external-transfer permission is single-use, current, bound to the
// exact evaluation it authorized, and that evaluation is bound to the ATTEMPT
// that produced it — never replayable across attempts or fences, and never
// refusable-but-observable. It also reads participant authority at the transfer
// boundary. Every rejection case asserts the provider (the network boundary) was
// reached ZERO times.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class ScreenshotExternalPermissionBindingTests: XCTestCase {
    private typealias Runtime = ScreenshotAssistanceRuntime<RequesterOrderWorkflow>
    private typealias Permission = ScreenshotExternalTransferPermission<RequesterOrderWorkflow>

    private func makeRuntime() -> (runtime: Runtime, external: StubExternalProvider) {
        let external = StubExternalProvider()
        return (makeRequesterTestRuntime(local: nil, external: external), external)
    }

    /// The evaluation of a fresh attempt on `runtime`'s own fence (which retires
    /// the previous attempt, as a new selection does).
    private func evaluation(
        _ runtime: Runtime,
        texts: [String] = [ScreenshotTestEvidence.eligibleCart],
        firstByte: UInt8 = 1,
        token: ScreenshotSelectionToken? = nil
    ) async throws -> ScreenshotAttemptEvaluation<RequesterOrderEvidence> {
        let images = texts.enumerated().map { ScreenshotTestEvidence.input($0.element, byte: firstByte + UInt8($0.offset)) }
        return try await evaluated(runtime, try XCTUnwrap(ScreenshotSelection(images: images)), token: token)
    }

    private func permission(_ runtime: Runtime, for evaluation: ScreenshotAttemptEvaluation<RequesterOrderEvidence>) throws -> Permission {
        try XCTUnwrap(runtime.authorizeExternalTransfer(for: evaluation.token, evaluation: evaluation))
    }

    private func run(
        _ runtime: Runtime,
        _ permission: Permission,
        authority: String? = "a"
    ) async throws -> ScreenshotValidatedAnalysis<ScreenshotProposalOutcome> {
        try await runtime.runExternal(authority: { authority }, permission: permission)
    }

    private func assertRefused(
        _ expected: (ScreenshotAnalysisFailure) -> Bool,
        _ runtime: Runtime,
        _ permission: Permission,
        authority: String? = "a",
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await run(runtime, permission, authority: authority)
            XCTFail("\(message): must be refused", file: file, line: line)
        } catch let failure as ScreenshotAnalysisFailure {
            XCTAssertTrue(expected(failure), "\(message): wrong refusal \(failure)", file: file, line: line)
        } catch {
            XCTFail("\(message): unexpected error \(error)", file: file, line: line)
        }
    }

    private let isPermissionRefusal: (ScreenshotAnalysisFailure) -> Bool = {
        if case .permissionUnavailable = $0 { return true } else { return false }
    }
    private let isAuthorityRefusal: (ScreenshotAnalysisFailure) -> Bool = {
        if case .authorityUnavailable = $0 { return true } else { return false }
    }

    // MARK: - Happy path

    func testAPermissionForACurrentAttemptRunsTheProviderOnceWithExactlyTheAuthorizedEvaluation() async throws {
        let (runtime, external) = makeRuntime()
        let authorized = try await evaluation(runtime, texts: ["Your Pickup Order first", "Your Pickup Order second"], firstByte: 7)
        let permission = try permission(runtime, for: authorized)
        XCTAssertEqual(permission.token, authorized.token)
        XCTAssertEqual(external.analyzeCallCount, 0, "minting sends nothing")

        _ = try await run(runtime, permission)

        XCTAssertEqual(external.analyzeCallCount, 1)
        XCTAssertEqual(external.lastInput?.selection.items.map(\.index), [0, 1])
        XCTAssertEqual(external.lastImages.map { $0.data.first }, [7, 8], "exactly the authorized screenshots, in order")
    }

    func testAuthorityIsReadExactlyOnceAtTheTransferBoundaryBeforeTheProvider() async throws {
        let (runtime, external) = makeRuntime()
        let permission = try permission(runtime, for: try await evaluation(runtime))
        var authorityReads = 0
        var providerCallsAtRead: Int?

        _ = try await runtime.runExternal(
            authority: { authorityReads += 1; providerCallsAtRead = external.analyzeCallCount; return "a" },
            permission: permission
        )

        XCTAssertEqual(authorityReads, 1, "authority is read once, at the transfer boundary")
        XCTAssertEqual(providerCallsAtRead, 0, "authority is read before the provider is reached")
        XCTAssertEqual(external.analyzeCallCount, 1)
    }

    func testTheAuthorityValueTheProviderReceivesIsTheOneReadAtTheBoundary() async throws {
        let external = CredentialRecordingExternalProvider()
        let runtime = makeRequesterTestRuntime(local: nil, external: external)
        let permission = try permission(runtime, for: try await evaluation(runtime))
        var value = "read-at-tap"

        // The task cannot start until this test suspends, so the value set below
        // is what the runtime reads at the boundary.
        let analysis = Task { try await runtime.runExternal(authority: { value }, permission: permission) }
        value = "read-at-boundary"
        _ = try await analysis.value

        XCTAssertEqual(external.credentials, ["read-at-boundary"])
    }

    // MARK: - Replay

    func testAPermissionCannotBeReplayed() async throws {
        let (runtime, external) = makeRuntime()
        let permission = try permission(runtime, for: try await evaluation(runtime))

        _ = try await run(runtime, permission)
        await assertRefused(isPermissionRefusal, runtime, permission, "replay of a consumed permission")

        XCTAssertEqual(external.analyzeCallCount, 1, "the provider was reached exactly once")
    }

    func testAnEarlierAttemptsPermissionIsRefusedAfterALaterAttemptBegan() async throws {
        let (runtime, external) = makeRuntime()
        let first = try permission(runtime, for: try await evaluation(runtime))
        _ = try await run(runtime, first)

        let second = try permission(runtime, for: try await evaluation(runtime)) // a new attempt
        XCTAssertNotEqual(first.token, second.token)
        await assertRefused(isPermissionRefusal, runtime, first, "the earlier attempt's permission")
        XCTAssertEqual(external.analyzeCallCount, 1)

        _ = try await run(runtime, second)
        XCTAssertEqual(external.analyzeCallCount, 2, "each attempt needs its own permission")
    }

    // MARK: - The fence advanced after minting

    func testAPermissionIsRefusedOnceItsAttemptWasRetiredAfterMinting() async throws {
        let (runtime, external) = makeRuntime()
        let permission = try permission(runtime, for: try await evaluation(runtime))

        runtime.fence.retire() // Off, screen departure, or a replacement selection

        await assertRefused(isPermissionRefusal, runtime, permission, "fence advanced after minting")
        XCTAssertEqual(external.analyzeCallCount, 0, "the provider was never reached")
    }

    func testAPermissionIsRefusedWhenANewerAttemptBeganAfterMinting() async throws {
        let (runtime, external) = makeRuntime()
        let permission = try permission(runtime, for: try await evaluation(runtime))

        _ = runtime.fence.beginAttempt()

        await assertRefused(isPermissionRefusal, runtime, permission, "a newer attempt superseded it")
        XCTAssertEqual(external.analyzeCallCount, 0)
    }

    // MARK: - Stale token at mint

    func testMintingFromAStaleOrSupersededTokenCreatesNoPermission() async throws {
        let (runtime, external) = makeRuntime()
        let stale = try await evaluation(runtime)
        runtime.fence.retire()
        XCTAssertNil(runtime.authorizeExternalTransfer(for: stale.token, evaluation: stale))

        let older = try await evaluation(runtime)
        let newer = try await evaluation(runtime)
        XCTAssertNil(runtime.authorizeExternalTransfer(for: older.token, evaluation: older))
        XCTAssertNotNil(runtime.authorizeExternalTransfer(for: newer.token, evaluation: newer))
        XCTAssertEqual(external.analyzeCallCount, 0)
    }

    // MARK: - An evaluation is bound to the attempt that produced it

    func testAnEvaluationFromOneAttemptCannotBeAuthorizedUnderAnotherAttemptsToken() async throws {
        let (runtime, external) = makeRuntime()
        let evaluationA = try await evaluation(runtime, texts: ["Your Pickup Order attempt A"], firstByte: 10)
        let tokenB = runtime.fence.beginAttempt() // attempt B is now the current attempt

        XCTAssertTrue(runtime.fence.isCurrent(tokenB))
        XCTAssertNil(
            runtime.authorizeExternalTransfer(for: tokenB, evaluation: evaluationA),
            "evaluation A + token B must fail: the token is current, the evaluation is not B's"
        )
        XCTAssertNil(runtime.authorizeExternalTransfer(for: evaluationA.token, evaluation: evaluationA), "A itself is retired")
        XCTAssertEqual(external.analyzeCallCount, 0)

        // B's own evaluation, stamped with B's token, is what B may authorize.
        let evaluationB = try await evaluation(runtime, texts: ["Your Pickup Order attempt B"], firstByte: 20, token: tokenB)
        XCTAssertEqual(evaluationB.token, tokenB)
        let permission = try XCTUnwrap(runtime.authorizeExternalTransfer(for: tokenB, evaluation: evaluationB))
        _ = try await run(runtime, permission)
        XCTAssertEqual(external.lastImages.first?.data.first, 20, "the transfer is B's evaluation, never A's")
    }

    func testAnEvaluationFromARetiredGenerationCannotBeAuthorizedEvenWithTheCurrentToken() async throws {
        let (runtime, external) = makeRuntime()
        let retired = try await evaluation(runtime)
        runtime.fence.retire()
        let current = runtime.fence.beginAttempt()

        XCTAssertNil(runtime.authorizeExternalTransfer(for: current, evaluation: retired))
        XCTAssertEqual(external.analyzeCallCount, 0)
    }

    func testAnEvaluationEvaluatedAfterTheAttemptWasRetiredCannotBeAuthorized() async throws {
        let (runtime, _) = makeRuntime()
        let token = runtime.fence.beginAttempt()
        runtime.fence.retire()
        let late = try await evaluation(runtime, token: token) // stamped with a token that is already retired

        XCTAssertNil(runtime.authorizeExternalTransfer(for: token, evaluation: late))
    }

    // MARK: - A token, evaluation, or permission from a different fence

    func testATokenFromAnotherFenceCannotMintAPermissionEvenWithAMatchingGeneration() async throws {
        let (runtime, external) = makeRuntime()
        let own = try await evaluation(runtime)
        let foreign = ScreenshotAttemptFence().beginAttempt()
        XCTAssertEqual(foreign.generation, own.token.generation, "the generation numbers coincide; only the fence differs")

        XCTAssertNil(runtime.authorizeExternalTransfer(for: foreign, evaluation: own))
        XCTAssertFalse(runtime.fence.isCurrent(foreign))
        XCTAssertNotNil(runtime.authorizeExternalTransfer(for: own.token, evaluation: own))
        XCTAssertEqual(external.analyzeCallCount, 0)
    }

    func testAnEvaluationFromAnotherRuntimeCannotBeAuthorizedEvenWithAMatchingNumericGeneration() async throws {
        let (runtimeA, externalA) = makeRuntime()
        let (runtimeB, externalB) = makeRuntime()
        let evaluationB = try await evaluation(runtimeB)
        let tokenA = runtimeA.fence.beginAttempt()
        XCTAssertEqual(tokenA.generation, evaluationB.token.generation, "same numeric generation, different fence")

        XCTAssertNil(runtimeA.authorizeExternalTransfer(for: tokenA, evaluation: evaluationB))
        XCTAssertNil(runtimeA.authorizeExternalTransfer(for: evaluationB.token, evaluation: evaluationB), "B's token is foreign to A")
        XCTAssertEqual(externalA.analyzeCallCount, 0)
        XCTAssertEqual(externalB.analyzeCallCount, 0)
    }

    func testAPermissionMintedByOneRuntimeIsRefusedByAnother() async throws {
        let (runtimeA, externalA) = makeRuntime()
        let (runtimeB, externalB) = makeRuntime()
        let permission = try permission(runtimeA, for: try await evaluation(runtimeA))
        _ = runtimeB.fence.beginAttempt() // same generation number on the other fence

        await assertRefused(isPermissionRefusal, runtimeB, permission, "a permission from another runtime's fence")

        XCTAssertEqual(externalB.analyzeCallCount, 0)
        XCTAssertEqual(externalA.analyzeCallCount, 0, "and the refusal consumed nothing on its own runtime")
        _ = try await run(runtimeA, permission)
        XCTAssertEqual(externalA.analyzeCallCount, 1, "it is still valid on its own runtime, once")
    }

    // MARK: - Authority at the transfer boundary

    func testAuthorityMissingAtTheTransferBoundaryRefusesBeforeTheProvider() async throws {
        let (runtime, external) = makeRuntime()
        let permission = try permission(runtime, for: try await evaluation(runtime))

        await assertRefused(isAuthorityRefusal, runtime, permission, authority: nil, "authority absent at the boundary")

        XCTAssertEqual(external.analyzeCallCount, 0, "no provider call")
    }

    func testAnAuthorityRefusalSpendsThePermissionSoItCannotBeRetried() async throws {
        let (runtime, external) = makeRuntime()
        let permission = try permission(runtime, for: try await evaluation(runtime))
        await assertRefused(isAuthorityRefusal, runtime, permission, authority: nil, "authority absent")

        await assertRefused(isPermissionRefusal, runtime, permission, authority: "a", "a retry after authority returned")

        XCTAssertEqual(external.analyzeCallCount, 0)
    }

    func testAuthorityLostAlongsideRetirementIsRefusedAsAStalePermission() async throws {
        let (runtime, external) = makeRuntime()
        let permission = try permission(runtime, for: try await evaluation(runtime))
        runtime.fence.retire()

        await assertRefused(isPermissionRefusal, runtime, permission, authority: nil, "retired and without authority")

        XCTAssertEqual(external.analyzeCallCount, 0)
    }

    func testACancelledCallerIsRefusedBeforeTheProvider() async throws {
        let (runtime, external) = makeRuntime()
        let permission = try permission(runtime, for: try await evaluation(runtime))

        let attempt = Task { () -> Error? in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await run(runtime, permission); return nil } catch { return error }
        }
        let error = await attempt.value

        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(external.analyzeCallCount, 0)
    }

    // MARK: - The store: a refused transfer is invisible
    //
    // W4-S3 consent-authority revision: the offer decision and (when
    // authorized) the transfer both happen inside the one `analyzeScreenshot`
    // call now — there is no separate `offerPopup` + tap step to retire
    // between. `local: nil` reaches the fallback decision immediately, so
    // these fixtures still exercise exactly the store ↔ runtime boundary the
    // pre-revision popup tests did.

    private func makeStore() -> (store: ScreenshotProposalStore, external: StubExternalProvider) {
        let external = StubExternalProvider()
        let runtime = makeRequesterTestRuntime(local: nil, external: external)
        return (makeStoreOver(runtime), external)
    }

    func testTheStoreAndItsRuntimeShareOneFence() async throws {
        let external = StubExternalProvider()
        let runtime = makeRequesterTestRuntime(local: nil, external: external)
        let store = makeStoreOver(runtime)

        let token = beginAttempt(store)

        XCTAssertTrue(runtime.fence.isCurrent(token), "the store's tokens are the runtime fence's tokens")
        store.invalidateCurrentSelection()
        XCTAssertFalse(runtime.fence.isCurrent(token))
        XCTAssertFalse(store.isCurrent(token))
    }

    func testARetiredSelectionCannotProduceATransferThroughTheStore() async {
        let (store, external) = makeStore()
        let token = beginAttempt(store)

        store.invalidateCurrentSelection()
        let resolved = await store.analyzeScreenshot(
            images: [ScreenshotTestEvidence.input()],
            participantAuthority: { "an-authority" },
            token: token
        )

        XCTAssertNil(resolved)
        XCTAssertEqual(external.analyzeCallCount, 0)
    }

    func testConcurrentRetirementDuringTheAutomaticAttemptResultsInNoProviderCallAndNoStateMutation() async {
        let (store, external) = makeStore()
        let token = beginAttempt(store)
        let noticeBefore = store.notice

        // Queued before the call, so it has a chance to run at one of
        // `analyzeScreenshot`'s own internal suspension points — evidence
        // derivation, the local attempt, or immediately before the external
        // task runs, whichever the scheduler reaches first. Wherever it
        // lands, the fence must make the result unusable and the provider
        // unreached.
        let retire = Task { store.invalidateCurrentSelection() }
        let resolved = await store.analyzeScreenshot(
            images: [ScreenshotTestEvidence.input()],
            participantAuthority: { "an-authority" },
            token: token
        )
        await retire.value

        XCTAssertNil(resolved)
        XCTAssertFalse(store.isCurrent(token))
        XCTAssertEqual(external.analyzeCallCount, 0, "zero provider calls")
        XCTAssertEqual(store.notice, noticeBefore, "no state mutation from the rejected attempt")
        XCTAssertFalse(store.isApplying)
    }

    func testAuthorityDisappearingBetweenTheOfferDecisionAndTheTransferBoundarySendsNothing() async {
        let (store, external) = makeStore()
        let token = beginAttempt(store)
        // First read: the offer decision. Second read: the transfer boundary,
        // inside the runtime.
        let authority = BoundaryScriptedAuthority(["an-authority", nil])

        let resolved = await store.analyzeScreenshot(
            images: [ScreenshotTestEvidence.input()],
            participantAuthority: { authority.read() },
            token: token
        )

        XCTAssertNil(resolved, "the local outcome that caused the fallback (a notice) is presented, nothing to apply")
        XCTAssertEqual(authority.readCount, 2, "read at the offer decision and again at the transfer boundary")
        XCTAssertEqual(external.analyzeCallCount, 0)
        XCTAssertEqual(store.notice, .unavailable, "the accepted authority-loss treatment")
        XCTAssertFalse(store.isApplying)
        XCTAssertTrue(store.isCurrent(token))
    }

    func testAuthorityDisappearingAtTheBoundaryAlongsideRetirementPresentsNothing() async {
        let (store, external) = makeStore()
        let token = beginAttempt(store)
        let authority = BoundaryScriptedAuthority(["an-authority", nil])

        let retire = Task { store.invalidateCurrentSelection() }
        let resolved = await store.analyzeScreenshot(
            images: [ScreenshotTestEvidence.input()],
            participantAuthority: { authority.read() },
            token: token
        )
        await retire.value

        XCTAssertNil(resolved)
        XCTAssertEqual(external.analyzeCallCount, 0)
        XCTAssertNil(store.notice, "a retired attempt presents nothing")
    }

    func testAnAuthorizedTransferThroughTheStoreReachesTheProviderExactlyOnce() async {
        let (store, external) = makeStore()
        let token = beginAttempt(store)

        let resolved = await store.analyzeScreenshot(
            images: [ScreenshotTestEvidence.input()],
            participantAuthority: { "an-authority" },
            token: token
        )

        XCTAssertNotNil(resolved)
        XCTAssertEqual(external.analyzeCallCount, 1)
    }

    // MARK: - Source structure

    func testRunExternalTakesNoSeparateEvaluation() throws {
        let runtime = ScreenshotBoundarySource.codeLines(try ScreenshotBoundarySource.read(
            "ios/CommonPlateios/CommonPlateios/Services/ScreenshotAssistance/ScreenshotAssistanceRuntime.swift",
            from: #filePath
        ))
        let signature = try XCTUnwrap(runtime.range(of: "func runExternal("))
        let afterSignature = runtime[signature.lowerBound...]
        let head = String(afterSignature[..<(afterSignature.range(of: ") async throws")?.lowerBound ?? afterSignature.endIndex)])
        XCTAssertTrue(head.contains("authority: @MainActor () -> String?"), "authority is a provider read at the boundary")
        XCTAssertTrue(head.contains("permission: ScreenshotExternalTransferPermission<Workflow>"))
        XCTAssertFalse(head.contains("evaluation"), "the permission is the only source of what is sent")
        XCTAssertTrue(runtime.contains("let fence = ScreenshotAttemptFence()"), "the runtime owns the fence")

        // The order inside `runExternal`: validate + consume, read authority,
        // observe cancellation, then reach the provider.
        let body = String(runtime[signature.lowerBound...])
        let validate = try XCTUnwrap(body.range(of: "permission.consume()"))
        let readAuthority = try XCTUnwrap(body.range(of: "guard let credential = authority()"))
        let cancellation = try XCTUnwrap(body.range(of: "try Task.checkCancellation()"))
        let provider = try XCTUnwrap(body.range(of: "externalProvider.analyze("))
        XCTAssertLessThan(validate.lowerBound, readAuthority.lowerBound)
        XCTAssertLessThan(readAuthority.lowerBound, cancellation.lowerBound)
        XCTAssertLessThan(cancellation.lowerBound, provider.lowerBound)
    }

    func testAnEvaluationCanOnlyBeCreatedByTheRuntimeAndCarriesItsAttempt() throws {
        let runtime = ScreenshotBoundarySource.codeLines(try ScreenshotBoundarySource.read(
            "ios/CommonPlateios/CommonPlateios/Services/ScreenshotAssistance/ScreenshotAssistanceRuntime.swift",
            from: #filePath
        ))
        XCTAssertTrue(runtime.contains("fileprivate init(token: ScreenshotSelectionToken, workflowEvaluation"))
        XCTAssertTrue(runtime.contains("guard fence.isCurrent(token), evaluation.token == token else { return nil }"))
        XCTAssertTrue(runtime.contains("evaluation.token == permission.token"))
        XCTAssertTrue(runtime.contains("func evaluate(_ selection: ScreenshotSelection, for token: ScreenshotSelectionToken)"))
    }
}

/// An authority whose successive reads return successive scripted values.
@MainActor
final class BoundaryScriptedAuthority {
    private var values: [String?]
    private(set) var readCount = 0

    init(_ values: [String?]) {
        self.values = values
    }

    func read() -> String? {
        readCount += 1
        return values.isEmpty ? nil : values.removeFirst()
    }
}

/// An external provider that records the credential it was handed.
@MainActor
final class CredentialRecordingExternalProvider: ScreenshotExternalProvider {
    typealias Workflow = RequesterOrderWorkflow

    let identity = ScreenshotProviderIdentity.nonShipping(id: "test.credential-recording", strategyVersion: "1")
    let inputMode: ScreenshotInputMode = .directImageMultimodal
    private(set) var credentials: [String] = []

    func analyze(
        _ input: ScreenshotProviderInput<RequesterOrderWorkflow>,
        authority: String
    ) async throws -> ScreenshotProviderResult<ScreenshotProposalOutcome> {
        credentials.append(authority)
        return ScreenshotProviderResult(output: ScreenshotProposalOutcome(eligible: true, proposal: .empty))
    }
}
