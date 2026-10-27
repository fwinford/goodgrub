//
//  RequestNotYetAvailableRoutingTests.swift
//  CommonPlateiosTests
//
//  W3-R1: what a helper is told when they reach a scheduled request before it
//  starts. The backend answers `GET /api/request/:id` with a distinct
//  `409 REQUEST_NOT_YET_AVAILABLE` carrying no request content, and these cases
//  pin that the app carries that truth through resolution, navigation, and copy
//  without degrading it into "gone" or into "try again".
//

import Foundation
import XCTest
@testable import CommonPlateios

/// Its own double, matching the convention in the neighbouring routing tests:
/// each test file owns its stubbing state.
final class NotYetAvailableRoutingURLProtocol: URLProtocol {
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

@MainActor
final class RequestNotYetAvailableRoutingTests: XCTestCase {
    private let requestID = "64b000000000000000000001"

    override func tearDown() {
        NotYetAvailableRoutingURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Resolution

    /// The whole point of the distinct backend outcome. A helper who reaches a
    /// scheduled request early must be told it has not started — not that it is
    /// gone, and not that the app failed to find out.
    func testTheBackendRefusalResolvesAsNotYetAvailable() async throws {
        let store = makeStore()
        NotYetAvailableRoutingURLProtocol.enqueue(.response(
            statusCode: 409,
            data: notYetAvailableEnvelope()
        ))

        let resolution = try await store.resolveHelperNotificationRequest(id: requestID)

        XCTAssertEqual(resolution, .notYetAvailable)
        XCTAssertNotEqual(resolution, .unavailable)
        XCTAssertNotEqual(resolution, .temporarilyUnavailable)
    }

    /// The regression this correction exists to prevent: before the distinct
    /// outcome, a 409 fell through to the generic catch and read as a transient
    /// failure, inviting a retry that could only fail the same way for hours.
    func testItIsNotDegradedIntoATransientFailure() async throws {
        let store = makeStore()
        NotYetAvailableRoutingURLProtocol.enqueue(.response(
            statusCode: 409,
            data: notYetAvailableEnvelope()
        ))

        let resolution = try await store.resolveHelperNotificationRequest(id: requestID)

        XCTAssertNotEqual(resolution, .temporarilyUnavailable)
    }

    /// A genuinely absent request is still a 404 and still resolves as gone.
    /// The two outcomes must not collapse into each other in either direction.
    func testATrueNotFoundStillResolvesAsUnavailable() async throws {
        let store = makeStore()
        NotYetAvailableRoutingURLProtocol.enqueue(.response(
            statusCode: 404,
            data: Data(#"{"error":"Request not found"}"#.utf8)
        ))

        let resolution = try await store.resolveHelperNotificationRequest(id: requestID)

        XCTAssertEqual(resolution, .unavailable)
        XCTAssertNotEqual(resolution, .notYetAvailable)
    }

    /// Another 409 code is not this one. Only the named code may produce the
    /// not-yet-available outcome; anything else the backend could not classify
    /// stays inconclusive.
    func testAnUnrelated409StaysTemporarilyUnavailable() async throws {
        let store = makeStore()
        NotYetAvailableRoutingURLProtocol.enqueue(.response(
            statusCode: 409,
            data: Data(#"{"error":{"code":"REQUEST_ALREADY_CLAIMED","message":"Someone else is helping.","fields":null}}"#.utf8)
        ))

        let resolution = try await store.resolveHelperNotificationRequest(id: requestID)

        XCTAssertEqual(resolution, .temporarilyUnavailable)
    }

    /// Transport failure is still inconclusive. Adding a settled-truth outcome
    /// must not have widened what counts as settled.
    func testATransportFailureIsStillTemporarilyUnavailable() async throws {
        let store = makeStore()
        NotYetAvailableRoutingURLProtocol.enqueue(.failure(.networkConnectionLost))

        let resolution = try await store.resolveHelperNotificationRequest(id: requestID)

        XCTAssertEqual(resolution, .temporarilyUnavailable)
    }

    // MARK: - Nothing about the request is exposed

    /// The refusal carries no request content, so there is nothing for the app
    /// to render even by accident: no detail screen is pushed, and the
    /// resolution holds no `FoodRequest`.
    func testNoFutureRequestDetailIsRenderedOrCarried() async throws {
        let store = makeStore()
        NotYetAvailableRoutingURLProtocol.enqueue(.response(
            statusCode: 409,
            data: notYetAvailableEnvelope()
        ))

        let resolution = try await store.resolveHelperNotificationRequest(id: requestID)

        if case .available = resolution {
            XCTFail("a future request must never resolve to a detail destination")
        }
        let path = AppRoute.afterNotificationResolution(resolution)
        XCTAssertEqual(path, [])
        for route in path {
            if case .requestDetail = route {
                XCTFail("a future request must never reach a detail route")
            }
        }
    }

    // MARK: - Presentation

    /// The queued recovery notice says the request has not started, using the
    /// same sentence the claim path already shows, and never borrows either
    /// neighbouring message.
    func testTheRecoveryNoticeTruthfullySaysNotYet() throws {
        let store = makeStore()

        store.reportRequestNotYetAvailableFromNotification(requestID: requestID)

        let notice = try XCTUnwrap(store.claimUnavailableNotice)
        XCTAssertEqual(notice.requestID, requestID)
        XCTAssertEqual(notice.reason, .notYetAvailable)
        XCTAssertEqual(
            HelperRequestPresentation.claimUnavailableTitle(for: notice.reason),
            RequestDetailView.notYetAvailableNotice
        )
        XCTAssertNotEqual(
            HelperRequestPresentation.claimUnavailableTitle(for: notice.reason),
            RequestDetailView.noLongerAvailableNotice
        )
        XCTAssertNotEqual(
            HelperRequestPresentation.claimUnavailableTitle(for: notice.reason),
            RequestDetailView.temporarilyUnavailableNotice
        )
    }

    /// It is a plain statement, not a warning: nothing was ordered and nothing
    /// was lost, so there is no second sentence to add.
    func testTheRecoveryNoticeNeedsNoSecondSentence() throws {
        let store = makeStore()

        store.reportRequestNotYetAvailableFromNotification(requestID: requestID)

        let notice = try XCTUnwrap(store.claimUnavailableNotice)
        XCTAssertNil(HelperRequestPresentation.claimUnavailableDetail(for: notice.reason))
    }

    /// Same invariant the sibling notification reporters carry: a recovery
    /// notice holds a request id and a locked reason, nothing else.
    func testTheRecoveryNoticeExposesNoPrivateRequesterData() throws {
        let store = makeStore()

        store.reportRequestNotYetAvailableFromNotification(requestID: requestID)

        let notice = try XCTUnwrap(store.claimUnavailableNotice)
        XCTAssertNil(notice.backendCode)
    }

    /// The copy has to read as "come back", not as a failure.
    func testTheNoticeSentenceSaysNotYetRatherThanGone() {
        let sentence = RequestDetailView.notYetAvailableNotice

        XCTAssertEqual(sentence, "This request is not available to help with yet.")
        XCTAssertTrue(sentence.contains("yet"))
        XCTAssertFalse(sentence.contains("no longer"))
        XCTAssertFalse(sentence.lowercased().contains("try again"))
    }

    // MARK: - Helpers

    /// Exactly what the backend sends: the shared code and sentence, and no
    /// request content of any kind.
    private func notYetAvailableEnvelope() -> Data {
        Data(#"""
        {"error":{"code":"REQUEST_NOT_YET_AVAILABLE","message":"This request is not available to help with yet.","fields":null}}
        """#.utf8)
    }

    private func makeStore() -> RequestStore {
        RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            // W3-I1: a verified participant, unless a case says otherwise.
            participantAuthorityProvider: { "64c0000000000000000000a1.1.test-credential" },
            participantAuthorityRejected: {}
        )
    }

    private func makeService() -> RequestService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NotYetAvailableRoutingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return RequestService(client: client)
    }
}
