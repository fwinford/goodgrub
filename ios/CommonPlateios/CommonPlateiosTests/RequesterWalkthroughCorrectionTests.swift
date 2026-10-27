import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

@MainActor
final class RequesterWalkthroughCorrectionTests: XCTestCase {
    func testAllTwentyStrictDestinationsUseN1Mappings() throws {
        for restaurant in GrubhubRestaurantDestination.Restaurant.allCases {
            for path in [RequestMenuPath.mealExchange, .diningDollars] {
                let actual = RequestFoodView.requesterGrubhubURL(
                    restaurantID: restaurant.rawValue, menuPath: path
                )
                XCTAssertNotNil(actual)
                XCTAssertEqual(actual, GrubhubRestaurantDestination.url(
                    restaurantID: restaurant.rawValue, menuPath: path
                ))
            }
        }
    }

    func testMissingOrUnmappedVenueShowsNoLink() {
        for id in [nil, "", "Palladium", "Crave NYU "] {
            XCTAssertNil(RequestFoodView.requesterGrubhubURL(
                restaurantID: id, menuPath: .mealExchange
            ))
        }
    }

    func testRequesterLinkIsUngatedUsesNoGenericFallbackAndSitsBelowDiningLocation() throws {
        let source = try String(
            contentsOfFile: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("CommonPlateios/Views/RequestFoodView.swift").path,
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "static func requesterGrubhubURL("))
        let end = try XCTUnwrap(source.range(of: "\n    ///", range: start.upperBound..<source.endIndex))
        let lookup = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(lookup.contains("#if DEBUG"))
        XCTAssertFalse(lookup.contains("environment"))
        XCTAssertFalse(source.contains("GrubhubRestaurantDestination.destination("))
        XCTAssertFalse(source.contains("GrubhubRestaurantDestination.fallback"))
        let location = try XCTUnwrap(source.range(of: "diningSpotControl\n"))
        let link = try XCTUnwrap(source.range(of: "Label(\"View menu on Grubhub\""))
        let menu = try XCTUnwrap(source.range(of: "menuPathControl\n"))
        XCTAssertLessThan(location.lowerBound, link.lowerBound)
        XCTAssertLessThan(link.lowerBound, menu.lowerBound)
    }

    func testOutsideTapFilterProtectsNativeInputsAndTheirDescendants() {
        for input in [UITextField(), UITextView()] as [UIView] {
            let child = UIView()
            input.addSubview(child)
            XCTAssertTrue(RequesterOutsideInputDismissal.TapView.isInput(input))
            XCTAssertTrue(RequesterOutsideInputDismissal.TapView.isInput(child))
        }
        XCTAssertFalse(RequesterOutsideInputDismissal.TapView.isInput(UILabel()))
        XCTAssertFalse(RequesterOutsideInputDismissal.TapView.isInput(nil))
    }

    func testPostingDisappearsForSoftwareKeyboardAndRestoresAfterDismissalWithoutChangingDraft() throws {
        var draft = RequestFoodFormDraft()
        draft.selectedDiningSpot = SupportedVendorCatalog.diningSpots.first
        draft.mealEntries[0] = MealItem(name: "Wings", details: "Ranch\nNo onions")
        draft.diningDollarsText = "12.50"
        let host = try RequesterFormHost(draft: draft)
        host.scrollToBottom()
        XCTAssertTrue(host.exists("request-post-request"))

        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        host.settle()
        XCTAssertFalse(host.exists("request-post-request"))

        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        host.settle()
        host.scrollToBottom()
        XCTAssertTrue(host.exists("request-post-request"))
        XCTAssertEqual(host.draftSession.draft, draft)
    }

    func testMealDoneResignsMultilineDetailsAndCollapsesWithoutChangingText() throws {
        var draft = RequestFoodFormDraft()
        draft.mealEntries[0] = MealItem(name: "Wings", details: "Ranch\nNo onions")
        let host = try RequesterFormHost(draft: draft)
        XCTAssertTrue(host.activate("request-meal-collapsed-0"))
        let details = try XCTUnwrap(host.uiView(withIdentifier: "request-meal-details-0"))
        XCTAssertTrue(details.becomeFirstResponder())
        host.settle()
        XCTAssertTrue(details.isFirstResponder)
        let doneFrame = try XCTUnwrap(host.frame("request-meal-done-0"))
        // Accessibility frames can round-trip 44pt as 43.99999999999994.
        // Permit only sub-micro-point representation error; the production
        // control's exact 44pt minimum remains asserted below.
        let roundingTolerance: CGFloat = 0.000_001
        XCTAssertGreaterThanOrEqual(doneFrame.height, 44 - roundingTolerance)
        XCTAssertGreaterThanOrEqual(doneFrame.width, 44 - roundingTolerance)
        let requestFoodSource = try String(
            contentsOfFile: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("CommonPlateios/Views/RequestFoodView.swift").path,
            encoding: .utf8
        )
        XCTAssertTrue(requestFoodSource.contains(".frame(minWidth: 44, minHeight: 44, alignment: .trailing)"))
        XCTAssertTrue(host.activate("request-meal-done-0"))
        host.settle()
        XCTAssertFalse(details.isFirstResponder)
        XCTAssertTrue(host.exists("request-meal-collapsed-0"))
        XCTAssertEqual(host.draftSession.draft, draft)
    }

    /// Covers only `GrubhubHandoff.open`'s completion-callback plumbing: that
    /// it passes the opener's reported outcome straight through. The opener
    /// here is a stub, so this does not exercise a real app-return
    /// (backgrounding to Grubhub and back) and is not proof the requester's
    /// draft survives that round trip.
    func testGrubhubHandoffCompletionPassesThroughTheOpenersOutcome() throws {
        let destination = try XCTUnwrap(RequestFoodView.requesterGrubhubURL(
            restaurantID: "Dunkin' at U-Hall", menuPath: .mealExchange
        ))
        for outcome in [true, false] {
            var result: Bool?
            GrubhubHandoff.open(
                destination: destination,
                using: { url, complete in
                    XCTAssertEqual(url, destination)
                    complete(outcome)
                },
                completion: { result = $0 }
            )
            XCTAssertEqual(result, outcome, "the completion handler must receive exactly the opener's reported outcome")
        }
    }
}
