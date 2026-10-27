//
//  ParticipantBlockYesNavigationTests.swift
//  CommonPlateiosTests
//
// W4-U1.3 final pre-acceptance pass (2026-10-15): Block → `Yes, already
// placed` leaves restricted Helping Home-rooted, and the Home Settings gear
// carries an explicit hit region. Unrelated Active Requests routing is pinned
// unchanged.
import Foundation
import XCTest
@testable import CommonPlateios

final class ParticipantBlockYesNavigationTests: XCTestCase {
    private func request() -> FoodRequest {
        FoodRequest(
            id: "64c0000000000000000000f2",
            diningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            foodDescription: "Rice bowl",
            pickupWindowText: "ASAP",
            mealSwipes: 1,
            windowStart: nil,
            windowEnd: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 3_600),
            status: .open
        )
    }

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testHomeOriginHelpingStaysHomeRootedAfterBlockYes() {
        let helping = AppRoute.fulfillment(request())
        XCTAssertEqual(AppRoute.afterParticipantBlockKeepingHelping(from: [helping]), [helping])
    }

    func testLegacyActiveRequestsRootedHelpingBacksToHomeAfterBlockYes() {
        let helping = AppRoute.fulfillment(request())
        let result = AppRoute.afterParticipantBlockKeepingHelping(from: [helping])
        XCTAssertEqual(result, [helping])
        XCTAssertEqual(result.count, 1)
    }

    func testBlockYesNormalizationWithNoHelpingRouteIsANoOp() {
        XCTAssertEqual(
            AppRoute.afterParticipantBlockKeepingHelping(from: []),
            []
        )
        XCTAssertEqual(AppRoute.afterParticipantBlockKeepingHelping(from: []), [])
    }

    func testNoAndPreHelpBlockStillResolveToHome() {
        let helping = AppRoute.fulfillment(request())
        XCTAssertEqual(AppRoute.afterParticipantBlock(from: [helping]), [])
        XCTAssertEqual(
            AppRoute.afterParticipantBlock(from: [.requestDetail(request())]),
            []
        )
    }

    func testUnrelatedNonBlockActiveRequestsRoutingIsUnchanged() {
        let r = request()
        XCTAssertEqual(
            AppRoute.afterNotificationResolution(.heldByCurrentHelper(r)),
            [.fulfillment(r)]
        )
        XCTAssertEqual(
            AppRoute.afterNotificationResolution(.available(r)),
            [.requestDetail(r)]
        )
        XCTAssertEqual(
            AppRoute.returningHome(from: [.fulfillment(r)]),
            []
        )
    }

    func testOnlyTheYesSeamUsesTheNormalization() throws {
        let fulfill = try source("Views/FulfillRequestView.swift")
        XCTAssertEqual(
            fulfill.components(separatedBy: "afterParticipantBlockKeepingHelping").count - 1, 1
        )
        let views = try source("Views/ParticipantBlockViews.swift")
        let yes = try XCTUnwrap(views.range(of: "externalOrderPlaced: true"))
        let no = try XCTUnwrap(views.range(of: "externalOrderPlaced: false"))
        let yesBody = String(views[yes.lowerBound..<no.lowerBound])
        XCTAssertTrue(yesBody.contains("onBlockedKeepingReservation()"))
        XCTAssertFalse(yesBody.contains("onBlockedAndReleased()"))
    }

    // MARK: - Settings gear

    func testSettingsGearHasExplicitComfortableHitRegionAndSameRoute() throws {
        XCTAssertGreaterThanOrEqual(HomeExchangeView.settingsGearHitSide, 44)
        let home = try source("Views/HomeExchangeView.swift")
        let link = try XCTUnwrap(home.range(of: "NavigationLink(value: AppRoute.settings)"))
        let tail = String(home[link.lowerBound...].prefix(900))
        XCTAssertTrue(tail.contains(".contentShape(Circle())"))
        XCTAssertTrue(tail.contains("settingsGearHitSide"))
        XCTAssertTrue(tail.contains(".strokeBorder(.secondary.opacity(0.3))"))
        XCTAssertTrue(tail.contains("home-settings"))
    }
}
