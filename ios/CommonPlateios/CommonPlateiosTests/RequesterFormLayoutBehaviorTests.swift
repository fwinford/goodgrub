//
//  RequesterFormLayoutBehaviorTests.swift
//  CommonPlateiosTests
//
// W4-R4 (2026-09-26) behavioral proof that does not need a mounted view: the
// `Post request` placement rule, Later's motion (including Reduce Motion),
// and the menu-path validation reset. Rendered geometry is proven separately
// in `RequesterFormHostedFidelityTests`.
import SwiftUI
import XCTest
@testable import CommonPlateios

final class RequesterFormLayoutBehaviorTests: XCTestCase {

    // MARK: - Post request placement rule

    func testNothingIsAnchoredUntilAllThreeMeasurementsExist() {
        XCTAssertFalse(RequesterFormLayoutMetrics().anchorsPostRequestToBottom)
        XCTAssertFalse(
            RequesterFormLayoutMetrics(viewportHeight: 700, formContentHeight: 300, postRequestHeight: 0)
                .anchorsPostRequestToBottom
        )
        XCTAssertFalse(
            RequesterFormLayoutMetrics(viewportHeight: 0, formContentHeight: 300, postRequestHeight: 48)
                .anchorsPostRequestToBottom
        )
    }

    func testAnchoredOnlyWhileTheFlowedFormFitsTheViewport() {
        var metrics = RequesterFormLayoutMetrics(viewportHeight: 700, formContentHeight: 500, postRequestHeight: 48)
        XCTAssertTrue(metrics.anchorsPostRequestToBottom)

        // Exactly fitting still anchors; one point more follows the content.
        metrics.viewportHeight = metrics.flowedContentHeight
        XCTAssertTrue(metrics.anchorsPostRequestToBottom)
        metrics.viewportHeight -= 1
        XCTAssertFalse(metrics.anchorsPostRequestToBottom)
    }

    func testPlacementDependsOnlyOnMeasurementsThatDoNotChangeWithPlacement() {
        // The rule reads the form's own height, the action's own height and
        // the region's height — never where the action currently is — so
        // flipping placement cannot change its own answer.
        let metrics = RequesterFormLayoutMetrics(viewportHeight: 720, formContentHeight: 640, postRequestHeight: 48)
        XCTAssertEqual(metrics.anchorsPostRequestToBottom, metrics.anchorsPostRequestToBottom)
        XCTAssertEqual(
            metrics.flowedContentHeight,
            RequesterFormLayoutMetrics.contentTopPadding + 640
                + RequesterFormLayoutMetrics.formToActionSpacing + 48
                + RequesterFormLayoutMetrics.contentBottomPadding
        )
    }

    // MARK: - Later motion

    func testLaterMotionIsARestrainedEaseOutAndReduceMotionRemovesIt() {
        XCTAssertEqual(RequestFoodView.laterMotionDuration, 0.22, accuracy: 0.0001)
        XCTAssertNotNil(RequestFoodView.laterMotionAnimation(reduceMotion: false))
        XCTAssertEqual(
            RequestFoodView.laterMotionAnimation(reduceMotion: false),
            Animation.easeOut(duration: 0.22)
        )
        XCTAssertNil(RequestFoodView.laterMotionAnimation(reduceMotion: true))
    }

    // MARK: - Menu-path validation reset

    private func errors(_ fields: [RequestFoodFormField]) -> [RequestFoodFieldError] {
        fields.map { RequestFoodFieldError(field: $0, error: .invalidDiningDollars(ceilingCents: 5_000)) }
    }

    func testPathSwitchForgetsOnlyBranchSpecificPresentation() {
        let all: [RequestFoodFormField] = [.diningSpot, .mealDetail(index: 0), .orderDetails, .diningDollars, .pickupSchedule]
        var presentation = RequestFoodValidationPresentation()
        presentation.presentAll(errors(all))

        presentation.resetMenuPathSpecificPresentation()

        let visible = presentation.visibleErrors(from: errors(all)).map(\.field)
        XCTAssertEqual(Set(visible), [.diningSpot, .pickupSchedule])
    }

    func testResetLeavesTheBranchAbleToPresentAgainThroughNormalBlur() {
        var presentation = RequestFoodValidationPresentation()
        presentation.presentAll(errors([.diningDollars]))
        presentation.resetMenuPathSpecificPresentation()
        XCTAssertTrue(presentation.visibleErrors(from: errors([.diningDollars])).isEmpty)

        presentation.handleFocusTransition(
            from: .diningDollars, to: nil, errors: errors([.diningDollars])
        )
        XCTAssertEqual(presentation.visibleErrors(from: errors([.diningDollars])).count, 1)
    }

    func testABlurCausedByThePathSwitchIsNotValidatedAgainstTheNewBranch() {
        // Focused on Dining Dollars under Dining Dollars, then the path became
        // Meal Exchange: that blur belongs to the branch just left.
        XCTAssertFalse(
            RequestFoodValidationPresentation.blurBelongsToCurrentMenuPath(
                previousField: .diningDollars,
                menuPathAtFocus: .diningDollars,
                currentMenuPath: .mealExchange
            )
        )
        XCTAssertFalse(
            RequestFoodValidationPresentation.blurBelongsToCurrentMenuPath(
                previousField: .mealDetail(index: 0),
                menuPathAtFocus: .mealExchange,
                currentMenuPath: .diningDollars
            )
        )
        // Ordinary blurs — same path, no recorded path, or a field both
        // branches share — still validate.
        XCTAssertTrue(
            RequestFoodValidationPresentation.blurBelongsToCurrentMenuPath(
                previousField: .diningDollars, menuPathAtFocus: .diningDollars, currentMenuPath: .diningDollars
            )
        )
        XCTAssertTrue(
            RequestFoodValidationPresentation.blurBelongsToCurrentMenuPath(
                previousField: .diningDollars, menuPathAtFocus: nil, currentMenuPath: .mealExchange
            )
        )
        XCTAssertTrue(
            RequestFoodValidationPresentation.blurBelongsToCurrentMenuPath(
                previousField: .diningSpot, menuPathAtFocus: .diningDollars, currentMenuPath: .mealExchange
            )
        )
    }

    // MARK: - Unchanged validation semantics

    func testDiningDollarsValidationSemanticsAreUnchanged() {
        func errors(_ path: RequestMenuPath, _ text: String) -> [RequestFoodFormError] {
            RequestFoodFormValidator.validate(
                draft: RequestFoodFormDraft(
                    selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
                    menuPath: path,
                    mealEntries: ["Wings", "", "", "", ""],
                    orderDetails: "Fries",
                    diningDollarsText: text
                ),
                isScheduledWindowValid: true,
                isScheduledTimingAvailable: true
            ).map(\.error)
        }
        XCTAssertEqual(errors(.diningDollars, ""), [.missingDiningDollars])
        XCTAssertEqual(errors(.diningDollars, "50.01"), [.invalidDiningDollars(ceilingCents: 5_000)])
        XCTAssertEqual(errors(.diningDollars, "50.00"), [])
        XCTAssertEqual(errors(.mealExchange, ""), [], "optional on Meal Exchange")
        XCTAssertEqual(errors(.mealExchange, "25.01"), [.invalidDiningDollars(ceilingCents: 2_500)])
    }
}
