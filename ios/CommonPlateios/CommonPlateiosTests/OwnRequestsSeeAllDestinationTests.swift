//
//  OwnRequestsSeeAllDestinationTests.swift
//  CommonPlateiosTests
//
// Focused W4-H4 coverage for the `See all N` destination: that the action
// exists only for 3+ owned open requests, that it is interactive and reads
// the full authoritative owned set (not the two-card Home preview), and that
// the subordinate `OwnRequestsListView` destination introduces no
// history/completed filtering or Edit/Remove/management affordance. The
// repository has no iOS UI-test target, so this proves the production source
// wiring; rendered scroll reachability, Dynamic Type, and VoiceOver order
// remain Simulator/physical-device proof.
import Foundation
import XCTest
@testable import CommonPlateios

final class OwnRequestsSeeAllDestinationTests: XCTestCase {
    private func request(id: String) -> FoodRequest {
        FoodRequest(
            id: id,
            diningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            foodDescription: "Rice bowl",
            pickupWindowText: "ASAP",
            mealSwipes: 2,
            windowStart: nil,
            windowEnd: nil,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            status: .open
        )
    }

    // MARK: - `See all N` exists only for 3+, is interactive

    func testSeeAllActionIsANavigationLinkCarryingTheFullOwnedSetNotThePreview() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        XCTAssertTrue(
            source.contains("seeAllRoute: seeAllCount == nil ? nil : .ownRequests(ownRequests)")
                && source.contains("NavigationLink(value: seeAllRoute) {"),
            "expected See all to push AppRoute.ownRequests with the full authoritative owned set, not the two-card preview"
        )
        XCTAssertTrue(source.contains("seeAllIdentifier: \"home-own-requests-see-all\""))
    }

    func testSeeAllOnlyRendersWhenThePreviewReportsASeeAllCount() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        XCTAssertTrue(
            source.contains("ownRequestsHeadingRow(seeAllCount: preview.seeAllCount)")
                && source.contains("if let seeAllCount, let seeAllRoute {"),
            "expected See all to be gated on the preview's seeAllCount, which is nil for 0/1/2 owned"
        )
    }

    // MARK: - Destination route wiring

    func testOwnRequestsRouteIsWiredToOwnRequestsListView() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/ContentView.swift")

        XCTAssertTrue(
            source.contains(
                "case .ownRequests(let requests):\n            OwnRequestsListView(requests: requests, placedOrders: requestStore.placedOrders)"
            ),
            "expected AppRoute.ownRequests to render OwnRequestsListView with the carried request set"
        )
    }

    // MARK: - Destination excludes management/history semantics

    func testDestinationIntroducesNoEditRemoveOrHistoryAffordance() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/OwnRequestsListView.swift")

        // The only interactive elements are the ordinary NavigationLinks
        // this file wires — no management `Button`, `swipeActions`, or
        // completed/history filtering predicate.
        XCTAssertFalse(source.contains("Button("))
        XCTAssertFalse(source.contains(".swipeActions"))
        XCTAssertFalse(source.contains(".filter"))
        XCTAssertFalse(source.contains("status !="))
        XCTAssertTrue(source.contains("if request.status == .placed"))
        XCTAssertTrue(source.contains("return .placedOrder(requestID: request.id)"))
    }

    func testDestinationSupportsOrdinaryScrollingAndPreservesRequestCardNavigation() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/OwnRequestsListView.swift")

        XCTAssertTrue(source.contains("ScrollView {"))
        XCTAssertTrue(
            source.contains("NavigationLink(value: route(for: request)) {")
                && source.contains("return .ownerRequest(OwnerRequest.provisional(from: request))"),
            "expected ongoing requests to preserve the requester-owned detail route"
        )
        XCTAssertTrue(source.contains("RequestCardView(") && source.contains("kind: .own"))
    }

    // MARK: - Full authoritative set and ordering reach the destination

    func testDestinationRendersEveryRequestPassedToItInOrder() {
        let requests = [request(id: "a"), request(id: "b"), request(id: "c"), request(id: "d")]
        let view = OwnRequestsListView(requests: requests)
        XCTAssertEqual(view.requests.map(\.id), ["a", "b", "c", "d"])
    }

    private func fileSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
