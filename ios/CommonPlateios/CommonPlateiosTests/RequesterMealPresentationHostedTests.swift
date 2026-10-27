//
//  RequesterMealPresentationHostedTests.swift
//  CommonPlateiosTests
//
// W4-R4 (2026-09-27) Meal expand/collapse latency mechanism. Both the
// collapsed summary and the expanded editor stay mounted for a Meal card's
// lifetime; only the active presentation takes layout height, hits, or
// accessibility. These tests mount the real `RequestFoodView` (see
// `RequesterFormHostedHarness`) and prove that mechanism: the multiline
// editor is never constructed or destroyed by a toggle, the hidden one is
// invisible to layout / hit testing / accessibility / focus, and the visible
// form height (and therefore `Post request` placement) follows only the
// visible presentation.
//
// Not established here: physical-device latency itself, motion smoothness, or
// real keyboard behavior. Faith's physical iPhone is the latency acceptance
// proof.
import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

@MainActor
final class RequesterMealPresentationHostedTests: XCTestCase {
    private let spot = DiningSpot(name: "Jasper Kane Cafe", address: nil)

    private func draft(mealName: String = "", details: String? = nil, swipes: Int = 1) -> RequestFoodFormDraft {
        var entries = RequestFoodFormDraft.emptyMealEntries
        entries[0] = MealItem(name: mealName, details: details)
        return RequestFoodFormDraft(
            selectedDiningSpot: spot,
            menuPath: .mealExchange,
            timing: .asap,
            mealSwipes: swipes,
            mealEntries: entries,
            orderDetails: "",
            diningDollarsText: ""
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

    private func textInputs(_ host: RequesterFormHost) -> [UIView] {
        var found: [UIView] = []
        func walk(_ view: UIView) {
            if view is UITextField || view is UITextView { found.append(view) }
            view.subviews.forEach(walk)
        }
        walk(host.controller.view)
        return found
    }

    private func firstResponder(_ host: RequesterFormHost) -> UIView? {
        var hit: UIView?
        func walk(_ view: UIView) {
            if view.isFirstResponder, hit == nil { hit = view }
            view.subviews.forEach(walk)
        }
        walk(host.controller.view)
        return hit
    }

    private struct ExposedElement {
        let identifier: String
        let label: String
    }

    /// What assistive technology can actually reach: only nodes that are
    /// accessibility elements, found by following the accessibility-container
    /// API from the hosting view. The harness's own `nodes()` also walks the
    /// UIView tree, which still finds a hidden text view by a stale identifier
    /// even though SwiftUI has removed it from accessibility.
    private func exposed(_ host: RequesterFormHost) -> [ExposedElement] {
        var result: [ExposedElement] = []
        var seen = Set<String>()
        func walk(_ node: NSObject, _ depth: Int) {
            guard depth < 60 else { return }
            if node.isAccessibilityElement, !node.accessibilityFrame.isEmpty {
                let identifier = node.responds(to: NSSelectorFromString("accessibilityIdentifier"))
                    ? (node.value(forKey: "accessibilityIdentifier") as? String ?? "") : ""
                let label = node.accessibilityLabel ?? ""
                let frame = node.accessibilityFrame
                let signature = "\(identifier)|\(label)|\(Int(frame.minX))|\(Int(frame.minY))|\(Int(frame.width))"
                if seen.insert(signature).inserted { result.append(ExposedElement(identifier: identifier, label: label)) }
            }
            if let elements = node.accessibilityElements {
                for case let element as NSObject in elements { walk(element, depth + 1) }
            } else {
                let count = node.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for index in 0..<count {
                        if let element = node.accessibilityElement(at: index) as? NSObject { walk(element, depth + 1) }
                    }
                } else if let view = node as? UIView {
                    view.subviews.forEach { walk($0, depth + 1) }
                }
            }
        }
        walk(host.controller.view, 0)
        return result
    }

    private func count(_ label: String, in host: RequesterFormHost) -> Int {
        exposed(host).filter { $0.label == label }.count
    }

    private func isExposed(_ identifier: String, in host: RequesterFormHost) -> Bool {
        exposed(host).contains { $0.identifier == identifier }
    }

    /// `Optional` is excluded: the Dining Dollars field legitimately carries
    /// its own `Optional` label, so it is compared by count delta instead.
    private let editorLabels = ["Meal item", "Details", "Done"]
    private let editorIdentifiers = [
        "request-meal-item-0", "request-meal-details-0", "request-meal-done-0",
    ]

    // MARK: - Mechanism: the editor is mounted once and never rebuilt

    func testToggleNeverConstructsOrDestroysTheMultilineEditor() throws {
        let host = try RequesterFormHost(draft: draft(mealName: "Chicken Wings"))
        let collapsedInputs = Set(textInputs(host).map(ObjectIdentifier.init))
        // Dining Dollars (visible) + Meal item + Details, mounted while collapsed.
        XCTAssertGreaterThanOrEqual(
            collapsedInputs.count, 3,
            "the collapsed card must already hold its editor's text inputs"
        )

        XCTAssertTrue(host.activate("request-meal-collapsed-0"))
        XCTAssertEqual(Set(textInputs(host).map(ObjectIdentifier.init)), collapsedInputs, "expanding built new text inputs")

        XCTAssertTrue(host.activate("request-meal-done-0"))
        XCTAssertEqual(Set(textInputs(host).map(ObjectIdentifier.init)), collapsedInputs, "collapsing destroyed text inputs")

        XCTAssertTrue(host.activate("request-meal-collapsed-0"))
        XCTAssertEqual(Set(textInputs(host).map(ObjectIdentifier.init)), collapsedInputs, "re-expanding rebuilt text inputs")
    }

    // MARK: - Accessibility: exactly one presentation at a time

    func testCollapsedCardHidesEveryEditorElementAndExposesOnlyTheSummary() throws {
        for populated in [false, true] {
            let host = try RequesterFormHost(
                draft: draft(mealName: populated ? "Chicken Wings" : "", details: populated ? "Buffalo sauce" : nil)
            )
            let context = populated ? "populated" : "empty"
            for label in editorLabels {
                XCTAssertEqual(count(label, in: host), 0, "\(context) collapsed exposes hidden editor label `\(label)`")
            }
            for identifier in editorIdentifiers {
                XCTAssertFalse(isExposed(identifier, in: host), "\(context) collapsed exposes hidden \(identifier)")
            }
            XCTAssertEqual(
                exposed(host).filter { $0.identifier == "request-meal-collapsed-0" }.count, 1,
                "\(context): the summary is the one exposed presentation"
            )
            XCTAssertEqual(count("Meal 1", in: host), 1, "\(context): label row appears once")
            // The Button folds its label content into one element; the
            // hidden editor's values must not appear anywhere else.
            let summary = exposed(host).first { $0.identifier == "request-meal-collapsed-0" }?.label ?? ""
            if populated {
                XCTAssertEqual(summary, "Chicken Wings, Buffalo sauce")
                XCTAssertEqual(exposed(host).filter { $0.label.contains("Chicken Wings") }.count, 1)
                XCTAssertEqual(exposed(host).filter { $0.label.contains("Buffalo sauce") }.count, 1)
            } else {
                XCTAssertEqual(summary, RequestFoodView.mealDetailPlaceholder)
            }
        }
    }

    func testExpandedCardExposesTheEditorOnceAndHidesTheSummary() throws {
        let host = try RequesterFormHost(draft: draft(mealName: "Chicken Wings", details: "Buffalo sauce"))
        let optionalWhileCollapsed = count("Optional", in: host)

        XCTAssertTrue(host.activate("request-meal-collapsed-0"))
        for label in editorLabels {
            XCTAssertEqual(count(label, in: host), 1, "expanded exposes `\(label)` \(count(label, in: host)) times")
        }
        XCTAssertEqual(count("Optional", in: host), optionalWhileCollapsed + 1, "the editor adds exactly one `Optional`")
        for identifier in editorIdentifiers {
            XCTAssertEqual(
                exposed(host).filter { $0.identifier == identifier }.count, 1,
                "expanded must expose \(identifier) exactly once"
            )
        }
        XCTAssertFalse(isExposed("request-meal-collapsed-0", in: host), "the hidden summary must stay hidden")
        XCTAssertEqual(count("Meal 1", in: host), 1)
        XCTAssertEqual(
            exposed(host).filter { $0.label.contains("Buffalo sauce") }.count, 0,
            "hidden summary Details must not duplicate the editor"
        )

        XCTAssertTrue(host.activate("request-meal-done-0"))
        for label in editorLabels {
            XCTAssertEqual(count(label, in: host), 0, "collapse left editor label `\(label)` exposed")
        }
        XCTAssertEqual(count("Optional", in: host), optionalWhileCollapsed, "collapse left the editor's `Optional` exposed")
        for identifier in editorIdentifiers {
            XCTAssertFalse(isExposed(identifier, in: host), "collapse left \(identifier) exposed")
        }
        XCTAssertTrue(isExposed("request-meal-collapsed-0", in: host))
    }

    func testExpandedMealDoneHasAFullTapTargetAndBreathingRoom() throws {
        let host = try RequesterFormHost(draft: draft(mealName: "Chicken Wings", details: "Buffalo sauce"))
        XCTAssertTrue(host.activate("request-meal-collapsed-0"))

        let control = try frame(host, "request-meal-control-0")
        let details = try frame(host, "request-meal-details-0")
        let done = try frame(host, "request-meal-done-0")

        XCTAssertEqual(control.height, RequestFoodView.expandedMealControlHeight, accuracy: 1)
        XCTAssertGreaterThanOrEqual(done.width, 44)
        XCTAssertGreaterThanOrEqual(done.height, 44)
        XCTAssertGreaterThanOrEqual(done.minY - details.maxY, 3)
        XCTAssertLessThanOrEqual(done.minY - details.maxY, 8)
        XCTAssertGreaterThanOrEqual(control.maxY - done.maxY, 3)
        XCTAssertLessThanOrEqual(control.maxY - done.maxY, 6)
    }

    // MARK: - Layout: hidden presentation has no visible height

    func testTogglingReturnsEveryFrameExactlyAndHiddenEditorAddsNoHeight() throws {
        for populated in [false, true] {
            let host = try RequesterFormHost(
                draft: draft(mealName: populated ? "Chicken Wings" : "", details: populated ? "Buffalo sauce" : nil)
            )
            let keys = ["request-meal-control-0", "label:Meal 1", "request-dining-dollars", "label:Timing", "request-post-request"]
            let before = try keys.map { try frame(host, $0) }

            XCTAssertTrue(host.activate("request-meal-collapsed-0"))
            XCTAssertEqual(
                try frame(host, "request-meal-control-0").height, RequestFoodView.expandedMealControlHeight, accuracy: 1
            )
            XCTAssertTrue(host.activate("request-meal-done-0"))

            for (key, pair) in zip(keys, zip(before, try keys.map { try frame(host, $0) })) {
                XCTAssertEqual(pair.0.minY, pair.1.minY, accuracy: 0.75, "\(key) y drifted after expand/collapse")
                XCTAssertEqual(pair.0.height, pair.1.height, accuracy: 0.75, "\(key) height drifted after expand/collapse")
            }
        }
    }

    func testStackedMealsExposeTheirOwnSummariesAndOnlyTheExpandedOneOpens() throws {
        var d = draft(swipes: 2)
        d.mealEntries[1] = MealItem(name: "Caesar Salad")
        let host = try RequesterFormHost(draft: d)
        XCTAssertEqual(count("Meal item", in: host), 0)

        XCTAssertTrue(host.activate("request-meal-collapsed-1"))
        XCTAssertEqual(count("Meal item", in: host), 1)
        XCTAssertTrue(isExposed("request-meal-item-1", in: host))
        XCTAssertFalse(isExposed("request-meal-item-0", in: host))
        XCTAssertTrue(isExposed("request-meal-collapsed-0", in: host), "the other card stays a summary")

        // Opening the other card collapses this one (single expanded index).
        host.scroll(toOffsetY: 0)
        XCTAssertTrue(host.activate("request-meal-collapsed-0"))
        XCTAssertTrue(isExposed("request-meal-item-0", in: host))
        XCTAssertFalse(isExposed("request-meal-item-1", in: host))
        XCTAssertEqual(count("Meal item", in: host), 1)
    }

    // MARK: - Post request placement follows only the visible presentation

    /// The viewport is sized so a COLLAPSED one-meal form fits with less
    /// slack than the expanded editor adds. A hidden editor that leaked into
    /// the measured form height would flip the collapsed form to flowing.
    func testHiddenEditorDoesNotContaminatePostRequestPlacement() throws {
        let viewport = Self.tightViewportHeight
        let host = try RequesterFormHost(draft: draft(), viewportHeight: viewport, screenshotAvailability: .shipping)
        XCTAssertEqual(host.maxScrollOffsetY, 0, accuracy: 0.5, "precondition: the collapsed form fits \(viewport)pt")
        let anchored = try frame(host, "request-post-request")

        XCTAssertTrue(host.activate("request-meal-collapsed-0"))
        XCTAssertGreaterThan(host.maxScrollOffsetY, 0, "precondition: the expanded editor makes this form tall")
        host.scroll(toOffsetY: 0)

        XCTAssertTrue(host.activate("request-meal-done-0"))
        XCTAssertEqual(host.maxScrollOffsetY, 0, accuracy: 0.5, "collapsing gives the height back")
        let restored = try frame(host, "request-post-request")
        XCTAssertEqual(restored.minY, anchored.minY, accuracy: 0.75)
        XCTAssertEqual(restored.maxY, anchored.maxY, accuracy: 0.75)
    }

    func testShortCollapsedFormStaysAnchoredAndTallFormStaysFlowing() throws {
        // A filled collapsed card fits even when the late-campus scheduling notice is present.
        let short = try RequesterFormHost(draft: draft(mealName: "Wings"), screenshotAvailability: .shipping)
        let post = try frame(short, "request-post-request")
        XCTAssertEqual(short.maxScrollOffsetY, 0, accuracy: 0.5)
        XCTAssertEqual(post.maxY, short.safeFrame.maxY - RequesterFormLayoutMetrics.contentBottomPadding, accuracy: 1)

        let tall = try RequesterFormHost(draft: draft(swipes: 4))
        XCTAssertGreaterThan(tall.maxScrollOffsetY, 0, "precondition: four collapsed meals still overflow")
        XCTAssertGreaterThan(try frame(tall, "request-post-request").minY, tall.safeFrame.maxY, "flowing below the fold")
    }

    /// Calibrated on the iPhone 17 Pro simulator: without the V1-hidden
    /// Screenshot Assistance row (~82pt, W4-N1) and with the tightened
    /// `View menu on Grubhub` link, the collapsed one-meal ASAP form fits from
    /// ~658pt in the daytime and ~698pt in the last half hour of the campus
    /// day, when the "Scheduling is closed for today" footnote appears. The
    /// expanded editor adds ~55pt, so 704 keeps both clock states inside the
    /// collapsed fit and outside the expanded one. The preconditions in the
    /// test above fail loudly if that drifts.
    static let tightViewportHeight: CGFloat = 704


    // MARK: - Focus

    func testMountedHiddenEditorNeverSummonsTheKeyboard() throws {
        let host = try RequesterFormHost(draft: draft(mealName: "Chicken Wings"))
        XCTAssertNil(firstResponder(host), "the hidden editor took focus on mount")

        XCTAssertTrue(host.activate("request-meal-collapsed-0"))
        XCTAssertNil(firstResponder(host), "revealing the editor must not summon the keyboard")

        XCTAssertTrue(host.activate("request-meal-done-0"))
        XCTAssertNil(firstResponder(host))
    }

    func testTapsOnTheCollapsedSummaryNeverReachTheHiddenEditorsTextInputs() throws {
        let host = try RequesterFormHost(draft: draft(mealName: "Chicken Wings", details: "Buffalo sauce"))
        let control = try frame(host, "request-meal-control-0")
        // Probe the hidden editor's region (below the summary's own height)
        // as well as the summary itself.
        for point in [
            CGPoint(x: control.midX, y: control.midY),
            CGPoint(x: control.midX, y: control.minY + 12),
            CGPoint(x: control.midX, y: control.maxY + 10),
        ] {
            let hit = host.window.hitTest(point, with: nil)
            var view: UIView? = hit
            while let current = view {
                XCTAssertFalse(
                    current is UITextField || current is UITextView,
                    "a tap at \(point) reached a hidden text input \(type(of: current))"
                )
                view = current.superview
            }
        }
    }

    func testRevealedEditorFieldsTakeFocusThroughNormalInteraction() throws {
        let host = try RequesterFormHost(draft: draft(mealName: "Chicken Wings"))
        XCTAssertTrue(host.activate("request-meal-collapsed-0"))

        let item = try XCTUnwrap(host.uiView(withIdentifier: "request-meal-item-0"))
        XCTAssertTrue(item.becomeFirstResponder(), "revealed Meal item cannot take focus")
        host.settle(0.5)
        XCTAssertTrue(item.isFirstResponder)
        item.resignFirstResponder()
        host.settle(0.5)

        let details = try XCTUnwrap(host.uiView(withIdentifier: "request-meal-details-0"))
        XCTAssertTrue(details.becomeFirstResponder(), "revealed Details cannot take focus")
        host.settle(0.5)
        XCTAssertTrue(details.isFirstResponder)
        details.resignFirstResponder()
    }

    func testCollapsingWhileEditingReleasesFocusForBothFields() throws {
        for identifier in ["request-meal-item-0", "request-meal-details-0"] {
            let host = try RequesterFormHost(draft: draft(mealName: "Chicken Wings"))
            XCTAssertTrue(host.activate("request-meal-collapsed-0"))
            let field = try XCTUnwrap(host.uiView(withIdentifier: identifier))
            XCTAssertTrue(field.becomeFirstResponder())
            host.settle(0.5)
            XCTAssertNotNil(firstResponder(host))

            XCTAssertTrue(host.activate("request-meal-done-0"))
            XCTAssertNil(firstResponder(host), "collapsing from \(identifier) left a hidden field holding the keyboard")
        }
    }

    // MARK: - W4-R4 (2026-09-28) collapsed provenance badge + Details wrapping

    /// A collapsed, fully screenshot-derived Meal shows exactly ONE
    /// `Filled from screenshot` indicator, right-aligned in the `Meal N`
    /// row — not the prior duplicate lines beneath Meal item/Details.
    func testCollapsedPopulatedMealShowsExactlyOneRightAlignedProvenanceBadge() throws {
        let host = try RequesterFormHost(draft: draft(mealName: "Chicken Wings", details: "Buffalo sauce"))
        host.draftSession.screenshotProvenance = ScreenshotProposalAppliedFields(mealItemNames: [0], mealItemDetails: [0])
        host.settle(0.5)

        XCTAssertEqual(
            count(RequestFoodView.filledFromScreenshotLabel, in: host), 1,
            "exactly one provenance indicator must be visible"
        )
        XCTAssertTrue(isExposed("request-meal-summary-provenance-0", in: host))
        XCTAssertFalse(
            isExposed("request-meal-item-provenance-0", in: host),
            "no collapsed provenance line may remain beneath Meal item"
        )
        XCTAssertFalse(
            isExposed("request-meal-details-provenance-0", in: host),
            "no collapsed provenance line may remain beneath Details"
        )

        let rowFrame = try frame(host, "request-meal-label-row-0")
        let mealLabelFrame = try frame(host, "label:Meal 1")
        let badgeFrame = try frame(host, "request-meal-summary-provenance-0")
        XCTAssertGreaterThan(badgeFrame.minX, mealLabelFrame.maxX, "the badge must sit to the right of `Meal 1`")
        XCTAssertEqual(badgeFrame.maxX, rowFrame.maxX, accuracy: 2, "the badge must be right-aligned in the Meal N row")
    }

    /// Faith's authorized rule (2026-09-28): the row badge is a union of the
    /// two independent field-level provenance units — it shows whenever
    /// EITHER Meal item or Details is still screenshot-derived, not only
    /// when both are, and disappears only once both are requester-owned.
    func testMixedProvenanceMealStillShowsTheUnionBadge() throws {
        for provenance in [
            ScreenshotProposalAppliedFields(mealItemNames: [0]),
            ScreenshotProposalAppliedFields(mealItemDetails: [0]),
        ] {
            let host = try RequesterFormHost(draft: draft(mealName: "Chicken Wings", details: "Buffalo sauce"))
            host.draftSession.screenshotProvenance = provenance
            host.settle(0.5)
            XCTAssertEqual(
                count(RequestFoodView.filledFromScreenshotLabel, in: host), 1,
                "a mixed-provenance Meal must still show the union badge"
            )
        }
    }

    func testFullyManualMealShowsNoProvenanceBadge() throws {
        let host = try RequesterFormHost(draft: draft(mealName: "Chicken Wings", details: "Buffalo sauce"))
        host.draftSession.screenshotProvenance = ScreenshotProposalAppliedFields()
        host.settle(0.5)
        XCTAssertEqual(count(RequestFoodView.filledFromScreenshotLabel, in: host), 0)
    }

    func testEmptyCollapsedMealNeverShowsProvenanceBadgeRegardlessOfState() throws {
        let host = try RequesterFormHost(draft: draft())
        host.draftSession.screenshotProvenance = ScreenshotProposalAppliedFields(mealItemNames: [0], mealItemDetails: [0])
        host.settle(0.5)
        XCTAssertEqual(
            count(RequestFoodView.filledFromScreenshotLabel, in: host), 0,
            "the badge is defined for a POPULATED collapsed summary only"
        )
    }

    /// Long stored Details must render completely, with no ellipsis/cap,
    /// growing the populated card's actual height and pushing content below
    /// down by exactly that growth — never a fixed populated-summary height.
    func testLongCollapsedDetailsWrapsFullyAndGrowsCardHeightNaturally() throws {
        let shortHost = try RequesterFormHost(draft: draft(mealName: "Chicken Wings", details: "Buffalo sauce"))
        let shortControl = try frame(shortHost, "request-meal-control-0")
        let shortTiming = try frame(shortHost, "label:Timing")

        let longDetails = String(
            repeating: "Extra spicy buffalo sauce, ranch dip, celery, carrots, blue cheese crumbles. ",
            count: 6
        )
        let longHost = try RequesterFormHost(draft: draft(mealName: "Chicken Wings", details: longDetails))
        let longControl = try frame(longHost, "request-meal-control-0")
        XCTAssertGreaterThan(longHost.maxScrollOffsetY, 0, "precondition: long Details extend beyond the viewport")
        longHost.scrollToBottom()
        let longTiming = try frame(longHost, "label:Timing")

        XCTAssertGreaterThan(
            longControl.height, shortControl.height + 20,
            "long Details must grow the populated card's actual height"
        )
        XCTAssertEqual(
            (longTiming.minY + longHost.scrollOffsetY) - (shortTiming.minY + shortHost.scrollOffsetY),
            longControl.height - shortControl.height,
            accuracy: 4,
            "content below the card must move down by exactly the card's actual growth"
        )
        let longControlAtBottom = try frame(longHost, "request-meal-control-0")
        XCTAssertGreaterThan(longTiming.minY, longControlAtBottom.maxY, "Timing must remain downstream of the expanded summary")
        XCTAssertTrue(longHost.safeFrame.intersects(longTiming), "Timing must be reachable and visible at the scroll position")
        XCTAssertLessThan(
            shortControl.height, 100,
            "a short populated summary must stay compact with no dead footer"
        )

        let summary = exposed(longHost).first { $0.identifier == "request-meal-collapsed-0" }?.label ?? ""
        XCTAssertTrue(summary.contains(longDetails), "the complete stored Details text must remain represented")
        XCTAssertFalse(summary.contains("…"), "no ellipsis caused by a presentation line-limit cap")
    }

    // MARK: - W4-R4 (2026-09-28) unified Meal-row provenance badge correction

    /// An expanded, screenshot-derived Meal shows exactly ONE `Filled from
    /// screenshot` indicator, right-aligned in the `Meal N` row — not the
    /// prior per-field captions beneath the expanded `Meal item`/`Details`
    /// rows.
    func testExpandedPopulatedMealShowsExactlyOneRightAlignedProvenanceBadge() throws {
        let host = try RequesterFormHost(draft: draft(mealName: "Chicken Wings", details: "Buffalo sauce"))
        host.draftSession.screenshotProvenance = ScreenshotProposalAppliedFields(mealItemNames: [0], mealItemDetails: [0])
        host.settle(0.5)
        XCTAssertTrue(host.activate("request-meal-collapsed-0"))

        XCTAssertEqual(
            count(RequestFoodView.filledFromScreenshotLabel, in: host), 1,
            "exactly one provenance indicator must be visible while expanded"
        )
        XCTAssertTrue(isExposed("request-meal-summary-provenance-0", in: host))
        XCTAssertFalse(
            isExposed("request-meal-item-provenance-0", in: host),
            "no expanded provenance caption may remain beneath Meal item"
        )
        XCTAssertFalse(
            isExposed("request-meal-details-provenance-0", in: host),
            "no expanded provenance caption may remain beneath Details"
        )

        let rowFrame = try frame(host, "request-meal-label-row-0")
        let mealLabelFrame = try frame(host, "label:Meal 1")
        let badgeFrame = try frame(host, "request-meal-summary-provenance-0")
        XCTAssertGreaterThan(badgeFrame.minX, mealLabelFrame.maxX, "the badge must sit to the right of `Meal 1`")
        XCTAssertEqual(badgeFrame.maxX, rowFrame.maxX, accuracy: 2, "the badge must be right-aligned in the Meal N row")
    }

    /// The badge's position on the `Meal N` row must not move when the Meal
    /// expands and collapses again, and the underlying field-level
    /// provenance state must be untouched by that presentation toggle.
    func testBadgeStaysInTheIdenticalPositionThroughExpandAndCollapse() throws {
        let host = try RequesterFormHost(draft: draft(mealName: "Chicken Wings", details: "Buffalo sauce"))
        let provenance = ScreenshotProposalAppliedFields(mealItemNames: [0], mealItemDetails: [0])
        host.draftSession.screenshotProvenance = provenance
        host.settle(0.5)

        let collapsedBadge = try frame(host, "request-meal-summary-provenance-0")

        XCTAssertTrue(host.activate("request-meal-collapsed-0"))
        let expandedBadge = try frame(host, "request-meal-summary-provenance-0")
        XCTAssertEqual(collapsedBadge.minX, expandedBadge.minX, accuracy: 1, "badge x drifted on expand")
        XCTAssertEqual(collapsedBadge.minY, expandedBadge.minY, accuracy: 1, "badge y drifted on expand")
        XCTAssertEqual(collapsedBadge.maxX, expandedBadge.maxX, accuracy: 1, "badge right edge drifted on expand")
        XCTAssertEqual(host.draftSession.screenshotProvenance, provenance, "expanding must not mutate field-level provenance")

        XCTAssertTrue(host.activate("request-meal-done-0"))
        let recollapsedBadge = try frame(host, "request-meal-summary-provenance-0")
        XCTAssertEqual(collapsedBadge.minX, recollapsedBadge.minX, accuracy: 1, "badge x drifted on re-collapse")
        XCTAssertEqual(collapsedBadge.minY, recollapsedBadge.minY, accuracy: 1, "badge y drifted on re-collapse")
        XCTAssertEqual(collapsedBadge.maxX, recollapsedBadge.maxX, accuracy: 1, "badge right edge drifted on re-collapse")
        XCTAssertEqual(
            host.draftSession.screenshotProvenance, provenance,
            "collapsing must not mutate field-level provenance"
        )
    }

    /// The OR/union visibility rule must hold in BOTH the collapsed and the
    /// expanded state: item-only, Details-only, and both-fields provenance
    /// each show the badge; neither hides it.
    func testUnionVisibilityMatrixHoldsInBothCollapsedAndExpandedStates() throws {
        let matrix: [(ScreenshotProposalAppliedFields, Bool)] = [
            (ScreenshotProposalAppliedFields(mealItemNames: [0]), true),
            (ScreenshotProposalAppliedFields(mealItemDetails: [0]), true),
            (ScreenshotProposalAppliedFields(mealItemNames: [0], mealItemDetails: [0]), true),
            (ScreenshotProposalAppliedFields(), false),
        ]
        for (provenance, expectsBadge) in matrix {
            let host = try RequesterFormHost(draft: draft(mealName: "Chicken Wings", details: "Buffalo sauce"))
            host.draftSession.screenshotProvenance = provenance
            host.settle(0.5)
            XCTAssertEqual(
                count(RequestFoodView.filledFromScreenshotLabel, in: host), expectsBadge ? 1 : 0,
                "collapsed: unexpected badge count for \(provenance)"
            )

            XCTAssertTrue(host.activate("request-meal-collapsed-0"))
            XCTAssertEqual(
                count(RequestFoodView.filledFromScreenshotLabel, in: host), expectsBadge ? 1 : 0,
                "expanded: unexpected badge count for \(provenance)"
            )
        }
    }

    /// The Meal-row badge must render in the accepted CommonPlate purple
    /// provenance treatment (the `CommonPlateProvenance` asset, which preserves the violet), not a gray/secondary
    /// tone, in both the collapsed and expanded state.
    func testProvenanceBadgeUsesTheAcceptedPurpleTreatment() throws {
        let host = try RequesterFormHost(draft: draft(mealName: "Chicken Wings", details: "Buffalo sauce"))
        host.draftSession.screenshotProvenance = ScreenshotProposalAppliedFields(mealItemNames: [0], mealItemDetails: [0])
        host.settle(0.5)

        let accent = try XCTUnwrap(UIColor(named: "CommonPlateProvenance"), "CommonPlateProvenance asset missing")
        func components(_ color: UIColor, _ traits: UITraitCollection) -> (r: Int, g: Int, b: Int) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            return (Int(r * 255), Int(g * 255), Int(b * 255))
        }
        let traits = host.window.traitCollection
        let expected = components(accent, traits)

        // The badge is small `caption2` text: a single midpoint sample can
        // land in inter-glyph whitespace. Instead, scan the whole frame for
        // its darkest (most fully-inked) pixel — the point closest to the
        // glyph's actual fill color rather than an anti-aliased edge or the
        // canvas background.
        func darkestInkPixel(
            in rect: CGRect, file: StaticString = #filePath, line: UInt = #line
        ) throws -> (r: Int, g: Int, b: Int) {
            let pixels = try XCTUnwrap(host.pixels(), "could not render the window", file: file, line: line)
            var darkest = pixels.rgb(atX: rect.midX, y: rect.midY)
            var darkestLuminance = CGFloat.greatestFiniteMagnitude
            var y = rect.minY
            while y <= rect.maxY {
                var x = rect.minX
                while x <= rect.maxX {
                    let color = pixels.rgb(atX: x, y: y)
                    let luminance = 0.299 * CGFloat(color.r) + 0.587 * CGFloat(color.g) + 0.114 * CGFloat(color.b)
                    if luminance < darkestLuminance {
                        darkestLuminance = luminance
                        darkest = color
                    }
                    x += 0.5
                }
                y += 0.5
            }
            return darkest
        }

        func assertBadgeIsPurple(file: StaticString = #filePath, line: UInt = #line) throws {
            let badgeFrame = try frame(host, "request-meal-summary-provenance-0", file: file, line: line)
            let sample = try darkestInkPixel(in: badgeFrame, file: file, line: line)
            let distanceFromAccent = abs(sample.r - expected.r) + abs(sample.g - expected.g) + abs(sample.b - expected.b)
            let distanceFromGray = abs(sample.r - sample.g) + abs(sample.g - sample.b)
            XCTAssertLessThan(
                distanceFromAccent, 140,
                "badge ink pixel \(sample) is not close to the provenance purple \(expected)", file: file, line: line
            )
            XCTAssertGreaterThan(
                distanceFromGray, 8,
                "badge ink pixel \(sample) looks achromatic/gray rather than purple-tinted", file: file, line: line
            )
        }

        try assertBadgeIsPurple()
        XCTAssertTrue(host.activate("request-meal-collapsed-0"))
        try assertBadgeIsPurple()
    }

    func testSubmissionRejectionNeverHandsFocusToACollapsedMealsHiddenEditor() {
        let hidden = RequestFoodFormField.mealDetail(index: 0)
        XCTAssertNil(RequestFoodView.focusTargetAfterRejection(hidden, expandedMealIndex: nil))
        XCTAssertNil(RequestFoodView.focusTargetAfterRejection(hidden, expandedMealIndex: 1))
        XCTAssertEqual(RequestFoodView.focusTargetAfterRejection(hidden, expandedMealIndex: 0), hidden)
        XCTAssertEqual(
            RequestFoodView.focusTargetAfterRejection(.diningDollars, expandedMealIndex: nil), .diningDollars
        )
        XCTAssertEqual(
            RequestFoodView.focusTargetAfterRejection(.orderDetails, expandedMealIndex: 2), .orderDetails
        )
        XCTAssertNil(RequestFoodView.focusTargetAfterRejection(nil, expandedMealIndex: 0))
    }
}
