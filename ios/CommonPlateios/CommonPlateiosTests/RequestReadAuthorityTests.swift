import Foundation
import XCTest
@testable import CommonPlateios

/// W4-R5 verified-only request reads, client side.
///
/// `GET /api/requests` and `GET /api/request/:id` now require participant
/// authority. These cases prove the typed classification, that nothing is sent
/// without authority, that only a definitive rejection discards an identity
/// (and only the identity that was actually presented), that an outage is
/// *unknown* rather than a verdict, and that the placement-ambiguity status
/// check never turns a refusal into proof either way.
@MainActor
private final class ReadAuthorityBox {
    var value: String?
    init(_ value: String?) { self.value = value }
}

@MainActor
final class RequestReadAuthorityTests: XCTestCase {
    private let requestID = "meal-a"
    private let authorityA = "64c0000000000000000000a1.1.credential"
    private let authorityB = "64c0000000000000000000b2.1.credential"

    private var rejectedCount = 0

    override func setUp() {
        super.setUp()
        rejectedCount = 0
        ClaimFlowURLProtocol.reset()
    }

    override func tearDown() {
        ClaimFlowURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Classification

    func testClassificationKeepsRefusedAndUnknownApart() {
        func classify(_ error: Error) -> RequestReadClassification {
            RequestReadClassification(error)
        }

        XCTAssertEqual(
            classify(RequestServiceError.participantAuthorityRequired),
            .authorityRequired
        )
        XCTAssertEqual(
            classify(RequestServiceError.serverError(
                code: ParticipantErrorCode.verificationRequired, message: "x"
            )),
            .authorityRequired
        )
        XCTAssertEqual(
            classify(RequestServiceError.serverError(
                code: ParticipantErrorCode.authorityInvalid, message: "x"
            )),
            .authorityInvalid
        )
        // A 503 from the gate, a transport failure, a decode failure and a
        // missing route are all *unknown*: never a revocation, never "required".
        XCTAssertEqual(
            classify(RequestServiceError.serverError(
                code: ParticipantErrorCode.verificationUnavailable, message: "x"
            )),
            .unavailableOrUnknown
        )
        XCTAssertEqual(
            classify(RequestServiceError.transport(underlying: URLError(.timedOut))),
            .unavailableOrUnknown
        )
        XCTAssertEqual(classify(RequestServiceError.notFound), .unavailableOrUnknown)
        XCTAssertEqual(classify(URLError(.notConnectedToInternet)), .unavailableOrUnknown)
    }

    // MARK: - List

    func testListWithoutAuthoritySendsNothingAndIsNeverAnAuthoritativeEmptyList() async {
        let store = makeStore(authority: nil)

        let outcome = await store.fetchRequests()

        XCTAssertEqual(outcome, .didNotSucceed)
        XCTAssertTrue(ClaimFlowURLProtocol.capturedPaths.isEmpty)
        XCTAssertFalse(store.hasSuccessfullyFetchedRequests)
        XCTAssertNotNil(store.initialFetchError)
        XCTAssertEqual(rejectedCount, 0)
    }

    func testDefinitiveRejectionDiscardsTheIdentityThatWasPresentedAndAppliesNoList() async {
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 401,
            data: errorResponse(code: ParticipantErrorCode.authorityInvalid)
        ))
        let store = makeStore(authority: authorityA)

        let outcome = await store.fetchRequests()

        XCTAssertEqual(outcome, .didNotSucceed)
        XCTAssertEqual(rejectedCount, 1)
        XCTAssertFalse(store.hasSuccessfullyFetchedRequests)
        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertNotNil(store.initialFetchError)
        // No verification code is ever requested automatically.
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, ["/api/requests"])
    }

    func testAuthorityRequiredRefusalDoesNotDiscardAnIdentity() async {
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 401,
            data: errorResponse(code: ParticipantErrorCode.verificationRequired)
        ))
        let store = makeStore(authority: authorityA)

        _ = await store.fetchRequests()

        XCTAssertEqual(rejectedCount, 0)
        XCTAssertNotNil(store.initialFetchError)
    }

    func testVerificationOutageAndTransportLossAreUnknownAndDiscardNothing() async {
        for stub in [
            ClaimFlowURLProtocol.Stub.response(
                statusCode: 503,
                data: errorResponse(code: ParticipantErrorCode.verificationUnavailable)
            ),
            .failure(.timedOut),
            .response(data: Data(#"{"unexpected":true}"#.utf8)),
        ] {
            ClaimFlowURLProtocol.reset()
            rejectedCount = 0
            ClaimFlowURLProtocol.enqueue(stub)
            let store = makeStore(authority: authorityA)

            let outcome = await store.fetchRequests()

            XCTAssertEqual(outcome, .didNotSucceed)
            XCTAssertEqual(rejectedCount, 0)
            XCTAssertFalse(store.hasSuccessfullyFetchedRequests)
            XCTAssertNotNil(store.initialFetchError)
            XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, ["/api/requests"])
        }
    }

    func testRefreshFailureKeepsTheLastAuthoritativeListInsteadOfBlankingIt() async {
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([requestObject(id: "a")])))
        let store = makeStore(authority: authorityA)
        _ = await store.fetchRequests()
        XCTAssertEqual(store.requests.map(\.id), ["a"])

        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 503,
            data: errorResponse(code: ParticipantErrorCode.verificationUnavailable)
        ))
        _ = await store.fetchRequests()

        XCTAssertEqual(store.requests.map(\.id), ["a"])
        XCTAssertNotNil(store.refreshError)
        XCTAssertEqual(rejectedCount, 0)
    }

    func testAlreadyParticipatedReadAlsoRefusesEmptyAuthorityBeforeSending() async {
        do {
            _ = try await makeService().fetchAlreadyParticipated(id: requestID, participantAuthority: "")
            XCTFail("expected the service boundary to refuse")
        } catch RequestServiceError.participantAuthorityRequired {
            XCTAssertTrue(ClaimFlowURLProtocol.capturedPaths.isEmpty)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// A rejection of a credential that is no longer current (a newer Change
    /// Email result replaced it while the read was in flight) must not erase
    /// the newer identity.
    func testStaleRejectionNeverDiscardsAReplacedIdentity() async throws {
        let gate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 401,
            data: errorResponse(code: ParticipantErrorCode.authorityInvalid),
            gate: gate
        ))
        let box = ReadAuthorityBox(authorityA)
        let store = makeStore(box: box)

        let fetch = Task { @MainActor in await store.fetchRequests() }
        await waitUntil { gate.isWaiting }
        box.value = authorityB
        gate.open()
        _ = await fetch.value

        XCTAssertEqual(rejectedCount, 0)
        XCTAssertFalse(store.hasSuccessfullyFetchedRequests)
    }

    // MARK: - Ownership and notification tap

    func testOwnershipWithoutAuthorityIsUnresolvedAndSendsNothing() async {
        let store = makeStore(authority: nil)

        let ownership = await store.resolveOwnership(requestID: requestID)

        XCTAssertEqual(ownership, .unresolved)
        XCTAssertTrue(ClaimFlowURLProtocol.capturedPaths.isEmpty)
    }

    func testOwnershipRejectionIsUnresolvedAndAppliesTheDefinitiveVerdict() async {
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 401,
            data: errorResponse(code: ParticipantErrorCode.authorityInvalid)
        ))
        let store = makeStore(authority: authorityA)

        let ownership = await store.resolveOwnership(requestID: requestID)

        XCTAssertEqual(ownership, .unresolved)
        XCTAssertEqual(rejectedCount, 1)
    }

    func testNotificationTapWithoutAuthorityIsUnknownNotUnavailable() async throws {
        let store = makeStore(authority: nil)

        let resolution = try await store.resolveHelperNotificationRequest(id: requestID)

        XCTAssertEqual(resolution, .temporarilyUnavailable)
        XCTAssertTrue(ClaimFlowURLProtocol.capturedPaths.isEmpty)
    }

    func testNotificationTapRefusalAndOutageAreNeverFabricatedAsUnavailable() async throws {
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 401,
            data: errorResponse(code: ParticipantErrorCode.authorityInvalid)
        ))
        let store = makeStore(authority: authorityA)
        let refused = try await store.resolveHelperNotificationRequest(id: requestID)
        XCTAssertEqual(refused, .temporarilyUnavailable)
        XCTAssertEqual(rejectedCount, 1)

        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 503,
            data: errorResponse(code: ParticipantErrorCode.verificationUnavailable)
        ))
        let outage = try await store.resolveHelperNotificationRequest(id: requestID)
        XCTAssertEqual(outage, .temporarilyUnavailable)
        XCTAssertEqual(rejectedCount, 1)
    }

    func testVerifiedNotificationTapKeepsAuthoritativeNotFoundAsUnavailable() async throws {
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 404,
            data: Data(#"{"error":"Request not found"}"#.utf8)
        ))
        let store = makeStore(authority: authorityA)

        let resolution = try await store.resolveHelperNotificationRequest(id: requestID)

        XCTAssertEqual(resolution, .unavailable)
        XCTAssertEqual(rejectedCount, 0)
    }

    // MARK: - Placement-ambiguity status check (C3)

    /// Claims, then loses the fulfillment response, leaving the ambiguity whose
    /// one-shot status read the next stub answers.
    private func ambiguousStore(
        box: ReadAuthorityBox,
        statusStub: ClaimFlowURLProtocol.Stub
    ) async throws -> RequestStore {
        let store = makeStore(box: box)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        ClaimFlowURLProtocol.enqueue(statusStub)
        try? await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )
        return store
    }

    private func assertAmbiguityPreserved(
        _ store: RequestStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertNil(store.fulfillmentConfirmation, "no placed outcome is fabricated", file: file, line: line)
        let ambiguity = try XCTUnwrap(store.fulfillmentAmbiguity, file: file, line: line)
        XCTAssertFalse(ambiguity.isCheckingStatus, file: file, line: line)
        XCTAssertTrue(ambiguity.isRecoveryAvailable, "one-use recovery is untouched", file: file, line: line)
        XCTAssertNotNil(store.activeClaim, "the raw claim stays private and held", file: file, line: line)
    }

    func testStatusCheckPresentsTheCurrentAuthorityAndConfirmsPlacement() async throws {
        let store = try await ambiguousStore(
            box: ReadAuthorityBox(authorityA),
            statusStub: .response(data: detailResponse(status: "placed"))
        )

        XCTAssertNotNil(store.fulfillmentConfirmation)
        XCTAssertNil(store.fulfillmentAmbiguity)
        let statusRead = try XCTUnwrap(ClaimFlowURLProtocol.capturedRequests.last)
        XCTAssertEqual(statusRead.path, "/api/request/\(requestID)")
        XCTAssertEqual(statusRead.headers[RequestService.participantAuthorityHeader], authorityA)
    }

    func testStatusCheckRefusalIsInconclusiveNeitherPlacedNorFailed() async throws {
        let store = try await ambiguousStore(
            box: ReadAuthorityBox(authorityA),
            statusStub: .response(
                statusCode: 401,
                data: errorResponse(code: ParticipantErrorCode.authorityInvalid)
            )
        )

        try assertAmbiguityPreserved(store)
        // The generic definitive-refusal path applies, once; it neither
        // consumes recovery nor clears the ambiguity.
        XCTAssertEqual(rejectedCount, 1)
    }

    func testStatusCheckAuthorityRequiredAndOutageAreInconclusiveAndDiscardNothing() async throws {
        for stub in [
            ClaimFlowURLProtocol.Stub.response(
                statusCode: 401,
                data: errorResponse(code: ParticipantErrorCode.verificationRequired)
            ),
            .response(
                statusCode: 503,
                data: errorResponse(code: ParticipantErrorCode.verificationUnavailable)
            ),
            .failure(.timedOut),
        ] {
            ClaimFlowURLProtocol.reset()
            rejectedCount = 0
            let store = try await ambiguousStore(box: ReadAuthorityBox(authorityA), statusStub: stub)
            try assertAmbiguityPreserved(store)
            XCTAssertEqual(rejectedCount, 0)
        }
    }

    func testStatusCheckWithNoAuthorityIsInconclusiveAndSendsNoStatusRead() async throws {
        let box = ReadAuthorityBox(authorityA)
        let store = makeStore(box: box)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        box.value = nil
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))

        try? await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )

        try assertAmbiguityPreserved(store)
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths,
            ["/api/request/\(requestID)/claim", "/api/request/\(requestID)/fulfill"]
        )
    }

    /// A `placed` answer that lands after the authority it was requested under
    /// changed cannot establish anything for the new principal.
    func testStatusAnswerAfterAnAuthorityChangeIsDiscardedAsInconclusive() async throws {
        let gate = RequestFetchingGate()
        let box = ReadAuthorityBox(authorityA)
        let store = makeStore(box: box)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "placed"), gate: gate))

        let fulfilling = Task { @MainActor in
            try? await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
        }
        await waitUntil { gate.isWaiting }
        box.value = authorityB
        gate.open()
        await fulfilling.value

        try assertAmbiguityPreserved(store)
    }

    // MARK: - Source boundary

    func testTheServiceBoundaryHasNoOptionalAuthorityDefaultOnProtectedReads() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Services/RequestService.swift")
        XCTAssertTrue(source.contains("func fetchActiveRequests(participantAuthority: String)"))
        XCTAssertTrue(source.contains("func fetchRequest(id: String, participantAuthority: String)"))
        XCTAssertFalse(source.contains("fetchActiveRequests(participantAuthority: String? = nil)"))
        XCTAssertFalse(source.contains("fetchRequest(id: String, participantAuthority: String? = nil)"))
    }

    // MARK: - Helpers

    private func makeStore(authority: String?) -> RequestStore {
        makeStore(box: ReadAuthorityBox(authority))
    }

    private func makeStore(box: ReadAuthorityBox) -> RequestStore {
        RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { box.value },
            participantAuthorityRejected: { [weak self] in self?.rejectedCount += 1 }
        )
    }

    private func makeService() -> RequestService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaimFlowURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
        return RequestService(client: client)
    }

    private func errorResponse(code: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"x","fields":null}}"#.utf8)
    }

    private func listResponse(_ objects: [String]) -> Data {
        Data(#"{"requests":[\#(objects.joined(separator: ","))]}"#.utf8)
    }

    private func requestObject(id: String, status: String = "open") -> String {
        """
        {
          "id": "\(id)",
          "vendor": "Crave NYU",
          "food": "Rice bowl",
          "pickupWindowText": "ASAP",
          "mealSwipes": 2,
          "menuPath": "meal-exchange",
          "mealItems": [],
          "orderDetails": null,
          "estimatedDiningDollarsCents": null,
          "windowStart": null,
          "windowEnd": null,
          "status": "\(status)",
          "isOwnRequest": false,
          "createdAt": "2026-07-20T18:30:00.000Z",
          "expiresAt": "\(iso8601String(Date().addingTimeInterval(5 * 60 * 60)))"
        }
        """
    }

    private func detailResponse(status: String) -> Data {
        Data(#"{"request": \#(requestObject(id: requestID, status: status))}"#.utf8)
    }

    private func claimResponse() -> Data {
        Data("""
        {
          "request": \(requestObject(id: requestID, status: "claimed")),
          "claim": {
            "pickupName": "Taylor",
            "claimToken": "claim-token",
            "claimExpiresAt": "\(iso8601String(Date().addingTimeInterval(15 * 60)))"
          }
        }
        """.utf8)
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func waitUntil(
        timeoutIterations: Int = 400,
        condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<timeoutIterations {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition was not reached")
    }

    private func fileSource(_ relativePath: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            let candidate = url.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        throw XCTSkip("source not found: \(relativePath)")
    }
}
