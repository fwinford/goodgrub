//
//  ScreenshotDeadlineEnforcementTests.swift
//  CommonPlateiosTests
//
// W4-S3 ACTIVE / FIX, D1: at provider completion, the deadline, or outer
// cancellation — whichever comes first — CommonPlate regains orchestration
// control WITHOUT waiting for the provider to cooperate. The provider used here
// (`NonCooperativeLocalProvider`) ignores cancellation entirely: it stays
// suspended until the test releases it, which is exactly what a structured
// timeout (a task group that waits for its children) cannot survive.
//
// These cases do NOT claim the provider's computation is terminated: the
// provider keeps running after control returns, and each case proves what its
// late completion can and cannot do (nothing).
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class ScreenshotDeadlineEnforcementTests: XCTestCase {
    private let environment = testQualifiableEnvironment

    private func makeRuntime(
        local: any ScreenshotLocalProvider<RequesterOrderWorkflow>,
        external: StubExternalProvider? = nil,
        timeout: Duration
    ) -> ScreenshotAssistanceRuntime<RequesterOrderWorkflow> {
        makeRequesterTestRuntime(
            local: local,
            external: external ?? StubExternalProvider(),
            qualification: qualifiedRegistry(provider: local.identity, environment: environment),
            environment: environment,
            timeout: timeout
        )
    }

    private func evaluation(
        _ runtime: ScreenshotAssistanceRuntime<RequesterOrderWorkflow>
    ) async throws -> ScreenshotAttemptEvaluation<RequesterOrderEvidence> {
        try await evaluated(runtime, try XCTUnwrap(ScreenshotSelection(images: [ScreenshotTestEvidence.input()])))
    }

    private func isTimedOut(_ result: ScreenshotAnalysisAttemptResult<ScreenshotProposalOutcome>) -> Bool {
        if case .failed(let error) = result, case ScreenshotAnalysisFailure.timedOut = error { return true }
        return false
    }

    /// Awaits `task` but fails the test, rather than hanging, if it does not
    /// return within `limit` — the whole point of these cases is promptness.
    private func returnsPromptly<T: Sendable>(
        _ task: Task<T, Never>,
        within limit: Duration = .seconds(2),
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> T? {
        let finished = expectation(description: message)
        Task {
            _ = await task.value
            finished.fulfill()
        }
        let outcome = await XCTWaiter().fulfillment(of: [finished], timeout: Double(limit.components.seconds))
        guard outcome == .completed else {
            XCTFail("did not return promptly: \(message)", file: file, line: line)
            return nil
        }
        return await task.value
    }

    // MARK: - The deadline (decisive proof)

    func testTheDeadlineFiresAndRunLocalReturnsTimedOutWhileTheProviderIsStillRunning() async throws {
        let provider = NonCooperativeLocalProvider(output: usefulRequesterOutput)
        let runtime = makeRuntime(local: provider, timeout: .milliseconds(50))
        let evaluation = try await evaluation(runtime)

        let clock = ContinuousClock()
        let started = clock.now
        let result = await runtime.runLocal(evaluation)
        let elapsed = clock.now - started

        XCTAssertTrue(isTimedOut(result), "the runtime took its contract-defined timeout path")
        XCTAssertLessThan(elapsed, .seconds(2), "control returned at the deadline, not when the provider finished")
        XCTAssertEqual(provider.startCount, 1)
        XCTAssertTrue(provider.isRunning, "the provider is unreleased and still running")
        XCTAssertEqual(provider.completionCount, 0)

        // The provider now completes with a USEFUL result, long after the deadline.
        provider.release()
        await waitUntil("the abandoned provider finished") { provider.completionCount == 1 }
        await letScheduledWorkSettle()
        XCTAssertFalse(provider.isRunning)
    }

    func testAProviderThatFinishesBeforeTheDeadlineIsUnaffected() async throws {
        let local = StubLocalProvider(behavior: .delayed(.milliseconds(10), usefulRequesterOutput))
        let runtime = makeRuntime(local: local, timeout: .seconds(5))

        guard case .completed(let analysis) = await runtime.runLocal(try await evaluation(runtime)) else {
            return XCTFail("a provider that finishes first must complete")
        }
        XCTAssertFalse(analysis.outcome.isEmpty)
    }

    func testACooperativeHangStillTimesOutAtTheDeadline() async throws {
        let local = StubLocalProvider(behavior: .hang)
        let runtime = makeRuntime(local: local, timeout: .milliseconds(50))

        let result = await runtime.runLocal(try await evaluation(runtime))

        XCTAssertTrue(isTimedOut(result))
    }

    // MARK: - Outer cancellation

    func testOuterCancellationReturnsCancelledPromptlyBeforeTheProviderIsReleased() async throws {
        let provider = NonCooperativeLocalProvider(output: usefulRequesterOutput)
        let runtime = makeRuntime(local: provider, timeout: .seconds(30))
        let evaluation = try await evaluation(runtime)
        let attempt = Task { await runtime.runLocal(evaluation) }
        await waitUntil("the provider started") { provider.isRunning }

        attempt.cancel()
        let result = await returnsPromptly(attempt, "runLocal returns on cancellation without the provider")

        guard case .cancelled? = result else { return XCTFail("expected .cancelled, got \(String(describing: result))") }
        XCTAssertTrue(provider.isRunning, "the provider was never released")
        XCTAssertEqual(provider.completionCount, 0)
        provider.release()
        await waitUntil("the abandoned provider finished") { provider.completionCount == 1 }
    }

    func testACancelledCallerNeverStartsTheProvider() async throws {
        let provider = NonCooperativeLocalProvider(output: usefulRequesterOutput)
        let runtime = makeRuntime(local: provider, timeout: .seconds(30))
        let evaluation = try await evaluation(runtime)
        let attempt = Task {
            // Cancelled before it ever reaches the runtime.
            try? await Task.sleep(for: .seconds(30))
            return await runtime.runLocal(evaluation)
        }
        attempt.cancel()
        let result = await returnsPromptly(attempt, "a cancelled caller returns at once")

        guard case .cancelled? = result else { return XCTFail("expected .cancelled, got \(String(describing: result))") }
        XCTAssertEqual(provider.startCount, 0)
    }

    // MARK: - Settlement object: the first result settles exactly once

    private func settle<T>(
        _ settlement: ScreenshotDeadlineSettlement<T>,
        body: (ScreenshotDeadlineSettlement<T>) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            if settlement.install(continuation) { body(settlement) }
        }
    }

    func testTheFirstSettlementWinsAndLaterOnesAreDropped() async throws {
        let settlement = ScreenshotDeadlineSettlement<Int>()
        var hinted = 0
        let value = try await settle(settlement) { settlement in
            settlement.attach { hinted += 1 }
            settlement.settle(.success(1))
            settlement.settle(.success(2))
            settlement.settle(.failure(CancellationError()))
        }
        XCTAssertEqual(value, 1)
        XCTAssertEqual(hinted, 1, "the losing tasks are hinted to cancel exactly once")
    }

    func testAFailureThatSettlesFirstIsTheOnlyResult() async {
        let settlement = ScreenshotDeadlineSettlement<Int>()
        do {
            _ = try await settle(settlement) { settlement in
                settlement.settle(.failure(ScreenshotAnalysisFailure.timedOut))
                settlement.settle(.success(9))
            }
            XCTFail("the first, failing settlement must win")
        } catch ScreenshotAnalysisFailure.timedOut {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testASettlementSpentBeforeInstallationResumesImmediatelyAndStartsNothing() async {
        let settlement = ScreenshotDeadlineSettlement<Int>()
        settlement.settle(.failure(CancellationError()))
        var installed = true
        var hinted = false
        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
                installed = settlement.install(continuation)
            }
            XCTFail("a settled settlement must not yield a value")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
        settlement.attach { hinted = true }
        XCTAssertFalse(installed, "the caller starts no work")
        XCTAssertTrue(hinted, "a hint registered after settlement fires immediately")
    }

    // MARK: - Store: stale, retired and late results have no effect

    private func makeStore(
        provider: NonCooperativeLocalProvider,
        external: StubExternalProvider? = nil,
        timeout: Duration = .seconds(30)
    ) -> ScreenshotProposalStore {
        makeStoreOver(makeRuntime(local: provider, external: external, timeout: timeout))
    }

    private func analyze(
        _ store: ScreenshotProposalStore,
        token: ScreenshotSelectionToken,
        authority: String? = "an-authority"
    ) async -> ScreenshotProposalOutcome? {
        await store.analyzeScreenshot(
            images: [ScreenshotTestEvidence.input(ScreenshotTestEvidence.eligibleCartWithoutVendor)],
            participantAuthority: { authority },
            token: token
        )
    }

    func testATimedOutAttemptFallsThroughAutomaticallyAndAnyLateUsefulResultFromTheAbandonedProviderChangesNothing() async {
        let provider = NonCooperativeLocalProvider(output: usefulRequesterOutput)
        let external = StubExternalProvider(result: .success(ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(mealItems: [MealItem(name: "External Item")])
        )))
        let store = makeStore(provider: provider, external: external, timeout: .milliseconds(50))
        let token = beginAttempt(store)

        let outcome = await analyze(store, token: token)

        XCTAssertEqual(outcome?.proposal.mealItems, [MealItem(name: "External Item")], "falls through automatically at the deadline")
        XCTAssertNil(store.notice)
        XCTAssertFalse(store.isApplying)
        XCTAssertTrue(provider.isRunning)
        XCTAssertEqual(external.analyzeCallCount, 1)

        provider.release() // a USEFUL result, arriving after the deadline and after the external attempt already settled
        await waitUntil("the abandoned provider finished") { provider.completionCount == 1 }
        await letScheduledWorkSettle()

        XCTAssertFalse(store.isApplying)
        XCTAssertEqual(external.analyzeCallCount, 1, "the abandoned local provider's late result never triggers another external attempt")
    }

    func testATimeoutWithoutAuthorityPresentsTheUnavailableTreatmentAndALateResultChangesNothing() async {
        let provider = NonCooperativeLocalProvider(output: usefulRequesterOutput)
        let external = StubExternalProvider()
        let store = makeStore(provider: provider, external: external, timeout: .milliseconds(50))
        let token = beginAttempt(store)

        let outcome = await analyze(store, token: token, authority: nil)

        XCTAssertNil(outcome)
        XCTAssertEqual(store.notice, .unavailable)

        provider.release()
        await waitUntil("the abandoned provider finished") { provider.completionCount == 1 }
        await letScheduledWorkSettle()

        XCTAssertEqual(store.notice, .unavailable)
        XCTAssertEqual(external.analyzeCallCount, 0)
    }

    func testARetiredSelectionReturnsPromptlyAndALateResultCannotTouchTheNewSelection() async {
        let provider = NonCooperativeLocalProvider(output: usefulRequesterOutput)
        let external = StubExternalProvider()
        let store = makeStore(provider: provider, external: external)
        let token = beginAttempt(store)
        let attempt = Task { await analyze(store, token: token) }
        await waitUntil("the provider started") { provider.isRunning }
        XCTAssertTrue(store.isApplying)

        store.invalidateCurrentSelection()
        let result = await returnsPromptly(attempt, "a retired selection returns without the provider")

        XCTAssertEqual(result.map { $0 == nil }, true, "the retired attempt yields no outcome")
        XCTAssertTrue(provider.isRunning, "the provider was never released")
        XCTAssertFalse(store.isApplying)

        // A newer selection begins while the abandoned provider is still running.
        let newer = beginAttempt(store)
        provider.release()
        await waitUntil("the abandoned provider finished") { provider.completionCount == 1 }
        await letScheduledWorkSettle()

        XCTAssertTrue(store.isCurrent(newer))
        XCTAssertFalse(store.isApplying, "the abandoned attempt did not mark the new selection busy")
        XCTAssertNil(store.notice)
        XCTAssertEqual(external.analyzeCallCount, 0)
    }

    func testASelectionReplacedByANewOneReturnsPromptly() async {
        let provider = NonCooperativeLocalProvider(output: usefulRequesterOutput)
        let store = makeStore(provider: provider)
        let token = beginAttempt(store)
        let attempt = Task { await analyze(store, token: token) }
        await waitUntil("the provider started") { provider.isRunning }

        let newer = beginAttempt(store) // a replacement selection
        let result = await returnsPromptly(attempt, "a replaced selection returns without the provider")

        XCTAssertEqual(result.map { $0 == nil }, true)
        XCTAssertFalse(store.isCurrent(token))
        XCTAssertTrue(store.isCurrent(newer))
        XCTAssertTrue(provider.isRunning)
        provider.release()
        await waitUntil("the abandoned provider finished") { provider.completionCount == 1 }
    }

    func testALateResultFromTheAbandonedLocalProviderNeverTriggersASecondExternalAttempt() async {
        let provider = NonCooperativeLocalProvider(output: usefulRequesterOutput)
        let external = StubExternalProvider()
        let store = makeStore(provider: provider, external: external, timeout: .milliseconds(50))
        let token = beginAttempt(store)
        _ = await analyze(store, token: token) // times out, falls through, the one external attempt settles

        XCTAssertEqual(external.analyzeCallCount, 1)

        provider.release() // the abandoned local provider's late, useful result
        await waitUntil("the abandoned provider finished") { provider.completionCount == 1 }
        await letScheduledWorkSettle()

        XCTAssertEqual(external.analyzeCallCount, 1, "the late local result never triggers another external attempt")
        XCTAssertFalse(store.isApplying)
    }

    // MARK: - Mechanism structure

    func testTheDeadlineIsNotBuiltOnAStructuredConstructThatWaitsForItsChildren() throws {
        let runtime = ScreenshotBoundarySource.codeLines(try ScreenshotBoundarySource.read(
            "ios/CommonPlateios/CommonPlateios/Services/ScreenshotAssistance/ScreenshotAssistanceRuntime.swift",
            from: #filePath
        ))
        for waitsForChildren in ["withThrowingTaskGroup", "withTaskGroup", "withDiscardingTaskGroup", "async let"] {
            XCTAssertFalse(runtime.contains(waitsForChildren), "`\(waitsForChildren)` waits for non-cooperative children")
        }
        for required in ["withCheckedThrowingContinuation", "withTaskCancellationHandler", "ScreenshotDeadlineSettlement"] {
            XCTAssertTrue(runtime.contains(required), required)
        }
        XCTAssertTrue(runtime.contains("Self.withDeadline(localAttemptTimeout)"))
    }
}
