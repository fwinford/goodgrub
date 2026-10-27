//
//  ScreenshotFallbackAuthorityTimingTests.swift
//  CommonPlateiosTests
//
// W4-S3 ACTIVE / FIX, Finding 1 (carried over by the W4-S3 consent-authority
// revision): the automatic external fallback attempt may proceed only if the
// requester's participant authority is CURRENT at the moment the offer
// decision is made — after evidence derivation (OCR) and the local attempt —
// not as it was when analysis started. Each case would otherwise fall through
// automatically: the local attempt fails (or yields nothing), so an
// authorized requester's attempt proceeds to the external provider.
//
// Driven against the real `ScreenshotProposalStore` and shared runtime with
// synthetic evidence. Authority is a value a test changes while a stage is
// running; the store reads it through the provider `analyzeScreenshot` receives.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class ScreenshotFallbackAuthorityTimingTests: XCTestCase {
    private let environment = testQualifiableEnvironment

    private struct Fixture {
        let store: ScreenshotProposalStore
        let external: StubExternalProvider
        let authority: AuthorityBox
    }

    private func makeFixture(
        local: (any ScreenshotLocalProvider<RequesterOrderWorkflow>)?,
        recognizer: any ScreenshotTextRecognizing = SyntheticTextRecognizer(),
        qualified: Bool = true,
        timeout: Duration = .seconds(5),
        authority: AuthorityBox? = nil
    ) -> Fixture {
        let authority = authority ?? AuthorityBox()
        let external = StubExternalProvider()
        let runtime = makeRequesterTestRuntime(
            local: local,
            external: external,
            qualification: qualified
                ? qualifiedRegistry(provider: local?.identity ?? StubLocalProvider.stubIdentity, environment: environment)
                : .production,
            environment: environment,
            timeout: timeout,
            recognizer: recognizer
        )
        return Fixture(store: makeStoreOver(runtime), external: external, authority: authority)
    }

    private func analyze(_ fixture: Fixture, token: ScreenshotSelectionToken) async -> ScreenshotProposalOutcome? {
        await fixture.store.analyzeScreenshot(
            images: [ScreenshotTestEvidence.input(ScreenshotTestEvidence.eligibleCartWithoutVendor)],
            participantAuthority: { fixture.authority.read() },
            token: token
        )
    }

    private func assertNoExternalCallAndNothingSent(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fixture.external.analyzeCallCount, 0, "nothing is sent externally", file: file, line: line)
        XCTAssertNotEqual(fixture.store.notice, .verificationRequired, file: file, line: line)
        XCTAssertNotEqual(fixture.store.notice, .verificationExpired, file: file, line: line)
    }

    // MARK: - Present throughout → falls through automatically

    func testAuthorityPresentThroughoutFallsThroughAndReadsAuthorityAtTheOfferDecisionAndAgainAtTheTransferBoundary() async {
        let authority = AuthorityBox()
        var readsWhileLocalAttemptRan: Int?
        let local = StubLocalProvider(behavior: .fail(StubLocalProvider.StubError()))
        local.onExtract = { readsWhileLocalAttemptRan = authority.readCount }
        let fixture = makeFixture(local: local, authority: authority)
        let token = beginAttempt(fixture.store)

        let outcome = await analyze(fixture, token: token)

        XCTAssertNotNil(outcome, "falls through automatically to the external attempt under standing consent")
        XCTAssertEqual(readsWhileLocalAttemptRan, 0, "authority is not read before the local attempt finishes")
        XCTAssertEqual(authority.readCount, 2, "authority is read once at the offer decision and once at the transfer boundary")
        XCTAssertEqual(fixture.external.analyzeCallCount, 1)
    }

    func testAuthorityPresentThroughoutFallsThroughForAnEmptyLocalResultToo() async {
        let local = StubLocalProvider(behavior: .output(emptyRequesterOutput))
        let fixture = makeFixture(local: local)
        let token = beginAttempt(fixture.store)

        let outcome = await analyze(fixture, token: token)

        XCTAssertNotNil(outcome)
        XCTAssertEqual(fixture.external.analyzeCallCount, 1)
    }

    // MARK: - Lost during evidence derivation (OCR)

    func testAuthorityLostDuringOCRMakesNoExternalAttemptAndPresentsTheUnavailableTreatment() async {
        let authority = AuthorityBox()
        let recognizer = HookedTextRecognizer { authority.value = nil }
        let local = StubLocalProvider(behavior: .fail(StubLocalProvider.StubError()))
        let fixture = makeFixture(local: local, recognizer: recognizer, authority: authority)
        let token = beginAttempt(fixture.store)

        let outcome = await analyze(fixture, token: token)

        XCTAssertNil(outcome)
        assertNoExternalCallAndNothingSent(fixture)
        XCTAssertEqual(fixture.store.notice, .unavailable, "the existing local outcome treatment is presented")
        XCTAssertEqual(local.extractCallCount, 1, "local analysis is unaffected by authority")
        XCTAssertTrue(fixture.store.isAIAssistanceEnabled)
    }

    func testAuthorityLostDuringOCRWithNoLocalModelMakesNoExternalAttempt() async {
        let authority = AuthorityBox()
        let recognizer = HookedTextRecognizer { authority.value = nil }
        let fixture = makeFixture(local: nil, recognizer: recognizer, authority: authority)
        let token = beginAttempt(fixture.store)

        let outcome = await analyze(fixture, token: token)
        XCTAssertNil(outcome)

        assertNoExternalCallAndNothingSent(fixture)
        XCTAssertEqual(fixture.store.notice, .unavailable)
    }

    // MARK: - Lost during the local provider

    func testAuthorityLostDuringTheLocalProviderMakesNoExternalAttemptForAFailure() async {
        let authority = AuthorityBox()
        let local = StubLocalProvider(behavior: .fail(StubLocalProvider.StubError()))
        local.onExtract = { authority.value = nil }
        let fixture = makeFixture(local: local, authority: authority)
        let token = beginAttempt(fixture.store)

        let outcome = await analyze(fixture, token: token)
        XCTAssertNil(outcome)

        assertNoExternalCallAndNothingSent(fixture)
        XCTAssertEqual(fixture.store.notice, .unavailable)
    }

    func testAuthorityLostDuringTheLocalProviderMakesNoExternalAttemptForAnEmptyResult() async {
        let authority = AuthorityBox()
        let local = StubLocalProvider(behavior: .output(emptyRequesterOutput))
        local.onExtract = { authority.value = nil }
        let fixture = makeFixture(local: local, authority: authority)
        let token = beginAttempt(fixture.store)

        let outcome = await analyze(fixture, token: token)

        XCTAssertEqual(outcome?.eligible, true, "the ordinary eligible-but-empty outcome is handed to apply")
        XCTAssertEqual(outcome?.isEmpty, true)
        assertNoExternalCallAndNothingSent(fixture)
    }

    func testAuthorityLostDuringTheLocalProviderStillAppliesAUsefulLocalResult() async {
        let authority = AuthorityBox()
        let local = StubLocalProvider(behavior: .output(usefulRequesterOutput))
        local.onExtract = { authority.value = nil }
        let fixture = makeFixture(local: local, authority: authority)
        let token = beginAttempt(fixture.store)

        let outcome = await analyze(fixture, token: token)

        XCTAssertEqual(outcome?.isEmpty, false, "local proposals never depended on authority")
        assertNoExternalCallAndNothingSent(fixture)
        XCTAssertEqual(authority.readCount, 0, "a useful local result never reaches the offer decision")
    }

    // MARK: - Stale attempt + loss

    func testAStaleAttemptWhoseAuthorityWasLostSurfacesNoFallbackAndNoNotice() async {
        let authority = AuthorityBox()
        var storeRef: ScreenshotProposalStore?
        let local = StubLocalProvider(behavior: .fail(StubLocalProvider.StubError()))
        local.onExtract = {
            // The attempt is retired AND authority disappears while it runs.
            authority.value = nil
            storeRef?.invalidateCurrentSelection()
        }
        let fixture = makeFixture(local: local, authority: authority)
        storeRef = fixture.store
        let token = beginAttempt(fixture.store)

        let outcome = await analyze(fixture, token: token)

        XCTAssertNil(outcome)
        assertNoExternalCallAndNothingSent(fixture)
        XCTAssertNil(fixture.store.notice, "a retired attempt presents nothing")
        XCTAssertEqual(authority.readCount, 0, "a stale attempt never reaches the offer decision")
    }

    func testAnAttemptSupersededByANewSelectionCannotLaterSurfaceAFallback() async {
        let authority = AuthorityBox()
        var storeRef: ScreenshotProposalStore?
        let local = StubLocalProvider(behavior: .fail(StubLocalProvider.StubError()))
        local.onExtract = {
            authority.value = nil
            if let store = storeRef { _ = beginAttempt(store) }
        }
        let fixture = makeFixture(local: local, authority: authority)
        storeRef = fixture.store
        let token = beginAttempt(fixture.store)

        let outcome = await analyze(fixture, token: token)
        XCTAssertNil(outcome)

        assertNoExternalCallAndNothingSent(fixture)
        XCTAssertFalse(fixture.store.isCurrent(token))
    }

    // MARK: - Timeout followed by fallback re-reads current authority

    func testAfterATimeoutTheFallbackDecisionReadsCurrentAuthorityAndFallsThroughAutomatically() async {
        let authority = AuthorityBox()
        let provider = NonCooperativeLocalProvider(output: usefulRequesterOutput)
        let fixture = makeFixture(local: provider, timeout: .milliseconds(50), authority: authority)
        let token = beginAttempt(fixture.store)

        let outcome = await analyze(fixture, token: token)

        XCTAssertNotNil(outcome)
        XCTAssertTrue(provider.isRunning, "the provider is still running: control returned at the deadline")
        XCTAssertEqual(authority.readCount, 2, "authority was read at the offer decision and the transfer boundary, both after the timeout")
        XCTAssertEqual(fixture.external.analyzeCallCount, 1)
        provider.release()
    }

    func testAuthorityLostWhileALocalAttemptRanToItsTimeoutMakesNoExternalAttempt() async {
        let authority = AuthorityBox()
        let provider = NonCooperativeLocalProvider(output: usefulRequesterOutput)
        let fixture = makeFixture(local: provider, timeout: .milliseconds(50), authority: authority)
        let token = beginAttempt(fixture.store)
        let attempt = Task { await analyze(fixture, token: token) }

        await waitUntil("the provider started") { provider.isRunning }
        authority.value = nil // lost while the provider is still running
        let outcome = await attempt.value

        XCTAssertNil(outcome)
        assertNoExternalCallAndNothingSent(fixture)
        XCTAssertEqual(fixture.store.notice, .unavailable)
        XCTAssertEqual(authority.readCount, 1, "the value read at the decision — after the timeout — was the lost one")
        provider.release()
        await letScheduledWorkSettle()
        assertNoExternalCallAndNothingSent(fixture)
    }

    // MARK: - Authority lost between the offer decision and the transfer boundary

    /// The offer decision's read and the transfer boundary's read are two
    /// separate reads of the SAME provider, within the one `analyzeScreenshot`
    /// call. If authority disappears between them, nothing is sent and the
    /// ordinary local-outcome treatment is presented — the transfer boundary
    /// check is not redundant with the offer decision's.
    func testAuthorityLostBetweenTheOfferDecisionAndTheTransferBoundarySendsNothingAndPresentsTheLocalOutcome() async {
        let fixture = makeFixture(local: StubLocalProvider(behavior: .fail(StubLocalProvider.StubError())))
        let token = beginAttempt(fixture.store)
        let authority = BoundaryScriptedAuthority(["an-authority", nil])

        let outcome = await fixture.store.analyzeScreenshot(
            images: [ScreenshotTestEvidence.input(ScreenshotTestEvidence.eligibleCartWithoutVendor)],
            participantAuthority: { authority.read() },
            token: token
        )

        XCTAssertNil(outcome)
        XCTAssertEqual(authority.readCount, 2, "read at the offer decision and again at the transfer boundary")
        XCTAssertEqual(fixture.external.analyzeCallCount, 0, "no provider call once authority is gone at the boundary")
        XCTAssertEqual(fixture.store.notice, .unavailable)
    }

    // MARK: - View wiring (source inspection; no rendered-view proof here)

    func testTheViewSuppliesAuthorityAsAProviderAndTheStoreReadsItOnlyAtTheOfferDecision() throws {
        let view = try ScreenshotBoundarySource.read(
            "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift",
            from: #filePath
        )
        XCTAssertTrue(view.contains("participantAuthority: { identityStore.currentAuthority() }"))
        XCTAssertFalse(
            view.contains("participantAuthority: identityStore.currentAuthority(),"),
            "authority must not be captured when analysis starts"
        )
        // There is exactly one call site: the automatic local-then-external
        // flow has no separate tap any more.
        XCTAssertEqual(
            view.components(separatedBy: "participantAuthority: { identityStore.currentAuthority() }").count - 1,
            1
        )

        let store = ScreenshotBoundarySource.codeLines(try ScreenshotBoundarySource.read(
            "ios/CommonPlateios/CommonPlateios/Stores/ScreenshotProposalStore.swift",
            from: #filePath
        ))
        // On the analysis path the provider is read directly only once, inside
        // `attemptExternalFallback`'s offer-decision guard; the runtime itself
        // reads it again at the transfer boundary (proved separately in
        // `ScreenshotExternalPermissionBindingTests`).
        XCTAssertEqual(store.components(separatedBy: "participantAuthority() != nil").count - 1, 1)
        let fallback = try XCTUnwrap(store.range(of: "private func attemptExternalFallback("))
        let read = try XCTUnwrap(store.range(of: "participantAuthority() != nil"))
        let authorize = try XCTUnwrap(store.range(of: "runtime.authorizeExternalTransfer("))
        XCTAssertGreaterThan(read.lowerBound, fallback.lowerBound)
        XCTAssertLessThan(read.lowerBound, authorize.lowerBound)
    }
}
