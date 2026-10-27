import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

/// CP5 removal notice, hosted: the real `OwnerRequestDetailView` reads the
/// requester's own detail through stubbed transport. Simulator rendering of the
/// production view only; not VoiceOver proof and not physical-device proof.
@MainActor
final class RequestRemovedHostedTests: XCTestCase {
    override func setUp() {
        super.setUp()
        OwnerHostedURLProtocol.detailStatus = 200
    }

    private func snapshot() -> OwnerRequest {
        OwnerRequest(
            request: FoodRequest(
                id: "h1",
                diningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
                foodDescription: "Chicken bowl",
                pickupWindowText: "ASAP",
                mealSwipes: 1,
                resource: RequestResource(
                    menuPath: .mealExchange,
                    mealItems: [MealItem(name: "Chicken bowl", details: nil)],
                    orderDetails: nil,
                    estimatedDiningDollarsCents: nil
                ),
                windowStart: nil,
                windowEnd: nil,
                createdAt: Date(timeIntervalSince1970: 1_784_000_000),
                expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
                status: .open,
                ownership: .own
            ),
            phase: .available,
            contentRevision: 3,
            canEdit: true,
            canWithdraw: true,
            latestScheduledStart: Date(timeIntervalSince1970: 4_000_000_000)
        )
    }

    private func host(
        status: Int,
        body: String,
        type: DynamicTypeSize = .large
    ) throws -> OwnerRequestHost {
        OwnerHostedURLProtocol.detailStatus = status
        OwnerHostedURLProtocol.detailBody = Data(body.utf8)
        let owner = snapshot()
        return try OwnerRequestHost(dynamicTypeSize: type) { store, path in
            AnyView(OwnerRequestDetailView(store: store, owner: owner, path: path))
        }
    }

    private func envelope(_ code: String) -> String {
        #"{"error":{"code":"\#(code)","message":"x","fields":null}}"#
    }

    func testRemovalShowsExactlyTheApprovedCopyWithTheSupportActionAndNoOwnerActions() throws {
        let host = try host(status: 410, body: envelope("REQUEST_REMOVED"))
        let keys = host.nodes().keys.sorted()

        XCTAssertTrue(host.exists("owner-request-removed"), "\(keys)")
        XCTAssertEqual(
            host.label("owner-request-removed"),
            "This request is no longer available. Contact support if you need assistance."
        )
        XCTAssertTrue(host.exists("owner-request-removed-contact-support"), "\(keys)")
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(host.frame("owner-request-removed-contact-support")).height, 44
        )
        XCTAssertTrue(host.exists("owner-request-removed-close"), "\(keys)")
        for absent in [
            "owner-request-edit", "owner-request-withdraw", "owner-request-details",
            "owner-request-unverified", "owner-request-expired",
        ] {
            XCTAssertFalse(host.exists(absent), absent)
        }
    }

    func testRemovalNoticeStaysOnScreenAtTheLargestTypeSize() throws {
        let host = try host(status: 410, body: envelope("REQUEST_REMOVED"), type: .accessibility5)
        let frame = try XCTUnwrap(host.frame("owner-request-removed"))
        XCTAssertGreaterThanOrEqual(frame.minX, -1)
        XCTAssertLessThanOrEqual(frame.maxX, UIScreen.main.bounds.width + 1)
        XCTAssertTrue(host.exists("owner-request-removed-contact-support"))
    }

    func testNonRemovalUnavailableStatesNeverShowTheRemovalNotice() throws {
        let cases: [(Int, String)] = [
            (404, envelope("REQUEST_NOT_FOUND")),
            (404, ""),
            (410, envelope("REQUEST_WITHDRAWN")),
            (409, envelope("REQUEST_ALREADY_PLACED")),
            (503, envelope("PARTICIPANT_VERIFICATION_UNAVAILABLE")),
            (500, envelope("INTERNAL_FAILURE")),
            (200, "not json"),
        ]
        for (status, body) in cases {
            let host = try host(status: status, body: body)
            XCTAssertFalse(host.exists("owner-request-removed"), "\(status) \(body)")
            XCTAssertFalse(host.exists("owner-request-removed-contact-support"), "\(status) \(body)")
        }
    }

    func testAnOrdinaryNotFoundStaysTheUnverifiedSnapshotNotARemoval() throws {
        let host = try host(status: 404, body: envelope("REQUEST_NOT_FOUND"))
        XCTAssertTrue(host.exists("owner-request-unverified"))
        XCTAssertFalse(host.exists("owner-request-removed"))
    }

    func testAVerifiedExpiryKeepsItsOwnOutcomeNotTheRemovalNotice() throws {
        let host = try host(status: 410, body: envelope("REQUEST_EXPIRED"))
        XCTAssertTrue(host.exists("owner-request-expired"))
        XCTAssertFalse(host.exists("owner-request-removed"))
    }
}
