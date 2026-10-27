//
//  ParticipantEmailUnsubscribeStoreTests.swift
//  CommonPlateiosTests
//
// Focused coverage for W3-N2's participant-authorized "Turn off email
// alerts" action: that it never fires without a resolved credential, that it
// sends no email or Subscriber ID of its own, that Off is shown only after
// the backend confirms it, and that failures map to the right recovery step.
import Foundation
import XCTest
@testable import CommonPlateios

/// Its own transport double, capturing headers — the one thing this store's
/// tests need beyond what `AlertSignupURLProtocol` already captures.
final class ParticipantEmailUnsubscribeURLProtocol: URLProtocol {
    struct CapturedRequest {
        let path: String
        let method: String
        let body: Data?
        let headers: [String: String]
    }

    struct Stub {
        let statusCode: Int
        let data: Data
        let errorCode: URLError.Code?
        let delay: TimeInterval

        static func response(statusCode: Int = 200, data: Data, delay: TimeInterval = 0) -> Stub {
            Stub(statusCode: statusCode, data: data, errorCode: nil, delay: delay)
        }

        static func failure(_ errorCode: URLError.Code) -> Stub {
            Stub(statusCode: 0, data: Data(), errorCode: errorCode, delay: 0)
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var stubs: [Stub] = []
    private nonisolated(unsafe) static var captured: [CapturedRequest] = []

    static func enqueue(_ stub: Stub) {
        lock.lock()
        stubs.append(stub)
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        stubs.removeAll()
        captured.removeAll()
        lock.unlock()
    }

    static var capturedRequests: [CapturedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
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
        Self.captured.append(
            CapturedRequest(
                path: request.url?.path ?? "",
                method: request.httpMethod ?? "",
                body: request.httpBody,
                headers: request.allHTTPHeaderFields ?? [:]
            )
        )
        Self.lock.unlock()

        guard let stub = Self.dequeue() else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        let completeRequest = {
            if let errorCode = stub.errorCode {
                self.client?.urlProtocol(self, didFailWithError: URLError(errorCode))
                return
            }
            guard let url = self.request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: stub.statusCode,
                      httpVersion: nil,
                      headerFields: ["Content-Type": "application/json"]
                  ) else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: stub.data)
            self.client?.urlProtocolDidFinishLoading(self)
        }

        if stub.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay, execute: completeRequest)
        } else {
            completeRequest()
        }
    }

    override func stopLoading() {}
}

@MainActor
final class ParticipantEmailUnsubscribeStoreTests: XCTestCase {
    override func tearDown() {
        ParticipantEmailUnsubscribeURLProtocol.reset()
        super.tearDown()
    }

    private func makeStore() -> ParticipantEmailUnsubscribeStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ParticipantEmailUnsubscribeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return ParticipantEmailUnsubscribeStore(
            service: ParticipantEmailUnsubscribeService(client: client)
        )
    }

    private var successBody: Data {
        Data(#"{"email":{"unsubscribed":true}}"#.utf8)
    }

    // MARK: - No credential

    /// The dangerous invariant this store must never violate on its own: no
    /// call is attempted, and no arbitrary email or Subscriber ID could ever
    /// be sent, because there is nothing here for a caller to supply besides
    /// the credential itself, and without one nothing is sent at all.
    func testWithNoCredentialNothingIsSentAndVerificationRequiredIsReported() async {
        let store = makeStore()

        await store.turnOffEmailAlerts(authority: nil)

        XCTAssertEqual(store.failure, .verificationRequired)
        XCTAssertFalse(store.emailAlertsOff)
        XCTAssertEqual(ParticipantEmailUnsubscribeURLProtocol.capturedRequests.count, 0)
    }

    // MARK: - Success

    func testSuccessSendsOnlyTheCredentialHeaderAndNoBody() async throws {
        let store = makeStore()
        ParticipantEmailUnsubscribeURLProtocol.enqueue(.response(data: successBody))

        await store.turnOffEmailAlerts(authority: "the-authority-credential")

        XCTAssertTrue(store.emailAlertsOff)
        XCTAssertNil(store.failure)
        let request = try XCTUnwrap(ParticipantEmailUnsubscribeURLProtocol.capturedRequests.last)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/participant/email-alerts/unsubscribe")
        XCTAssertEqual(request.headers["x-commonplate-participant"], "the-authority-credential")
        XCTAssertTrue(request.body?.isEmpty ?? true, "no body is sent — no email or Subscriber ID for a caller to supply")
    }

    /// Off is shown only once, and a repeated call after success is a no-op:
    /// there is nothing left to turn off, and no second request is needed.
    func testEmailAlertsOffIsNotReconfirmedOnASecondCall() async {
        let store = makeStore()
        ParticipantEmailUnsubscribeURLProtocol.enqueue(.response(data: successBody))
        await store.turnOffEmailAlerts(authority: "the-authority-credential")
        XCTAssertTrue(store.emailAlertsOff)

        await store.turnOffEmailAlerts(authority: "the-authority-credential")

        XCTAssertEqual(ParticipantEmailUnsubscribeURLProtocol.capturedRequests.count, 1)
    }

    // MARK: - Failure mapping

    func testAuthorityInvalidCodeMapsToAuthorityInvalidFailure() async {
        let store = makeStore()
        let body = Data(#"{"error":{"code":"PARTICIPANT_AUTHORITY_INVALID","message":"x","fields":null}}"#.utf8)
        ParticipantEmailUnsubscribeURLProtocol.enqueue(.response(statusCode: 401, data: body))

        await store.turnOffEmailAlerts(authority: "a-stale-credential")

        XCTAssertEqual(store.failure, .authorityInvalid)
        XCTAssertFalse(store.emailAlertsOff)
    }

    func testPausedCodeMapsToPausedFailure() async {
        let store = makeStore()
        let body = Data(#"{"error":{"code":"PUBLIC_ACTIONS_PAUSED","message":"x","fields":null}}"#.utf8)
        ParticipantEmailUnsubscribeURLProtocol.enqueue(.response(statusCode: 503, data: body))

        await store.turnOffEmailAlerts(authority: "the-authority-credential")

        XCTAssertEqual(store.failure, .paused)
        XCTAssertFalse(store.emailAlertsOff)
    }

    func testRateLimitedStatusMapsToRateLimitedFailure() async {
        let store = makeStore()
        ParticipantEmailUnsubscribeURLProtocol.enqueue(.response(statusCode: 429, data: Data()))

        await store.turnOffEmailAlerts(authority: "the-authority-credential")

        XCTAssertEqual(store.failure, .rateLimited)
        XCTAssertFalse(store.emailAlertsOff)
    }

    /// A transport-level loss is safe to retry — unlike push, this operation
    /// is idempotent and declarative in one direction only — but must still
    /// never be presented as a confirmed Off.
    func testTransportFailureMapsToUnavailableAndNeverClaimsOff() async {
        let store = makeStore()
        ParticipantEmailUnsubscribeURLProtocol.enqueue(.failure(.notConnectedToInternet))

        await store.turnOffEmailAlerts(authority: "the-authority-credential")

        XCTAssertEqual(store.failure, .unavailable)
        XCTAssertFalse(store.emailAlertsOff)
    }

    /// Explicit retry after an unavailable outcome can still succeed, exactly
    /// like the existing signup and push recovery patterns.
    func testRetryingAfterUnavailableCanSucceed() async {
        let store = makeStore()
        ParticipantEmailUnsubscribeURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.turnOffEmailAlerts(authority: "the-authority-credential")
        XCTAssertEqual(store.failure, .unavailable)

        ParticipantEmailUnsubscribeURLProtocol.enqueue(.response(data: successBody))
        await store.turnOffEmailAlerts(authority: "the-authority-credential")

        XCTAssertTrue(store.emailAlertsOff)
        XCTAssertNil(store.failure)
    }

    // MARK: - Reset (W3-N2 independent-review correction)

    /// `reset()` is what `AlertSignupView`'s `Use a different email` action
    /// calls alongside `AlertSubscriptionStore.useDifferentEmail()`, so a
    /// confirmed Off from the address just left behind cannot be shown for
    /// whatever signup comes next.
    func testResetReturnsEmailAlertsOffToFalse() async {
        let store = makeStore()
        ParticipantEmailUnsubscribeURLProtocol.enqueue(.response(data: successBody))
        await store.turnOffEmailAlerts(authority: "the-authority-credential")
        XCTAssertTrue(store.emailAlertsOff)

        store.reset()

        XCTAssertFalse(store.emailAlertsOff)
    }

    /// A stale failure message (from the address just left behind) must not
    /// linger either.
    func testResetClearsAStaleFailure() async {
        let store = makeStore()
        ParticipantEmailUnsubscribeURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.turnOffEmailAlerts(authority: "the-authority-credential")
        XCTAssertEqual(store.failure, .unavailable)

        store.reset()

        XCTAssertNil(store.failure)
    }

    /// After `reset()`, the action is fully usable again for the next
    /// signup's own address — not permanently disabled by the prior Off.
    func testAfterResetTurnOffEmailAlertsCanBeUsedAgain() async {
        let store = makeStore()
        ParticipantEmailUnsubscribeURLProtocol.enqueue(.response(data: successBody))
        await store.turnOffEmailAlerts(authority: "first-address-authority")
        store.reset()

        ParticipantEmailUnsubscribeURLProtocol.enqueue(.response(data: successBody))
        await store.turnOffEmailAlerts(authority: "second-address-authority")

        XCTAssertTrue(store.emailAlertsOff)
        XCTAssertEqual(ParticipantEmailUnsubscribeURLProtocol.capturedRequests.count, 2)
    }

    /// The race `reset()` exists to close: a request already in flight when
    /// the screen moves on must not apply its outcome afterwards and
    /// resurrect Off for a lifecycle the screen has already left.
    func testResetInvalidatesAStillInFlightAttemptSoALateSuccessCannotReapplyOff() async {
        let store = makeStore()
        ParticipantEmailUnsubscribeURLProtocol.enqueue(.response(data: successBody, delay: 0.2))

        let attempt = Task { await store.turnOffEmailAlerts(authority: "the-authority-credential") }
        try? await Task.sleep(nanoseconds: 20_000_000)
        store.reset()

        await attempt.value

        XCTAssertFalse(
            store.emailAlertsOff,
            "a result from before reset() must not reapply Off after the screen moved on"
        )
        XCTAssertNil(store.failure)
    }

    /// Same race, for a failure arriving after `reset()`: it must not leave a
    /// stale failure message behind either.
    func testResetInvalidatesAStillInFlightAttemptSoALateFailureCannotReapply() async {
        let store = makeStore()
        ParticipantEmailUnsubscribeURLProtocol.enqueue(
            .response(statusCode: 401, data: Data(#"{"error":{"code":"PARTICIPANT_AUTHORITY_INVALID","message":"x","fields":null}}"#.utf8), delay: 0.2)
        )

        let attempt = Task { await store.turnOffEmailAlerts(authority: "a-stale-credential") }
        try? await Task.sleep(nanoseconds: 20_000_000)
        store.reset()

        await attempt.value

        XCTAssertNil(store.failure, "a failure from before reset() must not reapply after the screen moved on")
        XCTAssertFalse(store.emailAlertsOff)
    }

    /// A stale attempt (A) started before `reset()` must not clear
    /// `isUnsubscribing` when it finishes after a newer attempt (B), started
    /// after `reset()`, is still genuinely in flight — otherwise the busy
    /// indicator would go false, and the button would re-enable, while a
    /// real request is still outstanding.
    func testStaleAttemptCompletingAfterResetDoesNotClearIsUnsubscribingWhileANewerAttemptIsStillInFlight() async {
        let store = makeStore()
        ParticipantEmailUnsubscribeURLProtocol.enqueue(.response(data: successBody, delay: 0.1))

        let attemptA = Task { await store.turnOffEmailAlerts(authority: "first-address-authority") }
        try? await Task.sleep(nanoseconds: 20_000_000)
        store.reset()

        ParticipantEmailUnsubscribeURLProtocol.enqueue(.response(data: successBody, delay: 0.2))
        let attemptB = Task { await store.turnOffEmailAlerts(authority: "second-address-authority") }
        try? await Task.sleep(nanoseconds: 20_000_000)

        await attemptA.value

        XCTAssertTrue(
            store.isUnsubscribing,
            "attempt B is still genuinely in flight; a stale attempt A completing after reset() must not clear isUnsubscribing"
        )
        XCTAssertFalse(store.emailAlertsOff)

        await attemptB.value

        XCTAssertFalse(store.isUnsubscribing)
        XCTAssertTrue(store.emailAlertsOff)
        XCTAssertNil(store.failure)
    }
}
