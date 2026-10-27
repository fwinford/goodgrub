//
//  ScreenshotVenueAuthorityReconciliationTests.swift
//  CommonPlateiosTests
//
// W4-R4.2 §5a: the accepted catalog matcher may populate
// `selectedDiningSpot`, but that is E/D authority only where no V1 Meal
// Exchange venue observation exists. Every case here drives the production
// path — `analyzeScreenshot` (OCR → classifier → local/external attempt →
// reconciliation) and then `apply` — and never hand-builds a disposition that
// reconciliation would not produce. All evidence is synthetic.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class ScreenshotVenueAuthorityReconciliationTests: XCTestCase {
    private let noManualEdits = ScreenshotFieldManualEditState()
    private let environment = testQualifiableEnvironment

    private var palladium: DiningSpot {
        SupportedVendorCatalog.diningSpots.first { $0.name == "Jasper Kane Cafe" }!
    }
    private var crave: DiningSpot {
        SupportedVendorCatalog.diningSpots.first { $0.name == "Crave NYU" }!
    }

    private let cart = "Your Pickup Order\nContinue to Checkout"
    /// The accepted checkout/payment structure for the Dining Dollars path
    /// (`Review your pickup order` … `Your payment` / `Payment method` /
    /// `Dining Dollars`), naming a supported catalog venue as a bare line and
    /// carrying NO `- Meal Exchange` venue identity line (no V1 observation).
    private let diningDollarsCheckout = [
        "Review your pickup order", "Jasper Kane Cafe", "Your order", "1 Screenshot Bowl",
        "Your payment", "Payment method", "Dining Dollars",
    ].joined(separator: "\n")
    private let orderDetails = RequesterOrderRawOutput(
        visibleVenueText: nil,
        foodItems: [.init(name: "Screenshot Bowl", quantity: 1, modifiers: [])],
        mealSwipes: 1
    )

    private func makeStore(
        local: any ScreenshotLocalProvider<RequesterOrderWorkflow>,
        external: StubExternalProvider? = nil
    ) -> ScreenshotProposalStore {
        makeStoreOver(makeRequesterTestRuntime(
            local: local,
            external: external ?? StubExternalProvider(),
            qualification: qualifiedRegistry(provider: local.identity, environment: environment),
            environment: environment
        ))
    }

    private func analyze(
        _ store: ScreenshotProposalStore,
        images evidence: [String],
        authority: @escaping @MainActor () -> String? = { nil }
    ) async -> ScreenshotProposalOutcome? {
        let token = beginAttempt(store)
        let images = evidence.enumerated().map {
            ScreenshotTestEvidence.input($0.element, byte: UInt8($0.offset + 1))
        }
        return await store.analyzeScreenshot(images: images, participantAuthority: authority, token: token)
    }

    /// Asserts the held-A contract for one analyzed selection: the catalog
    /// matcher DID populate a location (so the case is not vacuous), yet the
    /// disposition is A, nothing is auto-applied (with or without a manual
    /// location), no spurious D exists, and an explicit confirmation never
    /// lets the catalog-derived location replace the requester's pick.
    private func assertHeldAsUnresolved(
        _ outcome: ScreenshotProposalOutcome?,
        store: ScreenshotProposalStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let outcome = try XCTUnwrap(outcome, "expected an eligible outcome", file: file, line: line)
        XCTAssertTrue(outcome.eligible, file: file, line: line)
        XCTAssertEqual(outcome.proposal.selectedDiningSpot, palladium,
                       "precondition: the accepted catalog matcher populated a location", file: file, line: line)
        XCTAssertFalse(outcome.proposal.mealItems?.isEmpty ?? true,
                       "precondition: the proposal carries order details", file: file, line: line)
        XCTAssertEqual(outcome.venueDisposition, .unresolved, file: file, line: line)

        // No manual location: A recovery, nothing written.
        var empty = RequestFoodFormDraft()
        let emptyOriginal = empty
        XCTAssertEqual(
            ScreenshotProposalStore.venueRecoveryKind(for: outcome, manualEdits: noManualEdits, draft: empty),
            .unresolved, file: file, line: line
        )
        XCTAssertTrue(store.apply(outcome, manualEdits: noManualEdits, to: &empty).isEmpty, file: file, line: line)
        XCTAssertEqual(empty, emptyOriginal, "location, items, swipes and path are all withheld", file: file, line: line)

        // A different manual location: still A (never a spurious D), nothing written.
        var manualDraft = RequestFoodFormDraft(selectedDiningSpot: crave, mealSwipes: 2)
        let manualOriginal = manualDraft
        let manualEdits = ScreenshotFieldManualEditState(hasManuallyEditedLocation: true)
        XCTAssertEqual(
            ScreenshotProposalStore.venueRecoveryKind(for: outcome, manualEdits: manualEdits, draft: manualDraft),
            .unresolved, "uncertain venue evidence never creates D recovery", file: file, line: line
        )
        XCTAssertTrue(store.apply(outcome, manualEdits: manualEdits, to: &manualDraft).isEmpty, file: file, line: line)
        XCTAssertEqual(manualDraft, manualOriginal, file: file, line: line)

        // Explicit A confirmation applies details but the requester's pick
        // remains the location authority.
        let applied = store.apply(outcome, manualEdits: manualEdits, to: &manualDraft, venueConfirmation: true)
        XCTAssertFalse(applied.location, file: file, line: line)
        XCTAssertEqual(manualDraft.selectedDiningSpot, crave, file: file, line: line)
        XCTAssertEqual(manualDraft.mealEntries[0].name, "1 Screenshot Bowl", file: file, line: line)
    }

    // MARK: - Case 2: any indeterminate V1 observation stays A

    func testUnsupportedV1IdentityWithIncidentalSupportedCatalogTextStaysA() async throws {
        let store = makeStore(local: StubLocalProvider(behavior: .output(orderDetails)))
        let outcome = await analyze(store, images: [
            "\(cart)\nSynthetic Garden - Meal Exchange\nJasper Kane Cafe",
        ])
        try assertHeldAsUnresolved(outcome, store: store)
    }

    func testNearMissV1IdentityWithIncidentalSupportedCatalogTextStaysAAndNeverB() async throws {
        let store = makeStore(local: StubLocalProvider(behavior: .output(orderDetails)))
        let outcome = await analyze(store, images: [
            "\(cart)\nDunkin'at U-Hall - Meal Exchange\nJasper Kane Cafe",
        ])
        try assertHeldAsUnresolved(outcome, store: store)
    }

    func testTruncatedV1IdentityWithIncidentalSupportedCatalogTextStaysA() async throws {
        let store = makeStore(local: StubLocalProvider(behavior: .output(orderDetails)))
        let outcome = await analyze(store, images: [
            "\(cart)\nSynthetic Gar... - Meal Exchange\nJasper Kane Cafe",
        ])
        try assertHeldAsUnresolved(outcome, store: store)
    }

    func testContradictoryV1VenuesWithinOneImageStayA() async throws {
        let store = makeStore(local: StubLocalProvider(behavior: .output(orderDetails)))
        let outcome = await analyze(store, images: [
            "\(cart)\nJasper Kane Cafe - Meal Exchange\nSynthetic Garden - Meal Exchange",
        ])
        try assertHeldAsUnresolved(outcome, store: store)
    }

    func testSupportedV1InOneImagePlusIndeterminateV1InAnotherStaysA() async throws {
        let store = makeStore(local: StubLocalProvider(behavior: .output(orderDetails)))
        let outcome = await analyze(store, images: [
            "\(cart)\nJasper Kane Cafe - Meal Exchange",
            "\(cart)\nSynthetic Gar... - Meal Exchange",
        ])
        try assertHeldAsUnresolved(outcome, store: store)
    }

    // MARK: - Case 3: reliably supported V1 evidence

    func testReliablySupportedV1EvidencePreservesEAndDAnchoredOnTheV1Venue() async throws {
        let store = makeStore(local: StubLocalProvider(behavior: .output(orderDetails)))
        let analyzed = await analyze(store, images: ["\(cart)\nJasper Kane Cafe - Meal Exchange"])
        let outcome = try XCTUnwrap(analyzed)
        XCTAssertEqual(outcome.venueDisposition, .supported(palladium))
        XCTAssertEqual(outcome.proposal.selectedDiningSpot, palladium)

        // E
        var draft = RequestFoodFormDraft()
        let applied = store.apply(outcome, manualEdits: noManualEdits, to: &draft)
        XCTAssertTrue(applied.location)
        XCTAssertEqual(draft.selectedDiningSpot, palladium)

        // D against a differing requester-owned location: withheld until chosen.
        var manualDraft = RequestFoodFormDraft(selectedDiningSpot: crave, mealSwipes: 2)
        let original = manualDraft
        let edits = ScreenshotFieldManualEditState(hasManuallyEditedLocation: true)
        XCTAssertEqual(
            ScreenshotProposalStore.venueRecoveryKind(for: outcome, manualEdits: edits, draft: manualDraft),
            .manualMismatch(screenshot: palladium, manual: crave)
        )
        XCTAssertTrue(store.apply(outcome, manualEdits: edits, to: &manualDraft).isEmpty)
        XCTAssertEqual(manualDraft, original)
    }

    func testAProviderNamedVenueDisagreeingWithTheV1AnchorGainsNoAuthority() async throws {
        // The external result names a venue that disagrees with the V1 anchor.
        // On-device validation drops a venue the evidence does not ground, so
        // the proposal location is omitted and the result is A: provider
        // output never becomes venue authority.
        let external = StubExternalProvider(result: .success(ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(
                selectedDiningSpot: crave,
                mealItems: [MealItem(name: "Screenshot Bowl")]
            )
        )))
        let local = StubLocalProvider(availability: .unavailable(.modelNotEnabled), behavior: .output(orderDetails))
        let store = makeStore(local: local, external: external)

        let analyzed = await analyze(
            store, images: ["\(cart)\nJasper Kane Cafe - Meal Exchange"], authority: { "an-authority" }
        )
        let outcome = try XCTUnwrap(analyzed)

        XCTAssertEqual(external.analyzeCallCount, 1)
        XCTAssertNotEqual(outcome.proposal.selectedDiningSpot, crave)
        XCTAssertEqual(outcome.venueDisposition, .unresolved)
        var draft = RequestFoodFormDraft()
        let original = draft
        XCTAssertTrue(store.apply(outcome, manualEdits: noManualEdits, to: &draft).isEmpty)
        XCTAssertEqual(draft, original)
    }

    func testReconciliationOfSupportedV1AgainstADisagreeingProposalVenueIsA() {
        // The reconciliation rule itself, for a proposal venue that disagrees
        // with, or omits, the reliable V1 anchor.
        let supportedV1 = RequesterVenueClassification(disposition: .supported(palladium), hasV1Observation: true)
        let items = [MealItem(name: "Screenshot Bowl")]
        XCTAssertEqual(
            ScreenshotProposalStore.reconcileAcceptedCatalogAnchor(
                supportedV1, proposal: ScreenshotProposal(selectedDiningSpot: palladium, mealItems: items)
            ),
            .supported(palladium)
        )
        XCTAssertEqual(
            ScreenshotProposalStore.reconcileAcceptedCatalogAnchor(
                supportedV1, proposal: ScreenshotProposal(selectedDiningSpot: crave, mealItems: items)
            ),
            .unresolved
        )
        XCTAssertEqual(
            ScreenshotProposalStore.reconcileAcceptedCatalogAnchor(supportedV1, proposal: ScreenshotProposal(mealItems: items)),
            .unresolved
        )
    }

    func testSupportedV1WithNoProposalVenueRemainsA() async throws {
        // Provider text that disagrees with the evidence vetoes the location
        // (resolve-one-or-omit); the V1 venue alone is then not an E anchor.
        let vetoed = RequesterOrderRawOutput(
            visibleVenueText: "Crave NYU",
            foodItems: [.init(name: "Screenshot Bowl", quantity: 1, modifiers: [])],
            mealSwipes: nil
        )
        let store = makeStore(local: StubLocalProvider(behavior: .output(vetoed)))
        let analyzed = await analyze(store, images: ["\(cart)\nJasper Kane Cafe - Meal Exchange"])
        let outcome = try XCTUnwrap(analyzed)

        XCTAssertNil(outcome.proposal.selectedDiningSpot, "precondition: location was omitted")
        XCTAssertEqual(outcome.venueDisposition, .unresolved)
        var draft = RequestFoodFormDraft()
        let original = draft
        XCTAssertTrue(store.apply(outcome, manualEdits: noManualEdits, to: &draft).isEmpty)
        XCTAssertEqual(draft, original)
    }

    // MARK: - Case 1: no V1 observation keeps catalog recognition

    func testNoV1DiningDollarsKeepsLegitimateE() async throws {
        let store = makeStore(local: StubLocalProvider(behavior: .output(orderDetails)))
        let analyzed = await analyze(store, images: [diningDollarsCheckout])
        let outcome = try XCTUnwrap(analyzed)

        // Genuinely the Dining Dollars path, with catalog (not V1) venue evidence.
        XCTAssertEqual(outcome.proposal.menuPath, .diningDollars)
        XCTAssertEqual(outcome.proposal.selectedDiningSpot, palladium)
        XCTAssertEqual(outcome.venueDisposition, .supported(palladium))
        XCTAssertNil(ScreenshotProposalStore.venueRecoveryKind(
            for: outcome, manualEdits: noManualEdits, draft: RequestFoodFormDraft()
        ), "E applies without any A recovery")

        var draft = RequestFoodFormDraft()
        XCTAssertEqual(draft.menuPath, .mealExchange, "precondition: the form starts on the other path")
        let applied = store.apply(outcome, manualEdits: noManualEdits, to: &draft)
        XCTAssertTrue(applied.location)
        XCTAssertTrue(applied.menuPath)
        XCTAssertEqual(draft.selectedDiningSpot, palladium)
        XCTAssertEqual(draft.menuPath, .diningDollars)
        XCTAssertEqual(draft.orderDetails, "1 Screenshot Bowl")
    }

    func testNoV1DiningDollarsKeepsLegitimateDAgainstADifferingManualLocation() async throws {
        let store = makeStore(local: StubLocalProvider(behavior: .output(orderDetails)))
        let analyzed = await analyze(store, images: [diningDollarsCheckout])
        let outcome = try XCTUnwrap(analyzed)

        XCTAssertEqual(outcome.proposal.menuPath, .diningDollars)
        XCTAssertEqual(outcome.venueDisposition, .supported(palladium))

        var draft = RequestFoodFormDraft(selectedDiningSpot: crave, mealSwipes: 2)
        let original = draft
        let edits = ScreenshotFieldManualEditState(hasManuallyEditedLocation: true)
        XCTAssertEqual(
            ScreenshotProposalStore.venueRecoveryKind(for: outcome, manualEdits: edits, draft: draft),
            .manualMismatch(screenshot: palladium, manual: crave)
        )
        // Withheld: the mismatched screenshot venue, path and details do not
        // overwrite the requester's manual venue before an explicit choice.
        XCTAssertTrue(store.apply(outcome, manualEdits: edits, to: &draft).isEmpty)
        XCTAssertEqual(draft, original)

        // Keep: dismissal applies nothing (the view never calls `apply`).
        XCTAssertEqual(draft.selectedDiningSpot, crave)

        // Use & autofill: the explicit choice clears only the location's
        // manual flag, then the held outcome applies through the usual rules.
        var chosen = edits
        chosen.hasManuallyEditedLocation = false
        let applied = store.apply(outcome, manualEdits: chosen, to: &draft, venueConfirmation: true)
        XCTAssertTrue(applied.location)
        XCTAssertEqual(draft.selectedDiningSpot, palladium)
        XCTAssertEqual(draft.menuPath, .diningDollars)
        XCTAssertEqual(draft.orderDetails, "1 Screenshot Bowl")
    }

    // MARK: - Authority lost at the transfer boundary

    func testAuthorityLostAtTheTransferBoundaryKeepsTheNoUsefulExtractionNoticeAndFailsClosed() async throws {
        let external = StubExternalProvider()
        let store = makeStore(
            local: StubLocalProvider(behavior: .output(emptyRequesterOutput)),
            external: external
        )
        // The offer decision reads authority; the transfer boundary finds it gone.
        let authority = BoundaryScriptedAuthority(["an-authority", nil])

        let analyzed = await analyze(store, images: [cart], authority: { authority.read() })
        let outcome = try XCTUnwrap(analyzed, "the local outcome is still presented")

        XCTAssertEqual(authority.readCount, 2)
        XCTAssertEqual(external.analyzeCallCount, 0, "fail closed: no provider call")
        XCTAssertTrue(outcome.eligible)
        XCTAssertTrue(outcome.isEmpty)
        XCTAssertEqual(outcome.venueDisposition, .unresolved, "the venue disposition is not dropped")

        var draft = RequestFoodFormDraft()
        let original = draft
        XCTAssertTrue(store.apply(outcome, manualEdits: noManualEdits, to: &draft).isEmpty)
        XCTAssertEqual(draft, original)
        XCTAssertEqual(store.notice, .noUsefulExtraction)
    }

    func testAuthorityLostAtTheTransferBoundaryAfterALocalFailureStillPresentsOnlyTheUnavailableNotice() async {
        let external = StubExternalProvider()
        let store = makeStore(
            local: StubLocalProvider(behavior: .fail(StubLocalProvider.StubError())),
            external: external
        )
        let authority = BoundaryScriptedAuthority(["an-authority", nil])

        let outcome = await analyze(store, images: [cart], authority: { authority.read() })

        XCTAssertNil(outcome)
        XCTAssertEqual(external.analyzeCallCount, 0)
        XCTAssertEqual(store.notice, .unavailable)
    }
}
