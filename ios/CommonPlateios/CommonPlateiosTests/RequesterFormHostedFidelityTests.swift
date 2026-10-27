//
//  RequesterFormHostedFidelityTests.swift
//  CommonPlateiosTests
//
// W4-R4 (2026-09-26) hosted rendering/geometry proof. Every test mounts the
// real `RequestFoodView` in a real window (see `RequesterFormHostedHarness`)
// and asserts where things were actually laid out or drawn — the class of
// physical-device defect source-string assertions could not catch.
//
// What this does NOT establish: motion smoothness, keyboard behavior,
// physical-device safe areas, or real font rendering on hardware. Those
// remain Faith's physical iPhone checks.
import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

@MainActor
final class RequesterFormHostedFidelityTests: XCTestCase {
    private let spot = DiningSpot(name: "Jasper Kane Cafe", address: nil)
    private let accuracy: CGFloat = 0.75

    private func draft(
        path: RequestMenuPath = .mealExchange,
        swipes: Int = 1,
        timing: RequestTiming = .asap,
        mealName: String = "",
        orderDetails: String = "",
        diningDollars: String = ""
    ) -> RequestFoodFormDraft {
        var entries = RequestFoodFormDraft.emptyMealEntries
        entries[0] = MealItem(name: mealName)
        return RequestFoodFormDraft(
            selectedDiningSpot: spot,
            menuPath: path,
            timing: timing,
            mealSwipes: swipes,
            mealEntries: entries,
            orderDetails: orderDetails,
            diningDollarsText: diningDollars
        )
    }

    private func requireLaterAvailable() throws {
        try XCTSkipUnless(
            RequestFoodView.isScheduledTimingAvailable(
                now: Date(),
                calendar: NYUCampusTime.calendar
            ) && !RequestFoodView.quickScheduledTimes(
                now: Date(),
                calendar: NYUCampusTime.calendar
            ).isEmpty,
            "Later is withheld in the last half hour of the campus day; this proof needs it offered"
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

    private func assertSameFrame(
        _ lhs: CGRect,
        _ rhs: CGRect,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.minX, rhs.minX, accuracy: accuracy, "\(message) (x)", file: file, line: line)
        XCTAssertEqual(lhs.minY, rhs.minY, accuracy: accuracy, "\(message) (y)", file: file, line: line)
        XCTAssertEqual(lhs.width, rhs.width, accuracy: accuracy, "\(message) (width)", file: file, line: line)
        XCTAssertEqual(lhs.height, rhs.height, accuracy: accuracy, "\(message) (height)", file: file, line: line)
    }

    private var anchoredPostBottomInset: CGFloat { RequesterFormLayoutMetrics.contentBottomPadding }

    // MARK: - (1) Mounted brand tint

    func testMountedRequesterBrandTintResolvesToTheNamedAccentAsset() throws {
        let host = try RequesterFormHost(draft: draft())
        let field = try XCTUnwrap(host.uiView(withIdentifier: "request-dining-dollars"))
        let expected = try XCTUnwrap(UIColor(named: "AccentColor"), "AccentColor asset missing")

        func components(_ color: UIColor) -> [CGFloat] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.resolvedColor(with: field.traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
            return [r, g, b]
        }
        let tint = components(field.tintColor)
        let accent = components(expected)
        let systemBlue = components(UIColor.systemBlue)

        func distance(_ lhs: [CGFloat], _ rhs: [CGFloat]) -> CGFloat {
            zip(lhs, rhs).map { abs($0 - $1) }.max() ?? 0
        }
        XCTAssertLessThan(distance(tint, accent), 0.03, "mounted field tint \(tint) is not the AccentColor asset \(accent)")
        XCTAssertGreaterThan(distance(tint, systemBlue), 0.05, "mounted field tint resolved to system blue")
    }

    // MARK: - (2) Collapsed meal geometry

    func testCollapsedMealLabelGapControlAndTopAlignedPlaceholderGeometry() throws {
        let host = try RequesterFormHost(draft: draft())
        let control = try frame(host, "request-meal-control-0")
        let label = try frame(host, "label:Meal 1")
        let placeholder = try frame(host, "label:\(RequestFoodView.mealDetailPlaceholder)")

        XCTAssertEqual(control.height, RequestFoodView.collapsedMealControlHeight, accuracy: 1)
        XCTAssertEqual(RequestFoodView.collapsedMealControlHeight, 76)

        // The 18pt label row plus the 7pt gap sit above the control; `Meal 1`
        // is centered in its row and stays outside the control.
        let expectedRowCenter = control.minY - RequestFoodView.mealLabelToControlSpacing
            - RequestFoodView.mealLabelRowHeight / 2
        XCTAssertEqual(label.midY, expectedRowCenter, accuracy: 1)
        XCTAssertLessThan(label.maxY, control.minY)

        // Top-aligned, not vertically centered: the text starts at the
        // control's top inset. Centered would put it ~29pt down.
        let topInset = placeholder.minY - control.minY
        XCTAssertEqual(topInset, 11, accuracy: 2, "placeholder must start at the canonical 11pt top inset")
        XCTAssertLessThan(placeholder.midY - control.minY, control.height * 0.35)
        XCTAssertEqual(placeholder.minX - control.minX, 13, accuracy: 1, "canonical 13pt leading inset")
    }

    // MARK: - Collapsed FILLED Meal summary (W4-R4 2026-09-27)
    //
    // A SwiftUI `Button`'s label content collapses into ONE accessibility
    // element (confirmed empirically: neither an identifier nor
    // `.accessibilityElement(children: .contain)` on the inner content
    // exposes Meal item/Details as separately queryable elements here, unlike
    // the expanded editor's plain, non-interactive `VStack`). Equal font size
    // is proven instead by comparing each value's own per-extra-wrapped-line
    // growth of the whole rendered control — still rendered-geometry proof,
    // not a source-string assertion.

    private func filledMealHost(mealName: String = "Chicken Wings", details: String? = nil) throws -> RequesterFormHost {
        var d = draft(mealName: mealName)
        d.mealEntries[0].details = details
        return try RequesterFormHost(draft: d)
    }

    /// The lowest y at which non-background ink is drawn inside `rect`,
    /// inset from `rect`'s edges to skip the control's own 1pt border stroke.
    private func inkBottomEdge(_ host: RequesterFormHost, in rect: CGRect) throws -> CGFloat {
        let pixels = try XCTUnwrap(host.pixels())
        let background = pixels.rgb(atX: rect.maxX - 3, y: rect.minY + 2)
        var bottom = rect.minY
        var y = rect.minY + 2
        while y <= rect.maxY - 4 {
            var x = rect.minX + 5
            while x <= rect.maxX - 5 {
                let color = pixels.rgb(atX: x, y: y)
                let delta = abs(color.r - background.r) + abs(color.g - background.g) + abs(color.b - background.b)
                if delta > 60 { bottom = y; break }
                x += 1
            }
            y += 0.5
        }
        return bottom
    }

    func testFilledMealSummaryDetailsGrowsByTheSamePerLineHeightAsMealItemSoTheyShareTheSameTextSize() throws {
        // Meal item has no line limit. Force extra lines with explicit "\n"
        // rather than a long word-repeated string, so the fixture isn't
        // sensitive to the wrap point moving with font metrics or width.
        // Both variants must already clear the collapsed control's 44pt
        // tap-target floor (`RequesterMealEntryControl.collapsedSummary`),
        // or that floor — not the text — would absorb part of the growth;
        // a single "Wings" line alone is short enough to hit that floor, so
        // this compares two lines against three, not one against two.
        let twoLineName = "Wings\nWings"
        let threeLineName = "Wings\nWings\nWings"
        let itemControl1 = try frame(try filledMealHost(mealName: twoLineName, details: nil), "request-meal-control-0")
        let itemControl2 = try frame(try filledMealHost(mealName: threeLineName, details: nil), "request-meal-control-0")
        XCTAssertGreaterThan(itemControl2.height, itemControl1.height + 5, "precondition: the explicit line break must add a visible line")
        let itemLineHeight = itemControl2.height - itemControl1.height

        // Details is capped at `.lineLimit(2)`; force the second line the
        // same explicit way instead of relying on natural wrap.
        let detailsControl1 = try frame(try filledMealHost(details: "Buffalo sauce"), "request-meal-control-0")
        let detailsControl2 = try frame(
            try filledMealHost(details: "Buffalo sauce\nChips, fountain drink"),
            "request-meal-control-0"
        )
        XCTAssertGreaterThan(detailsControl2.height, detailsControl1.height + 5, "precondition: the explicit line break must add a visible line")
        let detailsLineHeight = detailsControl2.height - detailsControl1.height

        XCTAssertEqual(
            detailsLineHeight, itemLineHeight, accuracy: 1.5,
            "Details must grow by the same per-line height as Meal item (equal text size), not a smaller font"
        )
    }

    func testOneLineFilledMealSummaryHasNoLargeDeadBandBeneathTheFinalDetailsLine() throws {
        let host = try filledMealHost(details: "Buffalo sauce")
        let control = try frame(host, "request-meal-control-0")
        let bottomInk = try inkBottomEdge(host, in: control)
        XCTAssertLessThanOrEqual(
            control.maxY - bottomInk, 16,
            "no large unused blank band beneath the final visible Details line"
        )
    }

    func testFilledMealSummaryIsNotForcedToTheEmptyControlsSeventySixPointTargetButStaysTappable() throws {
        let host = try filledMealHost(details: nil)
        let control = try frame(host, "request-meal-control-0")
        XCTAssertLessThan(
            control.height, RequestFoodView.collapsedMealControlHeight - 5,
            "a filled summary must not be forced to the EMPTY control's 76pt target"
        )
        XCTAssertGreaterThanOrEqual(control.height, 43.5, "the card remains comfortably tappable")
    }

    func testWrappedTwoLineDetailsGrowsTheFilledSummaryByOnlyOneExtraLineNotANewFixedHeight() throws {
        // Explicit "\n" forces exactly one extra line deterministically,
        // instead of depending on where a long string happens to wrap.
        let oneLineControl = try frame(try filledMealHost(details: "Buffalo sauce"), "request-meal-control-0")
        let wrappedControl = try frame(
            try filledMealHost(details: "Buffalo sauce\nChips, fountain drink"),
            "request-meal-control-0"
        )

        let growth = wrappedControl.height - oneLineControl.height
        XCTAssertGreaterThan(growth, 8, "Details must actually wrap onto an extra line")
        XCTAssertLessThan(growth, 30, "growth must be one extra line, not a jump to a new fixed height")
        for forbidden: CGFloat in [85, 110, 117] {
            XCTAssertGreaterThan(
                abs(wrappedControl.height - forbidden), 2,
                "must not land on a previously-considered fixed filled-summary height (\(forbidden)pt)"
            )
        }
    }

    // MARK: - (3)(4) Path switch at scroll offset 0

    func testPathSwitchAtScrollOffsetZeroDoesNotMoveAnythingAboveTheBranch() throws {
        let host = try RequesterFormHost(draft: draft(mealName: "Wings"))
        XCTAssertEqual(host.scrollOffsetY, 0, accuracy: 0.5)
        let keys = [
            "request-dining-spot-picker",
            "label:Which menu are you using?", "request-menu-path-picker",
        ]
        let before = try keys.map { try frame(host, $0) }

        XCTAssertTrue(host.activate("request-menu-path-dining-dollars"))
        XCTAssertTrue(host.exists("request-order-details"), "the Dining Dollars branch should now be showing")
        let afterDiningDollars = try keys.map { try frame(host, $0) }
        for (key, pair) in zip(keys, zip(before, afterDiningDollars)) {
            assertSameFrame(pair.0, pair.1, "\(key) moved on Meal Exchange → Dining Dollars")
        }

        XCTAssertTrue(host.activate("request-menu-path-meal-exchange"))
        XCTAssertTrue(host.exists("label:Number of meal swipes"))
        let afterMealExchange = try keys.map { try frame(host, $0) }
        for (key, pair) in zip(keys, zip(before, afterMealExchange)) {
            assertSameFrame(pair.0, pair.1, "\(key) moved on Dining Dollars → Meal Exchange")
        }
    }

    // MARK: - (5) Path switch at a non-zero scroll offset

    func testPathSwitchAtMeaningfulScrollOffsetDoesNotMoveAnythingAboveTheBranch() throws {
        // A short viewport makes both branches scrollable, so the offset is
        // not simply clamped away by the shorter branch.
        let host = try RequesterFormHost(draft: draft(mealName: "Wings"), viewportHeight: 420)
        let offset: CGFloat = 90
        host.scroll(toOffsetY: offset)
        XCTAssertEqual(host.scrollOffsetY, offset, accuracy: 1, "precondition: Meal Exchange scrolled")

        let keys = ["request-dining-spot-picker", "request-menu-path-picker"]
        let before = try keys.map { try frame(host, $0) }

        XCTAssertTrue(host.activate("request-menu-path-dining-dollars"))
        XCTAssertTrue(host.exists("request-order-details"))
        XCTAssertGreaterThanOrEqual(
            host.maxScrollOffsetY, offset,
            "precondition: the Dining Dollars branch must still reach this offset"
        )
        XCTAssertEqual(host.scrollOffsetY, offset, accuracy: 1, "the scroll position must be untouched by the switch")
        for (key, pair) in zip(keys, zip(before, try keys.map { try frame(host, $0) })) {
            assertSameFrame(pair.0, pair.1, "\(key) moved on a scrolled path switch")
        }

        XCTAssertTrue(host.activate("request-menu-path-meal-exchange"))
        XCTAssertEqual(host.scrollOffsetY, offset, accuracy: 1)
        for (key, pair) in zip(keys, zip(before, try keys.map { try frame(host, $0) })) {
            assertSameFrame(pair.0, pair.1, "\(key) moved on the return switch")
        }
    }

    // MARK: - (6) Timing info glyph alignment

    func testTimingInfoGlyphRightEdgeAlignsWithOptionalAndKeepsItsFullTapTarget() throws {
        let host = try RequesterFormHost(draft: draft())
        let info = try frame(host, "request-timing-info")
        let optional = try frame(host, "label:Optional")

        XCTAssertGreaterThanOrEqual(info.width, 44)
        XCTAssertGreaterThanOrEqual(info.height, 44)
        XCTAssertEqual(info.maxX, optional.maxX, accuracy: 1, "the tap target ends at the content edge")

        let glyphInk = try XCTUnwrap(host.inkRightEdge(in: info), "no drawn glyph in the info target")
        let optionalInk = try XCTUnwrap(host.inkRightEdge(in: optional), "no drawn `Optional` text")
        XCTAssertEqual(
            glyphInk, optionalInk, accuracy: 2.5,
            "the visible glyph's right edge (\(glyphInk)) must align with `Optional`'s (\(optionalInk))"
        )
    }

    // MARK: - (7) Post request on a short ASAP form

    func testShortAsapFormPostRequestSitsAtTheBottomSafeAreaPositionWithoutRebalancingTheForm() throws {
        let host = try RequesterFormHost(draft: draft(path: .diningDollars))
        let post = try frame(host, "request-post-request")
        XCTAssertEqual(post.maxY, host.safeFrame.maxY - anchoredPostBottomInset, accuracy: 1)
        XCTAssertEqual(post.minX, 20, accuracy: 0.5)
        XCTAssertEqual(post.width, host.safeFrame.width - 40, accuracy: 0.5)
        XCTAssertEqual(host.maxScrollOffsetY, 0, accuracy: 0.5, "a short form has nothing to scroll")

        // Not stretched or rebalanced: the same sections sit at the same
        // places whether the action is anchored or follows the content.
        let keys = ["request-dining-spot-picker", "request-menu-path-picker", "request-dining-dollars", "label:Timing"]
        let anchoredFrames = try keys.map { try frame(host, $0) }

        let constrained = try RequesterFormHost(draft: draft(path: .diningDollars), viewportHeight: 480)
        let flowedPost = try frame(constrained, "request-post-request")
        XCTAssertGreaterThan(constrained.maxScrollOffsetY, 0, "precondition: this viewport forces the tall placement")
        for (key, pair) in zip(keys, zip(anchoredFrames, try keys.map { try frame(constrained, $0) })) {
            assertSameFrame(pair.0, pair.1, "\(key) shifted when only the action's placement changed")
        }
        let timing = try frame(constrained, "label:Timing")
        XCTAssertGreaterThan(flowedPost.minY, timing.maxY, "tall placement follows Timing in ordinary flow")
    }

    // MARK: - (8) Later expanded, plus local insertion

    func testLaterInsertsLocallyKeepsContentAboveStationaryAndDoesNotReserveFootprintInAsap() throws {
        try requireLaterAvailable()
        let host = try RequesterFormHost(draft: draft(path: .diningDollars), screenshotAvailability: .shipping)
        let above = ["request-dining-spot-picker", "request-menu-path-picker", "request-dining-dollars", "label:Timing", "request-timing-info"]
        let asapFrames = try above.map { try frame(host, $0) }
        XCTAssertFalse(host.exists("label:Choose time"), "ASAP must not mount (or reserve) the Later controls")
        let asapPost = try frame(host, "request-post-request")

        XCTAssertTrue(host.activate("label:Later"))
        XCTAssertTrue(host.exists("label:Choose time"), "Later controls should now be inserted")
        for (key, pair) in zip(above, zip(asapFrames, try above.map { try frame(host, $0) })) {
            assertSameFrame(pair.0, pair.1, "\(key) moved when Later was revealed")
        }
        let chooseTime = try frame(host, "label:Choose time")
        let laterPost = try frame(host, "request-post-request")
        XCTAssertGreaterThan(chooseTime.minY, try frame(host, "label:ASAP").maxY - 1)
        XCTAssertLessThan(chooseTime.maxY, laterPost.minY, "the action never overlaps the Later controls")
        // Still a short form: the action stays at the bottom position.
        XCTAssertEqual(laterPost.maxY, asapPost.maxY, accuracy: 1)

        XCTAssertTrue(host.activate("label:ASAP"))
        XCTAssertFalse(host.exists("label:Choose time"))
        for (key, pair) in zip(above, zip(asapFrames, try above.map { try frame(host, $0) })) {
            assertSameFrame(pair.0, pair.1, "\(key) moved when returning to ASAP")
        }
    }

    func testLaterMovesFollowingPostRequestDownWhenTheFormBecomesTallAndReturnsWithAsap() throws {
        try requireLaterAvailable()
        // Sized so ASAP fits (action anchored) and Later does not. Measured
        // flowed heights with the 76pt ordering field, the requester
        // `View menu on Grubhub` link and no V1 Screenshot Assistance row
        // (W4-N1): ASAP ~595pt, Later ~635pt; the preconditions below fail
        // loudly if that drifts.
        let host = try RequesterFormHost(
            draft: draft(path: .diningDollars), viewportHeight: 616, screenshotAvailability: .shipping
        )
        let anchoredPost = try frame(host, "request-post-request")
        XCTAssertEqual(host.maxScrollOffsetY, 0, accuracy: 0.5, "precondition: ASAP fits this viewport")
        let timing = try frame(host, "label:Timing")

        XCTAssertTrue(host.activate("label:Later"))
        XCTAssertGreaterThan(host.maxScrollOffsetY, 0, "precondition: Later makes the form tall")
        host.scrollToBottom()
        let chooseTime = try frame(host, "label:Choose time")
        let flowedPost = try frame(host, "request-post-request")
        XCTAssertGreaterThan(flowedPost.minY, chooseTime.maxY, "the action now follows the Later controls")
        XCTAssertLessThanOrEqual(flowedPost.maxY, host.safeFrame.maxY + 0.5, "reachable by scrolling")

        host.scroll(toOffsetY: 0)
        XCTAssertTrue(host.activate("label:ASAP"))
        XCTAssertEqual(host.maxScrollOffsetY, 0, accuracy: 0.5, "returning to ASAP gives the height back")
        assertSameFrame(try frame(host, "request-post-request"), anchoredPost, "action returns to its anchored place")
        XCTAssertEqual(try frame(host, "label:Timing").minY, timing.minY, accuracy: accuracy)
    }

    // MARK: - (9) Tall form: scroll-following action

    func testPostRequestFollowsContentWhenTheFormExceedsTheViewportAndNeverOverlaysFields() throws {
        let host = try RequesterFormHost(draft: draft(swipes: 4))
        XCTAssertGreaterThan(host.maxScrollOffsetY, 0, "precondition: four meals exceed the viewport")

        let post = try frame(host, "request-post-request")
        XCTAssertGreaterThan(post.minY, host.safeFrame.maxY, "at rest the action follows content, below the fold")

        host.scrollToBottom()
        let scrolledPost = try frame(host, "request-post-request")
        XCTAssertLessThanOrEqual(scrolledPost.maxY, host.safeFrame.maxY + 0.5, "reachable by scrolling")
        XCTAssertGreaterThanOrEqual(scrolledPost.minY, host.safeFrame.minY)
        for key in ["request-dining-dollars", "label:Timing", "request-timing-info", "label:ASAP"] {
            XCTAssertFalse(
                try frame(host, key).intersects(scrolledPost),
                "Post request overlays \(key)"
            )
        }
        XCTAssertGreaterThan(
            scrolledPost.minY, try frame(host, "request-dining-dollars").maxY,
            "the action follows the last field"
        )
    }

    func testPostRequestTransitionsBetweenBottomAnchorAndScrollFollowingAsTheFormGrowsAndShrinks() throws {
        // A filled collapsed card fits even when the late-campus scheduling notice is present.
        let host = try RequesterFormHost(
            draft: draft(swipes: 1, mealName: "Wings"), screenshotAvailability: .shipping
        )
        XCTAssertEqual(host.maxScrollOffsetY, 0, accuracy: 0.5, "precondition: the short form fits")
        let anchored = try frame(host, "request-post-request")
        XCTAssertEqual(anchored.maxY, host.safeFrame.maxY - anchoredPostBottomInset, accuracy: 1)

        host.draftSession.draft.mealSwipes = 4
        host.settle()
        XCTAssertGreaterThan(host.maxScrollOffsetY, 0)
        XCTAssertGreaterThan(try frame(host, "request-post-request").minY, host.safeFrame.maxY)

        host.draftSession.draft.mealSwipes = 1
        host.settle()
        assertSameFrame(try frame(host, "request-post-request"), anchored, "back to the bottom position")
    }

    // MARK: - (10) Larger Dynamic Type

    func testExtraExtraLargeTextKeepsPostRequestReachableAndTheInfoTargetFull() throws {
        // The compact ordering field (and, in V1, no Screenshot Assistance
        // row) makes the Dining Dollars form fit through accessibility1;
        // these are the sizes at which it genuinely overflows.
        for size in [DynamicTypeSize.accessibility2, .accessibility3] {
            let host = try RequesterFormHost(draft: draft(path: .diningDollars), dynamicTypeSize: size)
            XCTAssertGreaterThan(host.maxScrollOffsetY, 0, "\(size): larger text should be scrollable")

            host.scrollToBottom()
            let post = try frame(host, "request-post-request")
            XCTAssertLessThanOrEqual(post.maxY, host.safeFrame.maxY + 0.5, "\(size): action unreachable")
            XCTAssertGreaterThanOrEqual(post.minY, host.safeFrame.minY, "\(size): action off the top")
            for key in ["request-dining-dollars", "label:Timing", "request-timing-info"] {
                XCTAssertFalse(try frame(host, key).intersects(post), "\(size): Post request overlays \(key)")
            }
            let info = try frame(host, "request-timing-info")
            XCTAssertGreaterThanOrEqual(info.width, 44)
            XCTAssertGreaterThanOrEqual(info.height, 44)
        }
    }

    // MARK: - Meal expanded geometry

    func testExpandedMealKeepsItsLabelOutsideAndUsesTheSpaciousDoneControl() throws {
        let host = try RequesterFormHost(draft: draft())
        XCTAssertTrue(host.activate("request-meal-collapsed-0"))
        let control = try frame(host, "request-meal-control-0")
        let label = try frame(host, "label:Meal 1")
        let done = try frame(host, "request-meal-done-0")

        XCTAssertEqual(RequestFoodView.expandedMealControlHeight, 158)
        XCTAssertEqual(control.height, 158, accuracy: 1)
        XCTAssertLessThan(label.maxY, control.minY, "Meal N stays outside the control")
        XCTAssertTrue(control.insetBy(dx: -1, dy: -1).contains(done), "Done sits inside the control")
        XCTAssertGreaterThan(done.midY, control.midY, "Done is the footer")
        XCTAssertGreaterThanOrEqual(done.height, 44, "Done has a native tap target")
    }

    private func expandedMealHost(name: String = "Chicken Wings", details: String? = nil) throws -> RequesterFormHost {
        var d = draft(mealName: name)
        d.mealEntries[0].details = details
        let host = try RequesterFormHost(draft: d)
        XCTAssertTrue(host.activate("request-meal-collapsed-0"))
        return host
    }

    private func renderedFont(_ host: RequesterFormHost, _ key: String) throws -> UIFont {
        let view = try XCTUnwrap(host.uiView(withIdentifier: key), "no UIKit text view for \(key)")
        return try XCTUnwrap((view as? UITextView)?.font ?? (view as? UITextField)?.font, "no font on \(key)")
    }

    // MARK: - Expanded editor: equal value typography and compact rhythm

    func testEnteredMealItemAndDetailsValuesRenderWithTheSameFontAndLineHeightWhileLabelsStaySmaller() throws {
        let host = try expandedMealHost(details: "Buffalo sauce")
        let itemFont = try renderedFont(host, "request-meal-item-0")
        let detailsFont = try renderedFont(host, "request-meal-details-0")
        XCTAssertEqual(detailsFont.pointSize, itemFont.pointSize, "Details value must use the Meal item value size")
        XCTAssertEqual(detailsFont.fontName, itemFont.fontName, "Details value must use the Meal item value face/weight")
        XCTAssertEqual(
            detailsFont.fontDescriptor.symbolicTraits, itemFont.fontDescriptor.symbolicTraits
        )

        let item = try frame(host, "request-meal-item-0")
        let details = try frame(host, "request-meal-details-0")
        XCTAssertEqual(details.height, item.height, accuracy: 0.5, "one line of each value has the same line height")

        for label in ["label:Meal item", "label:Details", "label:Optional"] {
            let labelFrame = try frame(host, label)
            XCTAssertLessThan(labelFrame.height, item.height, "\(label) must stay smaller than the entered values")
        }
    }

    func testEmptyPlaceholdersAlsoUseTheSameValueFont() throws {
        let host = try expandedMealHost(name: "")
        let itemFont = try renderedFont(host, "request-meal-item-0")
        let detailsFont = try renderedFont(host, "request-meal-details-0")
        XCTAssertEqual(detailsFont.pointSize, itemFont.pointSize)
        XCTAssertEqual(detailsFont.fontName, itemFont.fontName)
    }

    func testDefaultExpandedEditorFillsItsTargetWithClearSeparationAroundDone() throws {
        for details in [nil, "Buffalo sauce"] as [String?] {
            let host = try expandedMealHost(details: details)
            let control = try frame(host, "request-meal-control-0")
            let detailsField = try frame(host, "request-meal-details-0")
            let done = try frame(host, "request-meal-done-0")

            XCTAssertEqual(control.height, RequestFoodView.expandedMealControlHeight, accuracy: 1)
            XCTAssertEqual(RequestFoodView.expandedMealControlHeight, 158)

            let detailsToDone = done.minY - detailsField.maxY
            let doneToBottom = control.maxY - done.maxY
            XCTAssertGreaterThanOrEqual(detailsToDone, 3, "Done retains separation from Details")
            XCTAssertLessThanOrEqual(detailsToDone, 8, "Done stays visually connected to Details")
            XCTAssertLessThanOrEqual(doneToBottom, 6, "the border stays close behind Done")
            XCTAssertGreaterThanOrEqual(doneToBottom, 3)
            XCTAssertLessThanOrEqual(control.maxX - done.maxX, 14, "Done stays right-aligned")
            XCTAssertGreaterThanOrEqual(done.height, 44, "Done retains the full tap target")
        }
    }

    func testMultilineDetailsWrapsAndGrowsTheEditorLocallyWithoutMovingContentAboveIt() throws {
        let collapsedReference = try expandedMealHost(details: "Buffalo sauce")
        let baseControl = try frame(collapsedReference, "request-meal-control-0")
        let baseLabel = try frame(collapsedReference, "label:Meal 1")
        let baseItem = try frame(collapsedReference, "request-meal-item-0")
        let baseDetails = try frame(collapsedReference, "request-meal-details-0")

        let long = "Buffalo sauce, chips, fountain drink, extra napkins, no onions, add ranch on the side please"
        let host = try expandedMealHost(details: long)
        let control = try frame(host, "request-meal-control-0")
        let details = try frame(host, "request-meal-details-0")
        let done = try frame(host, "request-meal-done-0")

        XCTAssertGreaterThan(details.height, baseDetails.height + 10, "Details must wrap onto more lines")
        XCTAssertEqual(control.height - baseControl.height, details.height - baseDetails.height, accuracy: 1, "the editor grows by exactly the extra Details height")
        XCTAssertEqual(control.minY, baseControl.minY, accuracy: 0.5)
        XCTAssertEqual(try frame(host, "label:Meal 1").minY, baseLabel.minY, accuracy: 0.5)
        XCTAssertEqual(try frame(host, "request-meal-item-0").minY, baseItem.minY, accuracy: 0.5)
        XCTAssertEqual(control.maxY - done.maxY, baseControl.maxY - (try frame(collapsedReference, "request-meal-done-0")).maxY, accuracy: 1, "Done keeps the same bottom offset when Details grows")
    }

    // MARK: - Details placeholder

    func testExpandedDetailsFieldShowsTheExactAcceptedPlaceholder() throws {
        XCTAssertEqual(RequestFoodView.mealDetailsPlaceholder, "e.g. Buffalo sauce, chips, fountain drink")
        let host = try RequesterFormHost(draft: draft())
        XCTAssertTrue(host.activate("request-meal-collapsed-0"))
        let details = try XCTUnwrap(host.nodes()["request-meal-details-0"], "no Details field")
        XCTAssertEqual(
            details.accessibilityValue,
            "e.g. Buffalo sauce, chips, fountain drink",
            "the rendered Details field does not show the accepted placeholder"
        )
        let item = try XCTUnwrap(host.nodes()["request-meal-item-0"])
        XCTAssertEqual(item.accessibilityValue, "e.g. Chicken Wings")
    }
}
