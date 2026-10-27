//
//  RequestFoodBranchAmountDraftTests.swift
//  CommonPlateiosTests
//
// W4-R4.1 separate branch monetary drafts: the Meal Exchange Dining Dollars
// TOP-UP and the Dining-Dollars-only whole-order AMOUNT are distinct values.
// Switching (by the requester or by Screenshot Assistance) is non-destructive,
// validation and submission read only the active branch, and one branch's
// value is never copied into, derived from, capped by, or submitted as the
// other's.
import XCTest
@testable import CommonPlateios

final class RequestFoodBranchAmountDraftTests: XCTestCase {
    private let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private let now = Date(timeIntervalSince1970: 1_000)

    private func draft(
        menuPath: RequestMenuPath = .mealExchange,
        topUp: String = "",
        diningOnly: String = ""
    ) -> RequestFoodFormDraft {
        RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            menuPath: menuPath,
            timing: .asap,
            preferredPickupTime: now,
            mealSwipes: 2,
            mealEntries: ["Rice bowl", "Side salad", "", "", ""],
            orderDetails: "Grain bowl",
            mealExchangeDiningDollarsText: topUp,
            diningDollarsOnlyText: diningOnly
        )
    }

    private func errors(_ draft: RequestFoodFormDraft) -> [RequestFoodFieldError] {
        RequestFoodFormValidator.validate(
            draft: draft,
            isScheduledWindowValid: true,
            isScheduledTimingAvailable: true
        )
    }

    private func payload(_ draft: RequestFoodFormDraft) throws -> CreateRequestPayload {
        try RequestFoodView.makePayload(draft: draft, now: now, calendar: utcCalendar)
    }

    // MARK: - Retention through switching

    func testSwitchingAwayAndBackRestoresEachBranchsOwnValue() {
        var value = draft(topUp: "$2.00", diningOnly: "$30.00")

        value.menuPath = .diningDollars
        XCTAssertEqual(value.diningDollarsText, "$30.00")
        XCTAssertEqual(value.mealExchangeDiningDollarsText, "$2.00", "the top-up draft is preserved while inactive")

        value.menuPath = .mealExchange
        XCTAssertEqual(value.diningDollarsText, "$2.00")
        XCTAssertEqual(value.diningDollarsOnlyText, "$30.00", "the whole-order draft is preserved while inactive")

        value.menuPath = .diningDollars
        value.menuPath = .mealExchange
        XCTAssertEqual(value.mealExchangeDiningDollarsText, "$2.00")
        XCTAssertEqual(value.diningDollarsOnlyText, "$30.00")
    }

    func testEditingTheActiveBranchTouchesOnlyThatBranch() {
        var value = draft(topUp: "$2.00", diningOnly: "$30.00")
        value.diningDollarsText = "$3.00"
        XCTAssertEqual(value.mealExchangeDiningDollarsText, "$3.00")
        XCTAssertEqual(value.diningDollarsOnlyText, "$30.00")

        value.menuPath = .diningDollars
        value.diningDollarsText = "$31.00"
        XCTAssertEqual(value.diningDollarsOnlyText, "$31.00")
        XCTAssertEqual(value.mealExchangeDiningDollarsText, "$3.00")
    }

    func testOneBranchNeverPopulatesTheOther() {
        var value = draft(topUp: "$2.00")
        value.menuPath = .diningDollars
        XCTAssertEqual(value.diningDollarsText, "", "the whole-order amount is not seeded from the top-up")
        XCTAssertEqual(value.diningDollarsOnlyText, "")

        var other = draft(menuPath: .diningDollars, diningOnly: "$30.00")
        other.menuPath = .mealExchange
        XCTAssertEqual(other.diningDollarsText, "", "the top-up is not seeded from the whole-order amount")
        XCTAssertEqual(other.mealExchangeDiningDollarsText, "")
    }

    func testSwitchingDoesNotCapZeroTruncateOrRewriteEitherValue() {
        // Each value is out of range for the OTHER branch's ceiling or simply
        // unusual text; neither is touched by a switch.
        var value = draft(topUp: "$24.99", diningOnly: "$49.99")
        value.menuPath = .diningDollars
        value.menuPath = .mealExchange
        XCTAssertEqual(value.mealExchangeDiningDollarsText, "$24.99")
        XCTAssertEqual(value.diningDollarsOnlyText, "$49.99")

        var overCeiling = draft(topUp: "$30.00", diningOnly: "abc")
        overCeiling.menuPath = .diningDollars
        overCeiling.menuPath = .mealExchange
        XCTAssertEqual(overCeiling.mealExchangeDiningDollarsText, "$30.00", "above the top-up ceiling, still retained verbatim")
        XCTAssertEqual(overCeiling.diningDollarsOnlyText, "abc")
    }

    func testSwitchingNeverTouchesSharedFieldsOrInactiveMealAndDetailsContent() {
        var value = draft(topUp: "$2.00", diningOnly: "$30.00")
        let spot = value.selectedDiningSpot
        value.menuPath = .diningDollars
        value.menuPath = .mealExchange
        XCTAssertEqual(value.selectedDiningSpot, spot)
        XCTAssertEqual(value.timing, .asap)
        XCTAssertEqual(value.mealSwipes, 2)
        XCTAssertEqual(value.mealEntries[0].name, "Rice bowl")
        XCTAssertEqual(value.orderDetails, "Grain bowl")
    }

    // MARK: - Active-only validation

    func testValidationUsesOnlyTheActiveBranchsAmount() {
        // Meal Exchange active: an invalid/over-ceiling Dining-Dollars-only
        // draft is irrelevant, and so is an empty one.
        XCTAssertTrue(errors(draft(topUp: "$2.00", diningOnly: "abc")).isEmpty)
        XCTAssertTrue(errors(draft(topUp: "", diningOnly: "")).isEmpty, "an empty top-up means none needed")
        XCTAssertTrue(errors(draft(topUp: "$1.00", diningOnly: "$500.00")).isEmpty)

        // Dining Dollars active: an invalid top-up draft is irrelevant, while
        // the whole-order amount is required.
        XCTAssertTrue(errors(draft(menuPath: .diningDollars, topUp: "abc", diningOnly: "$30.00")).isEmpty)
        XCTAssertEqual(
            errors(draft(menuPath: .diningDollars, topUp: "$2.00", diningOnly: "")).map(\.error),
            [.missingDiningDollars],
            "the top-up draft cannot satisfy the required whole-order amount"
        )
    }

    func testEachBranchKeepsItsOwnCeiling() {
        XCTAssertEqual(
            errors(draft(topUp: "$25.01")).map(\.error),
            [.invalidDiningDollars(ceilingCents: 2_500)]
        )
        XCTAssertTrue(errors(draft(topUp: "$25.00")).isEmpty)
        XCTAssertEqual(
            errors(draft(menuPath: .diningDollars, diningOnly: "$50.01")).map(\.error),
            [.invalidDiningDollars(ceilingCents: 5_000)]
        )
        XCTAssertTrue(errors(draft(menuPath: .diningDollars, diningOnly: "$50.00")).isEmpty)
        // A top-up above 25 is invalid only while the Meal branch is active;
        // $30 is perfectly valid as a whole-order amount.
        XCTAssertTrue(errors(draft(menuPath: .diningDollars, topUp: "$30.00", diningOnly: "$30.00")).isEmpty)
    }

    // MARK: - Active-only submission

    func testSubmissionUsesOnlyTheActiveBranchsAmount() throws {
        let meal = try payload(draft(topUp: "$2.00", diningOnly: "$30.00"))
        XCTAssertEqual(meal.menuPath, .mealExchange)
        XCTAssertEqual(meal.estimatedDiningDollarsCents, 200)
        XCTAssertNil(meal.orderDetails)

        let dining = try payload(draft(menuPath: .diningDollars, topUp: "$2.00", diningOnly: "$30.00"))
        XCTAssertEqual(dining.menuPath, .diningDollars)
        XCTAssertEqual(dining.estimatedDiningDollarsCents, 3_000)
        XCTAssertEqual(dining.mealSwipes, 0)
        XCTAssertEqual(dining.mealItems, [])

        // No top-up needed: nothing is sent, never the other branch's value.
        let noTopUp = try payload(draft(topUp: "", diningOnly: "$30.00"))
        XCTAssertNil(noTopUp.estimatedDiningDollarsCents)
    }

    func testSubmissionOfAnInvalidInactiveDraftStillSucceedsForTheActiveBranch() throws {
        XCTAssertNoThrow(try payload(draft(topUp: "$2.00", diningOnly: "garbage")))
        XCTAssertNoThrow(try payload(draft(menuPath: .diningDollars, topUp: "garbage", diningOnly: "$30.00")))
    }

    // MARK: - Construction and D2 restoration

    func testSingleValueInitializerTargetsTheActiveBranchOnly() {
        let meal = RequestFoodFormDraft(menuPath: .mealExchange, diningDollarsText: "$2.00")
        XCTAssertEqual(meal.mealExchangeDiningDollarsText, "$2.00")
        XCTAssertEqual(meal.diningDollarsOnlyText, "")

        let dining = RequestFoodFormDraft(menuPath: .diningDollars, diningDollarsText: "$30.00")
        XCTAssertEqual(dining.diningDollarsOnlyText, "$30.00")
        XCTAssertEqual(dining.mealExchangeDiningDollarsText, "")
    }

    func testRestorationReconstructsOnlyTheSubmittedBranchsAmount() throws {
        let diningPayload = try payload(draft(menuPath: .diningDollars, topUp: "$2.00", diningOnly: "$30.00"))
        let restoredDining = RequestFoodFormDraft(restoring: diningPayload)
        XCTAssertEqual(restoredDining.menuPath, .diningDollars)
        XCTAssertEqual(restoredDining.diningDollarsOnlyText, "$30.00")
        XCTAssertEqual(restoredDining.mealExchangeDiningDollarsText, "", "the inactive session draft cannot be reconstructed")

        let mealPayload = try payload(draft(topUp: "$2.00", diningOnly: "$30.00"))
        let restoredMeal = RequestFoodFormDraft(restoring: mealPayload)
        XCTAssertEqual(restoredMeal.menuPath, .mealExchange)
        XCTAssertEqual(restoredMeal.mealExchangeDiningDollarsText, "$2.00")
        XCTAssertEqual(restoredMeal.diningDollarsOnlyText, "")
    }

    // MARK: - View wiring (no UI-test target; source inspection only)

    /// The view is the only place a requester interaction can latch manual
    /// authority, so its three seams are pinned by source: the selector routes
    /// through `recordMenuPathSelection`, the amount field latches the top-up
    /// flag only while the Meal branch is active, and an applied path records
    /// that assistance established one. This is source inspection, not a
    /// rendered-behavior proof (that is the hosted simulator/device proof).
    func testRequestFoodViewWiresTheAuthoritySeams() throws {
        let view = try ScreenshotBoundarySource.read(
            "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift",
            from: #filePath
        )
        XCTAssertTrue(view.contains("screenshotManualEdits.recordMenuPathSelection(from: draft.menuPath, to: newValue)"))
        XCTAssertTrue(view.contains("screenshotManualEdits.record(applied)"))
        let binding = try XCTUnwrap(view.range(of: "private var diningDollarsBinding"))
        let bindingBody = String(view[binding.lowerBound...].prefix(720))
        XCTAssertTrue(bindingBody.contains("if draft.menuPath == .mealExchange {"))
        XCTAssertTrue(bindingBody.contains("screenshotManualEdits.hasManuallyEditedDiningDollars = !$0.isEmpty"))
        XCTAssertTrue(bindingBody.contains("screenshotManualEdits.hasManuallyEditedDiningDollarsOnly = !$0.isEmpty"))
        XCTAssertTrue(bindingBody.contains("screenshotProvenance.diningDollarsOnly = false"))
    }
}
