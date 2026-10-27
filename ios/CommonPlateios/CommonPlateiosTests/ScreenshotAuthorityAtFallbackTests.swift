//
//  ScreenshotAuthorityAtFallbackTests.swift
//  CommonPlateiosTests
//
// W4-S3 proof, against the real `ScreenshotProposalStore`, of participant-
// authority loss after form admission: local Screenshot Assistance follows its
// normal rules; the automatic external fallback attempt never runs (for each
// of the three local fallback outcome classes); no verification notice/prompt
// comes from Screenshot Assistance; manual entry and the Screenshot Assistance
// setting are untouched. Also proves only the eligible subset is ever
// transferred. All evidence is synthetic.
//
// W4-S3 consent-authority revision: there is no longer a separate per-attempt
// permission popup to hold open while authority is checked — the offer
// decision and (when authorized) the transfer both happen within the one
// `analyzeScreenshot` call, so "popup pending" scenarios from the pre-revision
// per-attempt model no longer exist; the authority-loss-between-the-two-reads
// race is covered in `ScreenshotFallbackAuthorityTimingTests`.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class ScreenshotAuthorityAtFallbackTests: XCTestCase {
    override func tearDown() {
        ScreenshotProposalURLProtocol.reset()
        super.tearDown()
    }

    private let environment = testQualifiableEnvironment
    private let noManualEdits = ScreenshotFieldManualEditState()

    // MARK: - Fixtures

    private func makeStore(
        local: StubLocalProvider?,
        external: StubExternalProvider,
        qualified: Bool = true
    ) -> ScreenshotProposalStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScreenshotProposalURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
        let runtime = makeRequesterTestRuntime(
            local: local,
            external: external,
            qualification: qualified ? qualifiedRegistry(environment: environment) : .production,
            environment: environment,
            timeout: .seconds(5)
        )
        return ScreenshotProposalStore(
            availability: .enabledForTesting(),
            service: ScreenshotProposalService(availability: .enabledForTesting(), client: client),
            preferences: InMemoryScreenshotProposalPreferencesStorage(),
            runtime: runtime
        )
    }

    private func begin(_ store: ScreenshotProposalStore) -> ScreenshotSelectionToken {
        var draft = RequestFoodFormDraft()
        return store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
    }

    private var usefulOutput: RequesterOrderRawOutput {
        RequesterOrderRawOutput(
            visibleVenueText: "Jasper Kane Cafe",
            foodItems: [.init(name: "Bowl", quantity: 1, modifiers: [])],
            mealSwipes: nil
        )
    }

    private var emptyOutput: RequesterOrderRawOutput {
        RequesterOrderRawOutput(visibleVenueText: nil, foodItems: [], mealSwipes: nil)
    }

    /// Runs one attempt with NO participant authority and asserts every
    /// suppression guarantee that must hold regardless of the local outcome:
    /// only the external fallback attempt is suppressed. Returns the outcome
    /// (if any) the requester view would apply, after applying it, so the
    /// caller can assert the ordinary notice for the local outcome.
    @discardableResult
    private func runWithoutAuthority(
        _ store: ScreenshotProposalStore,
        external: StubExternalProvider,
        evidence: String = ScreenshotTestEvidence.eligibleCartWithoutVendor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> ScreenshotProposalOutcome? {
        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let outcome = await store.analyzeScreenshot(
            images: [ScreenshotTestEvidence.input(evidence)],
            participantAuthority: { nil },
            token: token
        )
        if let outcome { store.apply(outcome, manualEdits: noManualEdits, to: &draft) }

        XCTAssertNotEqual(store.notice, .verificationRequired, "no verification notice", file: file, line: line)
        XCTAssertNotEqual(store.notice, .verificationExpired, "no verification notice", file: file, line: line)
        XCTAssertEqual(external.analyzeCallCount, 0, "nothing is sent externally", file: file, line: line)
        XCTAssertTrue(store.isAIAssistanceEnabled, "the setting is untouched; manual entry stays available", file: file, line: line)
        return outcome
    }

    // MARK: - Authority loss: the three fallback classes never run the external attempt

    func testLocalUnavailableWithoutAuthorityMakesNoExternalAttempt() async {
        let local = StubLocalProvider(
            availability: .unavailable(.modelNotEnabled),
            behavior: .output(usefulOutput)
        )
        let external = StubExternalProvider()
        let store = makeStore(local: local, external: external)
        let outcome = await runWithoutAuthority(store, external: external)
        XCTAssertNil(outcome)
        XCTAssertEqual(store.notice, .unavailable, "the existing unavailable treatment survives the suppressed fallback")
        XCTAssertEqual(local.extractCallCount, 0)
    }

    func testLocalNotQualifiedWithoutAuthorityMakesNoExternalAttempt() async {
        let local = StubLocalProvider(behavior: .output(usefulOutput))
        let external = StubExternalProvider()
        let store = makeStore(local: local, external: external, qualified: false)
        let outcome = await runWithoutAuthority(store, external: external)
        XCTAssertNil(outcome)
        XCTAssertEqual(store.notice, .unavailable, "the existing unavailable treatment survives the suppressed fallback")
        XCTAssertEqual(local.extractCallCount, 0, "an unqualified combination never runs locally")
    }

    func testLocalFailureWithoutAuthorityMakesNoExternalAttempt() async {
        let local = StubLocalProvider(behavior: .fail(StubLocalProvider.StubError()))
        let external = StubExternalProvider()
        let store = makeStore(local: local, external: external)
        let outcome = await runWithoutAuthority(store, external: external)
        XCTAssertNil(outcome)
        XCTAssertEqual(store.notice, .unavailable, "the existing unavailable treatment survives the suppressed fallback")
        XCTAssertEqual(local.extractCallCount, 1, "the local attempt still ran")
    }

    func testLocalZeroUsableFieldsWithoutAuthorityMakesNoExternalAttempt() async {
        let local = StubLocalProvider(behavior: .output(emptyOutput))
        let external = StubExternalProvider()
        let store = makeStore(local: local, external: external)
        let outcome = await runWithoutAuthority(store, external: external)
        XCTAssertEqual(outcome?.eligible, true, "the ordinary eligible-but-empty outcome is still delivered")
        XCTAssertEqual(outcome?.isEmpty, true)
        XCTAssertEqual(store.notice, .noUsefulExtraction, "the existing no-useful-extraction treatment survives the suppressed fallback")
        XCTAssertEqual(local.extractCallCount, 1, "the local attempt still ran")
    }

    // MARK: - Authority loss: local Screenshot Assistance otherwise unchanged

    func testUsefulLocalResultStillAppliesWithoutAuthority() async {
        let local = StubLocalProvider(behavior: .output(usefulOutput))
        let external = StubExternalProvider()
        let store = makeStore(local: local, external: external)
        let token = begin(store)

        let outcome = await store.analyzeScreenshot(
            images: [ScreenshotTestEvidence.input()],
            participantAuthority: { nil },
            token: token
        )

        XCTAssertEqual(outcome?.eligible, true)
        XCTAssertEqual(outcome?.isEmpty, false, "local proposals apply without participant authority")
        XCTAssertNil(store.notice)
        XCTAssertEqual(external.analyzeCallCount, 0)
    }

    func testIneligibleEvidenceKeepsItsExistingTreatmentWithoutAuthority() async {
        let external = StubExternalProvider()
        let store = makeStore(local: StubLocalProvider(behavior: .output(usefulOutput)), external: external)
        let token = begin(store)

        let outcome = await store.analyzeScreenshot(
            images: [ScreenshotTestEvidence.input(ScreenshotTestEvidence.ineligible)],
            participantAuthority: { nil },
            token: token
        )

        XCTAssertEqual(outcome, ScreenshotProposalOutcome(eligible: false, proposal: .empty))
        XCTAssertEqual(external.analyzeCallCount, 0)
    }

    /// The same failing local attempt WITH authority falls through to the
    /// external attempt, so the suppression above is attributable to
    /// authority alone.
    func testSameFailureWithAuthorityStillFallsThroughAutomatically() async {
        let external = StubExternalProvider()
        let store = makeStore(local: StubLocalProvider(behavior: .fail(StubLocalProvider.StubError())), external: external)
        let token = begin(store)

        let outcome = await store.analyzeScreenshot(
            images: [ScreenshotTestEvidence.input()],
            participantAuthority: { "an-authority" },
            token: token
        )

        XCTAssertNotNil(outcome, "an authorized requester's attempt falls through automatically")
        XCTAssertEqual(external.analyzeCallCount, 1)
    }

    // MARK: - Authorized requester: the fallback retains its reason-specific treatment on failure

    func testAuthorizedUnavailableOrFailedLocalOutcomeFallsThroughAndAppliesTheExternalResult() async {
        let cases: [(String, StubLocalProvider?, Bool)] = [
            ("unavailable", StubLocalProvider(availability: .unavailable(.modelNotEnabled), behavior: .output(usefulOutput)), true),
            ("not qualified", StubLocalProvider(behavior: .output(usefulOutput)), false),
            ("failed", StubLocalProvider(behavior: .fail(StubLocalProvider.StubError())), true),
        ]
        for (name, local, qualified) in cases {
            let external = StubExternalProvider(result: .success(ScreenshotProposalOutcome(
                eligible: true,
                proposal: ScreenshotProposal(mealItems: [MealItem(name: "External Item")])
            )))
            let store = makeStore(local: local, external: external, qualified: qualified)
            let token = begin(store)

            let outcome = await store.analyzeScreenshot(
                images: [ScreenshotTestEvidence.input()],
                participantAuthority: { "an-authority" },
                token: token
            )

            XCTAssertEqual(outcome?.proposal.mealItems, [MealItem(name: "External Item")], name)
            XCTAssertNil(store.notice, name)
            XCTAssertEqual(external.analyzeCallCount, 1, name)
        }
    }

    func testAuthorizedZeroUsableFieldsFallsThroughAndAppliesTheExternalResult() async {
        let external = StubExternalProvider(result: .success(ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(mealItems: [MealItem(name: "External Item")])
        )))
        let store = makeStore(local: StubLocalProvider(behavior: .output(emptyOutput)), external: external)
        let token = begin(store)

        let outcome = await store.analyzeScreenshot(
            images: [ScreenshotTestEvidence.input(ScreenshotTestEvidence.eligibleCartWithoutVendor)],
            participantAuthority: { "an-authority" },
            token: token
        )

        XCTAssertEqual(outcome?.proposal.mealItems, [MealItem(name: "External Item")])
        XCTAssertNil(store.notice)
        XCTAssertEqual(external.analyzeCallCount, 1)
    }

    // MARK: - Authorized external flow unchanged

    func testAuthorizedExternalFlowTransfersOnceAutomaticallyAndAppliesItsResult() async {
        let external = StubExternalProvider(result: .success(ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(mealItems: [MealItem(name: "External Item")])
        )))
        let store = makeStore(local: StubLocalProvider(behavior: .output(emptyOutput)), external: external)
        let token = begin(store)

        let outcome = await store.analyzeScreenshot(
            images: [ScreenshotTestEvidence.input(ScreenshotTestEvidence.eligibleCartWithoutVendor)],
            participantAuthority: { "an-authority" },
            token: token
        )

        XCTAssertEqual(outcome?.proposal.mealItems?.first?.name, "External Item")
        XCTAssertEqual(external.analyzeCallCount, 1)
        XCTAssertNil(store.notice)
    }

    // MARK: - View wiring (source inspection; no rendered-view proof here)

    func testRequesterViewSuppliesCurrentAuthorityAndLaunchesNoVerificationFromScreenshotFlow() throws {
        let view = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift")

        // Offer-time authority comes from the identity store, at call time.
        let analysis = try XCTUnwrap(view.range(of: "await screenshotProposalStore.analyzeScreenshot("))
        let analysisCall = String(view[analysis.lowerBound...].prefix(220))
        XCTAssertTrue(
            analysisCall.contains("participantAuthority: { identityStore.currentAuthority() }"),
            "authority is supplied as a provider the store reads at the offer decision, not captured at analysis start"
        )

        // The Screenshot Assistance flow never starts a verification flow.
        let start = try XCTUnwrap(view.range(of: "private func beginScreenshotAnalysis("))
        let end = try XCTUnwrap(view.range(of: "/// Applies one validated outcome"))
        let screenshotFlow = String(view[start.lowerBound..<end.lowerBound])
        for forbidden in ["verificationCoordinator", "requestVerification", "ParticipantVerification"] {
            XCTAssertFalse(screenshotFlow.contains(forbidden), forbidden)
        }
    }

    // MARK: - Only the eligible subset is transferred

    /// Three prepared screenshots, one policy-ineligible: the automatic
    /// external attempt transfers only the two eligible ones.
    func testOnlyTheEligibleSubsetIsTransferredExternally() async {
        let external = StubExternalProvider()
        let store = makeStore(local: nil, external: external)
        let token = begin(store)
        let images = [
            ScreenshotTestEvidence.input(ScreenshotTestEvidence.ineligible, byte: 1),
            ScreenshotTestEvidence.input("Your Pickup Order eligible one", byte: 2),
            ScreenshotTestEvidence.input("Your Pickup Order eligible two", byte: 3),
        ]

        _ = await store.analyzeScreenshot(images: images, participantAuthority: { "an-authority" }, token: token)

        XCTAssertEqual(external.analyzeCallCount, 1)
        XCTAssertEqual(external.lastImages.count, 2, "only the eligible subset is transferred")
    }

    private func fileSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CommonPlateiosTests
            .deletingLastPathComponent() // CommonPlateios
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repository root
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
