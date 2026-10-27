//
//  PlacementReentryContinuationTests.swift
//  CommonPlateiosTests
//
// Focused coverage for relaunch reconciliation of a *settled placement*, over
// the same `GET /api/participant/active-reservation` read W3-H1 continuation
// already uses.
//
// W4-H1 supersedes W3-H2's success-presentation restore. A placed request has
// no reservation authority or helper completion action, but R3 keeps its
// request/order context in Continue helping until requester pickup or expiry.
// These tests pin that read-only continuation, removal after authoritative
// pickup, and W3-I4 readiness without rebuilding the success presentation.
import Foundation
import XCTest
@testable import CommonPlateios

/// Its own transport double, matching the one-file-one-double convention
/// (`ClaimFlowURLProtocol`, `ReservationContinuationURLProtocol`).
final class PlacementReentryURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let data: Data

        static func response(statusCode: Int = 200, data: Data) -> Stub {
            Stub(statusCode: statusCode, data: data)
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var stubs: [Stub] = []
    private nonisolated(unsafe) static var capturedPaths: [String] = []

    static func enqueue(_ stub: Stub) {
        lock.lock()
        stubs.append(stub)
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        stubs.removeAll()
        capturedPaths.removeAll()
        lock.unlock()
    }

    static var requestedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return capturedPaths
    }

    private static func dequeue() -> Stub? {
        lock.lock()
        defer { lock.unlock() }
        guard !stubs.isEmpty else { return nil }
        return stubs.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.capturedPaths.append(request.url?.path ?? "")
        Self.lock.unlock()

        guard let stub = Self.dequeue(),
              let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: stub.statusCode,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class PlacementReentryContinuationTests: XCTestCase {
    override func tearDown() {
        PlacementReentryURLProtocol.reset()
        super.tearDown()
    }

    /// A retained placement restores the helper's read-only continuation,
    /// without recreating reservation authority or success presentation.
    func testASettledSentPlacementRestoresWaitingForPickupContext() async throws {
        let store = makeStore()
        PlacementReentryURLProtocol.enqueue(.response(
            data: placementResponse(notificationStatus: "sent")
        ))

        let outcome = try await store.continueActiveReservationIfNeeded()

        guard case .none = outcome else {
            return XCTFail("a settled placement is not reservation authority")
        }
        XCTAssertNil(store.activeClaim, "must never recreate reservation authority")
        XCTAssertEqual(store.helperPlacedContinuation?.request.id, "placed-reentry-target")
        XCTAssertEqual(store.helperPlacedContinuation?.orderNumber, "70154321")
        XCTAssertEqual(store.helperPlacedContinuation?.etaText, "15 minutes")
        XCTAssertNil(
            store.fulfillmentConfirmation,
            "W4-H1: relaunch must not rebuild a stale success/acknowledgement screen"
        )
        XCTAssertNil(store.confirmedFulfillmentOutcome)
        // W3-I4 removal-safety readiness is still authoritatively resolved by
        // this read — H1 removes a presentation gate, not this resolution.
        XCTAssertTrue(store.hasResolvedReservationStateForRemoval)
    }

    /// The `failed` and never-settled notification outcomes reconcile
    /// identically: the distinction only ever drove success copy, and there is
    /// no success presentation to restore.
    func testFailedAndUnknownNotificationOutcomesReconcileTheSameWay() async throws {
        for notificationStatus in ["failed", nil] {
            let store = makeStore()
            PlacementReentryURLProtocol.enqueue(.response(
                data: placementResponse(notificationStatus: notificationStatus)
            ))

            _ = try await store.continueActiveReservationIfNeeded()

            XCTAssertNil(store.fulfillmentConfirmation, "\(notificationStatus ?? "nil")")
            XCTAssertNil(store.confirmedFulfillmentOutcome, "\(notificationStatus ?? "nil")")
            XCTAssertNil(store.activeClaim, "\(notificationStatus ?? "nil")")
            XCTAssertEqual(
                store.helperPlacedContinuation?.notificationStatus,
                notificationStatus == "failed" ? .failed : nil
            )
            PlacementReentryURLProtocol.reset()
        }
    }

    /// Neither an active reservation nor a still-existing placement: ordinary
    /// W3-H1 absence, unaffected by the W3-H2 extension.
    func testNoReservationAndNoPlacementRestoresNothing() async throws {
        let store = makeStore()
        PlacementReentryURLProtocol.enqueue(.response(
            data: Data(#"{"reservation":null,"placement":null}"#.utf8)
        ))

        let outcome = try await store.continueActiveReservationIfNeeded()

        guard case .none = outcome else {
            return XCTFail("expected authoritative absence")
        }
        XCTAssertNil(store.activeClaim)
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertNil(store.helperPlacedContinuation)
    }

    func testRequesterPickupConfirmedOnRefreshClearsHelperContinuation() async throws {
        let store = makeStore()
        PlacementReentryURLProtocol.enqueue(.response(
            data: placementResponse(notificationStatus: "sent")
        ))
        _ = try await store.continueActiveReservationIfNeeded()
        XCTAssertNotNil(store.helperPlacedContinuation)

        PlacementReentryURLProtocol.enqueue(.response(
            data: Data(#"{"reservation":null,"placement":null}"#.utf8)
        ))
        _ = try await store.continueActiveReservationIfNeeded()

        XCTAssertNil(store.helperPlacedContinuation)
    }

    /// The central W4-H1 relaunch guarantee: after confirmed success, a cold
    /// launch leaves the helper free to help another eligible request. Nothing
    /// local refuses the claim, so it reaches the backend, which remains the
    /// only authority over whether it wins.
    func testRelaunchAfterConfirmedSuccessLetsTheHelperHelpAnotherRequest() async throws {
        let store = makeStore()
        PlacementReentryURLProtocol.enqueue(.response(
            data: placementResponse(notificationStatus: "sent")
        ))
        _ = try await store.continueActiveReservationIfNeeded()
        XCTAssertNil(store.fulfillmentConfirmation)
        let pathsAfterRelaunch = PlacementReentryURLProtocol.requestedPaths

        PlacementReentryURLProtocol.enqueue(.response(
            data: claimResponse(requestID: "some-other-request")
        ))
        try await store.claim(requestID: "some-other-request")

        XCTAssertEqual(
            PlacementReentryURLProtocol.requestedPaths,
            pathsAfterRelaunch + ["/api/request/some-other-request/claim"],
            "the claim must actually be attempted, not refused locally"
        )
        XCTAssertEqual(store.activeClaim?.requestID, "some-other-request")
        XCTAssertNil(store.claimError(for: "some-other-request"))
    }

    /// The authoritative read replaces the prior helper continuation with its
    /// current retained placement, without restoring reservation authority.
    func testASecondContinuationReadReplacesTheCurrentPlacement() async throws {
        let store = makeStore()
        PlacementReentryURLProtocol.enqueue(.response(
            data: placementResponse(requestID: "first-placement", notificationStatus: "sent")
        ))
        _ = try await store.continueActiveReservationIfNeeded()

        PlacementReentryURLProtocol.enqueue(.response(
            data: placementResponse(requestID: "second-placement", notificationStatus: "failed")
        ))
        _ = try await store.continueActiveReservationIfNeeded()

        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertNil(store.activeClaim)
        XCTAssertEqual(store.helperPlacedContinuation?.request.id, "second-placement")
    }

    /// An active reservation always takes priority; placement re-entry must
    /// never run or restore anything alongside it.
    func testAnActiveReservationTakesPriorityOverAnyPlacementField() async throws {
        let store = makeStore()
        let claimExpiresAt = Date().addingTimeInterval(9 * 60)
        PlacementReentryURLProtocol.enqueue(.response(
            data: activeReservationResponse(claimExpiresAt: claimExpiresAt)
        ))

        let outcome = try await store.continueActiveReservationIfNeeded()

        guard case .active(let claim) = outcome else {
            return XCTFail("expected the active reservation to be restored")
        }
        XCTAssertEqual(claim.requestID, "active-reservation-target")
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertEqual(store.activeClaim?.requestID, "active-reservation-target")
    }

    // MARK: - Helpers

    private func makeStore() -> RequestStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlacementReentryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return RequestStore(
            service: RequestService(client: client),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { "64c0000000000000000000a1.1.credential" },
            participantAuthorityRejected: {}
        )
    }

    private func placementResponse(
        requestID: String = "placed-reentry-target",
        notificationStatus: String?
    ) -> Data {
        let notificationField = notificationStatus.map { #"{"status":"\#($0)"}"# } ?? "null"
        return Data("""
        {
          "reservation": null,
          "placement": {
            "request": {
              "id": "\(requestID)",
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
              "status": "placed",
              "createdAt": "2026-08-10T15:00:00.000Z",
              "expiresAt": "2026-08-10T20:00:00.000Z"
            },
            "orderNumber": "70154321",
            "etaText": "15 minutes",
            "notification": \(notificationField)
          }
        }
        """.utf8)
    }

    private func claimResponse(requestID: String) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let claimExpiresAt = formatter.string(from: Date().addingTimeInterval(15 * 60))
        return Data("""
        {
          "request": {
            "id": "\(requestID)",
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
            "status": "claimed",
            "createdAt": "2026-08-10T15:00:00.000Z",
            "expiresAt": "2026-08-10T20:00:00.000Z"
          },
          "claim": {
            "pickupName": "Next Pickup",
            "claimToken": "next-claim-token",
            "claimExpiresAt": "\(claimExpiresAt)"
          }
        }
        """.utf8)
    }

    private func activeReservationResponse(claimExpiresAt: Date) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Data("""
        {
          "reservation": {
            "request": {
              "id": "active-reservation-target",
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
              "status": "claimed",
              "createdAt": "2026-08-10T15:00:00.000Z",
              "expiresAt": "2026-08-10T20:00:00.000Z"
            },
            "pickupName": "Reentry Pickup",
            "claimExpiresAt": "\(formatter.string(from: claimExpiresAt))",
            "claimExtendedAt": null
          }
        }
        """.utf8)
    }
}
