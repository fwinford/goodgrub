//
//  RequestIncompleteVsInvalidValidationTests.swift
//  CommonPlateiosTests
//
// W4-R4 (2026-09-26): empty required entry values are incomplete, not invalid.
// They keep posting blocked but are never presented as errors; an entered but
// invalid value still is. Rendered proof lives in
// `RequesterIncompleteVsInvalidHostedTests`.
import XCTest
@testable import CommonPlateios

final class RequestIncompleteVsInvalidValidationTests: XCTestCase {
    private let spot = DiningSpot(name: "Jasper Kane Cafe", address: nil)

    private func draft(
        path: RequestMenuPath,
        meal: String = "",
        orderDetails: String = "",
        diningDollars: String = ""
    ) -> RequestFoodFormDraft {
        RequestFoodFormDraft(
            selectedDiningSpot: spot,
            menuPath: path,
            timing: .asap,
            mealSwipes: 1,
            mealEntries: [meal, "", "", "", ""],
            orderDetails: orderDetails,
            diningDollarsText: diningDollars
        )
    }

    private func errors(_ draft: RequestFoodFormDraft) -> [RequestFoodFieldError] {
        RequestFoodFormValidator.validate(
            draft: draft,
            isScheduledWindowValid: true,
            isScheduledTimingAvailable: true
        )
    }

    private func blur(
        _ field: RequestFoodFormField,
        _ draft: RequestFoodFormDraft
    ) -> RequestFoodValidationPresentation {
        var presentation = RequestFoodValidationPresentation()
        presentation.handleFocusTransition(from: nil, to: field, errors: errors(draft))
        presentation.handleFocusTransition(from: field, to: nil, errors: errors(draft))
        return presentation
    }

    // MARK: - Classification

    func testExactlyTheThreeRequiredEntryValuesAreClassifiedIncomplete() {
        XCTAssertTrue(RequestFoodFormError.missingMealDetail(index: 0).isIncompleteEntry)
        XCTAssertTrue(RequestFoodFormError.missingOrderDetails.isIncompleteEntry)
        XCTAssertTrue(RequestFoodFormError.missingDiningDollars.isIncompleteEntry)

        XCTAssertFalse(RequestFoodFormError.missingDiningSpot.isIncompleteEntry)
        XCTAssertFalse(RequestFoodFormError.invalidDiningDollars(ceilingCents: 5_000).isIncompleteEntry)
        XCTAssertFalse(RequestFoodFormError.invalidScheduledTime.isIncompleteEntry)
        XCTAssertFalse(RequestFoodFormError.scheduledTimingUnavailable.isIncompleteEntry)
    }

    // MARK: - Empty blur stays neutral, posting stays blocked

    func testEmptyMealItemBlurIsNeutralAndPostingStaysBlocked() {
        let empty = draft(path: .mealExchange)
        XCTAssertEqual(errors(empty).map(\.error), [.missingMealDetail(index: 0)])

        let presentation = blur(.mealDetail(index: 0), empty)

        XCTAssertTrue(presentation.presentedFields.isEmpty)
        XCTAssertTrue(presentation.visibleErrors(from: errors(empty)).isEmpty)
        XCTAssertNil(presentation.visibleError(for: .mealDetail(index: 0), from: errors(empty)))
        XCTAssertFalse(RequestFoodView.isSubmissionEnabled(draft: empty, submissionError: nil, isCreating: false))
    }

    func testEmptyDiningDollarsAmountBlurIsNeutralAndPostingStaysBlocked() {
        let empty = draft(path: .diningDollars, orderDetails: "Fries")
        XCTAssertEqual(errors(empty).map(\.error), [.missingDiningDollars])

        let presentation = blur(.diningDollars, empty)

        XCTAssertTrue(presentation.presentedFields.isEmpty)
        XCTAssertTrue(presentation.visibleErrors(from: errors(empty)).isEmpty)
        XCTAssertFalse(RequestFoodView.isSubmissionEnabled(draft: empty, submissionError: nil, isCreating: false))
    }

    func testEmptyDiningDollarsOrderDescriptionBlurIsNeutralAndPostingStaysBlocked() {
        let empty = draft(path: .diningDollars, diningDollars: "12.00")
        XCTAssertEqual(errors(empty).map(\.error), [.missingOrderDetails])

        let presentation = blur(.orderDetails, empty)

        XCTAssertTrue(presentation.presentedFields.isEmpty)
        XCTAssertTrue(presentation.visibleErrors(from: errors(empty)).isEmpty)
        XCTAssertFalse(RequestFoodView.isSubmissionEnabled(draft: empty, submissionError: nil, isCreating: false))
    }

    func testWhitespaceOnlyEntriesAreStillIncompleteNotInvalid() {
        let blank = draft(path: .diningDollars, orderDetails: "   \n ", diningDollars: "  ")
        XCTAssertEqual(errors(blank).map(\.error), [.missingOrderDetails, .missingDiningDollars])
        var presentation = RequestFoodValidationPresentation()
        presentation.presentAll(errors(blank))
        XCTAssertTrue(presentation.visibleErrors(from: errors(blank)).isEmpty)
    }

    // MARK: - Entered-but-invalid keeps its normal feedback

    func testEnteredOutOfBoundsDiningDollarsStillShowsInvalidFeedbackAfterBlur() {
        for text in ["50.01", "0", "0.00", "abc", "1,2"] {
            let entered = draft(path: .diningDollars, orderDetails: "Fries", diningDollars: text)
            let presentation = blur(.diningDollars, entered)
            XCTAssertEqual(
                presentation.visibleError(for: .diningDollars, from: errors(entered))?.error,
                .invalidDiningDollars(ceilingCents: 5_000),
                "\(text) is entered and invalid, so it is not neutral"
            )
        }
        let mealExchange = draft(path: .mealExchange, meal: "Wings", diningDollars: "25.01")
        XCTAssertEqual(
            blur(.diningDollars, mealExchange)
                .visibleError(for: .diningDollars, from: errors(mealExchange))?.error,
            .invalidDiningDollars(ceilingCents: 2_500)
        )
    }

    func testAnInvalidAmountClearedBackToEmptyReturnsToNeutral() {
        let invalid = draft(path: .diningDollars, orderDetails: "Fries", diningDollars: "99")
        let presentation = blur(.diningDollars, invalid)
        XCTAssertNotNil(presentation.visibleError(for: .diningDollars, from: errors(invalid)))

        let cleared = draft(path: .diningDollars, orderDetails: "Fries", diningDollars: "")
        XCTAssertNil(
            presentation.visibleError(for: .diningDollars, from: errors(cleared)),
            "an emptied field is incomplete, even though it once presented an invalid value"
        )
        // ...and it is live again the moment a bad value is re-entered.
        XCTAssertNotNil(
            presentation.visibleError(
                for: .diningDollars,
                from: errors(draft(path: .diningDollars, orderDetails: "Fries", diningDollars: "75"))
            )
        )
    }

    func testNonRequiredEntryErrorsAreUnchanged() {
        var noSpot = draft(path: .mealExchange, meal: "Wings")
        noSpot.selectedDiningSpot = nil
        var presentation = RequestFoodValidationPresentation()
        presentation.presentAll(errors(noSpot))
        XCTAssertEqual(presentation.visibleErrors(from: errors(noSpot)).map(\.field), [.diningSpot])
    }

    // MARK: - Submit path

    func testAnAlternateSubmitPathStaysBlockedAndNeutralForIncompleteEntries() async throws {
        let empty = draft(path: .diningDollars)
        var submissions = 0
        let result = try await RequestFoodView.orchestrateSubmission(
            draft: empty,
            now: Date(),
            calendar: NYUCampusTime.calendar,
            presentation: RequestFoodValidationPresentation()
        ) { _ in submissions += 1 }

        XCTAssertEqual(submissions, 0, "incomplete never posts")
        XCTAssertFalse(result.didSubmit)
        XCTAssertTrue(
            result.presentation.visibleErrors(from: errors(empty)).isEmpty,
            "and it does not create the empty-required error state"
        )
        XCTAssertEqual(result.firstInvalidTextField, .orderDetails, "focus still points at the first gap")
    }

    // MARK: - Menu-path reset

    func testPathSwitchClearsVisibleInvalidAmountAndABlurFromTheOldBranchDoesNotCount() {
        let invalid = draft(path: .diningDollars, orderDetails: "Fries", diningDollars: "99")
        var presentation = blur(.diningDollars, invalid)
        XCTAssertNotNil(presentation.visibleError(for: .diningDollars, from: errors(invalid)))

        presentation.resetMenuPathSpecificPresentation()
        XCTAssertTrue(presentation.visibleErrors(from: errors(invalid)).isEmpty)

        // 99 is also invalid on Meal Exchange, but the blur that a path switch
        // causes belongs to the branch just left.
        XCTAssertFalse(
            RequestFoodValidationPresentation.blurBelongsToCurrentMenuPath(
                previousField: .diningDollars,
                menuPathAtFocus: .diningDollars,
                currentMenuPath: .mealExchange
            )
        )
    }

    func testPathSwitchPreservesEnteredValuesWithoutTouchingThem() {
        var value = draft(path: .diningDollars, meal: "Wings", orderDetails: "Fries", diningDollars: "12.00")
        value.menuPath = .mealExchange
        value.menuPath = .diningDollars
        XCTAssertEqual(value.mealEntries[0].name, "Wings")
        XCTAssertEqual(value.orderDetails, "Fries")
        XCTAssertEqual(value.diningDollarsText, "12.00")
    }

    // MARK: - Semantics that must not move

    func testRequiredSemanticsAndBoundsAreUnchanged() {
        XCTAssertEqual(RequestFoodFormDraft.diningDollarsOnlyCeilingCents, 5_000)
        XCTAssertEqual(RequestFoodFormDraft.mealExchangeDiningDollarsCeilingCents, 2_500)
        XCTAssertFalse(RequestFoodFormValidator.hasRequiredInput(draft(path: .mealExchange)))
        XCTAssertFalse(RequestFoodFormValidator.hasRequiredInput(draft(path: .diningDollars, diningDollars: "5")))
        XCTAssertFalse(RequestFoodFormValidator.hasRequiredInput(draft(path: .diningDollars, orderDetails: "Fries")))
        XCTAssertFalse(RequestFoodFormValidator.hasRequiredInput(
            draft(path: .diningDollars, orderDetails: "Fries", diningDollars: "50.01")
        ))
        XCTAssertTrue(RequestFoodFormValidator.hasRequiredInput(
            draft(path: .diningDollars, orderDetails: "Fries", diningDollars: "50.00")
        ))
        XCTAssertTrue(RequestFoodFormValidator.hasRequiredInput(draft(path: .mealExchange, meal: "Wings")))
    }

    func testDiningDollarsOnlyOrderFieldUsesTheAcceptedLabelAndNoPlaceholderCopy() {
        XCTAssertEqual(RequestFoodView.orderDetailsLabel, "What are you ordering?")
        XCTAssertEqual(RequestFoodView.orderDetailsLabel, RequestFoodView.mealDetailPlaceholder)
    }
}
