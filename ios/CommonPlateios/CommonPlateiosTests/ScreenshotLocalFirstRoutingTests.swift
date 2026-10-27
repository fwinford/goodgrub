//
//  ScreenshotLocalFirstRoutingTests.swift
//  CommonPlateiosTests
//
// W4-S3 requester routing and privacy proof against the real
// `ScreenshotProposalStore`: the local-first routing matrix, every local
// fallback class falling through to ONE automatic external attempt under
// Screenshot Assistance's standing consent (W4-S3 consent-authority
// revision — there is no per-attempt external-AI permission step any more),
// Settings ON/OFF semantics over that standing consent, external-attempt
// terminality, and stale-result fencing. All evidence is synthetic. Legacy
// pre-revision consent-key behavior is covered in
// `ScreenshotAssistanceConsentAuthorityTests`, not here.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class ScreenshotLocalFirstRoutingTests: XCTestCase {
    override func tearDown() {
        ScreenshotProposalURLProtocol.reset()
        super.tearDown()
    }

    private let environment = testQualifiableEnvironment
    private let noManualEdits = ScreenshotFieldManualEditState()

    // MARK: - Fixtures

    private func makeService() -> ScreenshotProposalService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScreenshotProposalURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
        return ScreenshotProposalService(availability: .enabledForTesting(), client: client)
    }

    /// Store wired to the injected qualified local path and a counting external
    /// stub — for behavior that needs to observe provider calls. Screenshot
    /// Assistance starts On with standing consent
    /// (`InMemoryScreenshotProposalPreferencesStorage`'s default) unless the
    /// caller supplies its own `preferences`.
    private func makeStore(
        local: StubLocalProvider?,
        external providedExternal: StubExternalProvider? = nil,
        qualified: Bool = true,
        preferences: ScreenshotProposalPreferencesStoring = InMemoryScreenshotProposalPreferencesStorage(),
        timeout: Duration = .seconds(5)
    ) -> ScreenshotProposalStore {
        let external = providedExternal ?? StubExternalProvider()
        let runtime = makeRequesterTestRuntime(
            local: local,
            external: external,
            qualification: qualified ? qualifiedRegistry(environment: environment) : .production,
            environment: environment,
            timeout: timeout
        )
        return ScreenshotProposalStore(availability: .enabledForTesting(), service: makeService(), preferences: preferences, runtime: runtime)
    }

    /// Store wired exactly like production wiring (real Apple provider factory,
    /// production qualification, real network-backed external provider) but on
    /// a stubbed transport, so any external byte is observable.
    private func makeProductionWiredStore(
        preferences: ScreenshotProposalPreferencesStoring = InMemoryScreenshotProposalPreferencesStorage()
    ) -> ScreenshotProposalStore {
        makeProductionWiredRequesterStore(service: makeService(), preferences: preferences)
    }

    private func begin(_ store: ScreenshotProposalStore) -> (ScreenshotSelectionToken, RequestFoodFormDraft) {
        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        return (token, draft)
    }

    private func usefulOutput(swipes: Int? = nil) -> RequesterOrderRawOutput {
        RequesterOrderRawOutput(
            visibleVenueText: "Jasper Kane Cafe",
            foodItems: [.init(name: "Bowl", quantity: 1, modifiers: [])],
            mealSwipes: swipes
        )
    }

    private var emptyOutput: RequesterOrderRawOutput {
        RequesterOrderRawOutput(visibleVenueText: nil, foodItems: [], mealSwipes: nil)
    }

    private func eligibleExternalStub() -> ScreenshotProposalURLProtocol.Stub {
        let body: [String: Any] = [
            "eligible": true,
            "proposal": ["mealItems": [["name": "1 Bowl"]]],
        ]
        return .response(data: try! JSONSerialization.data(withJSONObject: body))
    }

    /// An external provider configured to return a result distinguishable
    /// from any local output, so a test can tell the external attempt's
    /// result from a local one.
    private func distinguishableExternal() -> StubExternalProvider {
        StubExternalProvider(result: .success(ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(mealItems: [MealItem(name: "External Item")])
        )))
    }

    // MARK: - Routing matrix: success and ineligible never reach any provider fallback

    func testUsefulPartialLocalResultIsSuccessWithNoExternalCall() async {
        let local = StubLocalProvider(behavior: .output(usefulOutput()))
        let external = StubExternalProvider()
        let store = makeStore(local: local, external: external)
        let (token, _) = begin(store)

        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        // Partial: a location and an item, no swipe count. Still a success.
        XCTAssertEqual(outcome?.proposal.selectedDiningSpot?.name, "Jasper Kane Cafe")
        XCTAssertEqual(outcome?.proposal.mealItems, [MealItem(name: "1 Bowl")])
        XCTAssertNil(outcome?.proposal.mealSwipes)
        XCTAssertEqual(external.analyzeCallCount, 0, "a useful partial local result must not fall through to external AI")
        XCTAssertNil(store.notice)
    }

    func testPolicyIneligibleSelectionGetsTheExistingIneligibleTreatment() async {
        let local = StubLocalProvider(behavior: .output(usefulOutput()))
        let external = StubExternalProvider()
        let store = makeStore(local: local, external: external)
        let (token, _) = begin(store)

        let outcome = await store.analyzeScreenshot(
            images: [ScreenshotTestEvidence.input(ScreenshotTestEvidence.ineligible)],
            participantAuthority: { "an-authority" },
            token: token
        )

        XCTAssertEqual(outcome, ScreenshotProposalOutcome(eligible: false, proposal: .empty))
        XCTAssertEqual(local.extractCallCount, 0, "no provider of either class sees ineligible evidence")
        XCTAssertEqual(external.analyzeCallCount, 0, "policy-ineligible evidence never reaches external AI")

        var draft = RequestFoodFormDraft()
        store.apply(outcome!, manualEdits: noManualEdits, to: &draft)
        XCTAssertEqual(store.notice, .unsupportedScreenshot)
    }

    func testOnlyEligibleScreenshotsReachTheLocalProvider() async {
        let local = StubLocalProvider(behavior: .output(usefulOutput()))
        let store = makeStore(local: local)
        let (token, _) = begin(store)

        _ = await store.analyzeScreenshot(
            images: [
                ScreenshotTestEvidence.input(ScreenshotTestEvidence.ineligible, byte: 1),
                ScreenshotTestEvidence.input("Your Pickup Order eligible one", byte: 2),
            ],
            participantAuthority: { "an-authority" },
            token: token
        )

        XCTAssertEqual(local.lastEvidenceTexts, ["Your Pickup Order eligible one"])
    }

    // MARK: - Routing matrix: every local fallback class falls through to one
    // automatic external attempt under standing consent (W4-S3 consent-authority
    // revision: no per-attempt permission step)

    func testUnavailableLocalModelFallsThroughToAutomaticExternalAttempt() async {
        let local = StubLocalProvider(availability: .unavailable(.appleIntelligenceNotEnabledForTest), behavior: .output(usefulOutput()))
        let external = distinguishableExternal()
        let store = makeStore(local: local, external: external)
        let (token, _) = begin(store)

        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        XCTAssertEqual(outcome?.proposal.mealItems, [MealItem(name: "External Item")])
        XCTAssertEqual(local.extractCallCount, 0)
        XCTAssertEqual(external.analyzeCallCount, 1, "falls through to the external attempt automatically")
    }

    func testUnqualifiedLocalCombinationFallsThroughToAutomaticExternalAttemptWithoutRunningTheModel() async {
        let local = StubLocalProvider(behavior: .output(usefulOutput()))
        let external = distinguishableExternal()
        let store = makeStore(local: local, external: external, qualified: false)
        let (token, _) = begin(store)

        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        XCTAssertEqual(outcome?.proposal.mealItems, [MealItem(name: "External Item")])
        XCTAssertEqual(local.extractCallCount, 0, "an available but unqualified model is not used")
        XCTAssertEqual(external.analyzeCallCount, 1)
    }

    func testLocalFailureFallsThroughToAutomaticExternalAttempt() async {
        let local = StubLocalProvider(behavior: .fail(StubLocalProvider.StubError()))
        let external = distinguishableExternal()
        let store = makeStore(local: local, external: external)
        let (token, _) = begin(store)

        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        XCTAssertEqual(outcome?.proposal.mealItems, [MealItem(name: "External Item")])
        XCTAssertEqual(external.analyzeCallCount, 1, "a local failure falls through to the external attempt")
        XCTAssertNil(store.notice)
    }

    func testLocalTimeoutFallsThroughToAutomaticExternalAttempt() async {
        let local = StubLocalProvider(behavior: .hang)
        let external = distinguishableExternal()
        let store = makeStore(local: local, external: external, timeout: .milliseconds(80))
        let (token, _) = begin(store)

        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        XCTAssertEqual(outcome?.proposal.mealItems, [MealItem(name: "External Item")])
        XCTAssertEqual(external.analyzeCallCount, 1)
    }

    func testLocalResultWithZeroUsableValidFieldsFallsThroughToAutomaticExternalAttempt() async {
        let local = StubLocalProvider(behavior: .output(emptyOutput))
        let external = distinguishableExternal()
        let store = makeStore(local: local, external: external)
        let (token, _) = begin(store)

        let outcome = await store.analyzeScreenshot(
            images: [ScreenshotTestEvidence.input(ScreenshotTestEvidence.eligibleCartWithoutVendor)],
            participantAuthority: { "an-authority" },
            token: token
        )

        XCTAssertEqual(outcome?.proposal.mealItems, [MealItem(name: "External Item")])
        XCTAssertEqual(external.analyzeCallCount, 1)
    }

    /// A vendor grounded in the independent OCR evidence is itself a valid
    /// proposal field even when the model returns nothing, so such a result is
    /// a (partial) success rather than an external-fallback trigger.
    func testEvidenceGroundedVendorAloneIsAUsefulLocalResult() async {
        let external = StubExternalProvider()
        let store = makeStore(local: StubLocalProvider(behavior: .output(emptyOutput)), external: external)
        let (token, _) = begin(store)

        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        XCTAssertEqual(outcome?.proposal.selectedDiningSpot?.name, "Jasper Kane Cafe")
        XCTAssertEqual(external.analyzeCallCount, 0, "a useful local result never falls through")
    }

    /// Output that only looked useful before validation counts as zero usable
    /// fields once the on-device validator has dropped what evidence doesn't
    /// support.
    func testLocalOutputThatValidationEmptiesFallsThroughToAutomaticExternalAttempt() async {
        let ungrounded = RequesterOrderRawOutput(visibleVenueText: "Cafe 370", foodItems: [], mealSwipes: 3)
        let external = distinguishableExternal()
        let store = makeStore(local: StubLocalProvider(behavior: .output(ungrounded)), external: external)
        let (token, _) = begin(store)

        let outcome = await store.analyzeScreenshot(
            images: [ScreenshotTestEvidence.input(ScreenshotTestEvidence.eligibleCartWithoutVendor)],
            participantAuthority: { "an-authority" },
            token: token
        )

        XCTAssertEqual(outcome?.proposal.mealItems, [MealItem(name: "External Item")])
        XCTAssertEqual(external.analyzeCallCount, 1)
    }

    /// The production wiring has no qualified combination, so every eligible
    /// attempt falls through to the external attempt — proven with a real
    /// network-backed external provider on a stubbed transport.
    func testProductionWiringFallsThroughToAutomaticExternalAttempt() async {
        ScreenshotProposalURLProtocol.enqueue(eligibleExternalStub())
        let store = makeProductionWiredStore()
        let (token, _) = begin(store)

        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        XCTAssertEqual(outcome?.proposal.mealItems, [MealItem(name: "1 Bowl")])
        XCTAssertEqual(ScreenshotProposalURLProtocol.capturedRequests.count, 1)
    }

    // MARK: - No automatic external attempt for cancelled / stale / superseded / Off work

    func testCancelledLocalAttemptMakesNoExternalAttempt() async {
        let local = StubLocalProvider(behavior: .delayed(.milliseconds(300), usefulOutput()))
        let external = StubExternalProvider()
        let store = makeStore(local: local, external: external)
        let (token, _) = begin(store)
        let task = Task { await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token) }
        try? await Task.sleep(for: .milliseconds(30))

        store.invalidateCurrentSelection()

        let outcome = await task.value
        XCTAssertNil(outcome)
        XCTAssertEqual(external.analyzeCallCount, 0)
    }

    func testSupersededLocalAttemptMakesNoExternalAttemptAndCannotApply() async {
        let slowFailing = StubLocalProvider(behavior: .fail(StubLocalProvider.StubError()))
        let external = StubExternalProvider()
        let store = makeStore(local: slowFailing, external: external)
        var draft = RequestFoodFormDraft()
        let older = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let olderTask = Task { await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: older) }

        // A newer selection begins before the older attempt's failure lands.
        let newer = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let outcome = await olderTask.value

        XCTAssertNil(outcome)
        XCTAssertFalse(store.isCurrent(older))
        XCTAssertTrue(store.isCurrent(newer))
        XCTAssertEqual(external.analyzeCallCount, 0, "a superseded attempt must not fall through for the newer selection")
    }

    func testAttemptStartedWhileAssistanceIsOffMakesNoExternalAttempt() async {
        let external = StubExternalProvider()
        let store = makeStore(local: StubLocalProvider(behavior: .fail(StubLocalProvider.StubError())), external: external)
        let (token, _) = begin(store)
        store.setAIAssistanceEnabled(false)

        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        XCTAssertNil(outcome)
        XCTAssertEqual(external.analyzeCallCount, 0)
    }

    // MARK: - Automatic external fallback proceeds in the one call, exactly once

    func testAutomaticExternalFallbackTransfersInTheSameCallWithNoSeparateStepNeeded() async {
        let external = StubExternalProvider(result: .success(ScreenshotProposalOutcome(eligible: true, proposal: .empty)))
        let store = makeStore(local: nil, external: external)
        let (token, _) = begin(store)

        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        XCTAssertNotNil(outcome, "the external attempt's result is the one call's own return value")
        XCTAssertEqual(external.analyzeCallCount, 1)
    }

    func testRealTransportSeesZeroRequestsForAnOutrightLocalSuccess() async {
        // Real network-backed external provider on a capturing transport, with
        // a qualified local stub so the local path genuinely runs and succeeds.
        let runtime = ScreenshotAssistanceRuntime(
            workflow: RequesterOrderWorkflow(recognizer: SyntheticTextRecognizer()),
            localProvider: StubLocalProvider(behavior: .output(usefulOutput())),
            externalProvider: RequesterOpenAIExternalProvider(service: makeService()),
            qualification: qualifiedRegistry(environment: environment),
            environment: environment
        )
        let store = ScreenshotProposalStore(
            availability: .enabledForTesting(),
            service: makeService(),
            preferences: InMemoryScreenshotProposalPreferencesStorage(),
            runtime: runtime
        )
        let (token, _) = begin(store)
        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)
        XCTAssertNotNil(outcome)
        XCTAssertEqual(
            ScreenshotProposalURLProtocol.capturedRequests.count, 0,
            "selecting and locally analyzing screenshots must not send them off-device"
        )
    }

    // MARK: - Each selection's automatic attempt is independent

    func testEachNewSelectionRunsItsOwnAutomaticExternalAttempt() async {
        let external = StubExternalProvider()
        let store = makeStore(local: nil, external: external)
        var draft = RequestFoodFormDraft()

        let first = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        _ = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: first)
        XCTAssertEqual(external.analyzeCallCount, 1)

        let second = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        _ = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input(byte: 2)], participantAuthority: { "an-authority" }, token: second)
        XCTAssertEqual(external.analyzeCallCount, 2, "each selection's own attempt runs independently, with no reuse")
    }

    func testANewSelectionRetiresTheOlderAttemptsLateExternalResult() async {
        let external = StubExternalProvider(result: .success(ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(mealItems: [MealItem(name: "Stale")])
        )))
        external.delay = .milliseconds(200)
        let store = makeStore(local: nil, external: external)
        var draft = RequestFoodFormDraft()
        let older = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let olderTask = Task { await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: older) }
        try? await Task.sleep(for: .milliseconds(30))

        let newer = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)

        XCTAssertFalse(store.isCurrent(older))
        XCTAssertTrue(store.isCurrent(newer))
        let olderOutcome = await olderTask.value
        XCTAssertNil(olderOutcome, "a replaced selection's late external result can never apply")
    }

    func testLeavingTheScreenRetiresAnInFlightAutomaticExternalAttempt() async {
        let external = StubExternalProvider()
        external.delay = .milliseconds(200)
        let store = makeStore(local: nil, external: external)
        let (token, _) = begin(store)
        let task = Task { await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token) }
        try? await Task.sleep(for: .milliseconds(30))

        store.invalidateCurrentSelection()

        let outcome = await task.value
        XCTAssertNil(outcome)
    }

    // MARK: - Settings ON / OFF over the standing consent

    /// Enabling the setting alone, with no selection in flight, sends nothing:
    /// only an actual attempt — which only starts from `beginSelection` — can
    /// ever reach a provider.
    func testEnablingAloneSendsNothingUntilAnAttemptRuns() {
        let external = StubExternalProvider()
        let preferences = InMemoryScreenshotProposalPreferencesStorage()
        preferences.hasValidScreenshotAssistanceConsent = false
        let store = makeStore(local: nil, external: external, preferences: preferences)

        store.setAIAssistanceEnabled(true)

        XCTAssertTrue(store.isAIAssistanceEnabled)
        XCTAssertEqual(external.analyzeCallCount, 0)
        XCTAssertEqual(ScreenshotProposalURLProtocol.capturedRequests.count, 0)
    }

    func testOffRetiresAnInFlightAutomaticExternalAttemptAndOnDoesNotReviveIt() async {
        let external = StubExternalProvider(result: .success(ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(mealItems: [MealItem(name: "Bowl")])
        )))
        external.delay = .milliseconds(200)
        let store = makeStore(local: nil, external: external)
        let (token, _) = begin(store)
        let task = Task { await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token) }
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(external.analyzeCallCount, 1, "the attempt had already begun")

        store.setAIAssistanceEnabled(false)

        let resolved = await task.value
        XCTAssertNil(resolved, "a retired attempt's late result can never apply")
        XCTAssertFalse(store.isApplying)
        XCTAssertFalse(store.isCurrent(token))

        store.setAIAssistanceEnabled(true)
        XCTAssertEqual(external.analyzeCallCount, 1, "re-enabling never replays the retired attempt")

        var draft = RequestFoodFormDraft()
        let fresh = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let freshOutcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input(byte: 2)], participantAuthority: { "an-authority" }, token: fresh)
        XCTAssertNotNil(freshOutcome, "a fresh selection after re-enabling runs its own attempt normally")
        XCTAssertEqual(external.analyzeCallCount, 2)
    }

    func testSettingsOffWhileALocalAttemptRunsRetiresIt() async {
        let local = StubLocalProvider(behavior: .delayed(.milliseconds(300), usefulOutput()))
        let store = makeStore(local: local)
        let (token, _) = begin(store)
        let task = Task { await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token) }
        try? await Task.sleep(for: .milliseconds(30))

        store.setAIAssistanceEnabled(false)

        let cancelled = await task.value
        XCTAssertNil(cancelled)
    }

    // MARK: - External attempt is one terminal attempt

    func testExternalFailureUsesTheExistingNotice() async {
        let external = StubExternalProvider(result: .failure(ScreenshotProposalServiceError.unavailable(underlying: StubLocalProvider.StubError())))
        let store = makeStore(local: nil, external: external)
        let (token, _) = begin(store)

        let resolved = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        XCTAssertNil(resolved)
        XCTAssertEqual(store.notice, .unavailable)
        XCTAssertEqual(external.analyzeCallCount, 1)
    }

    func testExternalResultWithNoUsefulFieldsIsTheExistingTreatment() async {
        let external = StubExternalProvider(result: .success(ScreenshotProposalOutcome(eligible: true, proposal: .empty)))
        let store = makeStore(local: nil, external: external)
        let (token, _) = begin(store)

        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        XCTAssertEqual(outcome?.isEmpty, true)
        var draft = RequestFoodFormDraft()
        store.apply(outcome!, manualEdits: noManualEdits, to: &draft)
        XCTAssertEqual(store.notice, .noUsefulExtraction)
    }

    func testExternalIneligibleResultUsesTheUnsupportedTreatment() async {
        let external = StubExternalProvider(result: .success(ScreenshotProposalOutcome(eligible: false, proposal: .empty)))
        let store = makeStore(local: nil, external: external)
        let (token, _) = begin(store)

        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        XCTAssertEqual(outcome?.eligible, false)
    }

    /// Without current participant authority, nothing is sent and Screenshot
    /// Assistance surfaces no verification notice — the ordinary local-outcome
    /// treatment is presented instead.
    func testExternalAttemptWithoutParticipantAuthorityPresentsTheLocalOutcomeInsteadOfVerification() async {
        let external = StubExternalProvider()
        let store = makeStore(local: nil, external: external)
        let (token, _) = begin(store)

        let resolved = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { nil }, token: token)

        XCTAssertNil(resolved)
        XCTAssertEqual(store.notice, .unavailable, "the original local outcome, not a verification notice")
        XCTAssertEqual(external.analyzeCallCount, 0)
    }

    /// One logical attempt uses one provider class: an external attempt neither
    /// sees nor merges anything a local attempt produced.
    func testExternalAttemptSendsOnlyEligibleScreenshotsAndMergesNoLocalProposal() async {
        let local = StubLocalProvider(behavior: .output(emptyOutput))
        let external = StubExternalProvider(result: .success(ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(mealItems: [MealItem(name: "External Item")])
        )))
        let store = makeStore(local: local, external: external)
        let (token, _) = begin(store)
        let resolved = await store.analyzeScreenshot(
            images: [
                ScreenshotTestEvidence.input(ScreenshotTestEvidence.ineligible, byte: 1),
                ScreenshotTestEvidence.input(ScreenshotTestEvidence.eligibleCartWithoutVendor, byte: 2),
            ],
            participantAuthority: { "an-authority" },
            token: token
        )
        XCTAssertEqual(local.extractCallCount, 1)

        XCTAssertEqual(external.lastImages.map { $0.data.first }, [2], "an ineligible screenshot is never sent")
        XCTAssertEqual(resolved?.proposal.mealItems, [MealItem(name: "External Item")])
        XCTAssertNil(resolved?.proposal.selectedDiningSpot)
    }

    // MARK: - Real transport: what an external attempt actually sends

    func testExternalAttemptTransmitsAutomaticallyAndCarriesEligibleEvidence() async throws {
        ScreenshotProposalURLProtocol.enqueue(eligibleExternalStub())
        let store = makeProductionWiredStore()
        let (token, _) = begin(store)

        let resolved = await store.analyzeScreenshot(
            images: [
                ScreenshotTestEvidence.input("Your Pickup Order first", byte: 1),
                ScreenshotTestEvidence.input(ScreenshotTestEvidence.ineligible, byte: 2),
            ],
            participantAuthority: { "an-authority" },
            token: token
        )

        XCTAssertEqual(ScreenshotProposalURLProtocol.capturedRequests.count, 1)
        let body = try XCTUnwrap(ScreenshotProposalURLProtocol.capturedRequests.first?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let images = try XCTUnwrap(json["images"] as? [[String: Any]])
        XCTAssertEqual(images.compactMap { $0["localEvidenceText"] as? String }, ["Your Pickup Order first"])
        XCTAssertEqual(resolved?.proposal.mealItems, [MealItem(name: "1 Bowl")])
    }

    // MARK: - 1–5 screenshots and concurrency

    func testOneThroughFiveScreenshotsAreAnalyzedLocallyAsOneOrder() async {
        for count in 1...ScreenshotProposalStore.maxScreenshotSelection {
            let local = StubLocalProvider(behavior: .output(usefulOutput()))
            let store = makeStore(local: local)
            let (token, _) = begin(store)
            let texts = (1...count).map { "Your Pickup Order screenshot \($0)" }

            let outcome = await store.analyzeScreenshot(
                images: texts.enumerated().map { ScreenshotTestEvidence.input($0.element, byte: UInt8($0.offset + 1)) },
                participantAuthority: { "an-authority" },
                token: token
            )

            XCTAssertNotNil(outcome, "\(count) screenshots")
            XCTAssertEqual(local.extractCallCount, 1, "one attempt for the whole set, never one per screenshot")
            XCTAssertEqual(local.lastEvidenceTexts, texts)
        }
    }

    func testMoreThanFiveScreenshotsAreRefusedBeforeAnyProvider() async {
        let local = StubLocalProvider(behavior: .output(usefulOutput()))
        let external = StubExternalProvider()
        let store = makeStore(local: local, external: external)
        let (token, _) = begin(store)

        let outcome = await store.analyzeScreenshot(
            images: ScreenshotTestEvidence.inputs(6),
            participantAuthority: { "an-authority" },
            token: token
        )

        XCTAssertNil(outcome)
        XCTAssertEqual(local.extractCallCount, 0)
        XCTAssertEqual(external.analyzeCallCount, 0)
    }

    func testANewerSelectionWinsOverAnOlderSlowLocalAttempt() async {
        let local = StubLocalProvider(behavior: .delayed(.milliseconds(200), usefulOutput()))
        let store = makeStore(local: local)
        var draft = RequestFoodFormDraft()
        let older = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let olderTask = Task { await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: older) }
        try? await Task.sleep(for: .milliseconds(20))

        let newer = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        local.behavior = .output(usefulOutput())
        let newerOutcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input(byte: 2)], participantAuthority: { "an-authority" }, token: newer)

        let olderOutcome = await olderTask.value
        XCTAssertNil(olderOutcome, "the older attempt must be dropped even though it was already running")
        XCTAssertNotNil(newerOutcome)
        XCTAssertFalse(store.isApplying)
    }

    func testIsApplyingCoversTheLocalAttemptAndClearsWhenItEnds() async {
        let local = StubLocalProvider(behavior: .delayed(.milliseconds(150), usefulOutput()))
        let store = makeStore(local: local)
        let (token, _) = begin(store)
        let task = Task { await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token) }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(store.isApplying)

        _ = await task.value
        XCTAssertFalse(store.isApplying)
    }
}

private extension ScreenshotLocalUnavailableReason {
    /// Readable name for the local-fallback tests use.
    static var appleIntelligenceNotEnabledForTest: ScreenshotLocalUnavailableReason { .modelNotEnabled }
}
