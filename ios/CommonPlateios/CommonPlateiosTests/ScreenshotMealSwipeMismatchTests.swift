import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class ScreenshotMealSwipeMismatchTests: XCTestCase {
    private func store() -> ScreenshotProposalStore {
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

    private let twoMeals = ScreenshotProposal(
        menuPath: .mealExchange,
        mealItems: [MealItem(name: "1 Bowl"), MealItem(name: "1 Pasta", details: "Sauce")],
        mealSwipes: 2
    )

    private let palladium = SupportedVendorCatalog.diningSpots.first { $0.name == "Jasper Kane Cafe" }!

    /// These direct application tests are about meal-swipe authority after a
    /// supported venue has already anchored the result (State E).
    private func stateEOutcome(
        _ proposal: ScreenshotProposal,
        eligible: Bool = true
    ) -> ScreenshotProposalOutcome {
        var anchoredProposal = proposal
        if anchoredProposal.selectedDiningSpot == nil {
            anchoredProposal.selectedDiningSpot = palladium
        }
        return ScreenshotProposalOutcome(
            eligible: eligible,
            proposal: anchoredProposal,
            venueDisposition: .supported(palladium)
        )
    }

    func testRequesterOwnedLowerCountKeepsValueAndPreservesHiddenExtractedMeal() {
        let store = store()
        var draft = RequestFoodFormDraft(mealSwipes: 1)
        var manual = ScreenshotFieldManualEditState()
        manual.hasManuallyEditedMealSwipes = true
        let token = store.beginSelection(clearing: &draft, manualEdits: manual)
        let applied = store.apply(
            stateEOutcome(twoMeals),
            manualEdits: manual,
            to: &draft
        )

        XCTAssertTrue(store.isCurrent(token))
        XCTAssertEqual(draft.mealSwipes, 1)
        XCTAssertTrue(manual.hasManuallyEditedMealSwipes)
        XCTAssertEqual(applied.suggestedMealSwipes, 2)
        XCTAssertEqual(draft.mealEntries[1].name, "1 Pasta")
        XCTAssertEqual(draft.mealEntries[1].details, "Sauce")
        XCTAssertEqual(draft.activeMealEntries.map(\.name), ["1 Bowl"])
        XCTAssertTrue(applied.mealItemNames.contains(1))
        let suggestion = ScreenshotMealSwipeMismatch(
            token: token,
            proposedCount: 2,
            contributedMealItemNames: applied.mealItemNames,
            contributedMealItemDetails: applied.mealItemDetails
        )
        XCTAssertEqual(suggestion.message, "We found 2 meals")
        XCTAssertEqual(suggestion.action, "Use 2 swipes")
        XCTAssertEqual(RequestFoodView.manuallySelectedLabel, "Manually selected")
        XCTAssertEqual(RequestFoodView.filledFromScreenshotLabel, "Suggested")
    }

    func testExplicitAdoptionMakesCountScreenshotDerivedAndRevealsPreservedMeal() throws {
        let store = store()
        var draft = RequestFoodFormDraft(mealSwipes: 1)
        var manual = ScreenshotFieldManualEditState()
        manual.hasManuallyEditedMealSwipes = true
        var provenance = ScreenshotProposalAppliedFields()
        let applied = store.apply(
            stateEOutcome(twoMeals),
            manualEdits: manual,
            to: &draft
        )
        provenance.mealItemNames.formUnion(applied.mealItemNames)
        provenance.mealItemDetails.formUnion(applied.mealItemDetails)
        XCTAssertTrue(store.adoptSuggestedMealSwipes(
            2, manualEdits: &manual, provenance: &provenance, to: &draft
        ))
        XCTAssertEqual(draft.mealSwipes, 2)
        XCTAssertFalse(manual.hasManuallyEditedMealSwipes)
        XCTAssertTrue(provenance.mealSwipes)
        XCTAssertTrue(provenance.mealItemNames.contains(1))
        XCTAssertTrue(provenance.mealItemDetails.contains(1))
        XCTAssertEqual(draft.activeMealEntries.map(\.name), ["1 Bowl", "1 Pasta"])
        XCTAssertEqual(draft.activeMealEntries[1].details, "Sauce")

        // Exercise the production picker binding's session seam, rather than
        // manufacturing the manual flag and provenance transition in a test.
        let session = RequestFoodDraftSession()
        session.draft = draft
        session.screenshotManualEdits = manual
        session.screenshotProvenance = provenance
        session.setMealSwipesManually(1)
        XCTAssertEqual(session.draft.activeMealEntries.map(\.name), ["1 Bowl"])
        XCTAssertEqual(session.draft.mealEntries[1].name, "1 Pasta")
        XCTAssertTrue(session.screenshotManualEdits.hasManuallyEditedMealSwipes)
        XCTAssertFalse(session.screenshotProvenance.mealSwipes)

        session.draft.selectedDiningSpot = DiningSpot(name: "Jasper Kane Cafe", address: nil)
        let now = Date(timeIntervalSince1970: 1_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let lowered = try RequestFoodView.makePayload(draft: session.draft, now: now, calendar: calendar)
        XCTAssertEqual(lowered.mealSwipes, 1)
        XCTAssertEqual(lowered.mealItems.map(\.name), ["1 Bowl"], "inactive meal content is not submitted")

        session.setMealSwipesManually(2)
        XCTAssertEqual(session.draft.activeMealEntries.map(\.name), ["1 Bowl", "1 Pasta"])
        let restored = try RequestFoodView.makePayload(draft: session.draft, now: now, calendar: calendar)
        XCTAssertEqual(restored.mealItems.map(\.name), ["1 Bowl", "1 Pasta"])
    }

    func testDismissIsResultScopedAndEqualOrLowerCountHasNoSuggestion() {
        let store = store()
        var draft = RequestFoodFormDraft(mealSwipes: 1)
        var manual = ScreenshotFieldManualEditState()
        manual.hasManuallyEditedMealSwipes = true
        let first = store.beginSelection(clearing: &draft, manualEdits: manual)
        var state = ScreenshotMealSwipeMismatchState()
        state.present(2, for: first, applied: ScreenshotProposalAppliedFields())
        XCTAssertEqual(state.suggestion?.proposedCount, 2)
        state.dismiss()
        XCTAssertNil(state.suggestion)
        XCTAssertEqual(state.dismissedToken, first)
        XCTAssertTrue(state.showsManualProvenance, "the approved after-dismiss frame retains Manually selected")
        XCTAssertEqual(draft.mealSwipes, 1)
        XCTAssertTrue(manual.hasManuallyEditedMealSwipes)
        XCTAssertTrue(store.isCurrent(first))
        state.present(2, for: first, applied: ScreenshotProposalAppliedFields())
        XCTAssertNil(state.suggestion, "the same dismissed analysis cannot re-present")

        let second = store.beginSelection(clearing: &draft, manualEdits: manual)
        XCTAssertFalse(store.isCurrent(first))
        let applied = store.apply(
            stateEOutcome(twoMeals),
            manualEdits: manual,
            to: &draft
        )
        state.present(applied.suggestedMealSwipes, for: second, applied: applied)
        XCTAssertEqual(state.suggestion?.token, second)
        XCTAssertEqual(state.suggestion?.proposedCount, 2)

        draft.mealSwipes = 2
        XCTAssertNil(store.apply(
            stateEOutcome(twoMeals),
            manualEdits: manual,
            to: &draft
        ).suggestedMealSwipes)
        state.clear()
        XCTAssertFalse(state.showsManualProvenance)
        draft.mealSwipes = 3
        XCTAssertNil(store.apply(
            stateEOutcome(twoMeals),
            manualEdits: manual,
            to: &draft
        ).suggestedMealSwipes)
    }

    func testRequesterOwnedDiningPathAndIneligibleOutcomeCannotSuggestSwipes() {
        let store = store()
        var draft = RequestFoodFormDraft(menuPath: .diningDollars, mealSwipes: 1)
        var manual = ScreenshotFieldManualEditState()
        manual.hasManuallyEditedMenuPath = true
        manual.hasManuallyEditedMealSwipes = true
        let onDining = store.apply(
            stateEOutcome(twoMeals),
            manualEdits: manual, to: &draft
        )
        XCTAssertEqual(draft.menuPath, .diningDollars)
        XCTAssertEqual(draft.mealSwipes, 1)
        XCTAssertNil(onDining.suggestedMealSwipes)

        draft.menuPath = .mealExchange
        let ineligible = store.apply(
            stateEOutcome(twoMeals, eligible: false),
            manualEdits: manual, to: &draft
        )
        XCTAssertNil(ineligible.suggestedMealSwipes)
        XCTAssertEqual(draft.mealSwipes, 1)
    }

    func testDismissRejectsCurrentResultSurplusAndManualIncreaseCannotRestoreIt() throws {
        let store = store()
        let session = RequestFoodDraftSession()
        session.setMealSwipesManually(1)
        let token = session.beginScreenshotSelection(using: store)
        let applied = store.apply(
            stateEOutcome(twoMeals),
            manualEdits: session.screenshotManualEdits,
            to: &session.draft
        )
        session.screenshotProvenance.mealItemNames.formUnion(applied.mealItemNames)
        session.screenshotProvenance.mealItemDetails.formUnion(applied.mealItemDetails)
        var mismatch = ScreenshotMealSwipeMismatchState()
        mismatch.present(applied.suggestedMealSwipes, for: token, applied: applied)
        let suggestion = try XCTUnwrap(mismatch.suggestion)
        XCTAssertEqual(session.draft.mealEntries[1], MealItem(name: "1 Pasta", details: "Sauce"))

        session.rejectCurrentScreenshotSurplus(
            above: session.draft.mealSwipes,
            names: suggestion.contributedMealItemNames,
            details: suggestion.contributedMealItemDetails
        )
        mismatch.dismiss()
        XCTAssertNil(mismatch.suggestion)
        XCTAssertEqual(mismatch.dismissedToken, token)
        XCTAssertTrue(mismatch.showsManualProvenance)
        XCTAssertEqual(session.draft.mealSwipes, 1)
        XCTAssertTrue(session.screenshotManualEdits.hasManuallyEditedMealSwipes)
        XCTAssertEqual(session.draft.mealEntries[1], MealItem(name: ""))
        XCTAssertFalse(session.screenshotProvenance.mealItemNames.contains(1))
        XCTAssertFalse(session.screenshotProvenance.mealItemDetails.contains(1))

        session.draft.selectedDiningSpot = DiningSpot(name: "Jasper Kane Cafe", address: nil)
        let now = Date(timeIntervalSince1970: 1_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let active = try RequestFoodView.makePayload(draft: session.draft, now: now, calendar: calendar)
        XCTAssertEqual(active.mealSwipes, 1)
        XCTAssertEqual(active.mealItems.map(\.name), ["1 Bowl"])

        session.setMealSwipesManually(2)
        XCTAssertEqual(session.draft.activeMealEntries[1], MealItem(name: ""))
        mismatch.present(applied.suggestedMealSwipes, for: token, applied: applied)
        XCTAssertNil(mismatch.suggestion, "redraw/recomputation cannot restore the dismissed result")
        XCTAssertThrowsError(try RequestFoodView.makePayload(draft: session.draft, now: now, calendar: calendar))
    }

    func testDismissPreservesRequesterOwnedHigherIndexSubfields() {
        let store = store()
        let session = RequestFoodDraftSession()
        session.setMealSwipesManually(2)
        session.draft.mealEntries[1].name = "My saved pasta"
        session.screenshotManualEdits.manuallyEditedMealItemNames.insert(1)
        session.setMealSwipesManually(1)
        _ = session.beginScreenshotSelection(using: store)
        let applied = store.apply(
            stateEOutcome(twoMeals),
            manualEdits: session.screenshotManualEdits,
            to: &session.draft
        )
        session.screenshotProvenance.mealItemNames.formUnion(applied.mealItemNames)
        session.screenshotProvenance.mealItemDetails.formUnion(applied.mealItemDetails)
        XCTAssertFalse(applied.mealItemNames.contains(1))
        XCTAssertTrue(applied.mealItemDetails.contains(1))
        session.rejectCurrentScreenshotSurplus(
            above: 1, names: applied.mealItemNames, details: applied.mealItemDetails
        )
        session.setMealSwipesManually(2)
        XCTAssertEqual(session.draft.mealEntries[1], MealItem(name: "My saved pasta"))
        XCTAssertTrue(session.screenshotManualEdits.hasManuallyEditedMealItemName(1))

        // Name and Details ownership are independent; reject a proposed name
        // while retaining requester-authored Details in a separate draft.
        let other = RequestFoodDraftSession()
        other.setMealSwipesManually(2)
        other.draft.mealEntries[1].details = "My instructions"
        other.screenshotManualEdits.manuallyEditedMealItemDetails.insert(1)
        other.setMealSwipesManually(1)
        _ = other.beginScreenshotSelection(using: store)
        let otherApplied = store.apply(
            stateEOutcome(twoMeals),
            manualEdits: other.screenshotManualEdits,
            to: &other.draft
        )
        other.screenshotProvenance.mealItemNames.formUnion(otherApplied.mealItemNames)
        other.screenshotProvenance.mealItemDetails.formUnion(otherApplied.mealItemDetails)
        XCTAssertTrue(otherApplied.mealItemNames.contains(1))
        XCTAssertFalse(otherApplied.mealItemDetails.contains(1))
        other.rejectCurrentScreenshotSurplus(
            above: 1, names: otherApplied.mealItemNames, details: otherApplied.mealItemDetails
        )
        other.setMealSwipesManually(2)
        XCTAssertEqual(other.draft.mealEntries[1], MealItem(name: "", details: "My instructions"))
    }

    func testNewResultMayProposeSurplusAgainAfterEarlierDismissal() throws {
        let store = store()
        let session = RequestFoodDraftSession()
        session.setMealSwipesManually(1)
        let first = session.beginScreenshotSelection(using: store)
        let firstApplied = store.apply(
            stateEOutcome(twoMeals),
            manualEdits: session.screenshotManualEdits,
            to: &session.draft
        )
        session.screenshotProvenance.mealItemNames.formUnion(firstApplied.mealItemNames)
        session.screenshotProvenance.mealItemDetails.formUnion(firstApplied.mealItemDetails)
        var mismatch = ScreenshotMealSwipeMismatchState()
        mismatch.present(firstApplied.suggestedMealSwipes, for: first, applied: firstApplied)
        let firstSuggestion = try XCTUnwrap(mismatch.suggestion)
        session.rejectCurrentScreenshotSurplus(
            above: 1,
            names: firstSuggestion.contributedMealItemNames,
            details: firstSuggestion.contributedMealItemDetails
        )
        mismatch.dismiss()

        let second = session.beginScreenshotSelection(using: store)
        mismatch.clear()
        XCTAssertFalse(store.isCurrent(first))
        let secondProposal = ScreenshotProposal(
            menuPath: .mealExchange,
            mealItems: [MealItem(name: "1 Bowl"), MealItem(name: "1 New pasta")],
            mealSwipes: 2
        )
        let secondApplied = store.apply(
            stateEOutcome(secondProposal),
            manualEdits: session.screenshotManualEdits,
            to: &session.draft
        )
        mismatch.present(secondApplied.suggestedMealSwipes, for: second, applied: secondApplied)
        XCTAssertEqual(mismatch.suggestion?.token, second)
        XCTAssertEqual(session.draft.mealEntries[1].name, "1 New pasta")
        XCTAssertEqual(session.draft.mealSwipes, 1)
    }

    func testCurrentTokenAndClearSitesAreWiredIntoTheProductionView() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("CommonPlateios/Views/RequestFoodView.swift"),
            encoding: .utf8
        )
        let completion = try XCTUnwrap(source.range(of: "guard let outcome, screenshotProposalStore.isCurrent(token) else { return }"))
        let presentation = try XCTUnwrap(source.range(of: "mealSwipeMismatch.present(applied.suggestedMealSwipes, for: token, applied: applied)"))
        XCTAssertLessThan(completion.lowerBound, presentation.lowerBound)
        XCTAssertTrue(source.contains("let token = draftSession.beginScreenshotSelection(using: screenshotProposalStore)"))
        XCTAssertTrue(source.contains("draftSession.setMealSwipesManually(newValue)"))
        XCTAssertTrue(source.contains("mealSwipeMismatch = mountedState.mealSwipeMismatch"))
        XCTAssertTrue(source.contains("screenshotProposalStore.isCurrent(mismatch.token) else { return }"))
        XCTAssertTrue(source.contains("draftSession.rejectCurrentScreenshotSurplus("))
    }

    func testInsetIsBoundedToFieldAndDismissHasFullHitTarget() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("CommonPlateios/Views/RequestFoodView.swift"),
            encoding: .utf8
        )
        let field = try XCTUnwrap(source.range(of: "private func mealExchangeFields"))
        let inset = try XCTUnwrap(source.range(of: "mealSwipeMismatchInset($0)"))
        let meals = try XCTUnwrap(source.range(of: "ForEach(Array(draft.activeMealEntryIndices)"))
        XCTAssertLessThan(field.lowerBound, inset.lowerBound)
        XCTAssertLessThan(inset.lowerBound, meals.lowerBound)
        let dismiss = try XCTUnwrap(source.range(of: "request-dismiss-screenshot-swipes"))
        let leading = source[..<dismiss.lowerBound]
        XCTAssertTrue(String(leading.suffix(650)).contains(".frame(minWidth: 44, minHeight: 44)"))
        let function = try XCTUnwrap(source.range(of: "private func mealSwipeMismatchInset"))
        let next = try XCTUnwrap(source.range(of: "private func mealEditorCard", range: function.upperBound..<source.endIndex))
        XCTAssertFalse(source[function.lowerBound..<next.lowerBound].contains("submit("))
    }
}
