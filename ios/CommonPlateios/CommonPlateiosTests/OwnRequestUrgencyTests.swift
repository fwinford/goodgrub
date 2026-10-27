import Foundation
import XCTest
@testable import CommonPlateios

/// W4-R3 recorded scope addition: `Your Requests` urgency ordering.
final class OwnRequestUrgencyTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    func testGroupsFollowBackendDerivedTruth() {
        let placed = request("p", status: .placed)
        XCTAssertEqual(group(placed, phase: nil, confirm: true), .confirmPickup)
        XCTAssertEqual(group(placed, phase: .reserved, confirm: false), .ordered)

        let open = request("o", status: .open)
        XCTAssertEqual(group(open, phase: .scheduled, confirm: false), .scheduled)
        XCTAssertEqual(group(open, phase: .available, confirm: false), .available)
        XCTAssertEqual(group(open, phase: .reserved, confirm: false), .reserved)
        XCTAssertEqual(group(open, phase: nil, confirm: true), .available,
                       "pickup attention never applies to an unplaced request")
        XCTAssertEqual(group(request("c", status: .claimed), phase: nil, confirm: false), .reserved,
                       "no owner phase yet falls back like OwnerRequest.provisional")
    }

    func testOrdersByUrgencyThenNewestFirstWithStableTiebreak() {
        let requests = [
            request("scheduled-new", at: 90),
            request("available-old", at: 10),
            request("available-new", at: 80),
            request("reserved", at: 70),
            request("ordered", at: 60),
            request("confirm-old", at: 5),
            request("confirm-new", at: 50),
            request("tie-b", at: 40),
            request("tie-a", at: 40)
        ]
        let groups: [String: OwnRequestUrgency] = [
            "scheduled-new": .scheduled,
            "available-old": .available,
            "available-new": .available,
            "reserved": .reserved,
            "ordered": .ordered,
            "confirm-old": .confirmPickup,
            "confirm-new": .confirmPickup,
            "tie-b": .reserved,
            "tie-a": .reserved
        ]

        let ordered = OwnRequestUrgency.ordered(requests) { groups[$0.id]! }

        XCTAssertEqual(ordered.map(\.id), [
            "confirm-new", "confirm-old",
            "ordered",
            "reserved", "tie-a", "tie-b",
            "available-new", "available-old",
            "scheduled-new"
        ])
    }

    func testPreviewAndSeeAllCarryTheSameUrgencyOrder() {
        let requests = OwnRequestUrgency.ordered([
            request("available", at: 30),
            request("confirm", at: 10),
            request("reserved", at: 20)
        ]) { ["confirm": .confirmPickup, "reserved": .reserved, "available": .available][$0.id]! }

        let preview = HomeExchangeView.ownRequestsPreview(requests)
        XCTAssertEqual(preview.cards.map(\.id), ["confirm", "reserved"])
        XCTAssertEqual(preview.seeAllCount, 3)
        XCTAssertEqual(requests.map(\.id), ["confirm", "reserved", "available"],
                       "See all receives this same complete order")
    }

    func testContinuityLandingSlotIsChosenByIdentityNotPosition() {
        XCTAssertTrue(HomeExchangeView.isContinuityLandingSlot(requestID: "a", index: 0, continuityRequestID: nil))
        XCTAssertFalse(HomeExchangeView.isContinuityLandingSlot(requestID: "b", index: 1, continuityRequestID: nil))
        XCTAssertFalse(HomeExchangeView.isContinuityLandingSlot(requestID: "a", index: 0, continuityRequestID: "new"))
        XCTAssertTrue(HomeExchangeView.isContinuityLandingSlot(requestID: "new", index: 1, continuityRequestID: "new"))
    }

    private func group(_ request: FoodRequest, phase: OwnerRequestPhase?, confirm: Bool) -> OwnRequestUrgency {
        OwnRequestUrgency.group(for: request, ownerPhase: phase, needsPickupConfirmation: confirm)
    }

    private func request(_ id: String, at offset: TimeInterval = 0, status: RequestStatus = .open) -> FoodRequest {
        let createdAt = base.addingTimeInterval(offset)
        return FoodRequest(
            id: id,
            diningSpot: DiningSpot(name: "Crave NYU", address: "60 Washington Sq S"),
            foodDescription: "Rice bowl",
            pickupWindowText: "ASAP",
            mealSwipes: 2,
            windowStart: nil,
            windowEnd: nil,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(86_400),
            status: status,
            ownership: .own
        )
    }
}
