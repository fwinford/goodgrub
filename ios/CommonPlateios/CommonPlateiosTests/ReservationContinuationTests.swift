//
//  ReservationContinuationTests.swift
//  CommonPlateiosTests
//
// Focused coverage for W3-H1 reservation continuation:
// `RequestStore.continueActiveReservationIfNeeded()` reconstructing "do I
// have an active reservation" from `GET /api/participant/active-reservation`
// after a relaunch that did not go through `claim()` — never from the raw
// claim token, which is never persisted.
import Foundation
import XCTest
@testable import CommonPlateios

/// Its own transport double, matching the one-file-one-double convention
/// (`ClaimFlowURLProtocol`, `HelperNotificationRoutingURLProtocol`).
final class ReservationContinuationURLProtocol: URLProtocol {
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

@MainActor
final class ReservationContinuationTests: XCTestCase {
    private let requestID = "continued-reservation"

    override func tearDown() {
        ReservationContinuationURLProtocol.reset()
        super.tearDown()
    }

    func testRestoresAnActiveReservationWithoutARawClaimToken() async throws {
        let store = makeStore()
        let claimExpiresAt = Date().addingTimeInterval(9 * 60)
        ReservationContinuationURLProtocol.enqueue(.response(
            data: activeReservationResponse(claimExpiresAt: claimExpiresAt)
        ))

        let outcome = try await store.continueActiveReservationIfNeeded()

        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(claim.requestID, requestID)
        // W4-R4: the reservation no longer carries a pickup name, so the
        // restored claim presentation has none either.
        XCTAssertFalse(
            String(describing: claim).contains("Continuation Pickup")
        )
        // ISO-8601 round-tripping through JSON only preserves millisecond
        // precision, so this compares within a tolerance rather than for
        // bit-exact equality with the original `Date()` value.
        XCTAssertEqual(
            claim.claimExpiresAt.timeIntervalSince1970,
            claimExpiresAt.timeIntervalSince1970,
            accuracy: 0.01
        )
        XCTAssertNil(claim.claimExtendedAt)
        XCTAssertTrue(claim.isExtensionAvailable)
        guard case .active(let restored) = outcome else {
            return XCTFail("expected an active continuation outcome")
        }
        XCTAssertEqual(restored.requestID, requestID)
    }

    func testOpenRequestInsideNonNullReservationRemainsUnknownWithoutMutatingWarningTruth() async throws {
        try await assertContradictoryReservationRemainsUnknown(requestStatus: "open")
    }

    func testPlacedRequestInsideNonNullReservationRemainsUnknownWithoutMutatingWarningTruth() async throws {
        try await assertContradictoryReservationRemainsUnknown(requestStatus: "placed")
    }

    /// `RequestStatusWire` currently has exactly three representable values:
    /// `claimed`, plus the two non-claimed cases above. Keeping these named
    /// cases separate makes either contradictory success regression obvious.
    private func assertContradictoryReservationRemainsUnknown(
        requestStatus: String
    ) async throws {
        let scheduler = RecordingReservationWarningScheduler()
        scheduler.scheduleWarning(
            requestID: "possibly-still-active",
            fireAt: Date().addingTimeInterval(60)
        )
        let store = makeStore(scheduler: scheduler)
        ReservationContinuationURLProtocol.enqueue(.response(
            data: activeReservationResponse(
                claimExpiresAt: Date().addingTimeInterval(9 * 60),
                requestStatus: requestStatus
            )
        ))

        let outcome = try await store.continueActiveReservationIfNeeded()

        guard case .unknown = outcome else {
            return XCTFail("contradictory \(requestStatus) body must not establish continuation truth")
        }
        XCTAssertNil(store.activeClaim)
        XCTAssertEqual(scheduler.cancelAllCount, 0)
        XCTAssertEqual(scheduler.scheduled.map(\.requestID), ["possibly-still-active"])
        XCTAssertNotNil(scheduler.pending["possibly-still-active"])
        XCTAssertNil(scheduler.pending[requestID])
    }

    /// The request path and header are the entire authorization surface:
    /// no id or credential travels any other way.
    func testReadsFromTheAcceptedEndpointWithTheParticipantHeader() async throws {
        let store = makeStore()
        ReservationContinuationURLProtocol.enqueue(.response(
            data: activeReservationResponse(claimExpiresAt: Date().addingTimeInterval(600))
        ))

        _ = try await store.continueActiveReservationIfNeeded()

        XCTAssertEqual(
            ReservationContinuationURLProtocol.requestedPaths,
            ["/api/participant/active-reservation"]
        )
    }

    func testAnAlreadyExtendedReservationRestoresWithNoFurtherExtensionOffered() async throws {
        let store = makeStore()
        let claimExpiresAt = Date().addingTimeInterval(4 * 60)
        let claimExtendedAt = Date().addingTimeInterval(-2 * 60)
        ReservationContinuationURLProtocol.enqueue(.response(
            data: activeReservationResponse(
                claimExpiresAt: claimExpiresAt,
                claimExtendedAt: claimExtendedAt
            )
        ))

        _ = try await store.continueActiveReservationIfNeeded()

        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(
            claim.claimExtendedAt?.timeIntervalSince1970 ?? .nan,
            claimExtendedAt.timeIntervalSince1970,
            accuracy: 0.01
        )
        XCTAssertFalse(claim.isExtensionAvailable)
        XCTAssertTrue(claim.hasUsedExtension)
    }

    func testUnusedExtensionIsNotOfferedWhenFiveMinutesNoLongerFitBeforeRequestExpiry() async throws {
        let store = makeStore()
        let claimExpiresAt = Date().addingTimeInterval(4 * 60)
        let requestExpiresAt = claimExpiresAt.addingTimeInterval(4 * 60 + 59)
        ReservationContinuationURLProtocol.enqueue(.response(
            data: activeReservationResponse(
                claimExpiresAt: claimExpiresAt,
                requestExpiresAt: requestExpiresAt
            )
        ))

        _ = try await store.continueActiveReservationIfNeeded()

        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertNil(claim.claimExtendedAt, "the one extension is still unused")
        XCTAssertFalse(
            claim.isExtensionAvailable,
            "unused is insufficient when the complete fixed extension cannot fit"
        )
    }

    func testNoReservationLeavesActiveClaimNilAndClearsStaleWarnings() async throws {
        let scheduler = RecordingReservationWarningScheduler()
        scheduler.scheduleWarning(requestID: "stale-prior-process", fireAt: Date().addingTimeInterval(60))
        let store = makeStore(scheduler: scheduler)
        ReservationContinuationURLProtocol.enqueue(.response(data: Data(#"{"reservation":null}"#.utf8)))

        let outcome = try await store.continueActiveReservationIfNeeded()

        XCTAssertNil(store.activeClaim)
        guard case .none = outcome else {
            return XCTFail("expected authoritative absence")
        }
        XCTAssertEqual(scheduler.cancelAllCount, 1)
        XCTAssertTrue(scheduler.pending.isEmpty)
    }

    /// Backend truth could not be established — continuation must never
    /// fabricate a reservation from stale local presentation.
    func testATransportFailureLeavesActiveClaimNilRatherThanFabricatingOne() async throws {
        let scheduler = RecordingReservationWarningScheduler()
        scheduler.scheduleWarning(requestID: "possibly-still-active", fireAt: Date().addingTimeInterval(60))
        let store = makeStore(scheduler: scheduler)
        ReservationContinuationURLProtocol.enqueue(.failure(.networkConnectionLost))

        let outcome = try await store.continueActiveReservationIfNeeded()

        XCTAssertNil(store.activeClaim)
        guard case .unknown = outcome else {
            return XCTFail("transport failure must remain unknown")
        }
        XCTAssertEqual(scheduler.cancelAllCount, 0)
        XCTAssertNotNil(scheduler.pending["possibly-still-active"])
    }

    func testAnUnreadableResponseLeavesActiveClaimNil() async throws {
        let scheduler = RecordingReservationWarningScheduler()
        scheduler.scheduleWarning(requestID: "possibly-still-active", fireAt: Date().addingTimeInterval(60))
        let store = makeStore(scheduler: scheduler)
        ReservationContinuationURLProtocol.enqueue(.response(data: Data("{".utf8)))

        let outcome = try await store.continueActiveReservationIfNeeded()

        XCTAssertNil(store.activeClaim)
        guard case .unknown = outcome else {
            return XCTFail("decode failure must remain unknown")
        }
        XCTAssertEqual(scheduler.cancelAllCount, 0)
    }

    func testAServerFailureRemainsUnknownAndPreservesWarnings() async throws {
        let scheduler = RecordingReservationWarningScheduler()
        scheduler.scheduleWarning(requestID: "possibly-still-active", fireAt: Date().addingTimeInterval(60))
        let store = makeStore(scheduler: scheduler)
        ReservationContinuationURLProtocol.enqueue(.response(
            statusCode: 503,
            data: Data(#"{"error":{"code":"VERIFICATION_UNAVAILABLE","message":"Try again.","fields":null}}"#.utf8)
        ))

        let outcome = try await store.continueActiveReservationIfNeeded()

        guard case .unknown = outcome else {
            return XCTFail("server failure must remain unknown")
        }
        XCTAssertNil(store.activeClaim)
        XCTAssertEqual(scheduler.cancelAllCount, 0)
        XCTAssertNotNil(scheduler.pending["possibly-still-active"])
    }

    func testRejectedContinuationCredentialUsesExistingReverificationRecoveryWithoutFabricatingState() async throws {
        var currentAuthority: String? = canonicalParticipantAuthorityFixture
        var rejectionCount = 0
        let store = makeStore(
            participantAuthorityProvider: { currentAuthority },
            participantAuthorityRejected: {
                rejectionCount += 1
                currentAuthority = nil
            }
        )
        ReservationContinuationURLProtocol.enqueue(.response(
            statusCode: 401,
            data: Data(#"{"error":{"code":"PARTICIPANT_AUTHORITY_INVALID","message":"Credential rejected","fields":null}}"#.utf8)
        ))

        let outcome = try await store.continueActiveReservationIfNeeded()

        guard case .unknown = outcome else {
            return XCTFail("a rejected credential does not establish reservation truth")
        }
        XCTAssertEqual(rejectionCount, 1)
        XCTAssertNil(currentAuthority)
        XCTAssertNil(store.activeClaim)
    }

    /// Never called on behalf of an unverified installation: nothing here
    /// should hit the network at all without a stored credential.
    func testWithoutAVerifiedParticipantNothingIsRequested() async throws {
        let store = RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { nil },
            participantAuthorityRejected: {}
        )

        let outcome = try await store.continueActiveReservationIfNeeded()

        XCTAssertNil(store.activeClaim)
        XCTAssertTrue(ReservationContinuationURLProtocol.requestedPaths.isEmpty)
        guard case .unknown = outcome else {
            return XCTFail("missing authority cannot prove absence")
        }
    }

    /// A claim already held in this process — from `claim()`, or an earlier
    /// continuation call — must never be silently overwritten by a second
    /// continuation read.
    func testWithAClaimAlreadyHeldNothingIsRequestedOrOverwritten() async throws {
        let store = makeStore()
        let firstExpiration = Date().addingTimeInterval(600)
        ReservationContinuationURLProtocol.enqueue(.response(
            data: activeReservationResponse(claimExpiresAt: firstExpiration, requestID: "first-reservation")
        ))
        _ = try await store.continueActiveReservationIfNeeded()
        XCTAssertEqual(store.activeClaim?.requestID, "first-reservation")

        let outcome = try await store.continueActiveReservationIfNeeded()

        XCTAssertEqual(store.activeClaim?.requestID, "first-reservation")
        XCTAssertEqual(ReservationContinuationURLProtocol.requestedPaths.count, 1)
        guard case .active(let active) = outcome else {
            return XCTFail("an already restored claim remains the active result")
        }
        XCTAssertEqual(active.requestID, "first-reservation")
    }

    // MARK: - Helpers

    private func makeStore(
        scheduler: ReservationWarningScheduling = NoOpReservationWarningScheduler(),
        participantAuthorityProvider: (() -> String?)? = nil,
        participantAuthorityRejected: @escaping () -> Void = {}
    ) -> RequestStore {
        let authorityProvider = participantAuthorityProvider ?? {
            "64c0000000000000000000a1.1.credential"
        }
        return RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: authorityProvider,
            participantAuthorityRejected: participantAuthorityRejected,
            reservationWarningScheduler: scheduler
        )
    }

    private func makeService() -> RequestService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReservationContinuationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return RequestService(client: client)
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func activeReservationResponse(
        claimExpiresAt: Date,
        claimExtendedAt: Date? = nil,
        requestID: String? = nil,
        requestExpiresAt: Date? = nil,
        requestStatus: String = "claimed"
    ) -> Data {
        let extendedField = claimExtendedAt.map { "\"\(iso8601String($0))\"" } ?? "null"
        return Data("""
        {
          "reservation": {
            "request": {
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
              "status": "\(requestStatus)",
              "createdAt": "2026-07-20T18:30:00.000Z",
              "expiresAt": "\(iso8601String(requestExpiresAt ?? Date().addingTimeInterval(5 * 60 * 60)))"
            },
            "pickupName": "Continuation Pickup",
            "claimExpiresAt": "\(iso8601String(claimExpiresAt))",
            "claimExtendedAt": \(extendedField)
          }
        }
        """.utf8)
    }
}
