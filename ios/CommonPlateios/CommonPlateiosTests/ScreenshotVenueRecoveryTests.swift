import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class ScreenshotVenueRecoveryTests: XCTestCase {
    private let noManualEdits = ScreenshotFieldManualEditState()

    private func makeStore(
        local: (any ScreenshotLocalProvider<RequesterOrderWorkflow>)? = nil,
        external: StubExternalProvider? = nil,
        qualification: ScreenshotQualificationRegistry? = nil,
        environment: ScreenshotDeviceEnvironment? = nil
    ) -> ScreenshotProposalStore {
        let client = APIClient(configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!))
        return ScreenshotProposalStore(
            availability: .enabledForTesting(),
            service: ScreenshotProposalService(availability: .enabledForTesting(), client: client),
            preferences: InMemoryScreenshotProposalPreferencesStorage(),
            runtime: makeRequesterTestRuntime(
                local: local,
                external: external ?? StubExternalProvider(),
                qualification: qualification,
                environment: environment
            )
        )
    }

    private var palladium: DiningSpot {
        SupportedVendorCatalog.diningSpots.first { $0.name == "Jasper Kane Cafe" }!
    }

    func testBlockedBAndCOutcomesCannotReachTheSingleApplicationSeam() {
        let store = makeStore()
        let original = RequestFoodFormDraft(selectedDiningSpot: palladium, mealSwipes: 2)
        let proposal = ScreenshotProposal(mealItems: [MealItem(name: "Screenshot Bowl")], mealSwipes: 1)
        for disposition in [RequesterVenueDisposition.unsupported("syntheticgarden"), .conflicting] {
            var draft = original
            let applied = store.apply(
                ScreenshotProposalOutcome(eligible: true, proposal: proposal, venueDisposition: disposition),
                manualEdits: noManualEdits,
                to: &draft
            )
            XCTAssertEqual(draft, original)
            XCTAssertTrue(applied.isEmpty)
        }
    }

    func testAWithholdsUntilExplicitConfirmationAndPathOnlyUsesExistingNoUsefulFallback() {
        let store = makeStore()
        let details = ScreenshotProposal(mealItems: [MealItem(name: "Screenshot Bowl")], mealSwipes: 1)
        let held = ScreenshotProposalOutcome(eligible: true, proposal: details, venueDisposition: .unresolved)
        var draft = RequestFoodFormDraft(selectedDiningSpot: palladium, mealSwipes: 2)
        let original = draft

        XCTAssertEqual(
            ScreenshotProposalStore.venueRecoveryKind(for: held, manualEdits: noManualEdits, draft: draft),
            .unresolved
        )
        XCTAssertTrue(store.apply(held, manualEdits: noManualEdits, to: &draft).isEmpty)
        XCTAssertEqual(draft, original)
        XCTAssertFalse(store.apply(held, manualEdits: noManualEdits, to: &draft, venueConfirmation: true).isEmpty)

        let pathOnly = ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(menuPath: .mealExchange),
            venueDisposition: .unresolved
        )
        XCTAssertNil(ScreenshotProposalStore.venueRecoveryKind(for: pathOnly, manualEdits: noManualEdits, draft: original))
        var pathOnlyDraft = original
        XCTAssertTrue(store.apply(pathOnly, manualEdits: noManualEdits, to: &pathOnlyDraft).isEmpty)
        XCTAssertEqual(pathOnlyDraft, original)
        XCTAssertEqual(store.notice, .noUsefulExtraction)
    }

    func testIneligibleOutcomeUsesUnsupportedNoticeBeforeUnanchoredPathHandling() {
        let store = makeStore()
        var draft = RequestFoodFormDraft(menuPath: .mealExchange)
        let original = draft
        let applied = store.apply(
            ScreenshotProposalOutcome(
                eligible: false,
                proposal: ScreenshotProposal(menuPath: .diningDollars),
                venueDisposition: .unresolved
            ),
            manualEdits: noManualEdits,
            to: &draft
        )

        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(draft, original)
        XCTAssertEqual(store.notice, .unsupportedScreenshot)
    }

    func testMissingVenueDispositionFailsClosedAtTheApplicationGate() {
        let store = makeStore()
        var draft = RequestFoodFormDraft(selectedDiningSpot: palladium, mealSwipes: 2)
        let original = draft
        let applied = store.apply(
            ScreenshotProposalOutcome(
                eligible: true,
                proposal: ScreenshotProposal(
                    selectedDiningSpot: palladium,
                    mealItems: [MealItem(name: "Screenshot Bowl")],
                    mealSwipes: 1
                )
            ),
            manualEdits: noManualEdits,
            to: &draft
        )

        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(draft, original)
        XCTAssertNil(store.notice)
    }

    func testSupportedDispositionWithoutItsMatchingProposalAnchorFailsClosed() {
        let store = makeStore()
        var draft = RequestFoodFormDraft(selectedDiningSpot: palladium, mealSwipes: 2)
        let original = draft
        let applied = store.apply(
            ScreenshotProposalOutcome(
                eligible: true,
                proposal: ScreenshotProposal(mealItems: [MealItem(name: "Screenshot Bowl")], mealSwipes: 1),
                venueDisposition: .supported(palladium)
            ),
            manualEdits: noManualEdits,
            to: &draft
        )

        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(draft, original)
    }

    func testConfirmedAWithNilProposalLocationUsesTheManualVenueForUsefulDetails() {
        let store = makeStore()
        let outcome = ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(
                mealItems: [MealItem(name: "Screenshot Bowl")],
                mealSwipes: 1
            ),
            venueDisposition: .supported(palladium)
        )
        var draft = RequestFoodFormDraft(selectedDiningSpot: palladium, mealSwipes: 2)
        let original = draft

        XCTAssertEqual(
            ScreenshotProposalStore.venueRecoveryKind(for: outcome, manualEdits: noManualEdits, draft: draft),
            .unresolved
        )
        XCTAssertTrue(store.apply(outcome, manualEdits: noManualEdits, to: &draft).isEmpty)
        XCTAssertEqual(draft, original)

        let applied = store.apply(outcome, manualEdits: noManualEdits, to: &draft, venueConfirmation: true)
        XCTAssertTrue(applied.mealItemNames.contains(0))
        XCTAssertTrue(applied.mealSwipes)
        XCTAssertEqual(draft.selectedDiningSpot, palladium)
        XCTAssertEqual(draft.mealEntries[0].name, "Screenshot Bowl")
        XCTAssertEqual(draft.mealSwipes, 1)
    }

    func testSupportedDiningDollarsRecognitionRemainsAnApplyableStateEOutcome() {
        let store = makeStore()
        let outcome = ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(
                menuPath: .diningDollars,
                selectedDiningSpot: palladium,
                diningDollarsOrderTotalCents: 1200
            ),
            venueDisposition: .supported(palladium)
        )
        var draft = RequestFoodFormDraft()

        let applied = store.apply(outcome, manualEdits: noManualEdits, to: &draft)

        XCTAssertTrue(applied.location)
        XCTAssertTrue(applied.diningDollarsOnly)
        XCTAssertEqual(draft.selectedDiningSpot, palladium)
        XCTAssertEqual(draft.menuPath, .diningDollars)
        XCTAssertEqual(draft.diningDollarsOnlyText, "$12.00")
    }

    func testExistingCatalogRecognitionWithoutMealExchangeHeaderReconcilesToE() async {
        let local = StubLocalProvider(
            availability: .available,
            behavior: .output(.init(
                visibleVenueText: nil,
                foodItems: [.init(name: "Screenshot Bowl", quantity: 1, modifiers: [])],
                mealSwipes: nil
            ))
        )
        let store = makeStore(
            local: local,
            qualification: qualifiedRegistry(environment: testQualifiableEnvironment),
            environment: testQualifiableEnvironment
        )
        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let outcome = await store.analyzeScreenshot(
            images: [ScreenshotTestEvidence.input("Your Pickup Order\nContinue to Checkout\nJasper Kane Cafe")],
            participantAuthority: { nil },
            token: token
        )

        XCTAssertEqual(outcome?.venueDisposition, .supported(palladium))
        XCTAssertEqual(outcome?.proposal.selectedDiningSpot, palladium)
        let applied = store.apply(outcome!, manualEdits: noManualEdits, to: &draft)
        XCTAssertTrue(applied.location)
        XCTAssertEqual(draft.selectedDiningSpot, palladium)
    }

    func testUnresolvedCatalogLocationIsAUntilConfirmedAndNeverCreatesD() {
        let store = makeStore()
        let manual = SupportedVendorCatalog.diningSpots.first { $0.name == "Crave NYU" }!
        let outcome = ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(
                selectedDiningSpot: palladium,
                mealItems: [MealItem(name: "Screenshot Bowl")],
                mealSwipes: 1
            ),
            venueDisposition: .unresolved
        )
        var draft = RequestFoodFormDraft(selectedDiningSpot: manual, mealSwipes: 2)
        let edits = ScreenshotFieldManualEditState(hasManuallyEditedLocation: true)
        let original = draft

        XCTAssertEqual(
            ScreenshotProposalStore.venueRecoveryKind(for: outcome, manualEdits: edits, draft: draft),
            .unresolved
        )
        XCTAssertTrue(store.apply(outcome, manualEdits: edits, to: &draft).isEmpty)
        XCTAssertEqual(draft, original)

        let applied = store.apply(outcome, manualEdits: edits, to: &draft, venueConfirmation: true)
        XCTAssertFalse(applied.location)
        XCTAssertTrue(applied.mealItemNames.contains(0))
        XCTAssertEqual(draft.selectedDiningSpot, manual)
        XCTAssertEqual(draft.mealEntries[0].name, "Screenshot Bowl")
    }

    func testUnresolvedCatalogLocationWithoutOrderDetailsUsesNoUsefulFallback() {
        let store = makeStore()
        var draft = RequestFoodFormDraft()
        let outcome = ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(menuPath: .diningDollars, selectedDiningSpot: palladium),
            venueDisposition: .unresolved
        )

        XCTAssertNil(ScreenshotProposalStore.venueRecoveryKind(for: outcome, manualEdits: noManualEdits, draft: draft))
        XCTAssertTrue(store.apply(outcome, manualEdits: noManualEdits, to: &draft, venueConfirmation: true).isEmpty)
        XCTAssertNil(draft.selectedDiningSpot)
        XCTAssertEqual(store.notice, .noUsefulExtraction)
    }

    func testConfirmedAPathConflictSwitchCarriesOnlyThatResultsAuthorization() {
        let store = makeStore()
        var draft = RequestFoodFormDraft(selectedDiningSpot: palladium, menuPath: .mealExchange)
        var edits = ScreenshotFieldManualEditState(
            hasManuallyEditedLocation: true,
            hasManuallyEditedMenuPath: true
        )
        let token = store.beginSelection(clearing: &draft, manualEdits: edits)
        draft.selectedDiningSpot = palladium
        let outcome = ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(
                menuPath: .diningDollars,
                mealItems: [MealItem(name: "Screenshot Bowl")],
                diningDollarsOrderTotalCents: 1200
            ),
            venueDisposition: .unresolved
        )
        let confirmation = ScreenshotVenueRecovery(
            token: token,
            outcome: outcome,
            kind: .unresolved,
            wasGenuineRerun: false
        )

        let first = store.apply(outcome, manualEdits: edits, to: &draft, venueConfirmation: true)
        XCTAssertEqual(first.suggestedMenuPath, RequestMenuPath.diningDollars)
        XCTAssertEqual(draft.menuPath, RequestMenuPath.mealExchange)
        XCTAssertEqual(draft.mealEntries, RequestFoodFormDraft.emptyMealEntries)

        var conflict = ScreenshotMenuPathConflictState()
        conflict.present(first.suggestedMenuPath, outcome: outcome, for: token, venueConfirmation: confirmation)
        let heldConflict = try! XCTUnwrap(conflict.suggestion)
        XCTAssertEqual(heldConflict.venueConfirmation, confirmation)

        edits.hasManuallyEditedMenuPath = false
        let switched = store.apply(
            heldConflict.outcome,
            manualEdits: edits,
            to: &draft,
            venueConfirmation: heldConflict.venueConfirmation != nil
        )
        XCTAssertTrue(switched.menuPath)
        XCTAssertEqual(draft.menuPath, RequestMenuPath.diningDollars)
        XCTAssertEqual(draft.orderDetails, "Screenshot Bowl")
        XCTAssertEqual(draft.diningDollarsOnlyText, "$12.00")
    }

    func testConfirmedAThenPathSwitchDoesNotDuplicateCompletionOrPreservedFeedback() {
        let store = makeStore()
        var draft = RequestFoodFormDraft(selectedDiningSpot: palladium, menuPath: .mealExchange)
        var edits = ScreenshotFieldManualEditState(
            hasManuallyEditedLocation: true,
            hasManuallyEditedMenuPath: true
        )
        let token = store.beginSelection(clearing: &draft, manualEdits: edits)
        draft.selectedDiningSpot = palladium
        let outcome = ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(
                menuPath: .diningDollars,
                mealItems: [MealItem(name: "Screenshot Bowl")],
                diningDollarsOrderTotalCents: 1200
            ),
            venueDisposition: .supported(palladium)
        )
        let recovery = ScreenshotVenueRecovery(token: token, outcome: outcome, kind: .unresolved, wasGenuineRerun: false)
        var feedback = ScreenshotPreservedEntryFeedbackState()

        XCTAssertEqual(feedback.recordCompletedAnalysis(eligible: true), false)
        let first = store.apply(outcome, manualEdits: edits, to: &draft, venueConfirmation: true)
        XCTAssertEqual(first.suggestedMenuPath, .diningDollars)
        XCTAssertNil(feedback.showPreservedEntryFeedback(wasGenuineRerun: recovery.wasGenuineRerun, applying: first))

        var conflict = ScreenshotMenuPathConflictState()
        conflict.present(first.suggestedMenuPath, outcome: outcome, for: token, venueConfirmation: recovery)
        let held = try! XCTUnwrap(conflict.suggestion)
        edits.hasManuallyEditedMenuPath = false
        let switched = store.apply(
            held.outcome,
            manualEdits: edits,
            to: &draft,
            venueConfirmation: held.venueConfirmation != nil
        )

        XCTAssertTrue(switched.orderDetails)
        XCTAssertFalse(switched.didPreserveManualContent)
        XCTAssertEqual(draft.menuPath, .diningDollars)
        XCTAssertEqual(draft.orderDetails, "Screenshot Bowl")
        XCTAssertTrue(feedback.hasCompletedScreenshotAssistanceRun)
        XCTAssertFalse(feedback.isShowing)
        XCTAssertNil(feedback.showPreservedEntryFeedback(wasGenuineRerun: recovery.wasGenuineRerun, applying: switched))
    }

    func testVenueRecoveryDismissalAndReplacementRemainResultScoped() {
        let store = makeStore()
        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let otherToken = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        let outcome = ScreenshotProposalOutcome(eligible: true, proposal: ScreenshotProposal(mealSwipes: 1), venueDisposition: .unresolved)
        var state = ScreenshotVenueRecoveryState()
        state.present(ScreenshotVenueRecovery(token: token, outcome: outcome, kind: .unresolved, wasGenuineRerun: false))
        state.dismiss()
        XCTAssertNil(state.recovery)
        state.present(ScreenshotVenueRecovery(token: token, outcome: outcome, kind: .unresolved, wasGenuineRerun: false))
        XCTAssertNil(state.recovery)
        state.present(ScreenshotVenueRecovery(token: otherToken, outcome: outcome, kind: .unresolved, wasGenuineRerun: false))
        XCTAssertNotNil(state.recovery)
        state.clear()
        XCTAssertNil(state.recovery)
    }

    func testDPreservesManualLocationUntilItsExplicitUseChoice() {
        let store = makeStore()
        let screenshot = palladium
        let manual = SupportedVendorCatalog.diningSpots.first { $0.name == "Crave NYU" }!
        let outcome = ScreenshotProposalOutcome(
            eligible: true,
            proposal: ScreenshotProposal(selectedDiningSpot: screenshot, mealItems: [MealItem(name: "Screenshot Bowl")]),
            venueDisposition: .supported(screenshot)
        )
        var draft = RequestFoodFormDraft(selectedDiningSpot: manual)
        var edits = ScreenshotFieldManualEditState(hasManuallyEditedLocation: true)
        XCTAssertEqual(
            ScreenshotProposalStore.venueRecoveryKind(for: outcome, manualEdits: edits, draft: draft),
            .manualMismatch(screenshot: screenshot, manual: manual)
        )
        XCTAssertTrue(store.apply(outcome, manualEdits: edits, to: &draft).isEmpty)
        XCTAssertEqual(draft.selectedDiningSpot, manual)

        edits.hasManuallyEditedLocation = false
        _ = store.apply(outcome, manualEdits: edits, to: &draft, venueConfirmation: true)
        XCTAssertEqual(draft.selectedDiningSpot, screenshot)
    }

    func testBStopsBeforeAuthorityReadPermissionAndExternalProviderAfterUnchangedLocalAttempt() async {
        let local = StubLocalProvider(availability: .unavailable(.modelNotEnabled), behavior: .output(.init(visibleVenueText: nil, foodItems: [], mealSwipes: nil)))
        let external = StubExternalProvider()
        let store = makeStore(
            local: local,
            external: external,
            qualification: qualifiedRegistry(environment: testQualifiableEnvironment),
            environment: testQualifiableEnvironment
        )
        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: noManualEdits)
        var authorityReads = 0
        let evidence = "Your Pickup Order\nContinue to Checkout\nSynthetic Garden - Meal Exchange"

        let outcome = await store.analyzeScreenshot(
            images: [ScreenshotTestEvidence.input(evidence)],
            participantAuthority: { authorityReads += 1; return "authority" },
            token: token
        )

        XCTAssertEqual(outcome?.venueDisposition, .unsupported("syntheticgarden"))
        XCTAssertEqual(local.availabilityCallCount, 1, "the local attempt remains unchanged")
        XCTAssertEqual(authorityReads, 0, "B stops before participant authority is read")
        XCTAssertEqual(external.analyzeCallCount, 0, "B mints no permission and invokes no provider")
        XCTAssertFalse(store.isApplying)
    }

    func testCompletedARecordsRerunBeforeConfirmationButFeedbackNeedsRealPreservation() {
        var state = ScreenshotPreservedEntryFeedbackState()
        XCTAssertEqual(state.recordCompletedAnalysis(eligible: true), false)
        XCTAssertNil(state.showPreservedEntryFeedback(
            wasGenuineRerun: false,
            applying: ScreenshotProposalAppliedFields(preservedManualFieldCount: 1)
        ))
        XCTAssertEqual(state.recordCompletedAnalysis(eligible: true), true)
        XCTAssertNil(state.showPreservedEntryFeedback(
            wasGenuineRerun: true,
            applying: ScreenshotProposalAppliedFields()
        ))
        XCTAssertNotNil(state.showPreservedEntryFeedback(
            wasGenuineRerun: true,
            applying: ScreenshotProposalAppliedFields(preservedManualFieldCount: 1)
        ))
    }
}
