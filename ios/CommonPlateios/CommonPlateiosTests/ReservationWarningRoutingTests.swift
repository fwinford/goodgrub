//
//  ReservationWarningRoutingTests.swift
//  CommonPlateiosTests
//
// Focused coverage for W3-H1 reservation-warning notification tap routing:
// payload parsing, `HelperNotificationRouter`'s reservation-warning intent
// latch, and `ReservationWarningRouteDriver` — including the
// terminated-launch safety property `HelperNotificationRouteDriver` already
// established for helper taps, reused here by the identical mechanism.
import Foundation
import XCTest
@testable import CommonPlateios

// MARK: - Payload parsing

final class ReservationWarningNotificationPayloadParsingTests: XCTestCase {
    func testParsesAWellFormedPayload() {
        let payload = ReservationWarningNotificationPayloadParser.parse(userInfo: [
            "type": "reservation-warning",
            "requestId": "abc123"
        ])

        XCTAssertEqual(payload, ReservationWarningNotificationPayload(requestID: "abc123"))
    }

    func testRejectsAnUnrelatedNotificationType() {
        XCTAssertNil(ReservationWarningNotificationPayloadParser.parse(userInfo: [
            "type": "new-request",
            "requestId": "abc123"
        ]))
    }

    func testRejectsAMissingRequestID() {
        XCTAssertNil(ReservationWarningNotificationPayloadParser.parse(userInfo: [
            "type": "reservation-warning"
        ]))
    }

    func testRejectsAnEmptyRequestID() {
        XCTAssertNil(ReservationWarningNotificationPayloadParser.parse(userInfo: [
            "type": "reservation-warning",
            "requestId": ""
        ]))
    }

    func testDistinctFromTheOtherTwoNotificationTypes() {
        XCTAssertNotEqual(
            ReservationWarningNotificationPayloadParser.reservationWarningType,
            HelperNotificationPayloadParser.helperNewRequestType
        )
        XCTAssertNotEqual(
            ReservationWarningNotificationPayloadParser.reservationWarningType,
            RequesterFulfillmentNotificationPayloadParser.requesterFulfillmentType
        )
    }
}

// MARK: - Router latch

@MainActor
final class ReservationWarningRouterTests: XCTestCase {
    func testAValidPayloadBecomesThePendingReservationWarningIntent() {
        let router = HelperNotificationRouter()

        router.handleUserActedOnNotification(userInfo: [
            "type": "reservation-warning",
            "requestId": "abc"
        ])

        XCTAssertEqual(router.pendingReservationWarningIntent?.requestID, "abc")
    }

    func testRetiringClearsTheIntentAndASecondRetirementIsANoOp() throws {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: [
            "type": "reservation-warning",
            "requestId": "abc"
        ])
        let tapSequence = try XCTUnwrap(router.pendingReservationWarningIntent?.tapSequence)

        router.markReservationWarningIntentHandled(tapSequence: tapSequence)

        XCTAssertNil(router.pendingReservationWarningIntent)
        router.markReservationWarningIntentHandled(tapSequence: tapSequence)
        XCTAssertNil(router.pendingReservationWarningIntent)
    }

    /// Advances the same shared counters a helper tap does — returning to an
    /// already-held reservation is at least as specific a navigation intent.
    func testAdvancesTheSameSharedCountersAHelperTapDoes() {
        let router = HelperNotificationRouter()
        let startingSequence = router.latestTapSequence

        router.handleUserActedOnNotification(userInfo: [
            "type": "reservation-warning",
            "requestId": "abc"
        ])

        XCTAssertEqual(router.latestTapSequence, startingSequence + 1)
        XCTAssertEqual(router.reservationWarningRoutingGeneration, 1)
    }

    /// A later reservation-warning tap supersedes the older requester
    /// placed-order navigation intent.
    func testSupersedesAnOlderRequesterFulfillmentIntent() throws {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: [
            "type": "requester-order-placed",
            "requestId": "64c0000000000000000000a1"
        ])
        let requesterIntent = try XCTUnwrap(router.pendingRequesterFulfillmentIntent)

        router.handleUserActedOnNotification(userInfo: [
            "type": "reservation-warning",
            "requestId": "abc"
        ])

        XCTAssertFalse(TapAuthorityFence.isStillAuthoritative(
            capturedSequence: requesterIntent.tapSequence,
            currentSequence: router.latestTapSequence
        ))
    }

    func testAMalformedPayloadNeverBecomesAPendingIntent() {
        let router = HelperNotificationRouter()

        router.handleUserActedOnNotification(userInfo: ["type": "unrelated", "requestId": "abc"])

        XCTAssertNil(router.pendingReservationWarningIntent)
    }

    func testActiveSceneSuppressesOnlyReservationWarnings() {
        let router = HelperNotificationRouter()
        router.updateApplicationSceneActivity(isActive: true)
        let reservationOptions = router.foregroundPresentationOptions(userInfo: [
            "type": "reservation-warning",
            "requestId": "abc"
        ])
        let helperOptions = router.foregroundPresentationOptions(userInfo: [
            "type": "new-request",
            "requestId": "abc"
        ])
        let requesterOptions = router.foregroundPresentationOptions(userInfo: [
            "type": "requester-order-placed"
        ])

        XCTAssertTrue(reservationOptions.isEmpty)
        for options in [helperOptions, requesterOptions] {
            XCTAssertTrue(options.contains(.banner))
            XCTAssertTrue(options.contains(.list))
            XCTAssertTrue(options.contains(.sound))
        }
    }

    func testInactiveSceneDoesNotSuppressAReservationWarning() {
        let router = HelperNotificationRouter()
        router.updateApplicationSceneActivity(isActive: false)

        let options = router.foregroundPresentationOptions(userInfo: [
            "type": "reservation-warning",
            "requestId": "abc"
        ])

        XCTAssertTrue(options.contains(.banner))
        XCTAssertTrue(options.contains(.list))
        XCTAssertTrue(options.contains(.sound))
    }

    func testMalformedPayloadPresentationIsUnchangedInAnActiveScene() {
        let router = HelperNotificationRouter()
        router.updateApplicationSceneActivity(isActive: true)

        let options = router.foregroundPresentationOptions(userInfo: [
            "type": "reservation-warning"
        ])

        XCTAssertTrue(options.contains(.banner))
        XCTAssertTrue(options.contains(.list))
        XCTAssertTrue(options.contains(.sound))
    }
}

// MARK: - Route driver

@MainActor
final class ReservationWarningRouteDriverTests: XCTestCase {
    private let requestID = "warning-tap-target"

    override func tearDown() {
        ClaimFlowURLProtocol.reset()
        super.tearDown()
    }

    func testNothingPendingProducesNoDestination() async {
        let router = HelperNotificationRouter()
        let store = makeStore()

        let resolvedPath = await ReservationWarningRouteDriver.routeIfNeeded(router: router, resolver: store)

        XCTAssertNil(resolvedPath)
    }

    /// The common case: the process was merely backgrounded, so `activeClaim`
    /// never left memory and no continuation read is needed at all.
    func testAnAlreadyHeldClaimRoutesDirectlyToTheReservationScreen() async throws {
        let router = HelperNotificationRouter()
        let store = try await makeStoreWithActiveClaim()
        router.handleUserActedOnNotification(userInfo: [
            "type": "reservation-warning",
            "requestId": requestID
        ])

        let resolvedPath = await ReservationWarningRouteDriver.routeIfNeeded(router: router, resolver: store)

        let path = try XCTUnwrap(resolvedPath)
        XCTAssertEqual(path.count, 1, "Home is the root; Helping is the only route")
        guard case .fulfillment(let request) = try XCTUnwrap(path.last) else {
            return XCTFail("expected the reservation screen on top, got \(path)")
        }
        XCTAssertEqual(request.id, requestID)
        XCTAssertNil(router.pendingReservationWarningIntent, "an applied tap must be retired")
    }

    /// The terminated-launch case: nothing held in memory, so the driver must
    /// resolve continuation itself rather than assume `ContentView`'s own
    /// launch-time `.task` already finished first.
    func testATerminatedLaunchResolvesContinuationItselfBeforeRouting() async throws {
        let router = HelperNotificationRouter()
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: activeReservationResponse()))
        router.handleUserActedOnNotification(userInfo: [
            "type": "reservation-warning",
            "requestId": requestID
        ])

        let resolvedPath = await ReservationWarningRouteDriver.routeIfNeeded(router: router, resolver: store)

        let path = try XCTUnwrap(resolvedPath)
        guard case .fulfillment(let request) = try XCTUnwrap(path.last) else {
            return XCTFail("expected the reservation screen on top, got \(path)")
        }
        XCTAssertEqual(request.id, requestID)
    }

    func testAStaleWarningForReservationADoesNotRouteToCurrentReservationB() async throws {
        let staleRequestID = "ended-reservation-a"
        let currentRequestID = "current-reservation-b"
        let router = HelperNotificationRouter()
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(
            data: activeReservationResponse(requestID: currentRequestID)
        ))
        router.handleUserActedOnNotification(userInfo: [
            "type": "reservation-warning",
            "requestId": staleRequestID
        ])

        let resolvedPath = await ReservationWarningRouteDriver.routeIfNeeded(
            router: router,
            resolver: store
        )

        XCTAssertEqual(resolvedPath, [])
        XCTAssertEqual(store.activeClaim?.requestID, currentRequestID)
        let notice = try XCTUnwrap(store.claimUnavailableNotice)
        XCTAssertEqual(notice.requestID, staleRequestID)
        XCTAssertEqual(notice.reason, .noLongerAvailable)
        XCTAssertNil(router.pendingReservationWarningIntent)
    }

    /// The reservation ended (expired, released, or fulfilled some other way)
    /// between the notification firing and the tap.
    func testAReservationThatNoLongerExistsRecoversToActiveRequestsWithTheAcceptedNotice() async throws {
        let router = HelperNotificationRouter()
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: Data(#"{"reservation":null}"#.utf8)))
        router.handleUserActedOnNotification(userInfo: [
            "type": "reservation-warning",
            "requestId": requestID
        ])

        let resolvedPath = await ReservationWarningRouteDriver.routeIfNeeded(router: router, resolver: store)

        XCTAssertEqual(resolvedPath, [])
        let notice = try XCTUnwrap(store.claimUnavailableNotice)
        XCTAssertEqual(notice.requestID, requestID)
        XCTAssertEqual(notice.reason, .noLongerAvailable)
        XCTAssertNil(router.pendingReservationWarningIntent)
    }

    func testUnknownContinuationUsesTemporaryRecoveryWithoutClearingWarningsAsEnded() async throws {
        let router = HelperNotificationRouter()
        let scheduler = RecordingReservationWarningScheduler()
        scheduler.scheduleWarning(requestID: requestID, fireAt: Date().addingTimeInterval(60))
        let store = makeStore(scheduler: scheduler)
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        router.handleUserActedOnNotification(userInfo: [
            "type": "reservation-warning",
            "requestId": requestID
        ])

        let resolvedPath = await ReservationWarningRouteDriver.routeIfNeeded(router: router, resolver: store)

        XCTAssertEqual(resolvedPath, [])
        let notice = try XCTUnwrap(store.claimUnavailableNotice)
        XCTAssertEqual(notice.reason, .temporarilyUnavailable)
        XCTAssertEqual(scheduler.cancelAllCount, 0)
        XCTAssertNotNil(scheduler.pending[requestID])
        XCTAssertNil(router.pendingReservationWarningIntent, "the temporary recovery outcome was applied exactly once")
    }

    /// The terminated-launch fix, reused verbatim: an attempt SwiftUI cancels
    /// before it reaches a navigation outcome must leave the tap pending for
    /// the next attempt rather than destroy it.
    func testACancelledAttemptLeavesTheTapPendingForTheNextAttempt() async throws {
        let router = HelperNotificationRouter()
        let store = try await makeStoreWithActiveClaim()
        router.handleUserActedOnNotification(userInfo: [
            "type": "reservation-warning",
            "requestId": requestID
        ])

        let cancelledAttempt = Task {
            await ReservationWarningRouteDriver.routeIfNeeded(router: router, resolver: store)
        }
        cancelledAttempt.cancel()
        let cancelledResult = await cancelledAttempt.value

        XCTAssertNil(cancelledResult)
        XCTAssertEqual(
            router.pendingReservationWarningIntent?.requestID,
            requestID,
            "a cancelled attempt must leave the tap pending, not destroy it"
        )

        let resolvedPath = await ReservationWarningRouteDriver.routeIfNeeded(router: router, resolver: store)
        XCTAssertNotNil(resolvedPath, "the surviving tap must still produce a destination")
    }

    /// A later tap of either kind supersedes an unresolved reservation-warning
    /// intent, matching the helper driver's own tap-order authority.
    func testASupersededTapAppliesNothing() async throws {
        let router = HelperNotificationRouter()
        let store = try await makeStoreWithActiveClaim()
        router.handleUserActedOnNotification(userInfo: [
            "type": "reservation-warning",
            "requestId": requestID
        ])
        router.handleUserActedOnNotification(userInfo: [
            "type": "requester-order-placed", "requestId": "64c0000000000000000000a1"
        ])

        let resolvedPath = await ReservationWarningRouteDriver.routeIfNeeded(router: router, resolver: store)

        XCTAssertNil(resolvedPath, "a superseded tap must not overwrite newer navigation intent")
        XCTAssertNil(router.pendingReservationWarningIntent, "a superseded tap is retired, not left to fire later")
    }

    // MARK: - Helpers

    private func makeStore(
        scheduler: ReservationWarningScheduling = NoOpReservationWarningScheduler()
    ) -> RequestStore {
        RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { "64c0000000000000000000a1.1.credential" },
            participantAuthorityRejected: {},
            reservationWarningScheduler: scheduler
        )
    }

    private func makeService() -> RequestService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaimFlowURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return RequestService(client: client)
    }

    private func makeStoreWithActiveClaim() async throws -> RequestStore {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        return store
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func requestObject(status: String, requestID: String? = nil) -> String {
        """
        {
          "id": "\(requestID ?? self.requestID)",
          "vendor": "Crave NYU",
          "food": "Rice bowl",
          "pickupWindowText": "ASAP",
          "mealSwipes": 2,
          "menuPath": "meal-exchange",
          "mealItems": ["Meal 1", "Meal 2"],
          "orderDetails": null,
          "estimatedDiningDollarsCents": null,
          "windowStart": null,
          "windowEnd": null,
          "status": "\(status)",
          "createdAt": "2026-07-20T18:30:00.000Z",
          "expiresAt": "\(iso8601String(Date().addingTimeInterval(5 * 60 * 60)))"
        }
        """
    }

    private func claimResponse() -> Data {
        Data("""
        {
          "request": \(requestObject(status: "claimed")),
          "claim": {
            "pickupName": "Taylor",
            "claimToken": "claim-token",
            "claimExpiresAt": "\(iso8601String(Date().addingTimeInterval(15 * 60)))"
          }
        }
        """.utf8)
    }

    private func activeReservationResponse(requestID: String? = nil) -> Data {
        Data("""
        {
          "reservation": {
            "request": \(requestObject(status: "claimed", requestID: requestID)),
            "pickupName": "Taylor",
            "claimExpiresAt": "\(iso8601String(Date().addingTimeInterval(15 * 60)))",
            "claimExtendedAt": null
          }
        }
        """.utf8)
    }
}
