//
//  HelperNotificationRoutingTests.swift
//  CommonPlateiosTests
//
// Focused coverage for the Week 3 Day 6 helper new-request notification
// tap-routing slice: payload parsing, the router's exactly-once pending-route
// latch, the pure navigation-resolution mapping, and destination truth
// against `RequestStore.resolveHelperNotificationRequest(id:)`.
//
// `UNUserNotificationCenterDelegate`'s own methods (`willPresent`,
// `didReceive response:`) are not exercised here: `UNNotification` and
// `UNNotificationResponse` have no public initializer, so constructing one to
// drive those methods is not possible from ordinary unit tests. Coverage
// therefore targets `HelperNotificationRouter.handleUserActedOnNotification`
// directly — the same code both real delegate methods funnel into — and the
// delegate methods themselves are verified structurally (see
// `HelperNotificationRouter.swift`) plus by physical-device acceptance.
import Foundation
import XCTest
@testable import CommonPlateios

/// Its own double, matching the convention in `PushSubscriptionStoreTests`
/// and `RequestFetchingTests`: each test file owns its stubbing state.
final class HelperNotificationRoutingURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let data: Data
        let errorCode: URLError.Code?

        static func response(statusCode: Int = 200, data: Data) -> Stub {
            Stub(statusCode: statusCode, data: data, errorCode: nil)
        }

        static func failure(_ errorCode: URLError.Code) -> Stub {
            Stub(statusCode: 0, data: Data(), errorCode: errorCode)
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var stubs: [Stub] = []

    static func enqueue(_ stub: Stub) {
        lock.lock()
        stubs.append(stub)
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        stubs.removeAll()
        lock.unlock()
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
        guard let stub = Self.dequeue() else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        if let errorCode = stub.errorCode {
            client?.urlProtocol(self, didFailWithError: URLError(errorCode))
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: stub.statusCode,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Payload parsing

final class HelperNotificationPayloadParsingTests: XCTestCase {
    func testParsesAWellFormedPayload() {
        let payload = HelperNotificationPayloadParser.parse(userInfo: [
            "type": "new-request",
            "requestId": "abc123"
        ])

        XCTAssertEqual(payload, HelperNewRequestNotificationPayload(requestID: "abc123"))
    }

    func testRejectsAnUnrelatedNotificationType() {
        XCTAssertNil(HelperNotificationPayloadParser.parse(userInfo: [
            "type": "something-else",
            "requestId": "abc123"
        ]))
    }

    func testRejectsAMissingType() {
        XCTAssertNil(HelperNotificationPayloadParser.parse(userInfo: ["requestId": "abc123"]))
    }

    func testRejectsAMissingRequestID() {
        XCTAssertNil(HelperNotificationPayloadParser.parse(userInfo: ["type": "new-request"]))
    }

    func testRejectsAnEmptyRequestID() {
        XCTAssertNil(HelperNotificationPayloadParser.parse(userInfo: [
            "type": "new-request",
            "requestId": ""
        ]))
    }

    func testRejectsANonStringRequestID() {
        XCTAssertNil(HelperNotificationPayloadParser.parse(userInfo: [
            "type": "new-request",
            "requestId": 12345
        ]))
    }

    func testRejectsAnEmptyPayload() {
        XCTAssertNil(HelperNotificationPayloadParser.parse(userInfo: [:]))
    }
}

// MARK: - Router latch

@MainActor
final class HelperNotificationRouterTests: XCTestCase {
    func testAValidPayloadBecomesThePendingRoute() {
        let router = HelperNotificationRouter()

        router.handleUserActedOnNotification(userInfo: ["type": "new-request", "requestId": "abc"])

        XCTAssertEqual(router.pendingRequestID, "abc")
    }

    func testAMalformedPayloadNeverBecomesAPendingRoute() {
        let router = HelperNotificationRouter()

        router.handleUserActedOnNotification(userInfo: ["type": "unrelated", "requestId": "abc"])

        XCTAssertNil(router.pendingRequestID)
    }

    /// Proxy for a cold launch: `PushAppDelegate` creates this router in its
    /// own `init`, before `application(_:willFinishLaunchingWithOptions:)`
    /// runs and long before `ContentView` exists, so a tap captured here
    /// survives — in memory, within this one process — until something is
    /// ready to route it. Whether the real launch sequence actually
    /// delivers the OS callback in time for this is not something a unit
    /// test can prove; that is physical-device acceptance territory.
    func testAPendingRouteSurvivesUntilSomethingRoutesIt() throws {
        let router = HelperNotificationRouter()

        router.handleUserActedOnNotification(userInfo: ["type": "new-request", "requestId": "abc"])

        XCTAssertEqual(router.pendingRequestID, "abc")
        // Reading it, however often, never retires it.
        XCTAssertEqual(router.pendingRequestID, "abc")
        router.markHelperIntentHandled(tapSequence: try XCTUnwrap(router.pendingRequestTapSequence))
        XCTAssertNil(router.pendingRequestID)
    }

    func testRetiringTheIntentClearsTheRouteSoItCannotBeAppliedTwice() throws {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: ["type": "new-request", "requestId": "abc"])
        let tapSequence = try XCTUnwrap(router.pendingRequestTapSequence)

        router.markHelperIntentHandled(tapSequence: tapSequence)

        XCTAssertNil(router.pendingRequestID)
        router.markHelperIntentHandled(tapSequence: tapSequence)
        XCTAssertNil(router.pendingRequestID, "a second retirement must not reopen the same route")
    }

    func testRetiringWithNothingPendingIsANoOp() {
        let router = HelperNotificationRouter()

        router.markHelperIntentHandled(tapSequence: 1)

        XCTAssertNil(router.pendingRequestID)
    }

    /// The terminated-launch guard at the router level: an attempt that never
    /// reached a navigation outcome retires nothing, so the tap is still
    /// there for the next attempt.
    func testAnAttemptThatNeverAppliedARouteLeavesTheIntentPending() {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: ["type": "new-request", "requestId": "abc"])

        // Whatever an unfinished attempt read, it never called
        // `markHelperIntentHandled`.
        XCTAssertEqual(router.pendingRequestID, "abc")
        XCTAssertNotNil(router.pendingRequestTapSequence)
    }

    /// A late attempt for an older tap must not clear the newer tap standing
    /// in the slot.
    func testRetiringAnOlderTapCannotClearANewerPendingTap() throws {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: ["type": "new-request", "requestId": "abc"])
        let olderTapSequence = try XCTUnwrap(router.pendingRequestTapSequence)
        router.handleUserActedOnNotification(userInfo: ["type": "new-request", "requestId": "def"])

        router.markHelperIntentHandled(tapSequence: olderTapSequence)

        XCTAssertEqual(router.pendingRequestID, "def")
    }

    // MARK: - Routing-generation trigger semantics

    /// This is the self-cancellation correction: `ContentView` keys its
    /// resolution `.task(id:)` on `routingGeneration`, not `pendingRequestID`,
    /// specifically because retiring a routed intent must not be able to
    /// rewrite that id.
    func testRetiringThePendingIntentDoesNotAdvanceTheGeneration() throws {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: ["type": "new-request", "requestId": "abc"])
        let generationAfterTap = router.routingGeneration

        router.markHelperIntentHandled(tapSequence: try XCTUnwrap(router.pendingRequestTapSequence))

        XCTAssertEqual(router.routingGeneration, generationAfterTap)
    }

    func testOneNewTapAdvancesTheGenerationExactlyOnce() {
        let router = HelperNotificationRouter()
        let startingGeneration = router.routingGeneration

        router.handleUserActedOnNotification(userInfo: ["type": "new-request", "requestId": "abc"])

        XCTAssertEqual(router.routingGeneration, startingGeneration + 1)
    }

    func testASecondTapAfterRetirementCreatesAFreshIntent() throws {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: ["type": "new-request", "requestId": "abc"])
        let firstGeneration = router.routingGeneration
        router.markHelperIntentHandled(tapSequence: try XCTUnwrap(router.pendingRequestTapSequence))

        router.handleUserActedOnNotification(userInfo: ["type": "new-request", "requestId": "def"])

        XCTAssertEqual(router.routingGeneration, firstGeneration + 1)
        XCTAssertEqual(router.pendingRequestID, "def")
    }

    func testAMalformedPayloadDoesNotAdvanceTheGeneration() {
        let router = HelperNotificationRouter()
        let startingGeneration = router.routingGeneration

        router.handleUserActedOnNotification(userInfo: ["type": "unrelated", "requestId": "abc"])

        XCTAssertEqual(router.routingGeneration, startingGeneration)
    }
}

// MARK: - Pure navigation resolution

final class HelperNotificationDestinationRoutingTests: XCTestCase {
    func testAnAvailableResolutionRoutesThroughActiveRequestsToDetail() {
        let request = FoodRequest(
            id: "abc",
            diningSpot: DiningSpot(name: "Crave NYU", address: nil),
            foodDescription: "Rice bowl",
            pickupWindowText: "ASAP",
            mealSwipes: 2,
            windowStart: nil,
            windowEnd: nil,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(60 * 60),
            status: .open
        )

        XCTAssertEqual(
            AppRoute.afterNotificationResolution(.available(request)),
            [.requestDetail(request)]
        )
    }

    func testAnUnavailableResolutionRoutesToActiveRequestsOnly() {
        XCTAssertEqual(
            AppRoute.afterNotificationResolution(.unavailable),
            []
        )
    }

    func testATemporarilyUnavailableResolutionRoutesToActiveRequestsOnly() {
        XCTAssertEqual(
            AppRoute.afterNotificationResolution(.temporarilyUnavailable),
            []
        )
    }
}

// MARK: - Destination truth

@MainActor
final class HelperNotificationDestinationTruthTests: XCTestCase {
    private let requestID = "meal-notification"

    override func tearDown() {
        HelperNotificationRoutingURLProtocol.reset()
        super.tearDown()
    }

    func testAnOpenDetailResolvesAsAvailable() async throws {
        let store = makeStore()
        HelperNotificationRoutingURLProtocol.enqueue(.response(data: detailResponse(status: "open")))

        let resolution = try await store.resolveHelperNotificationRequest(id: requestID)

        guard case .available(let request) = resolution else {
            return XCTFail("expected an available resolution, got \(resolution)")
        }
        XCTAssertEqual(request.id, requestID)
        XCTAssertEqual(request.status, .open)
    }

    /// This is also where the backend fix lands: the detail endpoint now
    /// reports effective availability, so a claim-expired-but-actually-open
    /// request would already read back as `"open"` here, not `"claimed"` —
    /// that case is covered on the backend side
    /// (`src/requestDetailRoute.test.ts`), not re-proven on iOS.
    func testAClaimedDetailResolvesAsUnavailable() async throws {
        let store = makeStore()
        HelperNotificationRoutingURLProtocol.enqueue(.response(data: detailResponse(status: "claimed")))

        let resolution = try await store.resolveHelperNotificationRequest(id: requestID)

        XCTAssertEqual(resolution, .unavailable)
    }

    func testAPlacedDetailResolvesAsUnavailable() async throws {
        let store = makeStore()
        HelperNotificationRoutingURLProtocol.enqueue(.response(data: detailResponse(status: "placed")))

        let resolution = try await store.resolveHelperNotificationRequest(id: requestID)

        XCTAssertEqual(resolution, .unavailable)
    }

    func testAMissingRequestResolvesAsUnavailable() async throws {
        let store = makeStore()
        HelperNotificationRoutingURLProtocol.enqueue(.response(
            statusCode: 404,
            data: Data(#"{"error":"Request not found"}"#.utf8)
        ))

        let resolution = try await store.resolveHelperNotificationRequest(id: requestID)

        XCTAssertEqual(resolution, .unavailable)
    }

    /// An inconclusive transport failure must not be treated as proof the
    /// request is gone: current backend truth could not be established, so
    /// it resolves to the distinct "try again" outcome rather than being
    /// folded into the authoritative "no longer available" one.
    func testATransportFailureResolvesAsTemporarilyUnavailableRatherThanThrowing() async throws {
        let store = makeStore()
        HelperNotificationRoutingURLProtocol.enqueue(.failure(.networkConnectionLost))

        let resolution = try await store.resolveHelperNotificationRequest(id: requestID)

        XCTAssertEqual(resolution, .temporarilyUnavailable)
    }

    /// A non-404 server failure is likewise inconclusive, not proof of
    /// absence.
    func testAServerFailureResolvesAsTemporarilyUnavailable() async throws {
        let store = makeStore()
        HelperNotificationRoutingURLProtocol.enqueue(.response(
            statusCode: 500,
            data: Data(#"{"error":"Internal error"}"#.utf8)
        ))

        let resolution = try await store.resolveHelperNotificationRequest(id: requestID)

        XCTAssertEqual(resolution, .temporarilyUnavailable)
    }

    /// A response that cannot be decoded is truth that could not be
    /// established, not truth that the request is gone.
    func testADecodingFailureResolvesAsTemporarilyUnavailable() async throws {
        let store = makeStore()
        HelperNotificationRoutingURLProtocol.enqueue(.response(data: Data("{".utf8)))

        let resolution = try await store.resolveHelperNotificationRequest(id: requestID)

        XCTAssertEqual(resolution, .temporarilyUnavailable)
    }

    /// Cancellation is not a resolution at all: it must remain distinct from
    /// both the unavailable and temporarily-unavailable outcomes rather than
    /// inventing either one.
    func testCancellationRemainsCancellationRatherThanBecomingAResolution() async throws {
        let store = makeStore()
        // This test class is @MainActor, so `Task {}` inherits that isolation
        // and its body cannot begin until this synchronous scope suspends;
        // `cancel()` therefore always lands before the first cancellation
        // check, matching the pattern in `AlertSignupTests`.
        let task = Task {
            try await store.resolveHelperNotificationRequest(id: requestID)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation to propagate")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testReportingUnavailabilityQueuesTheAcceptedRecoveryNotice() throws {
        let store = makeStore()

        store.reportRequestUnavailableFromNotification(requestID: requestID)

        let notice = try XCTUnwrap(store.claimUnavailableNotice)
        XCTAssertEqual(notice.requestID, requestID)
        XCTAssertEqual(notice.reason, .noLongerAvailable)
        // Same locked copy the claim-attempt path already shows.
        XCTAssertEqual(
            HelperRequestPresentation.claimUnavailableTitle(for: notice.reason),
            RequestDetailView.noLongerAvailableNotice
        )
    }

    /// The temporarily-unavailable path must read as "try again", never
    /// borrow the "no longer available" copy — that would be a false claim
    /// about a request that may still be open.
    func testReportingTemporaryUnavailabilityQueuesTheDistinctRecoveryNotice() throws {
        let store = makeStore()

        store.reportRequestTemporarilyUnavailableFromNotification(requestID: requestID)

        let notice = try XCTUnwrap(store.claimUnavailableNotice)
        XCTAssertEqual(notice.requestID, requestID)
        XCTAssertEqual(notice.reason, .temporarilyUnavailable)
        XCTAssertEqual(
            HelperRequestPresentation.claimUnavailableTitle(for: notice.reason),
            RequestDetailView.temporarilyUnavailableNotice
        )
        XCTAssertNotEqual(
            HelperRequestPresentation.claimUnavailableTitle(for: notice.reason),
            RequestDetailView.noLongerAvailableNotice
        )
    }

    /// Neither recovery notice may carry requester-private data — only a
    /// request id and a locked, generic reason.
    func testNeitherRecoveryNoticeExposesPrivateRequesterData() throws {
        let unavailableStore = makeStore()
        unavailableStore.reportRequestUnavailableFromNotification(requestID: requestID)
        let unavailableNotice = try XCTUnwrap(unavailableStore.claimUnavailableNotice)
        XCTAssertNil(unavailableNotice.backendCode)

        let temporaryStore = makeStore()
        temporaryStore.reportRequestTemporarilyUnavailableFromNotification(requestID: requestID)
        let temporaryNotice = try XCTUnwrap(temporaryStore.claimUnavailableNotice)
        XCTAssertNil(temporaryNotice.backendCode)
    }

    // MARK: - Helpers

    private func makeStore() -> RequestStore {
        RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            // W3-I1: a verified participant, so the gate is not what these
            // cases are proving.
            participantAuthorityProvider: { "64c0000000000000000000a1.1.credential" },
            participantAuthorityRejected: {}
        )
    }

    private func makeService() -> RequestService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HelperNotificationRoutingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return RequestService(client: client)
    }

    private func detailResponse(status: String) -> Data {
        Data("""
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
            "status": "\(status)",
            "createdAt": "2026-07-20T18:30:00.000Z",
            "expiresAt": "\(iso8601String(Date().addingTimeInterval(5 * 60 * 60)))"
          }
        }
        """.utf8)
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
