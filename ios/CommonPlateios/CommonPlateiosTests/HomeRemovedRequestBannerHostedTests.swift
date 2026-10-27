import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

/// CP5 Home removal notice, hosted: the production banner rendered in a real
/// window. Simulator rendering only; not VoiceOver proof and not
/// physical-device proof.
@MainActor
final class HomeRemovedRequestBannerHostedTests: XCTestCase {
    private func host(_ type: DynamicTypeSize) throws -> OwnerRequestHost {
        try OwnerRequestHost(dynamicTypeSize: type) { _, _ in
            AnyView(HomeRemovedRequestBanner(onDismiss: {}))
        }
    }

    func testBannerShowsExactlyTheApprovedCopyWithSupportAndDismiss() throws {
        let host = try host(.large)
        let keys = host.nodes().keys.sorted()

        XCTAssertTrue(host.exists("home-notice-request-removed"), "\(keys)")
        XCTAssertEqual(
            host.label("home-notice-request-removed-message"),
            "This request is no longer available. Contact support if you need assistance."
        )
        XCTAssertEqual(
            RequestRemovedPresentation.message,
            "This request is no longer available. Contact support if you need assistance."
        )
        XCTAssertTrue(host.exists("home-notice-request-removed-contact-support"), "\(keys)")
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(host.frame("home-notice-request-removed-contact-support")).height, 44
        )
        XCTAssertEqual(host.label("home-notice-request-removed-dismiss"), "Dismiss")
        let dismiss = try XCTUnwrap(host.frame("home-notice-request-removed-dismiss"))
        XCTAssertGreaterThanOrEqual(dismiss.width, 44)
        XCTAssertGreaterThanOrEqual(dismiss.height, 44)
    }

    func testBannerStaysReachableAtTheLargestAccessibilityTextSize() throws {
        let host = try host(.accessibility5)
        let screen = host.window.bounds
        for id in [
            "home-notice-request-removed-message",
            "home-notice-request-removed-contact-support",
            "home-notice-request-removed-dismiss",
        ] {
            let frame = try XCTUnwrap(host.frame(id), id)
            XCTAssertGreaterThan(frame.width, 0, id)
            XCTAssertLessThanOrEqual(frame.maxX, screen.maxX + 1, "\(id) fits the width")
        }
    }

    func testBannerCopyNamesNoModerationDetail() {
        let copy = RequestRemovedPresentation.message.lowercased()
        for forbidden in ["report", "violat", "policy", "moderat", "suspend", "reason", "removed by"] {
            XCTAssertFalse(copy.contains(forbidden), forbidden)
        }
    }
}
