//
//  RequesterIncompleteVsInvalidHostedTests.swift
//  CommonPlateiosTests
//
// W4-R4 (2026-09-26) hosted proof for incomplete-vs-invalid validation and the
// compact Dining-Dollars-only ordering field. Every test mounts the real
// `RequestFoodView` (see `RequesterFormHostedHarness`) and reads what was
// actually laid out and drawn.
//
// Not established here: keyboard behavior, motion smoothness, or physical-device
// rendering. Those remain Faith's physical iPhone checks.
import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

@MainActor
final class RequesterIncompleteVsInvalidHostedTests: XCTestCase {
    private let spot = DiningSpot(name: "Jasper Kane Cafe", address: nil)
    private let accuracy: CGFloat = 0.75

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

    private func frame(
        _ host: RequesterFormHost,
        _ key: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CGRect {
        try XCTUnwrap(host.frame(key), "no element \(key)", file: file, line: line)
    }

    private func requiredCount(_ host: RequesterFormHost) -> Int {
        host.allLabels().filter { $0 == "Required" }.count
    }

    /// Matches the real indexed accessibility identifiers `RequestFoodView`
    /// assigns. Order details has no distinct field-error identifier of its
    /// own (its "Tell us what to order." copy is checked separately below).
    /// The meal error identifier is indexed per meal entry, so `mealCount`
    /// must cover every meal index the caller actually activated.
    private func errorIdentifiers(mealCount: Int) -> [String] {
        ["request-dining-dollars-error"] + (0..<mealCount).map { "request-meal-error-\($0)" }
    }

    private func assertNoErrorTextOrRequired(
        _ host: RequesterFormHost,
        _ message: String,
        mealCount: Int = 1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(requiredCount(host), 0, "\(message): no `Required`", file: file, line: line)
        for identifier in errorIdentifiers(mealCount: mealCount) {
            XCTAssertFalse(host.exists(identifier), "\(message): no \(identifier)", file: file, line: line)
        }
        let labels = host.allLabels()
        for copy in [
            "Tell us what this meal swipe is for.",
            "Tell us what to order.",
            "Enter how many Dining Dollars this order needs.",
        ] {
            XCTAssertFalse(labels.contains(copy), "\(message): no detached copy \(copy)", file: file, line: line)
        }
    }

    /// How red a rendered point is (red channel over the stronger of the other
    /// two). The neutral canvas is ~0; the invalid fill/outline are clearly
    /// positive.
    private func redness(_ pixels: RequesterFormHost.Pixels, x: CGFloat, y: CGFloat) -> Int {
        let color = pixels.rgb(atX: x, y: y)
        return color.r - max(color.g, color.b)
    }

    /// Asserts no invalid fill and no red outline anywhere on `control`'s
    /// rendered box.
    private func assertNeutralRendering(
        _ host: RequesterFormHost,
        control: CGRect,
        baselineRedness: Int,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let pixels = try XCTUnwrap(host.pixels(), file: file, line: line)
        XCTAssertLessThanOrEqual(
            redness(pixels, x: control.minX + 6, y: control.midY),
            baselineRedness + 2,
            "\(message): fill is neutral",
            file: file, line: line
        )
        var redOutline = false
        var y = control.minY - 3
        while y <= control.minY + 3 {
            var x = control.minX + 20
            while x <= control.maxX - 20 {
                let c = pixels.rgb(atX: x, y: y)
                if c.r - c.g > 60, c.r - c.b > 60 { redOutline = true }
                x += 4
            }
            y += 0.5
        }
        XCTAssertFalse(redOutline, "\(message): no red outline", file: file, line: line)
    }

    private func isPostDisabled(_ host: RequesterFormHost) throws -> Bool {
        let node = try XCTUnwrap(host.nodes()["request-post-request"], "no Post request")
        return node.accessibilityTraits.contains(.notEnabled)
    }

    // MARK: - Empty required entries stay neutral

    func testEmptyMealItemBlurAndCollapseStayNeutralAndPostingStaysDisabled() throws {
        let host = try RequesterFormHost(draft: draft(path: .mealExchange))
        let collapsed = try frame(host, "request-meal-control-0")
        let baseline = redness(try XCTUnwrap(host.pixels()), x: collapsed.minX + 6, y: collapsed.midY)

        XCTAssertTrue(host.activate("request-meal-collapsed-0"))
        try host.focusThenBlur("request-meal-item-0")
        assertNoErrorTextOrRequired(host, "expanded, blurred empty")
        try assertNeutralRendering(
            host, control: try frame(host, "request-meal-control-0"),
            baselineRedness: baseline, "expanded, blurred empty"
        )

        XCTAssertTrue(host.activate("request-meal-done-0"))
        assertNoErrorTextOrRequired(host, "collapsed after empty blur")
        try assertNeutralRendering(
            host, control: try frame(host, "request-meal-control-0"),
            baselineRedness: baseline, "collapsed after empty blur"
        )
        XCTAssertTrue(try isPostDisabled(host), "Post request stays disabled while incomplete")
        XCTAssertFalse(RequestFoodView.isSubmissionEnabled(
            draft: host.draftSession.draft, submissionError: nil, isCreating: false
        ))
    }

    func testEveryActiveMealExchangeSwipeStaysNeutralWhenEmpty() throws {
        var d = draft(path: .mealExchange)
        d.mealSwipes = 3
        let host = try RequesterFormHost(draft: d)
        for index in 0..<3 {
            XCTAssertTrue(host.activate("request-meal-collapsed-\(index)"))
            try host.focusThenBlur("request-meal-item-\(index)")
            XCTAssertTrue(host.activate("request-meal-done-\(index)"))
        }
        assertNoErrorTextOrRequired(host, "three empty meals blurred", mealCount: 3)
        XCTAssertTrue(try isPostDisabled(host))
    }

    func testDetailsWithoutMealItemShowsPromptExpandedAndCollapsedWithoutAllowingPosting() throws {
        var value = draft(path: .mealExchange)
        value.mealEntries[0] = MealItem(name: " \n ", details: "Sauce on the side")
        let host = try RequesterFormHost(draft: value)
        let message = "Enter a meal item to go with these details."

        XCTAssertTrue(host.exists("request-meal-error-0"))
        XCTAssertTrue(host.allLabels().contains(message))
        XCTAssertTrue(try isPostDisabled(host))
        XCTAssertTrue(host.activate("request-meal-collapsed-0"))
        XCTAssertTrue(host.exists("request-meal-error-0"))
        let input = try XCTUnwrap(host.nodes()["request-meal-item-0"])
        XCTAssertEqual(input.accessibilityHint, message)
        XCTAssertTrue(host.activate("request-meal-done-0"))
        XCTAssertTrue(host.exists("request-meal-error-0"))
        XCTAssertEqual(host.draftSession.draft.mealEntries[0], value.mealEntries[0])
        XCTAssertFalse(RequestFoodView.isSubmissionEnabled(
            draft: host.draftSession.draft, submissionError: nil, isCreating: false
        ))
    }

    func testAddingMealItemClearsDetailsOnlyPromptAndAllowsPosting() throws {
        var value = draft(path: .mealExchange)
        value.mealEntries[0] = MealItem(name: "", details: "Sauce on the side")
        let host = try RequesterFormHost(draft: value)
        XCTAssertTrue(host.exists("request-meal-error-0"))

        host.draftSession.draft.mealEntries[0].name = "Chicken wings"
        host.settle()

        XCTAssertFalse(host.exists("request-meal-error-0"))
        XCTAssertFalse(try isPostDisabled(host))
        XCTAssertEqual(host.draftSession.draft.mealEntries[0].details, "Sauce on the side")
    }

    func testClearingDetailsReturnsNamelessMealToNeutralAndKeepsPostingBlocked() throws {
        var value = draft(path: .mealExchange)
        value.mealEntries[0] = MealItem(name: "", details: "Sauce on the side")
        let host = try RequesterFormHost(draft: value)
        XCTAssertTrue(host.exists("request-meal-error-0"))

        host.draftSession.draft.mealEntries[0].details = " \n "
        host.settle()

        XCTAssertFalse(host.exists("request-meal-error-0"))
        XCTAssertEqual(requiredCount(host), 0)
        XCTAssertTrue(try isPostDisabled(host))
    }

    func testMealNamePromptOnlyAppliesToDetailsWithoutAName() {
        XCTAssertNil(RequestFoodView.mealItemNamePrompt(for: MealItem(name: "", details: nil)))
        XCTAssertNil(RequestFoodView.mealItemNamePrompt(for: MealItem(name: "", details: " \n ")))
        XCTAssertNil(RequestFoodView.mealItemNamePrompt(for: MealItem(name: "Wings", details: "Sauce")))
        XCTAssertNotNil(RequestFoodView.mealItemNamePrompt(for: MealItem(name: " \n ", details: "Sauce")))
    }

    func testEmptyDiningDollarsAmountBlurStaysNeutralAndPostingStaysDisabled() throws {
        let host = try RequesterFormHost(draft: draft(path: .diningDollars, orderDetails: "Fries"))
        let control = try frame(host, "request-dining-dollars-control")
        let baseline = redness(try XCTUnwrap(host.pixels()), x: control.minX + 6, y: control.midY)

        try host.focusThenBlur("request-dining-dollars")

        assertNoErrorTextOrRequired(host, "empty amount blurred")
        try assertNeutralRendering(
            host, control: try frame(host, "request-dining-dollars-control"),
            baselineRedness: baseline, "empty amount blurred"
        )
        XCTAssertTrue(try isPostDisabled(host))
    }

    func testEmptyDiningDollarsOrderDescriptionBlurStaysNeutralAndPostingStaysDisabled() throws {
        let host = try RequesterFormHost(draft: draft(path: .diningDollars, diningDollars: "12.00"))
        let control = try frame(host, "request-order-details-control")
        let baseline = redness(try XCTUnwrap(host.pixels()), x: control.minX + 6, y: control.midY)

        try host.focusThenBlur("request-order-details")

        assertNoErrorTextOrRequired(host, "empty order description blurred")
        try assertNeutralRendering(
            host, control: try frame(host, "request-order-details-control"),
            baselineRedness: baseline, "empty order description blurred"
        )
        XCTAssertTrue(try isPostDisabled(host))
    }

    func testDecimalKeyboardFocusPreservesTheAmount() throws {
        let host = try RequesterFormHost(
            draft: draft(path: .diningDollars, orderDetails: "Fries", diningDollars: "12.50")
        )
        let field = try XCTUnwrap(host.uiView(withIdentifier: "request-dining-dollars") as? UITextField)
        XCTAssertEqual(field.keyboardType, .decimalPad)
        XCTAssertTrue(field.becomeFirstResponder())
        host.settle(0.8)

        XCTAssertTrue(field.isFirstResponder, "the decimal-pad field accepts focus")
        XCTAssertEqual(host.draftSession.draft.diningDollarsText, "12.50")
        field.resignFirstResponder()
    }

    // MARK: - Entered-invalid keeps its feedback

    func testEnteredOutOfBoundsDiningDollarsStillShowsInvalidFeedbackAndBlocksPosting() throws {
        let host = try RequesterFormHost(
            draft: draft(path: .diningDollars, orderDetails: "Fries", diningDollars: "50.01")
        )
        XCTAssertFalse(host.exists("request-dining-dollars-error"), "quiet until its own blur")

        try host.focusThenBlur("request-dining-dollars")

        XCTAssertTrue(host.exists("request-dining-dollars-error"))
        XCTAssertTrue(host.allLabels().contains("Enter an amount between $0.01 and $50.00."))
        XCTAssertEqual(requiredCount(host), 0)
        XCTAssertTrue(try isPostDisabled(host))
    }

    // MARK: - Menu-path reset

    func testPathSwitchClearsVisibleInvalidAmountAndPreservesEveryEnteredValue() throws {
        var initial = draft(path: .diningDollars, meal: "Wings", orderDetails: "Fries", diningDollars: "99")
        initial.mealSwipes = 1
        let host = try RequesterFormHost(draft: initial)

        try host.focusThenBlur("request-dining-dollars")
        XCTAssertTrue(host.exists("request-dining-dollars-error"), "precondition: invalid amount is visible")

        XCTAssertTrue(host.activate("request-menu-path-meal-exchange"))
        XCTAssertTrue(host.exists("label:Number of meal swipes"))
        XCTAssertFalse(host.exists("request-dining-dollars-error"), "Meal Exchange starts visually clean")

        XCTAssertTrue(host.activate("request-menu-path-dining-dollars"))
        XCTAssertFalse(host.exists("request-dining-dollars-error"), "returning starts visually clean too")

        try host.focusThenBlur("request-dining-dollars")
        XCTAssertTrue(host.exists("request-dining-dollars-error"), "an entered invalid value can present again through blur")

        XCTAssertEqual(host.draftSession.draft.mealEntries[0].name, "Wings")
        XCTAssertEqual(host.draftSession.draft.orderDetails, "Fries")
        XCTAssertEqual(host.draftSession.draft.diningDollarsText, "99")
    }

    func testAClearedAmountDoesNotReopenRedFromOldPresentationHistory() throws {
        let host = try RequesterFormHost(
            draft: draft(path: .diningDollars, orderDetails: "Fries", diningDollars: "99")
        )
        try host.focusThenBlur("request-dining-dollars")
        XCTAssertTrue(host.exists("request-dining-dollars-error"), "precondition")

        host.draftSession.draft.diningDollarsText = ""
        host.settle()
        assertNoErrorTextOrRequired(host, "amount cleared after being invalid")

        XCTAssertTrue(host.activate("request-menu-path-meal-exchange"))
        XCTAssertTrue(host.activate("request-menu-path-dining-dollars"))
        try host.focusThenBlur("request-dining-dollars")
        assertNoErrorTextOrRequired(host, "cleared amount after a round trip and another blur")
    }

    func testTheBlurCausedByAPathSwitchIsNotValidatedAgainstTheDestinationBranch() throws {
        // 99 is invalid on both branches, so if the switch's own blur counted
        // against Meal Exchange an error would appear there.
        let host = try RequesterFormHost(
            draft: draft(path: .diningDollars, meal: "Wings", orderDetails: "Fries", diningDollars: "99")
        )
        let field = try XCTUnwrap(host.uiView(withIdentifier: "request-dining-dollars"))
        XCTAssertTrue(field.becomeFirstResponder())
        host.settle(0.5)

        XCTAssertTrue(host.activate("request-menu-path-meal-exchange"))
        (host.uiView(withIdentifier: "request-dining-dollars") ?? field).resignFirstResponder()
        host.settle(0.7)

        XCTAssertTrue(host.exists("label:Number of meal swipes"))
        XCTAssertFalse(host.exists("request-dining-dollars-error"), "the switch's blur is not an invalid blur")
        assertNoErrorTextOrRequired(host, "after switching with the amount focused")
    }

    // MARK: - Compact Dining-Dollars-only ordering field

    func testOrderFieldUsesTheAcceptedLabelAndPlaceholderWithNoSecondPrompt() throws {
        // W4-R4 (2026-09-27): a placeholder IS required, matching the Meal
        // item pattern — this supersedes the prior "no placeholder" decision.
        XCTAssertEqual(RequestFoodView.orderDetailsPlaceholder, "e.g. Chicken Wings")
        let host = try RequesterFormHost(draft: draft(path: .diningDollars))
        let labels = host.allLabels()

        XCTAssertTrue(labels.contains("What are you ordering?"))
        XCTAssertFalse(labels.contains("What would you like to order?"))
        XCTAssertFalse(labels.contains("Order details"))
        let order = try XCTUnwrap(host.nodes()["request-order-details"])
        XCTAssertEqual(
            order.accessibilityValue,
            "e.g. Chicken Wings",
            "the empty control must show the accepted placeholder"
        )
    }

    func testEmptyOrderControlMatchesTheCollapsedMealControlHeightNotTheAmountControlHeight() throws {
        // W4-R4 (2026-09-27): the default empty ordering control uses the
        // same 76pt collapsed-control target as the collapsed Meal Exchange
        // Meal entry — it does NOT use the 44pt Dining Dollars amount-field
        // height (supersedes the 2026-09-26 compact-height decision).
        for size in [DynamicTypeSize.large, .xLarge, .accessibility1] {
            let host = try RequesterFormHost(
                draft: draft(path: .diningDollars),
                dynamicTypeSize: size
            )
            let order = try frame(host, "request-order-details-control")
            let amount = try frame(host, "request-dining-dollars-control")

            let mealExchangeHost = try RequesterFormHost(
                draft: draft(path: .mealExchange),
                dynamicTypeSize: size
            )
            let mealControl = try frame(mealExchangeHost, "request-meal-control-0")

            XCTAssertEqual(
                order.height, mealControl.height, accuracy: 1,
                "\(size): empty ordering control must match the collapsed Meal control target"
            )
            XCTAssertGreaterThan(
                order.height, amount.height + 10,
                "\(size): must NOT match the compact Dining Dollars amount-field height"
            )
            if size == .large {
                XCTAssertEqual(order.height, RequestFoodView.collapsedMealControlHeight, accuracy: 1)
                XCTAssertEqual(RequestFoodView.collapsedMealControlHeight, 76)
            }
        }
    }

    func testMultilineOrderTextGrowsLocallyWhileContentAboveStaysAndContentBelowMoves() throws {
        let host = try RequesterFormHost(draft: draft(path: .diningDollars, diningDollars: "12.00"))
        let above = [
            "request-dining-spot-picker",
            "request-menu-path-picker",
            "label:Dining location",
        ]
        let below = ["request-dining-dollars-control", "label:Timing"]

        let beforeAbove = try above.map { try frame(host, $0) }
        let beforeBelow = try below.map { try frame(host, $0) }
        let beforeOrder = try frame(host, "request-order-details-control")
        let beforeAmount = try frame(host, "request-dining-dollars-control")

        // The 76pt empty floor (2026-09-27) already accommodates a couple of
        // wrapped lines, so this needs enough text to grow past it, not just
        // past the old 44pt floor.
        host.draftSession.draft.orderDetails =
            "Chicken tenders combo, extra honey mustard, a large fountain drink with no ice, a side of fries with plenty of salt, extra ranch dressing on the side, a few napkins, and please make sure it is packed to go"
        host.settle()

        let order = try frame(host, "request-order-details-control")
        let growth = order.height - beforeOrder.height
        XCTAssertGreaterThan(growth, 15, "the wrapped text adds at least one line of local height")
        XCTAssertEqual(order.minY, beforeOrder.minY, accuracy: accuracy, "grows downward from a fixed top")
        for (key, before) in zip(above, beforeAbove) {
            let after = try frame(host, key)
            XCTAssertEqual(after.minY, before.minY, accuracy: accuracy, "\(key) (above) must not move")
            XCTAssertEqual(after.minX, before.minX, accuracy: accuracy, "\(key) (above) must not shift")
            XCTAssertEqual(after.height, before.height, accuracy: accuracy, "\(key) (above) keeps its size")
        }
        for (key, before) in zip(below, beforeBelow) {
            let after = try frame(host, key)
            XCTAssertEqual(after.minY - before.minY, growth, accuracy: 1.5, "\(key) (below) moves down by exactly the growth")
        }
        let amount = try frame(host, "request-dining-dollars-control")
        XCTAssertEqual(amount.height, beforeAmount.height, accuracy: accuracy, "the amount control is unaffected")
    }

    func testOrderFieldGrowsAtLargerDynamicTypeAndStillStartsAtTheCollapsedMealTarget() throws {
        // Empty ordering control at a large Dynamic Type size still matches
        // the collapsed Meal control target, not the amount field.
        let host = try RequesterFormHost(
            draft: draft(path: .diningDollars),
            dynamicTypeSize: .accessibility2
        )
        let mealExchangeHost = try RequesterFormHost(
            draft: draft(path: .mealExchange),
            dynamicTypeSize: .accessibility2
        )
        let empty = try frame(host, "request-order-details-control")
        let mealControl = try frame(mealExchangeHost, "request-meal-control-0")
        XCTAssertEqual(empty.height, mealControl.height, accuracy: 1)

        host.draftSession.draft.orderDetails = "Chicken tenders combo with extra honey mustard and a large drink"
        host.settle()
        let grown = try frame(host, "request-order-details-control")
        XCTAssertGreaterThan(grown.height, empty.height + 20)
        XCTAssertEqual(grown.minY, empty.minY, accuracy: accuracy)
        XCTAssertLessThanOrEqual(grown.maxX, host.window.bounds.maxX, "stays inside the screen")
    }

    func testTheOrderFieldNeverStretchesToFillADifferentViewportHeight() throws {
        let short = try RequesterFormHost(draft: draft(path: .diningDollars), viewportHeight: 520)
        let tall = try RequesterFormHost(draft: draft(path: .diningDollars))
        // The field never stretches to fill a taller viewport.
        XCTAssertEqual(
            try frame(short, "request-order-details-control").height,
            try frame(tall, "request-order-details-control").height,
            accuracy: accuracy
        )
    }
}
