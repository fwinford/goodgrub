//
//  ScreenshotMenuPathApplicationTests.swift
//  CommonPlateiosTests
//
// W4-R4.1 application and authority: a deterministic path is applied FIRST,
// switches the selector until the requester actually changes it, never writes
// opposite-path evidence into the retained branch or fabricates an amount. The
// end-to-end cases drive the real store → runtime → external provider →
// `ScreenshotProposalService` (a stubbed transport) → on-device re-validation
// chain with synthetic evidence; there is no UI-test target, so the `Form`
// harness stands in for the view exactly as
// `ScreenshotPreservedEntryFeedbackLifecycleTests` does.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class ScreenshotMenuPathApplicationTests: XCTestCase {
    override func tearDown() {
        ScreenshotProposalURLProtocol.reset()
        super.tearDown()
    }

    private let palladium = SupportedVendorCatalog.diningSpots.first { $0.name == "Jasper Kane Cafe" }!

    private func makeStore() -> ScreenshotProposalStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScreenshotProposalURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
        return makeProductionWiredRequesterStore(
            service: ScreenshotProposalService(availability: .enabledForTesting(), client: client),
            preferences: InMemoryScreenshotProposalPreferencesStorage()
        )
    }

    private func outcome(_ proposal: ScreenshotProposal, eligible: Bool = true) -> ScreenshotProposalOutcome {
        // R4.2 requires an actual supported venue anchor before a path (or
        // any other screenshot field) may apply. These R4.1 path fixtures are
        // ordinary State E controls, not implicit A/D confirmations.
        var anchored = proposal
        if anchored.selectedDiningSpot == nil {
            anchored.selectedDiningSpot = palladium
        }
        return ScreenshotProposalOutcome(
            eligible: eligible,
            proposal: anchored,
            venueDisposition: .supported(palladium)
        )
    }

    // MARK: - First deterministic path switches; path is applied first

    func testFirstDeterministicPathSwitchesTheSelectorInBothDirections() {
        let store = makeStore()
        var draft = RequestFoodFormDraft(menuPath: .mealExchange)

        let toDining = store.apply(
            outcome(ScreenshotProposal(menuPath: .diningDollars)),
            manualEdits: ScreenshotFieldManualEditState(),
            to: &draft
        )
        XCTAssertEqual(draft.menuPath, .diningDollars)
        XCTAssertTrue(toDining.menuPath)
        XCTAssertTrue(toDining.establishedMenuPath)
        XCTAssertEqual(toDining.preservedManualFieldCount, 0, "a branch switch alone is not preservation")
        XCTAssertFalse(toDining.isEmpty)

        let toMeal = store.apply(
            outcome(ScreenshotProposal(menuPath: .mealExchange)),
            manualEdits: ScreenshotFieldManualEditState(),
            to: &draft
        )
        XCTAssertEqual(draft.menuPath, .mealExchange)
        XCTAssertTrue(toMeal.menuPath)
        XCTAssertEqual(toMeal.preservedManualFieldCount, 0)
    }

    func testDefaultAndSameValueRetapBothAutoSwitchToDiningDollars() {
        let store = makeStore()
        for retap in [false, true] {
            var draft = RequestFoodFormDraft(menuPath: .mealExchange)
            var manual = ScreenshotFieldManualEditState()
            if retap {
                manual.recordMenuPathSelection(from: draft.menuPath, to: .mealExchange)
            }
            XCTAssertFalse(manual.hasManuallyEditedMenuPath)
            let applied = store.apply(outcome(ScreenshotProposal(menuPath: .diningDollars)), manualEdits: manual, to: &draft)
            XCTAssertEqual(draft.menuPath, .diningDollars)
            XCTAssertTrue(applied.menuPath)
            XCTAssertNil(applied.suggestedMenuPath)
        }
    }

    func testBothActualChangesMoveManualAuthorityToTheCurrentPath() {
        var draft = RequestFoodFormDraft(menuPath: .mealExchange)
        var manual = ScreenshotFieldManualEditState()
        manual.recordMenuPathSelection(from: draft.menuPath, to: .diningDollars)
        draft.menuPath = .diningDollars
        XCTAssertTrue(manual.hasManuallyEditedMenuPath)
        manual.recordMenuPathSelection(from: draft.menuPath, to: .mealExchange)
        draft.menuPath = .mealExchange
        XCTAssertTrue(manual.hasManuallyEditedMenuPath)
        let applied = makeStore().apply(outcome(ScreenshotProposal(menuPath: .diningDollars)), manualEdits: manual, to: &draft)
        XCTAssertEqual(draft.menuPath, .mealExchange)
        XCTAssertEqual(applied.suggestedMenuPath, .diningDollars)
    }

    func testOppositeEvidenceKeepsSharedLocationAndDoesNotRepurposeBranchFields() {
        let store = makeStore()
        var manual = ScreenshotFieldManualEditState()
        manual.hasManuallyEditedMenuPath = true
        for path in [RequestMenuPath.mealExchange, .diningDollars] {
            var draft = RequestFoodFormDraft(menuPath: path)
            let proposed: RequestMenuPath = path == .mealExchange ? .diningDollars : .mealExchange
            let proposal = ScreenshotProposal(
                menuPath: proposed,
                selectedDiningSpot: palladium,
                mealItems: [MealItem(name: "Bowl")],
                mealSwipes: 2,
                estimatedDiningDollarsCents: 200,
                diningDollarsOrderTotalCents: 1200
            )
            let applied = store.apply(outcome(proposal), manualEdits: manual, to: &draft)
            XCTAssertEqual(draft.menuPath, path)
            XCTAssertEqual(applied.suggestedMenuPath, proposed)
            XCTAssertEqual(draft.selectedDiningSpot, palladium)
            XCTAssertEqual(draft.mealSwipes, 1)
            XCTAssertEqual(draft.mealEntries, RequestFoodFormDraft.emptyMealEntries)
            XCTAssertEqual(draft.orderDetails, "")
            XCTAssertEqual(draft.mealExchangeDiningDollarsText, "")
            XCTAssertEqual(draft.diningDollarsOnlyText, "")
        }
    }

    func testSwitchAppliesValidProposalsAndSupersedesManualPathInBothDirections() {
        let store = makeStore()
        for path in [RequestMenuPath.mealExchange, .diningDollars] {
            let proposed: RequestMenuPath = path == .mealExchange ? .diningDollars : .mealExchange
            var draft = RequestFoodFormDraft(menuPath: path)
            var manual = ScreenshotFieldManualEditState()
            manual.hasManuallyEditedMenuPath = true
            let proposal = proposed == .diningDollars
                ? ScreenshotProposal(menuPath: proposed, mealItems: [MealItem(name: "Bowl")], diningDollarsOrderTotalCents: 1200)
                : ScreenshotProposal(menuPath: proposed, mealItems: [MealItem(name: "Bowl")], mealSwipes: 1, estimatedDiningDollarsCents: 200)
            let result = outcome(proposal)
            let withheld = store.apply(result, manualEdits: manual, to: &draft)
            XCTAssertEqual(withheld.suggestedMenuPath, proposed)
            manual.hasManuallyEditedMenuPath = false
            let accepted = store.apply(result, manualEdits: manual, to: &draft)
            manual.record(accepted)
            XCTAssertEqual(draft.menuPath, proposed)
            XCTAssertTrue(accepted.menuPath)
            XCTAssertTrue(manual.hasScreenshotEstablishedMenuPath)
            XCTAssertFalse(manual.hasManuallyEditedMenuPath)
            XCTAssertNil(accepted.suggestedMenuPath)
            if proposed == .diningDollars {
                XCTAssertEqual(draft.orderDetails, "Bowl")
                XCTAssertEqual(draft.diningDollarsOnlyText, "$12.00")
                XCTAssertTrue(accepted.orderDetails)
                XCTAssertTrue(accepted.diningDollarsOnly)
            } else {
                XCTAssertEqual(draft.mealEntries[0].name, "Bowl")
                XCTAssertEqual(draft.mealExchangeDiningDollarsText, "$2.00")
                XCTAssertTrue(accepted.mealItemNames.contains(0))
                XCTAssertTrue(accepted.diningDollars)
            }
        }
    }

    func testDismissRejectsOnlyCurrentResultAndFreshAnalysisMayProposeAgain() {
        let store = makeStore()
        for path in [RequestMenuPath.mealExchange, .diningDollars] {
            let proposed: RequestMenuPath = path == .mealExchange ? .diningDollars : .mealExchange
            var draft = RequestFoodFormDraft(menuPath: path)
            var manual = ScreenshotFieldManualEditState()
            manual.hasManuallyEditedMenuPath = true
            var state = ScreenshotMenuPathConflictState()
            let first = store.beginSelection(clearing: &draft, manualEdits: manual)
            let result = outcome(ScreenshotProposal(menuPath: proposed, selectedDiningSpot: palladium))
            let applied = store.apply(result, manualEdits: manual, to: &draft)
            state.present(applied.suggestedMenuPath, outcome: result, for: first)
            XCTAssertEqual(state.suggestion?.proposedPath, proposed)
            state.dismiss()
            state.present(applied.suggestedMenuPath, outcome: result, for: first)
            XCTAssertNil(state.suggestion)
            XCTAssertEqual(state.dismissedToken, first)
            XCTAssertEqual(draft.menuPath, path)
            XCTAssertTrue(manual.hasManuallyEditedMenuPath)
            XCTAssertEqual(draft.selectedDiningSpot, palladium)

            let second = store.beginSelection(clearing: &draft, manualEdits: manual)
            let fresh = store.apply(result, manualEdits: manual, to: &draft)
            state.present(fresh.suggestedMenuPath, outcome: result, for: second)
            XCTAssertEqual(state.suggestion?.proposedPath, proposed)
        }
    }

    func testConflictAndMismatchControlsHaveApprovedHierarchyAndAccessibleActions() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("CommonPlateios/Views/RequestFoodView.swift"),
            encoding: .utf8
        )
        let conflict = try XCTUnwrap(source.range(of: "menuPathConflictInset(conflict)"))
        let selector = try XCTUnwrap(source.range(of: "menuPathControl", range: conflict.upperBound..<source.endIndex))
        XCTAssertLessThan(conflict.lowerBound, selector.lowerBound)
        let mismatch = try XCTUnwrap(source.range(of: "mealSwipeMismatchInset($0)"))
        let swipeControl = try XCTUnwrap(source.range(of: "mealSwipesControl", range: mismatch.upperBound..<source.endIndex))
        XCTAssertLessThan(mismatch.lowerBound, swipeControl.lowerBound)
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Dismiss menu suggestion\")"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"request-switch-screenshot-menu-path\")"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"request-dismiss-screenshot-menu-path\")"))
        XCTAssertTrue(source.contains(".frame(minWidth: 44, minHeight: 44)"))
        XCTAssertTrue(source.contains(".buttonStyle(.borderedProminent)"))
        XCTAssertTrue(source.contains(".tint(Color(\"AccentColor\"))"))
        XCTAssertTrue(source.contains("ViewThatFits(in: .horizontal)"))
        let actions = try XCTUnwrap(source.range(of: "private func menuPathConflictActions"))
        let control = try XCTUnwrap(source.range(of: "private var menuPathControl", range: actions.upperBound..<source.endIndex))
        let actionSource = source[actions.lowerBound..<control.lowerBound]
        XCTAssertTrue(actionSource.contains("confirmedVenueRecovery: conflict.venueConfirmation"))
        XCTAssertTrue(source.contains("venueConfirmation: confirmedVenueRecovery"))
        XCTAssertFalse(actionSource.contains("submit("), "Switch never posts a request")
        XCTAssertEqual(RequestFoodView.filledFromScreenshotLabel, "Suggested")
    }

    func testPathIsAppliedBeforeBranchDependentFieldsSoNothingLandsInTheWrongBranch() {
        let store = makeStore()

        // Form on Dining Dollars, proposal says Meal Exchange: entries, swipes,
        // and the top-up fill the Meal branch; order details stay untouched.
        var onDining = RequestFoodFormDraft(menuPath: .diningDollars, orderDetails: "requester words", diningDollarsOnlyText: "$20.00")
        store.apply(
            outcome(ScreenshotProposal(
                menuPath: .mealExchange,
                mealItems: [MealItem(name: "1 Bowl")],
                mealSwipes: 1,
                estimatedDiningDollarsCents: 200
            )),
            manualEdits: ScreenshotFieldManualEditState(),
            to: &onDining
        )
        XCTAssertEqual(onDining.menuPath, .mealExchange)
        XCTAssertEqual(onDining.mealEntries[0].name, "1 Bowl")
        XCTAssertEqual(onDining.mealSwipes, 1)
        XCTAssertEqual(onDining.mealExchangeDiningDollarsText, "$2.00")
        XCTAssertEqual(onDining.orderDetails, "requester words")
        XCTAssertEqual(onDining.diningDollarsOnlyText, "$20.00", "the other branch's amount is never touched")

        // Form on Meal Exchange, proposal says Dining Dollars: items become
        // order details; no Meal entry is written and no amount is invented.
        var onMeal = RequestFoodFormDraft(menuPath: .mealExchange, mealExchangeDiningDollarsText: "$1.50")
        store.apply(
            outcome(ScreenshotProposal(menuPath: .diningDollars, mealItems: [MealItem(name: "1 Bowl")])),
            manualEdits: ScreenshotFieldManualEditState(),
            to: &onMeal
        )
        XCTAssertEqual(onMeal.menuPath, .diningDollars)
        XCTAssertEqual(onMeal.orderDetails, "1 Bowl")
        XCTAssertEqual(onMeal.mealEntries, RequestFoodFormDraft.emptyMealEntries)
        XCTAssertEqual(onMeal.diningDollarsOnlyText, "", "a selected-method signal never supplies the amount")
        XCTAssertEqual(onMeal.mealExchangeDiningDollarsText, "$1.50")
    }

    func testTopUpProposalFillsOnlyTheMealBranchAndNeverTheDiningDollarsOnlyAmount() {
        let store = makeStore()
        var draft = RequestFoodFormDraft(menuPath: .diningDollars, diningDollarsOnlyText: "$20.00")
        var manual = ScreenshotFieldManualEditState()
        manual.hasManuallyEditedMenuPath = true // requester-owned Dining Dollars selection

        store.apply(
            outcome(ScreenshotProposal(estimatedDiningDollarsCents: 200)),
            manualEdits: manual,
            to: &draft
        )
        XCTAssertEqual(draft.mealExchangeDiningDollarsText, "")
        XCTAssertEqual(draft.diningDollarsOnlyText, "$20.00")
    }

    func testOrderTotalFillsOnlyDiningDollarsBranchAndHonorsManualAmount() {
        let store = makeStore()
        var draft = RequestFoodFormDraft(
            menuPath: .mealExchange,
            mealExchangeDiningDollarsText: "$2.00"
        )
        let proposal = ScreenshotProposal(
            menuPath: .diningDollars,
            diningDollarsOrderTotalCents: 1306
        )
        var applied = store.apply(outcome(proposal), manualEdits: .init(), to: &draft)
        XCTAssertEqual(draft.menuPath, .diningDollars)
        XCTAssertEqual(draft.diningDollarsOnlyText, "$13.06")
        XCTAssertEqual(draft.mealExchangeDiningDollarsText, "$2.00")
        XCTAssertTrue(applied.diningDollarsOnly)

        var manual = ScreenshotFieldManualEditState()
        manual.hasManuallyEditedDiningDollarsOnly = true
        draft.diningDollarsOnlyText = "$20.00"
        applied = store.apply(outcome(proposal), manualEdits: manual, to: &draft)
        XCTAssertEqual(draft.diningDollarsOnlyText, "$20.00")
        XCTAssertFalse(applied.diningDollarsOnly)
        XCTAssertEqual(applied.preservedManualFieldCount, 1)

        // A manually selected Dining Dollars path may use a labeled Total
        // even when no deterministic path proposal is present.
        manual.hasManuallyEditedDiningDollarsOnly = false
        applied = store.apply(
            outcome(ScreenshotProposal(diningDollarsOrderTotalCents: 1400)),
            manualEdits: manual, to: &draft
        )
        XCTAssertEqual(draft.diningDollarsOnlyText, "$14.00")
        XCTAssertTrue(applied.diningDollarsOnly)
    }

    // MARK: - Requester manual authority

    func testFirstActualPathChangeBeforeAssistanceProtectsTheRequesterSelection() {
        let store = makeStore()
        var draft = RequestFoodFormDraft(menuPath: .mealExchange)
        var manual = ScreenshotFieldManualEditState()

        // The requester freely picks Dining Dollars before any assistance.
        manual.recordMenuPathSelection(from: draft.menuPath, to: .diningDollars)
        draft.menuPath = .diningDollars
        XCTAssertTrue(manual.hasManuallyEditedMenuPath)

        let applied = store.apply(outcome(ScreenshotProposal(menuPath: .mealExchange)), manualEdits: manual, to: &draft)
        XCTAssertEqual(draft.menuPath, .diningDollars)
        XCTAssertFalse(applied.menuPath)
        XCTAssertEqual(applied.suggestedMenuPath, .mealExchange)
    }

    func testRealPathChangeLatchesButNoOpReselectionDoesNot() {
        var manual = ScreenshotFieldManualEditState()

        manual.recordMenuPathSelection(from: .diningDollars, to: .diningDollars)
        XCTAssertFalse(manual.hasManuallyEditedMenuPath, "re-selecting the current option is not a path change")

        manual.recordMenuPathSelection(from: .diningDollars, to: .mealExchange)
        XCTAssertTrue(manual.hasManuallyEditedMenuPath)

        // Latched ownership is not undone by later selector activity.
        manual.recordMenuPathSelection(from: .mealExchange, to: .mealExchange)
        XCTAssertTrue(manual.hasManuallyEditedMenuPath)
    }

    func testStoreWriteNeverLatchesManualAuthority() {
        let store = makeStore()
        var draft = RequestFoodFormDraft(menuPath: .mealExchange)
        let manual = ScreenshotFieldManualEditState()

        let applied = store.apply(outcome(ScreenshotProposal(menuPath: .diningDollars)), manualEdits: manual, to: &draft)
        XCTAssertTrue(applied.establishedMenuPath)
        XCTAssertFalse(manual.hasManuallyEditedMenuPath)
        XCTAssertFalse(manual.hasScreenshotEstablishedMenuPath, "only `record(_:)`, from the applied fields, establishes it")
        var recorded = manual
        recorded.record(applied)
        XCTAssertTrue(recorded.hasScreenshotEstablishedMenuPath)
        XCTAssertFalse(recorded.hasManuallyEditedMenuPath)
    }

    func testRequesterOwnedPathIsNeverOverwrittenAndOppositeProposalIsAssistance() {
        let store = makeStore()
        var manual = ScreenshotFieldManualEditState()
        manual.hasManuallyEditedMenuPath = true

        var draft = RequestFoodFormDraft(menuPath: .mealExchange)
        let opposite = store.apply(outcome(ScreenshotProposal(menuPath: .diningDollars)), manualEdits: manual, to: &draft)
        XCTAssertEqual(draft.menuPath, .mealExchange)
        XCTAssertFalse(opposite.menuPath)
        XCTAssertFalse(opposite.establishedMenuPath)
        XCTAssertEqual(opposite.suggestedMenuPath, .diningDollars)
        XCTAssertEqual(opposite.preservedManualFieldCount, 0)

        let same = store.apply(outcome(ScreenshotProposal(menuPath: .mealExchange)), manualEdits: manual, to: &draft)
        XCTAssertEqual(draft.menuPath, .mealExchange)
        XCTAssertEqual(same.preservedManualFieldCount, 0, "a same-path proposal does not falsely count as preservation")
        XCTAssertFalse(same.establishedMenuPath)
        XCTAssertTrue(same.location, "the explicit State E anchor remains independently applicable")

        let unsupported = store.apply(
            outcome(ScreenshotProposal(menuPath: .diningDollars), eligible: false),
            manualEdits: manual,
            to: &draft
        )
        XCTAssertEqual(draft.menuPath, .mealExchange)
        XCTAssertNil(unsupported.suggestedMenuPath)
    }

    func testBranchDependentFieldsFollowTheRequesterOwnedPathWhenAnOppositePathIsPreserved() {
        let store = makeStore()
        var manual = ScreenshotFieldManualEditState()
        manual.hasManuallyEditedMenuPath = true
        var draft = RequestFoodFormDraft(menuPath: .diningDollars)

        store.apply(
            outcome(ScreenshotProposal(menuPath: .mealExchange, mealItems: [MealItem(name: "1 Bowl")], estimatedDiningDollarsCents: 200)),
            manualEdits: manual,
            to: &draft
        )
        XCTAssertEqual(draft.menuPath, .diningDollars)
        XCTAssertEqual(draft.orderDetails, "", "opposite-path items are not reinterpreted for the retained branch")
        XCTAssertEqual(draft.mealEntries, RequestFoodFormDraft.emptyMealEntries)
        XCTAssertEqual(draft.mealExchangeDiningDollarsText, "")
    }

    func testNoPathProposalLeavesTheSelectionAndBothAmountsAlone() {
        let store = makeStore()
        for path in [RequestMenuPath.mealExchange, .diningDollars] {
            var draft = RequestFoodFormDraft(menuPath: path, mealExchangeDiningDollarsText: "$1.00", diningDollarsOnlyText: "$9.00")
            let applied = store.apply(
                outcome(ScreenshotProposal(selectedDiningSpot: palladium)),
                manualEdits: ScreenshotFieldManualEditState(),
                to: &draft
            )
            XCTAssertEqual(draft.menuPath, path)
            XCTAssertFalse(applied.menuPath)
            XCTAssertFalse(applied.establishedMenuPath)
            XCTAssertEqual(draft.mealExchangeDiningDollarsText, "$1.00")
            XCTAssertEqual(draft.diningDollarsOnlyText, "$9.00")
        }
    }

    func testBeginSelectionKeepsPathAndTopUpButClearsNonManualDiningAmount() {
        let store = makeStore()
        var draft = RequestFoodFormDraft(menuPath: .diningDollars, mealExchangeDiningDollarsText: "$1.00", diningDollarsOnlyText: "$9.00")
        _ = store.beginSelection(clearing: &draft, manualEdits: ScreenshotFieldManualEditState())
        XCTAssertEqual(draft.menuPath, .diningDollars)
        XCTAssertEqual(draft.mealExchangeDiningDollarsText, "$1.00")
        XCTAssertEqual(draft.diningDollarsOnlyText, "")
    }

    func testNewSelectionClearsScreenshotDiningAmountAndBadgeButKeepsManualAmount() {
        let store = makeStore()
        let session = RequestFoodDraftSession()
        session.draft.menuPath = .diningDollars

        // The same session method used by the real picker starts a selection
        // and clears draft values together with their view provenance.
        _ = session.beginScreenshotSelection(using: store)
        let proposal = ScreenshotProposal(menuPath: .diningDollars, diningDollarsOrderTotalCents: 1306)
        var value = session.draft
        var applied = store.apply(outcome(proposal), manualEdits: session.screenshotManualEdits, to: &value)
        session.draft = value
        session.screenshotProvenance.diningDollarsOnly = applied.diningDollarsOnly
        XCTAssertEqual(session.draft.diningDollarsOnlyText, "$13.06")
        XCTAssertTrue(session.screenshotProvenance.diningDollarsOnly)

        _ = session.beginScreenshotSelection(using: store)
        XCTAssertEqual(session.draft.diningDollarsOnlyText, "")
        XCTAssertFalse(session.screenshotProvenance.diningDollarsOnly)

        value = session.draft
        applied = store.apply(outcome(proposal), manualEdits: session.screenshotManualEdits, to: &value)
        session.draft = value
        session.screenshotProvenance.diningDollarsOnly = applied.diningDollarsOnly
        XCTAssertEqual(session.draft.diningDollarsOnlyText, "$13.06", "a later supported result may repropose")
        XCTAssertTrue(session.screenshotProvenance.diningDollarsOnly)

        session.draft.diningDollarsOnlyText = "$20.00"
        session.screenshotManualEdits.hasManuallyEditedDiningDollarsOnly = true
        session.screenshotProvenance.diningDollarsOnly = false
        _ = session.beginScreenshotSelection(using: store)
        XCTAssertEqual(session.draft.diningDollarsOnlyText, "$20.00")
        XCTAssertFalse(session.screenshotProvenance.diningDollarsOnly)

        value = session.draft
        applied = store.apply(outcome(proposal), manualEdits: session.screenshotManualEdits, to: &value)
        session.draft = value
        XCTAssertFalse(applied.diningDollarsOnly)
        XCTAssertEqual(session.draft.diningDollarsOnlyText, "$20.00")
    }

    func testAPathOnlyOutcomeIsUsefulAndShowsNoNoUsefulExtractionNotice() {
        let store = makeStore()
        var draft = RequestFoodFormDraft()
        store.apply(outcome(ScreenshotProposal(menuPath: .diningDollars)), manualEdits: ScreenshotFieldManualEditState(), to: &draft)
        XCTAssertNil(store.notice)
        XCTAssertFalse(outcome(ScreenshotProposal(menuPath: .diningDollars)).isEmpty)
    }

    // MARK: - End to end: backend DTO → on-device re-validation → apply → feedback

    @MainActor
    private struct Form {
        let store: ScreenshotProposalStore
        var draft = RequestFoodFormDraft()
        var manualEdits = ScreenshotFieldManualEditState()
        var feedback = ScreenshotPreservedEntryFeedbackState()

        /// Mirrors `RequestFoodView.menuPathBinding`'s setter.
        mutating func requesterSelects(_ path: RequestMenuPath) {
            manualEdits.recordMenuPathSelection(from: draft.menuPath, to: path)
            draft.menuPath = path
        }

        @discardableResult
        mutating func run(evidence: String, wireProposal: [String: Any]) async -> ScreenshotProposalAppliedFields? {
            let body: [String: Any] = ["eligible": true, "proposal": wireProposal]
            ScreenshotProposalURLProtocol.enqueue(.response(data: try! JSONSerialization.data(withJSONObject: body)))
            let token = store.beginSelection(clearing: &draft, manualEdits: manualEdits)
            feedback.beginSelection()
            let store = self.store
            let inputs = [ScreenshotTestEvidence.input(evidence)]
            let outcome = await Task { @MainActor in
                await analyzeThroughExternalFallback(store: store, images: inputs, participantAuthority: "an-authority", token: token)
            }.value
            guard let outcome, store.isCurrent(token) else { return nil }
            let applied = store.apply(outcome, manualEdits: manualEdits, to: &draft)
            manualEdits.record(applied)
            _ = feedback.completeAnalysis(eligible: outcome.eligible, applying: applied)
            return applied
        }
    }

    private static let diningEvidence =
        "Review your pickup order\nYour order\n1 Chicken Bowl\nJasper Kane Cafe\nYour payment\nPayment method\nDining Dollars"
    private static let mealEvidence = "Your Pickup Order\nContinue to Checkout\nJasper Kane Cafe\nBowl 1M"

    func testEndToEndDeterministicSwitchBothDirectionsThenManualOverrideSurvivesRerun() async {
        var form = Form(store: makeStore())

        // Dining Dollars evidence → switches off the default Meal Exchange.
        let first = await form.run(evidence: Self.diningEvidence, wireProposal: [
            "menuPath": "dining-dollars",
            "selectedDiningSpot": ["name": "Jasper Kane Cafe", "address": "BROOKLYN, Rogers Hall"],
        ])
        XCTAssertEqual(form.draft.menuPath, .diningDollars)
        XCTAssertEqual(first?.menuPath, true)
        XCTAssertTrue(form.manualEdits.hasScreenshotEstablishedMenuPath)
        XCTAssertEqual(form.draft.diningDollarsOnlyText, "", "no amount is fabricated from the selected method")
        XCTAssertFalse(form.feedback.isShowing)

        // Meal evidence rerun → switches back (assistance has acted but the
        // requester has not changed the selector).
        let second = await form.run(evidence: Self.mealEvidence, wireProposal: [
            "menuPath": "meal-exchange",
            "selectedDiningSpot": ["name": "Jasper Kane Cafe", "address": "BROOKLYN, Rogers Hall"],
        ])
        XCTAssertEqual(form.draft.menuPath, .mealExchange)
        XCTAssertEqual(second?.menuPath, true)
        XCTAssertFalse(form.feedback.isShowing, "a branch switch alone never shows preserved-entry feedback")

        // The requester now genuinely changes the selector: it becomes theirs.
        form.requesterSelects(.mealExchange) // no-op re-selection
        XCTAssertFalse(form.manualEdits.hasManuallyEditedMenuPath)
        form.requesterSelects(.diningDollars)
        XCTAssertTrue(form.manualEdits.hasManuallyEditedMenuPath)

        let third = await form.run(evidence: Self.mealEvidence, wireProposal: [
            "menuPath": "meal-exchange",
            "selectedDiningSpot": ["name": "Jasper Kane Cafe", "address": "BROOKLYN, Rogers Hall"],
        ])
        XCTAssertEqual(form.draft.menuPath, .diningDollars, "the rerun cannot overwrite the requester-owned path")
        XCTAssertEqual(third?.suggestedMenuPath, .mealExchange)
        XCTAssertFalse(form.feedback.isShowing, "path assistance is inline, not a toast")

        // A same-path proposal changes and preserves nothing.
        let fourth = await form.run(evidence: Self.diningEvidence, wireProposal: [
            "menuPath": "dining-dollars",
            "selectedDiningSpot": ["name": "Jasper Kane Cafe", "address": "BROOKLYN, Rogers Hall"],
        ])
        XCTAssertEqual(form.draft.menuPath, .diningDollars)
        XCTAssertEqual(fourth?.preservedManualFieldCount, 0)
        XCTAssertFalse(form.feedback.isShowing)
    }

    func testEndToEndNoEvidenceAndConflictPreserveTheRequesterSelection() async {
        for path in [RequestMenuPath.mealExchange, .diningDollars] {
            var form = Form(store: makeStore())
            form.draft.menuPath = path

            // The backend claims a path the on-device evidence does not support.
            let noEvidence = await form.run(
                evidence: "Your Pickup Order\nContinue to Checkout\nJasper Kane Cafe",
                wireProposal: ["menuPath": path == .mealExchange ? "dining-dollars" : "meal-exchange"]
            )
            XCTAssertEqual(form.draft.menuPath, path, "a returned path is not evidence")
            XCTAssertEqual(noEvidence?.menuPath, false)
            XCTAssertFalse(form.manualEdits.hasScreenshotEstablishedMenuPath)

            // Genuinely conflicting on-device evidence: even a backend that
            // (wrongly) proposed a path and branch-dependent values is overruled.
            let conflict = "Review your pickup order\nYour order\n1 Chicken Bowl\nJasper Kane Cafe\n3M + $2.00\nYour payment\nPayment method\nDining Dollars"
            let applied = await form.run(
                evidence: conflict,
                wireProposal: [
                    "menuPath": "meal-exchange",
                    "mealItems": [["name": "1 Chicken Bowl"]],
                    "mealSwipes": 3,
                    "estimatedDiningDollarsCents": 200,
                    "selectedDiningSpot": ["name": "Jasper Kane Cafe", "address": "x"],
                ]
            )
            XCTAssertEqual(form.draft.menuPath, path)
            XCTAssertEqual(applied?.menuPath, false)
            XCTAssertEqual(form.draft.selectedDiningSpot?.name, "Jasper Kane Cafe", "the shared location may still apply")
            XCTAssertEqual(form.draft.mealEntries, RequestFoodFormDraft.emptyMealEntries)
            XCTAssertEqual(form.draft.orderDetails, "")
            XCTAssertEqual(form.draft.mealExchangeDiningDollarsText, "")
            XCTAssertEqual(form.draft.diningDollarsOnlyText, "")
        }
    }

    func testServiceDecodesTheWirePathLeniently() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScreenshotProposalURLProtocol.self]
        let service = ScreenshotProposalService(availability: .enabledForTesting(), client: APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        ))
        let image = ScreenshotProposalImage(data: Data([1]), mimeType: "image/jpeg", localEvidenceText: "x")
        for (wire, expected): (Any, RequestMenuPath?) in [
            ("meal-exchange", .mealExchange),
            ("dining-dollars", .diningDollars),
            ("MEAL_EXCHANGE", nil),
            ("garbage", nil),
        ] {
            let body: [String: Any] = ["eligible": true, "proposal": ["menuPath": wire]]
            ScreenshotProposalURLProtocol.enqueue(.response(data: try JSONSerialization.data(withJSONObject: body)))
            let result = try await service.requestProposal(images: [image], authority: "a")
            XCTAssertEqual(result.proposal.menuPath, expected, "\(wire)")
        }
        let absent: [String: Any] = ["eligible": true, "proposal": [String: Any]()]
        ScreenshotProposalURLProtocol.enqueue(.response(data: try JSONSerialization.data(withJSONObject: absent)))
        let none = try await service.requestProposal(images: [image], authority: "a")
        XCTAssertNil(none.proposal.menuPath)
    }
}
