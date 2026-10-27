import SwiftUI
import XCTest
@testable import CommonPlateios

/// W4-R5 D-R5-4: optional Screenshot Assistance on Edit. The domain rules are
/// R4.2's and are proven in their own files; these tests prove the Edit glue
/// treats saved content as requester-owned and never lets a held or stale
/// result mutate it.
@MainActor
final class EditRequestScreenshotAssistanceTests: XCTestCase {
    private let palladium = SupportedVendorCatalog.diningSpots.first { $0.name == "Jasper Kane Cafe" }!
    private lazy var otherSpot = SupportedVendorCatalog.diningSpots.first { $0.name != "Jasper Kane Cafe" }!

    private func makeStore() -> ScreenshotProposalStore {
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: .ephemeral)
        )
        return ScreenshotProposalStore(
            availability: .enabledForTesting(),
            service: ScreenshotProposalService(availability: .enabledForTesting(), client: client),
            preferences: InMemoryScreenshotProposalPreferencesStorage()
        )
    }

    private func savedDraft() -> RequestFoodFormDraft {
        var draft = RequestFoodFormDraft(mealSwipes: 1)
        draft.selectedDiningSpot = palladium
        draft.menuPath = .mealExchange
        draft.mealEntries[0].name = "Saved bowl"
        return draft
    }

    private func outcome(
        _ proposal: ScreenshotProposal,
        venue: DiningSpot? = nil
    ) -> ScreenshotProposalOutcome {
        let spot = venue ?? palladium
        var anchored = proposal
        anchored.selectedDiningSpot = spot
        return ScreenshotProposalOutcome(
            eligible: true,
            proposal: anchored,
            venueDisposition: .supported(spot)
        )
    }

    func testSeedingTreatsEverySavedValueAsRequesterOwnedAndRestoresNoProvenance() {
        var draft = savedDraft()
        draft.mealEntries[0].details = "No mayo"
        let state = EditScreenshotAssistanceState.seeded(from: draft)

        XCTAssertTrue(state.manualEdits.hasManuallyEditedLocation)
        XCTAssertTrue(state.manualEdits.hasManuallyEditedMealSwipes)
        XCTAssertTrue(state.manualEdits.hasManuallyEditedMenuPath)
        XCTAssertTrue(state.manualEdits.hasManuallyEditedMealItemName(0))
        XCTAssertTrue(state.manualEdits.hasManuallyEditedMealItemDetails(0))
        XCTAssertFalse(state.manualEdits.hasManuallyEditedMealItemName(1))
        XCTAssertEqual(state.provenance, ScreenshotProposalAppliedFields())
        XCTAssertFalse(state.checked)
    }

    func testBeginningASelectionNeverClearsSavedContent() {
        let store = makeStore()
        var draft = savedDraft()
        let state = EditScreenshotAssistanceState.seeded(from: draft)
        let before = draft
        _ = store.beginSelection(clearing: &draft, manualEdits: state.manualEdits)
        XCTAssertEqual(draft, before)
    }

    func testAScreenshotFillsOnlyEmptyFieldsAndKeepsSavedOnes() {
        let store = makeStore()
        var draft = savedDraft()
        var state = EditScreenshotAssistanceState.seeded(from: draft)
        let token = store.beginSelection(clearing: &draft, manualEdits: state.manualEdits)
        let proposal = ScreenshotProposal(
            menuPath: .mealExchange,
            mealItems: [MealItem(name: "Screenshot bowl"), MealItem(name: "Screenshot pasta", details: "Sauce")],
            mealSwipes: 2
        )

        state.apply(outcome(proposal), token: token, store: store, to: &draft)

        XCTAssertEqual(draft.mealEntries[0].name, "Saved bowl", "a saved value is never overwritten")
        XCTAssertEqual(draft.mealSwipes, 1, "a saved count is only ever suggested against")
        XCTAssertEqual(state.mealSwipeMismatch.suggestion?.proposedCount, 2)
        XCTAssertTrue(state.checked)

        // Explicit adoption is the only way the count changes.
        let suggestion = try! XCTUnwrap(state.mealSwipeMismatch.suggestion)
        state.adoptSuggestedMealSwipes(suggestion, store: store, to: &draft)
        XCTAssertEqual(draft.mealSwipes, 2)
        XCTAssertEqual(draft.mealEntries[0].name, "Saved bowl")
        XCTAssertEqual(draft.mealEntries[1].name, "Screenshot pasta")
    }

    func testDismissingTheSwipeSuggestionRejectsOnlySurplusTheScreenshotWrote() {
        let store = makeStore()
        var draft = savedDraft()
        var state = EditScreenshotAssistanceState.seeded(from: draft)
        let token = store.beginSelection(clearing: &draft, manualEdits: state.manualEdits)
        state.apply(
            outcome(ScreenshotProposal(
                menuPath: .mealExchange,
                mealItems: [MealItem(name: "A"), MealItem(name: "B")],
                mealSwipes: 2
            )),
            token: token,
            store: store,
            to: &draft
        )
        XCTAssertEqual(draft.mealEntries[1].name, "B")
        let suggestion = try! XCTUnwrap(state.mealSwipeMismatch.suggestion)

        state.dismissMealSwipeMismatch(suggestion, store: store, in: &draft)

        XCTAssertEqual(draft.mealEntries[1].name, "")
        XCTAssertEqual(draft.mealEntries[0].name, "Saved bowl")
        XCTAssertNil(state.mealSwipeMismatch.suggestion)
    }

    func testADifferentVenueIsHeldUntilTheRequesterConfirmsIt() throws {
        let store = makeStore()
        var draft = savedDraft()
        var state = EditScreenshotAssistanceState.seeded(from: draft)
        let token = store.beginSelection(clearing: &draft, manualEdits: state.manualEdits)

        state.apply(
            outcome(ScreenshotProposal(menuPath: .mealExchange, mealItems: [MealItem(name: "Wrap")], mealSwipes: 1), venue: otherSpot),
            token: token,
            store: store,
            to: &draft
        )

        let recovery = try XCTUnwrap(state.venueRecovery.recovery)
        guard case .manualMismatch = recovery.kind else { return XCTFail("\(recovery.kind)") }
        XCTAssertEqual(draft.selectedDiningSpot, palladium, "nothing applies before the explicit choice")
        XCTAssertEqual(draft.mealEntries[0].name, "Saved bowl")

        state.confirmVenueRecovery(recovery, store: store, to: &draft)
        XCTAssertEqual(draft.selectedDiningSpot, otherSpot)
        XCTAssertNil(state.venueRecovery.recovery)
    }

    func testTheSameVenueAsASavedRequestRaisesNoVenueConflict() {
        let store = makeStore()
        var draft = EditRequestPresentation.draft(from: EditScreenshotFixtures.owner())
        var state = EditScreenshotAssistanceState.seeded(from: draft)
        let token = store.beginSelection(clearing: &draft, manualEdits: state.manualEdits)

        state.apply(
            outcome(ScreenshotProposal(menuPath: .mealExchange, mealItems: [MealItem(name: "Wrap")], mealSwipes: 1)),
            token: token,
            store: store,
            to: &draft
        )

        XCTAssertNil(state.venueRecovery.recovery, "a saved venue with no address is the same venue")
        XCTAssertEqual(draft.selectedDiningSpot?.name, "Jasper Kane Cafe")
        XCTAssertEqual(draft.mealEntries[0].name, "Chicken bowl")
    }

    func testConfirmingADifferentVenueStillOffersTheOppositeMenuPathAsASuggestion() throws {
        let store = makeStore()
        var draft = savedDraft()
        draft.menuPath = .diningDollars
        draft.diningDollarsOnlyText = "2.00"
        var state = EditScreenshotAssistanceState.seeded(from: draft)
        let token = store.beginSelection(clearing: &draft, manualEdits: state.manualEdits)

        state.apply(
            outcome(ScreenshotProposal(menuPath: .mealExchange, mealItems: [MealItem(name: "Wrap")], mealSwipes: 1), venue: otherSpot),
            token: token,
            store: store,
            to: &draft
        )
        let recovery = try XCTUnwrap(state.venueRecovery.recovery)
        state.confirmVenueRecovery(recovery, store: store, to: &draft)

        XCTAssertEqual(draft.selectedDiningSpot, otherSpot)
        XCTAssertEqual(draft.menuPath, .diningDollars, "the saved path is never switched without Switch")
        XCTAssertEqual(state.menuPathConflict.suggestion?.proposedPath, .mealExchange)
        XCTAssertEqual(draft.diningDollarsOnlyText, "2.00")
    }

    func testDismissingVenueRecoveryKeepsTheSavedVenue() throws {
        let store = makeStore()
        var draft = savedDraft()
        var state = EditScreenshotAssistanceState.seeded(from: draft)
        let token = store.beginSelection(clearing: &draft, manualEdits: state.manualEdits)
        state.apply(
            outcome(ScreenshotProposal(mealItems: [MealItem(name: "Wrap")], mealSwipes: 1), venue: otherSpot),
            token: token,
            store: store,
            to: &draft
        )
        let recovery = try XCTUnwrap(state.venueRecovery.recovery)
        state.dismissVenueRecovery(recovery, store: store)
        XCTAssertNil(state.venueRecovery.recovery)
        XCTAssertEqual(draft.selectedDiningSpot, palladium)
        XCTAssertEqual(draft.mealEntries[0].name, "Saved bowl")
    }

    func testUnsupportedAndConflictingVenuesNeverApplyAnything() throws {
        for disposition in [RequesterVenueDisposition.unsupported("Other Cafe"), .conflicting] {
            let store = makeStore()
            var draft = savedDraft()
            var state = EditScreenshotAssistanceState.seeded(from: draft)
            let token = store.beginSelection(clearing: &draft, manualEdits: state.manualEdits)
            let before = draft
            state.apply(
                ScreenshotProposalOutcome(
                    eligible: true,
                    proposal: ScreenshotProposal(mealItems: [MealItem(name: "X")], mealSwipes: 1),
                    venueDisposition: disposition
                ),
                token: token,
                store: store,
                to: &draft
            )
            XCTAssertNotNil(state.venueRecovery.recovery, "\(disposition)")
            XCTAssertEqual(draft, before, "\(disposition)")
            XCTAssertFalse(state.checked, "\(disposition) is not a completed assistance outcome")
        }
    }

    func testAnOppositeMenuPathIsOnlySuggestedUntilSwitchIsChosen() throws {
        let store = makeStore()
        var draft = savedDraft()
        var state = EditScreenshotAssistanceState.seeded(from: draft)
        let token = store.beginSelection(clearing: &draft, manualEdits: state.manualEdits)
        state.apply(
            outcome(ScreenshotProposal(
                menuPath: .diningDollars,
                mealItems: [MealItem(name: "Bowl")],
                diningDollarsOrderTotalCents: 1200
            )),
            token: token,
            store: store,
            to: &draft
        )
        let conflict = try XCTUnwrap(state.menuPathConflict.suggestion)
        XCTAssertEqual(conflict.proposedPath, .diningDollars)
        XCTAssertEqual(draft.menuPath, .mealExchange)

        state.switchMenuPath(conflict, store: store, to: &draft)
        XCTAssertEqual(draft.menuPath, .diningDollars)
    }

    func testClearingASavedFieldReleasesOnlyThatFieldsProtection() {
        let store = makeStore()
        var draft = savedDraft()
        var state = EditScreenshotAssistanceState.seeded(from: draft)
        state.setMealName("", at: 0, in: &draft)
        XCTAssertFalse(state.manualEdits.hasManuallyEditedMealItemName(0))
        XCTAssertTrue(state.manualEdits.hasManuallyEditedLocation)

        let token = store.beginSelection(clearing: &draft, manualEdits: state.manualEdits)
        state.apply(
            outcome(ScreenshotProposal(menuPath: .mealExchange, mealItems: [MealItem(name: "Screenshot bowl")], mealSwipes: 1)),
            token: token,
            store: store,
            to: &draft
        )
        XCTAssertEqual(draft.mealEntries[0].name, "Screenshot bowl")
        XCTAssertEqual(draft.selectedDiningSpot, palladium)
    }

    func testAStaleOutcomeCannotConfirmAHeldRecovery() throws {
        let store = makeStore()
        var draft = savedDraft()
        var state = EditScreenshotAssistanceState.seeded(from: draft)
        let token = store.beginSelection(clearing: &draft, manualEdits: state.manualEdits)
        state.apply(
            outcome(ScreenshotProposal(mealItems: [MealItem(name: "Wrap")], mealSwipes: 1), venue: otherSpot),
            token: token,
            store: store,
            to: &draft
        )
        let recovery = try XCTUnwrap(state.venueRecovery.recovery)

        store.invalidateCurrentSelection()
        state.confirmVenueRecovery(recovery, store: store, to: &draft)

        XCTAssertEqual(draft.selectedDiningSpot, palladium)
    }

    func testAStartedSelectionRetiresThePreviousResultPresentation() throws {
        let store = makeStore()
        var draft = savedDraft()
        var state = EditScreenshotAssistanceState.seeded(from: draft)
        let token = store.beginSelection(clearing: &draft, manualEdits: state.manualEdits)
        state.apply(
            outcome(ScreenshotProposal(mealItems: [MealItem(name: "Wrap")], mealSwipes: 1), venue: otherSpot),
            token: token,
            store: store,
            to: &draft
        )
        XCTAssertNotNil(state.venueRecovery.recovery)
        state.beginSelection()
        XCTAssertNil(state.venueRecovery.recovery)
        XCTAssertFalse(state.checked)
    }

    func testPreservedEntryFeedbackShowsOnlyOnALaterAnalysisThatKeptSavedValues() {
        let store = makeStore()
        var draft = savedDraft()
        var state = EditScreenshotAssistanceState.seeded(from: draft)
        let proposal = ScreenshotProposal(
            menuPath: .mealExchange,
            mealItems: [MealItem(name: "Screenshot bowl")],
            mealSwipes: 1
        )

        let firstToken = store.beginSelection(clearing: &draft, manualEdits: state.manualEdits)
        state.beginSelection()
        let first = state.apply(outcome(proposal), token: firstToken, store: store, to: &draft)
        XCTAssertNil(first, "an initial successful analysis never shows it")
        XCTAssertFalse(state.preservedEntryFeedback.isShowing)

        let secondToken = store.beginSelection(clearing: &draft, manualEdits: state.manualEdits)
        state.beginSelection()
        let second = state.apply(outcome(proposal), token: secondToken, store: store, to: &draft)
        let generation = try! XCTUnwrap(second)
        XCTAssertTrue(state.preservedEntryFeedback.isShowing)
        XCTAssertEqual(draft.mealEntries[0].name, "Saved bowl")

        state.preservedEntryFeedback.clearAfterTimeout(ifCurrent: generation &+ 1)
        XCTAssertTrue(state.preservedEntryFeedback.isShowing, "a stale timeout cannot hide a newer message")
        state.preservedEntryFeedback.clearAfterTimeout(ifCurrent: generation)
        XCTAssertFalse(state.preservedEntryFeedback.isShowing, "the message dismisses itself")

        state.beginSelection()
        XCTAssertFalse(state.preservedEntryFeedback.isShowing, "a new selection retires it")
    }

    func testAnIneligibleOutcomeNeverCountsAsACompletedAnalysis() {
        let store = makeStore()
        var draft = savedDraft()
        var state = EditScreenshotAssistanceState.seeded(from: draft)
        let token = store.beginSelection(clearing: &draft, manualEdits: state.manualEdits)
        let result = state.apply(
            ScreenshotProposalOutcome(eligible: false, proposal: ScreenshotProposal(), venueDisposition: nil),
            token: token,
            store: store,
            to: &draft
        )
        XCTAssertNil(result)
        XCTAssertFalse(state.checked)
        XCTAssertFalse(state.preservedEntryFeedback.isShowing)
    }

    // MARK: Hosted

    func testEditShowsTheOptionalScreenshotAssistanceEntryPoint() throws {
        let owner = EditScreenshotFixtures.owner()
        let host = try OwnerRequestHost { store, path in
            AnyView(EditScreenshotFixtures.editView(store: store, owner: owner, path: path))
        }
        XCTAssertTrue(host.exists("edit-request-screenshot-picker"), "\(host.nodes().keys.sorted())")
        XCTAssertFalse(host.exists("edit-request-screenshot-turn-on"))
        XCTAssertTrue(host.exists("edit-request-save"))
    }

    func testEditShowsTurnOnWhenAssistanceIsOff() throws {
        let owner = EditScreenshotFixtures.owner()
        let host = try OwnerRequestHost { store, path in
            AnyView(EditScreenshotFixtures.editView(store: store, owner: owner, path: path, enabled: false))
        }
        XCTAssertTrue(host.exists("edit-request-screenshot-turn-on"), "\(host.nodes().keys.sorted())")
        XCTAssertFalse(host.exists("edit-request-screenshot-picker"))
    }
}

@MainActor
enum EditScreenshotFixtures {
    static func editView(
        store: RequestStore,
        owner: OwnerRequest,
        path: Binding<[AppRoute]>,
        enabled: Bool = true
    ) -> EditRequestView {
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: .ephemeral)
        )
        let screenshotStore = ScreenshotProposalStore(
            availability: .enabledForTesting(),
            service: ScreenshotProposalService(availability: .enabledForTesting(), client: client),
            preferences: InMemoryScreenshotProposalPreferencesStorage()
        )
        screenshotStore.setAIAssistanceEnabled(enabled)
        return EditRequestView(
            store: store,
            screenshotProposalStore: screenshotStore,
            identityStore: ParticipantIdentityStore(
                service: ParticipantVerificationService(client: client),
                storage: InMemoryParticipantIdentityStorage()
            ),
            owner: owner,
            path: path
        )
    }

    static func owner() -> OwnerRequest {
        OwnerRequest(
            request: FoodRequest(
                id: "h1",
                diningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
                foodDescription: "Chicken bowl",
                pickupWindowText: "ASAP",
                mealSwipes: 1,
                resource: RequestResource(
                    menuPath: .mealExchange,
                    mealItems: [MealItem(name: "Chicken bowl")],
                    orderDetails: nil,
                    estimatedDiningDollarsCents: nil
                ),
                windowStart: nil,
                windowEnd: nil,
                createdAt: Date(timeIntervalSince1970: 1_784_000_000),
                expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
                status: .open,
                ownership: .own
            ),
            phase: .available,
            contentRevision: 3,
            canEdit: true,
            canWithdraw: true,
            latestScheduledStart: Date(timeIntervalSince1970: 4_000_000_000)
        )
    }
}
