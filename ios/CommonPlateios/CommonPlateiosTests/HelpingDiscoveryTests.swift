//
//  HelpingDiscoveryTests.swift
//  CommonPlateiosTests
//
// W4-O1 focused proof: first-eligible-request discovery selection, plus exact
// Welcome / Settings copy and route replacement.

import XCTest
@testable import CommonPlateios

final class HelpingDiscoveryTests: XCTestCase {
    private func request(_ id: String, _ ownership: RequestOwnership = .notOwn) -> FoodRequest {
        FoodRequest(
            id: id,
            diningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            foodDescription: "Rice bowl",
            pickupWindowText: "ASAP",
            mealSwipes: 1,
            windowStart: nil,
            windowEnd: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: Date().addingTimeInterval(3600),
            status: .open,
            ownership: ownership
        )
    }

    func testSelectsFirstEligibleRequestInExistingBoardOrderSkippingOwn() {
        let board = HomeExchangeView.BoardState.populated([
            request("own", .own), request("a"), request("b")
        ])
        let eligible = HelpingDiscovery.eligibleRequests(boardState: board)
        XCTAssertEqual(eligible.map(\.id), ["a", "b"])
        XCTAssertEqual(
            HelpingDiscovery.selectedRequestID(isPending: true, hasActiveReservation: false, eligible: eligible),
            "a"
        )
    }

    func testMovesToNextEligibleWhenSelectedRequestLeavesBoard() {
        let before = HelpingDiscovery.eligibleRequests(boardState: .populated([request("a"), request("b")]))
        let after = HelpingDiscovery.eligibleRequests(boardState: .populated([request("b")]))
        XCTAssertEqual(HelpingDiscovery.selectedRequestID(isPending: true, hasActiveReservation: false, eligible: before), "a")
        XCTAssertEqual(HelpingDiscovery.selectedRequestID(isPending: true, hasActiveReservation: false, eligible: after), "b")
    }

    func testNothingSelectedForLoadingUnavailableEmptyOrOnlyOwn() {
        for state in [HomeExchangeView.BoardState.loading, .unavailable, .empty, .populated([request("own", .own)])] {
            let eligible = HelpingDiscovery.eligibleRequests(boardState: state)
            XCTAssertNil(HelpingDiscovery.selectedRequestID(isPending: true, hasActiveReservation: false, eligible: eligible))
        }
    }

    func testSuppressedDuringActiveReservationAndReturnsAfter() {
        let eligible = [request("a")]
        XCTAssertNil(HelpingDiscovery.selectedRequestID(isPending: true, hasActiveReservation: true, eligible: eligible))
        XCTAssertEqual(HelpingDiscovery.selectedRequestID(isPending: true, hasActiveReservation: false, eligible: eligible), "a")
    }

    func testNothingSelectedWhenDiscoveryNotPending() {
        XCTAssertNil(HelpingDiscovery.selectedRequestID(isPending: false, hasActiveReservation: false, eligible: [request("a")]))
    }

    // MARK: - Copy / routing / structure

    func testWelcomeCopyIsExact() {
        // W4-UI1 Checkpoint 1 (B, Faith 2026-10-23).
        XCTAssertEqual(OnboardingCopy.heroTitle, "Meals move through the community.")
        XCTAssertEqual(OnboardingCopy.heroSubtitle, "Sometimes you need a meal. Sometimes you have an extra swipe to share.")
        XCTAssertEqual(OnboardingCopy.scrollInvitation, "See how it works")
        XCTAssertEqual(OnboardingCopy.sectionLabel, "HOW GOODGRUB WORKS")
        XCTAssertEqual(OnboardingCopy.continueTitle, "Continue")
        XCTAssertEqual(OnboardingCopy.story.map(\.title), [
            "Someone posts a meal request", "Other students can find it", "Someone chooses to help",
            "They place the order", "The requester gets pickup information", "Then you pick it up"
        ])
        XCTAssertEqual(OnboardingCopy.story.map(\.detail), [
            "They find what they want on Grubhub, then copy the meal details into \(AppBrand.name).",
            "It appears on Home, and students can get notified when a new request is posted.",
            "A student with extra swipes steps in.",
            "The helper orders through Grubhub, then shares the order details in \(AppBrand.name).",
            "\(AppBrand.name) notifies the requester when their pickup details are ready.",
            "You use the pickup details to pick up your meal."
        ])
        XCTAssertEqual(OnboardingCopy.story.map(\.showsGrubhubBadge), [false, false, false, true, false, false])
    }

    func testSettingsReferenceCopyIsExact() {
        typealias C = HowCommonPlateWorksCopy
        XCTAssertEqual(C.hubTitle, "How \(AppBrand.name) Works")
        XCTAssertEqual(C.hubPremise, "Request a meal. Help when you can.")
        XCTAssertEqual(C.requestingSteps.map(\.title), ["Create your request", "Other students can find it", "Pickup details come back to you"])
        XCTAssertEqual(C.helpingSteps.map(\.title), ["Find a request", "Choose to help", "Place the order in Grubhub", "Send the pickup details back"])
        XCTAssertEqual(C.returnToHome, "Return to Home")
    }

    func testRetiredCopyAndBrandAssetAreAbsentFromOnboardingSources() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios/Views")
        var combined = ""
        for name in ["OnboardingExperienceView.swift", "HowCommonPlateWorksViews.swift"] {
            combined += try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
        }
        for retired in ["Extra swipes. More meals.", "I need a meal", "I have extra meal swipes",
                        "Ready for pickup", "Screenshot", "emails you", "TicketToMealMotif",
                        "OnboardingIntent", "URLSession", "RequestStore", "APIClient"] {
            XCTAssertFalse(combined.contains(retired), retired)
        }
        XCTAssertFalse(combined.contains("Image(\"Grubhub"))
    }

    func testRoutesReplaceChooserAndSettingsKeepsIdentifier() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
        let settings = try String(contentsOf: root.appendingPathComponent("Views/SettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(settings.contains("NavigationLink(value: AppRoute.howCommonPlateWorks)"))
        XCTAssertTrue(settings.contains("settings-how-commonplate-works"))
        let route = try String(contentsOf: root.appendingPathComponent("Navigation/AppRoute.swift"), encoding: .utf8)
        XCTAssertFalse(route.contains("onboardingChooser"))
        XCTAssertTrue(route.contains("case howRequestingWorks"))
        XCTAssertTrue(route.contains("case howHelpingWorks"))
    }

    func testDiscoveryTreatmentIsPresentationOnlyWithoutPermanentChrome() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios/Views")
        let home = try String(contentsOf: root.appendingPathComponent("HomeExchangeView.swift"), encoding: .utf8)
        XCTAssertTrue(home.contains("discoverySelectedRequestID"))
        XCTAssertTrue(home.contains("LinearKeyframe(0, duration: 1.2)"))
        XCTAssertTrue(home.contains("CubicKeyframe(-3, duration: 0.8)"))
        XCTAssertFalse(home.contains("scaleEffect"))
        let card = try String(contentsOf: root.appendingPathComponent("RequestCardView.swift"), encoding: .utf8)
        XCTAssertFalse(card.contains("View request"))
    }
}
