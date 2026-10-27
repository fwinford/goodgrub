//
//  HelperContinuationSetTests.swift
//  CommonPlateiosTests
//
// W4-R3 asymmetric continuation contract: every valid helper continuation is
// represented (never newest-only, never hidden by an active claim), the shared
// Home preview limit applies, and helper / requester visibility cutoffs are
// backend-derived and advanced only on the monotonic clock.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class HelperContinuationSetTests: XCTestCase {
    private let serverNow = "2026-10-19T17:00:00.000Z"

    override func tearDown() {
        PlacementReentryURLProtocol.reset()
        super.tearDown()
    }

    // MARK: A / C — active first, waiting alone

    func testActiveClaimAndWaitingPlacementBothExistActiveFirst() async {
        let store = makeStore()
        enqueue(claim: "claim-b", placements: [("placed-a", 1800)])

        await store.refreshHelperContinuations()

        let items = store.helperContinuationItems()
        XCTAssertEqual(items.map(\.id), ["claim-b", "placed-a"])
        guard case .active = items[0], case .waiting = items[1] else {
            return XCTFail("active claim must precede passive continuation")
        }
    }

    func testTwoWaitingPlacementsWithNoClaimBothExist() async {
        let store = makeStore()
        enqueue(claim: nil, placements: [("placed-a", 1800), ("placed-c", 1800)])

        await store.refreshHelperContinuations()

        XCTAssertNil(store.activeClaim)
        XCTAssertEqual(store.helperContinuationItems().map(\.id), ["placed-a", "placed-c"])
    }

    // MARK: B — shared preview limit, See all reveals overflow

    func testPreviewAppliesSharedLimitAndSeeAllExposesEveryContinuation() async {
        let store = makeStore()
        enqueue(claim: "claim-b", placements: [("placed-a", 1800), ("placed-c", 1800)])

        await store.refreshHelperContinuations()

        let items = store.helperContinuationItems()
        XCTAssertEqual(items.count, 3, "nothing is discarded from the full collection")
        let preview = HomeExchangeView.homePreview(items)
        XCTAssertEqual(HomeExchangeView.homePreviewLimit, 2)
        XCTAssertEqual(preview.cards.map(\.id), ["claim-b", "placed-a"])
        XCTAssertEqual(preview.seeAllCount, 3)
        // See all renders the live full set, so the overflow is reachable.
        XCTAssertEqual(items.map(\.id).last, "placed-c")
    }

    // MARK: D — pickup for A retires only A

    func testAuthoritativeRefreshRetiresOnlyThePickedUpPlacement() async {
        let store = makeStore()
        enqueue(claim: nil, placements: [("placed-a", 1800), ("placed-b", 1800)])
        await store.refreshHelperContinuations()
        XCTAssertEqual(store.helperContinuationItems().map(\.id), ["placed-a", "placed-b"])

        enqueue(claim: nil, placements: [("placed-b", 1800)])
        await store.refreshHelperContinuations()

        XCTAssertEqual(store.helperContinuationItems().map(\.id), ["placed-b"])
    }

    // MARK: E / H — helper cutoff is local to helper Home

    func testHelperCutoffRetiresOnlyThatCardOnTheMonotonicClock() async {
        let store = makeStore()
        // A leaves helper Home in 600s, B in 7200s.
        enqueue(claim: nil, placements: [("placed-a", 600), ("placed-b", 7200)])
        await store.refreshHelperContinuations()
        let uptime = ProcessInfo.processInfo.systemUptime

        XCTAssertEqual(store.helperContinuationItems(at: uptime).map(\.id), ["placed-a", "placed-b"])
        XCTAssertEqual(store.helperContinuationItems(at: uptime + 601).map(\.id), ["placed-b"])
        XCTAssertEqual(store.helperContinuationItems(at: uptime + 7201).map(\.id), [])
    }

    func testHelperCutoffDoesNotConfirmPickupOrTouchRequesterOrders() async {
        let store = makeStore()
        enqueue(claim: nil, placements: [("placed-a", 600)])
        await store.refreshHelperContinuations()
        let uptime = ProcessInfo.processInfo.systemUptime

        XCTAssertTrue(store.helperContinuationItems(at: uptime + 601).isEmpty)
        // Helper expiry is presentation-only: no pickup/confirmation state moves.
        XCTAssertTrue(store.placedOrders.isEmpty)
        XCTAssertEqual(
            PlacementReentryURLProtocol.requestedPaths.filter { $0.contains("pickup") },
            []
        )
    }

    func testRequesterCardOutlivesTheHelperWindow() {
        let order = placedOrder(id: "placed-a", homeVisibleInSeconds: 6 * 3600)
        let uptime = ProcessInfo.processInfo.systemUptime
        // Well past the helper's one-hour window, still before requester end of day.
        XCTAssertTrue(order.isVisibleOnRequesterHome(at: uptime + 2 * 3600))
    }

    // MARK: F — requester end-of-day cutoff

    func testRequesterCardLeavesActiveHomeAtItsCampusDayCutoff() {
        let order = placedOrder(id: "placed-a", homeVisibleInSeconds: 3600)
        let uptime = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(order.isVisibleOnRequesterHome(at: uptime + 3599))
        XCTAssertFalse(order.isVisibleOnRequesterHome(at: uptime + 3600))
    }

    // MARK: G — requester pickup retires the helper card on authoritative refresh

    func testRequesterPickupRetiresBothSides() async {
        let store = makeStore()
        enqueue(claim: nil, placements: [("placed-a", 1800)])
        await store.refreshHelperContinuations()
        XCTAssertEqual(store.helperContinuationItems().map(\.id), ["placed-a"])

        // After requester pickup the backend no longer lists it for the helper.
        enqueue(claim: nil, placements: [])
        await store.refreshHelperContinuations()

        XCTAssertTrue(store.helperContinuationItems().isEmpty)
    }

    // MARK: Helper pickup acknowledgement (authoritative fact only)

    func testHelperAcknowledgementComesOnlyFromTheBackendConfirmationFact() async {
        UserDefaults.standard.removeObject(forKey: "commonplate.helperPickupAcknowledged")
        let store = makeStore()
        enqueue(claim: nil, placements: [("placed-a", 1800)])
        await store.refreshHelperContinuations()

        // The card leaving the set (withdrawal, expiry, stale read) is NOT pickup.
        enqueue(claim: nil, placements: [])
        await store.refreshHelperContinuations()
        XCTAssertNil(store.helperPickupNoticeRequestID)

        enqueue(claim: nil, placements: [], confirmed: ["placed-a"])
        await store.refreshHelperContinuations()
        XCTAssertEqual(store.helperPickupNoticeRequestID, "placed-a")
    }

    func testHelperAcknowledgementIsOneTimeAcrossRepeatedReads() async {
        UserDefaults.standard.removeObject(forKey: "commonplate.helperPickupAcknowledged")
        let store = makeStore()
        enqueue(claim: nil, placements: [], confirmed: ["placed-a"])
        await store.refreshHelperContinuations()
        XCTAssertEqual(store.helperPickupNoticeRequestID, "placed-a")

        store.dismissHelperPickupNotice()
        XCTAssertNil(store.helperPickupNoticeRequestID)

        enqueue(claim: nil, placements: [], confirmed: ["placed-a"])
        await store.refreshHelperContinuations()
        XCTAssertNil(store.helperPickupNoticeRequestID, "an acknowledged event never returns")
    }

    func testHelperAcknowledgementDoesNotSurviveAnIdentityChange() async {
        UserDefaults.standard.removeObject(forKey: "commonplate.helperPickupAcknowledged")
        var principal: String? = "64c0000000000000000000a1"
        let store = makeStore(principal: { principal })
        enqueue(claim: nil, placements: [], confirmed: ["placed-a"])
        await store.refreshHelperContinuations()
        XCTAssertEqual(store.helperPickupNoticeRequestID, "placed-a")

        principal = "64c0000000000000000000b2"
        store.invalidateRequestDataIfIdentityReplaced()

        XCTAssertNil(store.helperPickupNoticeRequestID)
        UserDefaults.standard.removeObject(forKey: "commonplate.helperPickupAcknowledged")
    }

    // MARK: J — stale helper response cannot resurrect an expired card

    func testLateHelperResponseAlreadyPastItsCutoffIsNotRestored() async {
        let store = makeStore()
        // Backend projects a cutoff already behind server time.
        enqueue(claim: nil, placements: [("placed-a", -5)])

        await store.refreshHelperContinuations()

        XCTAssertTrue(store.helperContinuationItems().isEmpty)
    }

    func testReadWithoutPlacementsClearsAnEarlierSet() async {
        let store = makeStore()
        enqueue(claim: nil, placements: [("placed-a", 1800), ("placed-b", 1800)])
        await store.refreshHelperContinuations()
        enqueue(claim: nil, placements: [("placed-b", 1800)])
        await store.refreshHelperContinuations()

        XCTAssertEqual(store.helperContinuationItems().map(\.id), ["placed-b"])
    }

    // MARK: K — requester list cannot resurrect expired card

    func testRequesterListRowPastItsCutoffIsNotShownOnActiveHome() async {
        let store = makeStore()
        PlacementReentryURLProtocol.enqueue(.response(data: requesterList([
            ("placed-expired", -60),
            ("placed-live", 3600)
        ])))

        await store.fetchPlacedOrders()

        XCTAssertEqual(store.homeVisiblePlacedOrders().map(\.id), ["placed-live"])
    }

    // MARK: L — authority is server time + monotonic uptime, not the device clock

    func testCutoffIgnoresDeviceWallClock() async {
        let store = makeStore()
        // `serverNow` here is years behind the device clock; remaining time is
        // still the difference of backend instants.
        enqueue(claim: nil, placements: [("placed-a", 900)])
        await store.refreshHelperContinuations()

        let uptime = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(store.helperContinuationItems(at: uptime + 899).count, 1)
        XCTAssertEqual(store.helperContinuationItems(at: uptime + 901).count, 0)
    }

    // MARK: I — B1 seam stays on the unfinished-obligation predicate

    func testHomeCutoffsAreNotPartOfTheUnfinishedObligationFilter() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("src/placedOrderRoutes.ts"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "unfinishedPlacedObligationFilter"))
        let window = String(source[start.lowerBound...].prefix(600))
        XCTAssertTrue(window.contains("requesterPickupConfirmedAt"))
        XCTAssertFalse(window.contains("helperVisibleUntil"))
        XCTAssertFalse(window.contains("campusDayEnd"))
    }

    // MARK: - Harness

    private func enqueue(
        claim: String?,
        placements: [(id: String, helperVisibleInSeconds: Double)],
        confirmed: [String] = []
    ) {
        PlacementReentryURLProtocol.enqueue(.response(data: reservationResponse(
            claimID: claim,
            placements: placements,
            confirmed: confirmed
        )))
    }

    private func reservationResponse(
        claimID: String?,
        placements: [(id: String, helperVisibleInSeconds: Double)],
        confirmed: [String] = []
    ) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let base = formatter.date(from: serverNow)!
        let reservation: Any = claimID.map {
            [
                "request": requestObject(id: $0, status: "claimed"),
                "pickupName": "Pickup",
                "claimExpiresAt": formatter.string(from: Date().addingTimeInterval(15 * 60)),
                "claimExtendedAt": NSNull()
            ] as [String: Any]
        } ?? NSNull()
        let placed = placements.map { placement -> [String: Any] in
            [
                "request": requestObject(id: placement.id, status: "placed"),
                "orderNumber": "70154321",
                "etaText": "15 minutes",
                "notification": ["status": "sent"],
                "helperVisibleUntil": formatter.string(from: base.addingTimeInterval(placement.helperVisibleInSeconds))
            ]
        }
        let body: [String: Any] = [
            "reservation": reservation,
            "placement": placed.first as Any? ?? NSNull(),
            "placements": placed,
            "pickupConfirmations": confirmed.map { ["requestId": $0] },
            "serverNow": serverNow
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func requesterList(_ rows: [(id: String, homeVisibleInSeconds: Double)]) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let base = formatter.date(from: serverNow)!
        let orders = rows.map { row -> [String: Any] in
            var object = requestObject(id: row.id, status: "placed")
            object["isOwnRequest"] = true
            object["orderNumber"] = "70154321"
            object["etaText"] = "15 minutes"
            object["placedAt"] = serverNow
            object["estimatedReadyAt"] = serverNow
            object["homeVisibleUntil"] = formatter.string(from: base.addingTimeInterval(row.homeVisibleInSeconds))
            return object
        }
        return try! JSONSerialization.data(withJSONObject: ["orders": orders, "serverNow": serverNow])
    }

    private func placedOrder(id: String, homeVisibleInSeconds: Double) -> PlacedOrder {
        let now = Date()
        let request = FoodRequest(
            id: id,
            diningSpot: DiningSpot(name: "Crave NYU", address: nil),
            foodDescription: "Rice bowl",
            pickupWindowText: "ASAP",
            mealSwipes: 2,
            resource: RequestResource(
                menuPath: .mealExchange,
                mealItems: [],
                orderDetails: nil,
                estimatedDiningDollarsCents: nil
            ),
            windowStart: nil,
            windowEnd: nil,
            createdAt: now,
            expiresAt: now.addingTimeInterval(3 * 3600),
            status: .placed,
            ownership: .own
        )
        return PlacedOrder(
            request: request,
            orderNumber: "70154321",
            etaText: "15 minutes",
            placedAt: now,
            estimatedReadyAt: now,
            homeVisibleUntil: now.addingTimeInterval(homeVisibleInSeconds),
            serverNow: now
        )
    }

    private func requestObject(id: String, status: String) -> [String: Any] {
        [
            "id": id, "vendor": "Crave NYU", "food": "Rice bowl", "pickupWindowText": "ASAP",
            "mealSwipes": 2, "menuPath": "meal-exchange", "mealItems": ["Meal 1"],
            "orderDetails": NSNull(), "estimatedDiningDollarsCents": NSNull(),
            "windowStart": NSNull(), "windowEnd": NSNull(), "status": status,
            "createdAt": "2026-10-19T15:00:00.000Z", "expiresAt": "2026-10-19T20:00:00.000Z"
        ]
    }

    // MARK: R3 UI reconciliation

    func testHelperWaitingDetailResolvesPlacedContinuationAndRetiresWhenGone() async {
        let store = makeStore()
        enqueue(claim: nil, placements: [("placed-a", 1800)])
        await store.refreshHelperContinuations()

        let found = HelperWaitingDetailView.placement(
            requestID: "placed-a", in: store.helperContinuationItems()
        )
        XCTAssertEqual(found?.id, "placed-a")
        XCTAssertNil(HelperWaitingDetailView.placement(
            requestID: "placed-z", in: store.helperContinuationItems()
        ))
        XCTAssertNil(HelperWaitingDetailView.placement(requestID: "placed-a", in: []))
    }

    func testHelperWaitingDetailIsPrivateUnavailablePathFreeAndMessagingFree() throws {
        let detail = try repoSource("Views/HelperWaitingDetailView.swift")
        for forbidden in ["requestDetail", "RequestDetailView", "no longer available",
                          "requesterPickupConfirmedAt", "requesterParticipantId",
                          "I picked it up", "Contact helper", "Message"] {
            XCTAssertFalse(detail.contains(forbidden), forbidden)
        }
        for required in ["fetchHelperPlacementContact", "helper-waiting-contact", "commonPlateCard",
                         "RequestDetailBlockMenu", "R3MapsDestination"] {
            XCTAssertTrue(detail.contains(required), required)
        }
        XCTAssertFalse(detail.contains("warmSurface"))
    }

    func testPickupConfirmedNoticeRendersBeforeEveryHomeSection() throws {
        let home = try repoSource("Views/HomeExchangeView.swift")
        let notice = try XCTUnwrap(home.range(of: "                            pickupConfirmationNotice\n"))
        let continueHelping = try XCTUnwrap(home.range(of: "                            continueHelpingSection\n"))
        let own = try XCTUnwrap(home.range(of: "                            ownRequestsSection\n"))
        XCTAssertLessThan(notice.lowerBound, continueHelping.lowerBound)
        XCTAssertLessThan(notice.lowerBound, own.lowerBound)
    }

    func testDiningDollarsAppearsOnceInPlacedDetailContext() {
        let request = FoodRequest(
            id: "r", diningSpot: DiningSpot(name: "Kimmel", address: nil),
            foodDescription: "wings ($5.00 Dining Dollars)",
            pickupWindowText: "ASAP", mealSwipes: 0,
            resource: RequestResource(
                menuPath: .diningDollars, mealItems: [], orderDetails: nil,
                estimatedDiningDollarsCents: 500
            ),
            windowStart: nil, windowEnd: nil, createdAt: Date(),
            expiresAt: Date().addingTimeInterval(3600), status: .placed
        )
        XCTAssertEqual(RequestCardView.quantityText(for: request), "$5.00 Dining Dollars")
        XCTAssertEqual(RequestCardView.bodyText(for: request), "wings")
    }

    func testRequesterConfirmPickupSortsAboveOrderedAndLowerGroups() {
        XCTAssertLessThan(OwnRequestUrgency.confirmPickup, .ordered)
        XCTAssertLessThan(OwnRequestUrgency.ordered, .reserved)
    }

    private func repoSource(_ relative: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        url.appendPathComponent("CommonPlateios/\(relative)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func makeStore(
        principal: @escaping () -> String? = { "64c0000000000000000000a1" }
    ) -> RequestStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlacementReentryURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
        return RequestStore(
            service: RequestService(client: client),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { "64c0000000000000000000a1.1.credential" },
            participantAuthorityRejected: {},
            participantPrincipalProvider: principal
        )
    }
}
