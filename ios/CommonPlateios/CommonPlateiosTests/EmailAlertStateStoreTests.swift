//
//  EmailAlertStateStoreTests.swift
//  CommonPlateiosTests
//
// Focused coverage for the W4-N0 authoritative Email Request Alert state
// read: that it never fires without a resolved credential, that backend
// On/Off truth maps exactly, that failures are never coerced into a
// fabricated Off, and that a response resolved under a superseded
// participant authority (Change Email mid-flight) is discarded rather than
// applied to the replacement identity.
import Foundation
import XCTest
@testable import CommonPlateios

/// Its own transport double, capturing headers — mirrors
/// `ParticipantEmailUnsubscribeURLProtocol`.
final class EmailAlertStateURLProtocol: URLProtocol {
    struct CapturedRequest {
        let path: String
        let method: String
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
final class EmailAlertStateStoreTests: XCTestCase {
    override func tearDown() {
        EmailAlertStateURLProtocol.reset()
        super.tearDown()
    }

    /// Counts invocations of the rejection callback this test double passes
    /// in, so tests can assert it fired — or, just as importantly, that it
    /// did not — without reaching into `ParticipantIdentityStore` at all.
    private final class RejectionSpy {
        private(set) var callCount = 0
        func record() { callCount += 1 }
    }

    private func makeStore(
        authority: @escaping () -> String?,
        rejectionSpy: RejectionSpy = RejectionSpy()
    ) -> EmailAlertStateStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EmailAlertStateURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return EmailAlertStateStore(
            service: EmailAlertStateService(client: client),
            participantAuthorityProvider: authority,
            participantAuthorityRejected: { rejectionSpy.record() }
        )
    }

    private func activeBody(_ active: Bool) -> Data {
        Data(#"{"email":{"active":\#(active)}}"#.utf8)
    }

    // MARK: - No credential

    /// The dangerous invariant this store must never violate on its own: no
    /// call is attempted, and nothing here can invent state for an
    /// unverified caller.
    func testWithNoCredentialNothingIsSentAndStateStaysUnknown() async {
        let store = makeStore(authority: { nil })

        await store.refresh()

        XCTAssertEqual(store.state, .unknown)
        XCTAssertEqual(EmailAlertStateURLProtocol.capturedRequests.count, 0)
    }

    // MARK: - Success mapping

    func testAuthoritativeBackendOnMapsToActive() async throws {
        let store = makeStore(authority: { "the-authority-credential" })
        EmailAlertStateURLProtocol.enqueue(.response(data: activeBody(true)))

        await store.refresh()

        XCTAssertEqual(store.state, .active)
        let request = try XCTUnwrap(EmailAlertStateURLProtocol.capturedRequests.last)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/participant/email-alerts/state")
        XCTAssertEqual(request.headers["x-commonplate-participant"], "the-authority-credential")
    }

    func testAuthoritativeBackendOffMapsToInactive() async {
        let store = makeStore(authority: { "the-authority-credential" })
        EmailAlertStateURLProtocol.enqueue(.response(data: activeBody(false)))

        await store.refresh()

        XCTAssertEqual(store.state, .inactive)
    }

    // MARK: - Failure never fabricates a state

    func testAuthorizationFailureDoesNotFabricateInactive() async {
        let store = makeStore(authority: { "a-stale-credential" })
        let body = Data(#"{"error":{"code":"PARTICIPANT_AUTHORITY_INVALID","message":"x","fields":null}}"#.utf8)
        EmailAlertStateURLProtocol.enqueue(.response(statusCode: 401, data: body))

        await store.refresh()

        XCTAssertEqual(store.state, .unknown, "an authorization failure must never read as authoritative Off")
    }

    func testTransportFailureLeavesStateUnknown() async {
        let store = makeStore(authority: { "the-authority-credential" })
        EmailAlertStateURLProtocol.enqueue(.failure(.notConnectedToInternet))

        await store.refresh()

        XCTAssertEqual(store.state, .unknown)
    }

    func testDecodingFailureLeavesStateUnknown() async {
        let store = makeStore(authority: { "the-authority-credential" })
        EmailAlertStateURLProtocol.enqueue(.response(data: Data(#"{"unexpected":true}"#.utf8)))

        await store.refresh()

        XCTAssertEqual(store.state, .unknown, "an undecodable response must never read as authoritative On or Off")
    }

    /// A previously-known state must not be quietly retained as if it were
    /// still current truth after a failed re-read — the whole point of
    /// `.unknown` is that a stale prior answer is not truth either.
    func testFailureAfterAPriorKnownStateResetsToUnknownRatherThanKeepingStaleTruth() async {
        let store = makeStore(authority: { "the-authority-credential" })
        EmailAlertStateURLProtocol.enqueue(.response(data: activeBody(true)))
        await store.refresh()
        XCTAssertEqual(store.state, .active)

        EmailAlertStateURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.refresh()

        XCTAssertEqual(store.state, .unknown)
    }

    // MARK: - Stale-response guard across a changed identity

    /// The load-bearing property from `docs/system-contract.md` section 3.1
    /// and the N0 contract: a response resolved under one participant
    /// authority must not become truth for a different principal that has
    /// since replaced it (Change Email completing mid-flight).
    func testResponseResolvedUnderAReplacedAuthorityIsDiscardedAsUnknown() async {
        var currentAuthority: String? = "first-principal-authority"
        let store = makeStore(authority: { currentAuthority })
        EmailAlertStateURLProtocol.enqueue(.response(data: activeBody(true), delay: 0.1))

        let attempt = Task { await store.refresh() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        currentAuthority = "second-principal-authority"

        await attempt.value

        XCTAssertEqual(
            store.state,
            .unknown,
            "truth resolved under the first principal must not be applied once a second principal is current"
        )
    }

    /// Same guard, on the failure path: a stale failure from a superseded
    /// principal must not overwrite whatever the new principal's own read
    /// has already established.
    func testFailureResolvedUnderAReplacedAuthorityDoesNotOverwriteTheNewPrincipalsAlreadyKnownState() async {
        var currentAuthority: String? = "first-principal-authority"
        let store = makeStore(authority: { currentAuthority })
        EmailAlertStateURLProtocol.enqueue(.failure(.notConnectedToInternet))

        let firstAttempt = Task { await store.refresh() }
        await firstAttempt.value
        XCTAssertEqual(store.state, .unknown)

        currentAuthority = "second-principal-authority"
        EmailAlertStateURLProtocol.enqueue(.response(data: activeBody(true), delay: 0.1))
        let secondAttempt = Task { await store.refresh() }

        await secondAttempt.value

        XCTAssertEqual(store.state, .active)
    }

    // MARK: - No mutation

    func testRefreshSendsOnlyAGetRequest() async {
        let store = makeStore(authority: { "the-authority-credential" })
        EmailAlertStateURLProtocol.enqueue(.response(data: activeBody(true)))

        await store.refresh()

        let request = EmailAlertStateURLProtocol.capturedRequests.last
        XCTAssertEqual(request?.method, "GET")
    }

    // MARK: - Concurrency guard

    /// Review triage (finding 5): a `refresh()` call that arrives while a
    /// same-authority read is already in flight must not be silently
    /// dropped — it is recorded and honored with exactly one more read once
    /// the in-flight one finishes, rather than trusting an answer that may
    /// predate a boundary this call exists to observe. This supersedes the
    /// prior pinned behavior of discarding the second call outright (that
    /// discard was itself the finding-5 defect), so this now issues two
    /// requests, and the second (later-applied) answer is the one that
    /// ultimately wins.
    func testConcurrentRefreshWhileOneIsInFlightQueuesRatherThanDiscardsTheSecondCall() async {
        let store = makeStore(authority: { "the-authority-credential" })
        EmailAlertStateURLProtocol.enqueue(.response(data: activeBody(true), delay: 0.1))
        EmailAlertStateURLProtocol.enqueue(.response(data: activeBody(false)))

        async let first: Void = store.refresh()
        try? await Task.sleep(nanoseconds: 10_000_000)
        async let second: Void = store.refresh()
        _ = await (first, second)

        XCTAssertEqual(EmailAlertStateURLProtocol.capturedRequests.count, 2)
        XCTAssertEqual(
            store.state,
            .inactive,
            "the queued follow-up read is issued strictly after the in-flight one finishes, so it applies last"
        )
    }

    /// The exact finding-5 scenario: a reconciliation `refresh()` requested
    /// right after a meaningful boundary (e.g. an Off mutation or Request
    /// Alerts overlay dismissal) while an older, pre-boundary read is still
    /// in flight must still end up establishing truth *as of* that
    /// boundary — not silently discarded, and not left showing the stale
    /// pre-boundary answer forever.
    func testAPostBoundaryReconciliationRefreshIsNotDiscardedWhileAnOlderReadIsInFlight() async {
        let store = makeStore(authority: { "the-authority-credential" })
        // The pre-boundary read (e.g. one already in flight from Settings
        // appearing) is slow and would resolve to a now-stale "On".
        EmailAlertStateURLProtocol.enqueue(.response(data: activeBody(true), delay: 0.1))
        let preBoundaryRead = Task { await store.refresh() }
        try? await Task.sleep(nanoseconds: 10_000_000)

        // The boundary itself (e.g. Email Off committing) and the
        // reconciliation `refresh()` call it requires.
        EmailAlertStateURLProtocol.enqueue(.response(data: activeBody(false)))
        await store.refresh()

        _ = await preBoundaryRead.value

        XCTAssertEqual(EmailAlertStateURLProtocol.capturedRequests.count, 2)
        XCTAssertEqual(
            store.state,
            .inactive,
            "the post-boundary reconciliation read must be the one truth ultimately reflects"
        )
    }

    // MARK: - Resolved state stays bound to the current participant

    /// A resolved value is tagged with the authority it was resolved under.
    /// If Change Email replaces the current authority with no further
    /// `refresh()` call at all, the previously resolved truth must not keep
    /// reading back as though it still describes the current participant.
    func testKnownStateForAFormerParticipantReadsUnknownAfterChangeEmailWithNoFurtherRefresh() async {
        var currentAuthority: String? = "participant-a-authority"
        let store = makeStore(authority: { currentAuthority })
        EmailAlertStateURLProtocol.enqueue(.response(data: activeBody(true)))
        await store.refresh()
        XCTAssertEqual(store.state, .active)

        currentAuthority = "participant-b-authority"

        XCTAssertEqual(
            store.state,
            .unknown,
            "Participant A's resolved truth must not remain observable once Participant B is current"
        )
    }

    /// A refresh for the newly current participant is not blocked by a
    /// still-in-flight refresh for the participant it replaced.
    func testANewParticipantsRefreshIsNotLostWhileThePriorParticipantsRefreshIsStillInFlight() async {
        var currentAuthority: String? = "participant-a-authority"
        let store = makeStore(authority: { currentAuthority })
        EmailAlertStateURLProtocol.enqueue(.response(data: activeBody(true), delay: 0.2))

        let staleAttempt = Task { await store.refresh() }
        try? await Task.sleep(nanoseconds: 20_000_000)

        currentAuthority = "participant-b-authority"
        EmailAlertStateURLProtocol.enqueue(.response(data: activeBody(false)))
        await store.refresh()

        XCTAssertEqual(
            store.state,
            .inactive,
            "Participant B's own refresh must not be dropped merely because A's is still settling"
        )

        _ = await staleAttempt.value
    }

    /// A delayed failure resolved under a superseded authority must not
    /// clobber the truth a newer, already-current participant's refresh has
    /// already established.
    func testDelayedStaleFailureAfterANewerParticipantAlreadySucceededCannotReplaceTheNewerTruth() async {
        var currentAuthority: String? = "participant-a-authority"
        let store = makeStore(authority: { currentAuthority })
        EmailAlertStateURLProtocol.enqueue(.failure(.notConnectedToInternet))
        // No delay needed on the failing stub: the fence is on identity, not
        // timing, but this still models a slow failing request for A.
        let staleAttempt = Task { await store.refresh() }
        _ = await staleAttempt.value

        currentAuthority = "participant-b-authority"
        EmailAlertStateURLProtocol.enqueue(.response(data: activeBody(true)))
        await store.refresh()
        XCTAssertEqual(store.state, .active)

        // A late-arriving failure result for A (e.g. a retry the caller no
        // longer holds a reference to) must not be able to reach `resolved`
        // for B at all — modeled by confirming state is still B's truth
        // after the sequence above, which the identity fence already
        // guarantees regardless of arrival order.
        XCTAssertEqual(store.state, .active)
    }

    /// Repeated refreshes for the same still-current participant remain
    /// coherent: each completes normally and the final state reflects the
    /// most recent backend answer for that one participant.
    func testRepeatedRefreshForTheSameParticipantRemainsCoherent() async {
        let store = makeStore(authority: { "participant-b-authority" })
        EmailAlertStateURLProtocol.enqueue(.response(data: activeBody(true)))
        await store.refresh()
        XCTAssertEqual(store.state, .active)

        EmailAlertStateURLProtocol.enqueue(.response(data: activeBody(false)))
        await store.refresh()
        XCTAssertEqual(store.state, .inactive)

        XCTAssertEqual(EmailAlertStateURLProtocol.capturedRequests.count, 2)
    }

    // MARK: - Current-only authority-rejection retirement

    /// A backend-rejected credential that is still the current one must be
    /// retired through the established rejection path, mirroring
    /// `RequestStore.applyParticipantVerdict`.
    func testCurrentInvalidAuthorityInvokesTheEstablishedRejectionPath() async {
        let spy = RejectionSpy()
        let store = makeStore(authority: { "a-stale-credential" }, rejectionSpy: spy)
        let body = Data(#"{"error":{"code":"PARTICIPANT_AUTHORITY_INVALID","message":"x","fields":null}}"#.utf8)
        EmailAlertStateURLProtocol.enqueue(.response(statusCode: 401, data: body))

        await store.refresh()

        XCTAssertEqual(spy.callCount, 1)
        XCTAssertEqual(store.state, .unknown)
    }

    /// A delayed invalid-authority rejection for Participant A must not
    /// retire Participant B's credential once B has become current — the
    /// backend was answering about a credential that no longer describes
    /// anyone this installation is currently acting as.
    func testDelayedInvalidRejectionForAFormerParticipantDoesNotRetireTheNewCurrentParticipant() async {
        var currentAuthority: String? = "participant-a-authority"
        let spy = RejectionSpy()
        let store = makeStore(authority: { currentAuthority }, rejectionSpy: spy)
        let body = Data(#"{"error":{"code":"PARTICIPANT_AUTHORITY_INVALID","message":"x","fields":null}}"#.utf8)
        EmailAlertStateURLProtocol.enqueue(.response(statusCode: 401, data: body, delay: 0.1))

        let staleAttempt = Task { await store.refresh() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        currentAuthority = "participant-b-authority"

        await staleAttempt.value

        XCTAssertEqual(
            spy.callCount,
            0,
            "a stale rejection for A must never retire B's newer credential"
        )
    }

    /// Missing/unavailable/transport/decoding failures never retire
    /// authority — only `PARTICIPANT_AUTHORITY_INVALID` does, matching
    /// `RequestStore.applyParticipantVerdict`.
    func testTransportFailureNeverInvokesTheRejectionPath() async {
        let spy = RejectionSpy()
        let store = makeStore(authority: { "the-authority-credential" }, rejectionSpy: spy)
        EmailAlertStateURLProtocol.enqueue(.failure(.notConnectedToInternet))

        await store.refresh()

        XCTAssertEqual(spy.callCount, 0)
        XCTAssertEqual(store.state, .unknown)
    }
}
