//
//  RequestEligibilityTests.swift
//  CommonPlateiosTests
//
// Focused coverage for the W4-Q1 bounded participant-authorized read of
// whether the currently verified participant is presently eligible to
// attempt another request under the existing best-effort
// three-per-NYU-campus-day quota. This proves only the
// `APIClient -> RequestService -> RequestStore` authority itself:
// `RequestService.fetchRequestCreationEligibility` and
// `RequestStore.resolveRequestCreationEligibility`, including its
// stale-response/identity-staleness guard, matching the pattern established
// by `RequestDetailStaleParticipationTests.swift` for
// `resolveStaleParticipationEligibility`. `RequestFoodEntryTests.swift`
// proves the W4-R2 requester-entry consumer built on top of this authority.
import Foundation
import XCTest
@testable import CommonPlateios

/// A gate an enqueued stub can wait on before completing, so a test can hold
/// a request genuinely suspended in flight and cancel its `Task` while it is
/// provably still waiting — rather than cancelling a `Task` that has already
/// synchronously finished. Mirrors `RequestFetchingGate`
/// (`RequestFetchingTests.swift`) / the same pattern
/// `ManualRefreshCancellationTests.swift` exercises real cancellation with.
final class RequestEligibilityGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (() -> Void)?
    private var isOpen = false

    var isWaiting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completion != nil
    }

    func wait(_ completion: @escaping () -> Void) {
        lock.lock()
        if isOpen {
            lock.unlock()
            completion()
        } else {
            self.completion = completion
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let completion = completion
        self.completion = nil
        lock.unlock()
        completion?()
    }
}

/// Its own transport double, matching the one-file-one-double convention
/// (`ClaimFlowURLProtocol`, `StaleParticipationURLProtocol`, etc).
final class RequestEligibilityURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let data: Data
        let errorCode: URLError.Code?
        let gate: RequestEligibilityGate?

        static func response(
            statusCode: Int = 200,
            data: Data,
            gate: RequestEligibilityGate? = nil
        ) -> Stub {
            Stub(statusCode: statusCode, data: data, errorCode: nil, gate: gate)
        }

        static func failure(_ errorCode: URLError.Code) -> Stub {
            Stub(statusCode: 0, data: Data(), errorCode: errorCode, gate: nil)
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var stubs: [Stub] = []
    private nonisolated(unsafe) static var capturedPaths: [String] = []
    private nonisolated(unsafe) static var capturedHeaders: [[String: String]] = []

    static func enqueue(_ stub: Stub) {
        lock.lock()
        stubs.append(stub)
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        stubs.removeAll()
        capturedPaths.removeAll()
        capturedHeaders.removeAll()
        lock.unlock()
    }

    static var requestedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return capturedPaths
    }

    static var lastCapturedHeaders: [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        return capturedHeaders.last
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
        Self.capturedHeaders.append(request.allHTTPHeaderFields ?? [:])
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
                self.client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
                return
            }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: stub.data)
            self.client?.urlProtocolDidFinishLoading(self)
        }

        if let gate = stub.gate {
            gate.wait(completeRequest)
        } else {
            completeRequest()
        }
    }

    override func stopLoading() {}
}

@MainActor
final class RequestEligibilityTests: XCTestCase {
    override func tearDown() {
        RequestEligibilityURLProtocol.reset()
        super.tearDown()
    }

    private func makeService() -> RequestService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestEligibilityURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return RequestService(client: client)
    }

    private func makeStore(
        service: RequestService,
        participantAuthority: String? = "64c0000000000000000000a1.1.credential",
        onRejection: @escaping () -> Void = {}
    ) -> RequestStore {
        RequestStore(
            service: service,
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { participantAuthority },
            participantAuthorityRejected: onRejection
        )
    }

    /// A store whose `participantAuthorityProvider` returns a different value
    /// on each successive call — models the authoritative identity changing
    /// (e.g. a Change Email completing) between
    /// `resolveRequestCreationEligibility`'s pre-read capture and its
    /// post-read comparison, which are its only two calls to the provider.
    private func makeStoreWithShiftingAuthority(
        service: RequestService,
        authorities: [String],
        onRejection: @escaping () -> Void = {}
    ) -> RequestStore {
        var callCount = 0
        return RequestStore(
            service: service,
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: {
                defer { callCount = min(callCount + 1, authorities.count - 1) }
                return authorities[callCount]
            },
            participantAuthorityRejected: onRejection
        )
    }

    private func eligibilityResponse(_ value: String) -> Data {
        Data("{\"eligibility\":\"\(value)\"}".utf8)
    }

    private func errorResponse(code: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"detail","fields":null}}"#.utf8)
    }

    // MARK: - RequestService.fetchRequestCreationEligibility

    func testFetchRequestCreationEligibilityDecodesEligibleAndSendsTheParticipantHeader() async throws {
        let service = makeService()
        RequestEligibilityURLProtocol.enqueue(.response(data: eligibilityResponse("eligible")))

        let result = try await service.fetchRequestCreationEligibility(
            participantAuthority: "64c0000000000000000000a1.1.credential"
        )

        XCTAssertEqual(result, .eligible)
        XCTAssertEqual(
            RequestEligibilityURLProtocol.requestedPaths,
            ["/api/participant/request-eligibility"]
        )
        XCTAssertNotNil(RequestEligibilityURLProtocol.lastCapturedHeaders?["x-commonplate-participant"])
    }

    func testFetchRequestCreationEligibilityDecodesExhausted() async throws {
        let service = makeService()
        RequestEligibilityURLProtocol.enqueue(.response(data: eligibilityResponse("exhausted")))

        let result = try await service.fetchRequestCreationEligibility(
            participantAuthority: "64c0000000000000000000a1.1.credential"
        )

        XCTAssertEqual(result, .exhausted)
    }

    /// An unrecognized wire value must fail decoding rather than being
    /// silently mapped to a guessed state — matching `RequestStatusWire`.
    func testFetchRequestCreationEligibilityThrowsOnAnUnrecognizedWireValue() async throws {
        let service = makeService()
        RequestEligibilityURLProtocol.enqueue(.response(data: eligibilityResponse("some-future-value")))

        do {
            _ = try await service.fetchRequestCreationEligibility(
                participantAuthority: "64c0000000000000000000a1.1.credential"
            )
            XCTFail("Expected a decoding failure for an unrecognized eligibility value")
        } catch {
            // Any thrown error is correct here; the only wrong outcome is a
            // silently decoded result.
        }
    }

    func testFetchRequestCreationEligibilityPropagatesATransportFailure() async throws {
        let service = makeService()
        RequestEligibilityURLProtocol.enqueue(.failure(.notConnectedToInternet))

        do {
            _ = try await service.fetchRequestCreationEligibility(
                participantAuthority: "64c0000000000000000000a1.1.credential"
            )
            XCTFail("Expected a transport failure to propagate")
        } catch {
            // Expected.
        }
    }

    // MARK: - RequestStore.resolveRequestCreationEligibility

    func testResolvesEligibleFromAuthoritativeBackendTruth() async throws {
        let service = makeService()
        RequestEligibilityURLProtocol.enqueue(.response(data: eligibilityResponse("eligible")))
        let store = makeStore(service: service)

        let result = await store.resolveRequestCreationEligibility()

        XCTAssertEqual(result, .eligible)
    }

    func testResolvesExhaustedFromAuthoritativeBackendTruth() async throws {
        let service = makeService()
        RequestEligibilityURLProtocol.enqueue(.response(data: eligibilityResponse("exhausted")))
        let store = makeStore(service: service)

        let result = await store.resolveRequestCreationEligibility()

        XCTAssertEqual(result, .exhausted)
    }

    /// No participant identity presented at all resolves immediately to
    /// `.unknown` without any network call — there is no principal to ask
    /// about, and unknown must fail closed for a future entry decision.
    func testResolvesUnknownWithoutAnyReadWhenNoParticipantIdentityIsPresented() async throws {
        let service = makeService()
        let store = makeStore(service: service, participantAuthority: nil)

        let result = await store.resolveRequestCreationEligibility()

        XCTAssertEqual(result, .unknown)
        XCTAssertTrue(RequestEligibilityURLProtocol.requestedPaths.isEmpty)
    }

    /// A transport failure must never be treated as eligible — it stays
    /// `.unknown`. `POST /api/request` remains the real backstop regardless.
    func testResolvesUnknownRatherThanEligibleWhenTheReadFailsOnTransport() async throws {
        let service = makeService()
        RequestEligibilityURLProtocol.enqueue(.failure(.notConnectedToInternet))
        let store = makeStore(service: service)

        let result = await store.resolveRequestCreationEligibility()

        XCTAssertEqual(result, .unknown)
    }

    /// A decoding failure (malformed/unrecognized response body) must also
    /// resolve to `.unknown`, never `.eligible`.
    func testResolvesUnknownRatherThanEligibleWhenTheResponseFailsToDecode() async throws {
        let service = makeService()
        RequestEligibilityURLProtocol.enqueue(.response(data: Data("not json".utf8)))
        let store = makeStore(service: service)

        let result = await store.resolveRequestCreationEligibility()

        XCTAssertEqual(result, .unknown)
    }

    /// A server-side authority refusal (e.g. `401 PARTICIPANT_AUTHORITY_INVALID`)
    /// must also resolve to `.unknown`, never `.eligible` or `.exhausted`.
    func testResolvesUnknownWhenTheBackendRefusesAuthority() async throws {
        let service = makeService()
        RequestEligibilityURLProtocol.enqueue(
            .response(
                statusCode: 401,
                data: errorResponse(code: ParticipantErrorCode.authorityInvalid)
            )
        )
        let store = makeStore(service: service)

        let result = await store.resolveRequestCreationEligibility()

        XCTAssertEqual(result, .unknown)
    }

    // MARK: - Authority-retirement verdict (W4-Q1 review fix 2)
    //
    // `resolveRequestCreationEligibility` must feed a current
    // `PARTICIPANT_AUTHORITY_INVALID` refusal into the same
    // `applyParticipantVerdict` / `participantAuthorityRejected` lifecycle
    // every other participant-gated store method already uses (e.g.
    // `RequestStore.createRequest`, per `ParticipantGateTests.swift`), rather
    // than silently discarding it as an unmapped `.unknown`. Every other
    // failure shape must remain a no-op for that lifecycle.

    /// A current `PARTICIPANT_AUTHORITY_INVALID` refusal — for the exact
    /// authority this call itself presented — must invoke the existing
    /// rejection/retirement path.
    func testCurrentAuthorityInvalidRefusalInvokesTheRejectionPath() async throws {
        let service = makeService()
        RequestEligibilityURLProtocol.enqueue(
            .response(
                statusCode: 401,
                data: errorResponse(code: ParticipantErrorCode.authorityInvalid)
            )
        )
        var rejectionCount = 0
        let store = makeStore(service: service) { rejectionCount += 1 }

        let result = await store.resolveRequestCreationEligibility()

        XCTAssertEqual(result, .unknown)
        XCTAssertEqual(rejectionCount, 1)
    }

    /// A stale rejection for an authority a newer Change Email has already
    /// replaced must not retire the replacement: `applyParticipantVerdict`'s
    /// own fence compares the rejected credential against whatever
    /// `participantAuthorityProvider` reports *now*, which this scenario
    /// makes a different, newer authority than the one presented.
    func testAStaleAuthorityInvalidRejectionCannotRetireANewerReplacementIdentity() async throws {
        let service = makeService()
        RequestEligibilityURLProtocol.enqueue(
            .response(
                statusCode: 401,
                data: errorResponse(code: ParticipantErrorCode.authorityInvalid)
            )
        )
        var rejectionCount = 0
        // The provider reports the presented (soon-to-be-stale) authority for
        // the pre-read capture, then the *replacement* authority for every
        // subsequent call — modeling a Change Email completing while this
        // exact read was in flight.
        let store = makeStoreWithShiftingAuthority(
            service: service,
            authorities: ["authority-before-change-email", "authority-after-change-email"],
            onRejection: { rejectionCount += 1 }
        )

        let result = await store.resolveRequestCreationEligibility()

        XCTAssertEqual(result, .unknown)
        XCTAssertEqual(rejectionCount, 0)
    }

    /// A transport failure must not retire identity — only a current
    /// `PARTICIPANT_AUTHORITY_INVALID` server refusal may.
    func testTransportFailureDoesNotRetireIdentity() async throws {
        let service = makeService()
        RequestEligibilityURLProtocol.enqueue(.failure(.notConnectedToInternet))
        var rejectionCount = 0
        let store = makeStore(service: service) { rejectionCount += 1 }

        let result = await store.resolveRequestCreationEligibility()

        XCTAssertEqual(result, .unknown)
        XCTAssertEqual(rejectionCount, 0)
    }

    /// A decoding failure must not retire identity.
    func testDecodingFailureDoesNotRetireIdentity() async throws {
        let service = makeService()
        RequestEligibilityURLProtocol.enqueue(.response(data: Data("not json".utf8)))
        var rejectionCount = 0
        let store = makeStore(service: service) { rejectionCount += 1 }

        let result = await store.resolveRequestCreationEligibility()

        XCTAssertEqual(result, .unknown)
        XCTAssertEqual(rejectionCount, 0)
    }

    /// Cancellation must not retire identity. No participant authority is
    /// presented at all here, which is itself one of the ways this method
    /// never reaches the network — and, more generally, never reaches
    /// `applyParticipantVerdict` with anything but a `.serverError` case.
    /// Rereview fix 2: cancellation supplying no authority at all merely
    /// proves the no-authority short-circuit never calls the network — it
    /// does not prove real mid-flight cancellation is handled correctly.
    /// This holds a genuinely suspended in-flight read (via
    /// `RequestEligibilityGate`, the same technique
    /// `ManualRefreshCancellationTests.swift` uses at the `RequestService`
    /// boundary) with a valid current participant authority, cancels the
    /// `Task` while it is provably still waiting on the transport, and
    /// proves the result is `.unknown` and that cancellation is not
    /// misclassified as `PARTICIPANT_AUTHORITY_INVALID` — the only case that
    /// would have wrongly retired identity.
    func testCancellationDoesNotRetireIdentity() async throws {
        let service = makeService()
        let gate = RequestEligibilityGate()
        RequestEligibilityURLProtocol.enqueue(
            .response(data: eligibilityResponse("eligible"), gate: gate)
        )
        var rejectionCount = 0
        let store = makeStore(service: service) { rejectionCount += 1 }

        let task = Task { await store.resolveRequestCreationEligibility() }
        await waitUntil { gate.isWaiting }

        task.cancel()
        let result = await task.value
        gate.open()

        XCTAssertEqual(result, .unknown)
        XCTAssertEqual(rejectionCount, 0)
    }

    private func waitUntil(
        timeoutIterations: Int = 100,
        condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<timeoutIterations {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }

    /// An unrelated server refusal (e.g. `503 PARTICIPANT_VERIFICATION_UNAVAILABLE`)
    /// must not retire identity — only the specific `PARTICIPANT_AUTHORITY_INVALID`
    /// code does, matching `applyParticipantVerdict`'s own guard everywhere
    /// else it is used.
    func testAnUnrelatedServerFailureDoesNotRetireIdentity() async throws {
        let service = makeService()
        RequestEligibilityURLProtocol.enqueue(
            .response(
                statusCode: 503,
                data: errorResponse(code: "PARTICIPANT_VERIFICATION_UNAVAILABLE")
            )
        )
        var rejectionCount = 0
        let store = makeStore(service: service) { rejectionCount += 1 }

        let result = await store.resolveRequestCreationEligibility()

        XCTAssertEqual(result, .unknown)
        XCTAssertEqual(rejectionCount, 0)
    }

    /// The identity-staleness guard: the authority in effect when the read
    /// started differs from the authority in effect when it completed (a
    /// Change Email finished mid-read). The result belongs to a principal
    /// that is no longer authoritative and must be discarded as `.unknown`,
    /// never silently applied to the replacement identity — matching
    /// `resolveStaleParticipationEligibility`'s own guard.
    func testDiscardsAResultResolvedForAnAuthorityThatChangedWhileTheReadWasInFlight() async throws {
        let service = makeService()
        RequestEligibilityURLProtocol.enqueue(.response(data: eligibilityResponse("eligible")))
        let store = makeStoreWithShiftingAuthority(
            service: service,
            authorities: ["authority-before-change-email", "authority-after-change-email"]
        )

        let result = await store.resolveRequestCreationEligibility()

        XCTAssertEqual(result, .unknown)
    }

    /// The unchanged-identity path must still resolve normally — the guard
    /// above must not make every read `.unknown`.
    func testAppliesTheResultWhenTheAuthorityIsUnchangedAcrossTheRead() async throws {
        let service = makeService()
        RequestEligibilityURLProtocol.enqueue(.response(data: eligibilityResponse("exhausted")))
        let store = makeStoreWithShiftingAuthority(
            service: service,
            authorities: ["stable-authority", "stable-authority"]
        )

        let result = await store.resolveRequestCreationEligibility()

        XCTAssertEqual(result, .exhausted)
    }
}
