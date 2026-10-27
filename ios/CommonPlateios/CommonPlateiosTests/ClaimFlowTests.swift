import Foundation
import XCTest
@testable import CommonPlateios

/// Isolated transport stub for claim and fulfillment tests; its private queue
/// prevents cross-suite stub consumption.
final class ClaimFlowURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let data: Data
        let errorCode: URLError.Code?
        let gate: RequestFetchingGate?

        static func response(
            statusCode: Int = 200,
            data: Data,
            gate: RequestFetchingGate? = nil
        ) -> Stub {
            Stub(statusCode: statusCode, data: data, errorCode: nil, gate: gate)
        }

        static func failure(_ errorCode: URLError.Code, gate: RequestFetchingGate? = nil) -> Stub {
            Stub(statusCode: 0, data: Data(), errorCode: errorCode, gate: gate)
        }
    }

    struct CapturedRequest {
        let path: String
        let method: String
        let body: Data?
        let headers: [String: String]

        var bodyObject: [String: Any]? {
            guard let body else { return nil }
            return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
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

    static var capturedPaths: [String] {
        capturedRequests.map(\.path)
    }

    private static func dequeue() -> Stub? {
        lock.lock()
        defer { lock.unlock() }
        guard !stubs.isEmpty else { return nil }
        return stubs.removeFirst()
    }

    /// `URLProtocol` receives the body as a stream once the request has been
    /// handed to the loading system, so `httpBody` alone would silently capture
    /// nothing for the extension POST.
    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1_024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if answerOperationLedgerReadIfNeeded() { return }
        Self.lock.lock()
        Self.captured.append(
            CapturedRequest(
                path: request.url?.path ?? "",
                method: request.httpMethod ?? "",
                body: Self.readBody(from: request),
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

        if let gate = stub.gate {
            gate.wait(completeRequest)
        } else {
            completeRequest()
        }
    }

    override func stopLoading() {}
}

@MainActor
final class ClaimFlowTests: XCTestCase {
    enum TestHelperError: Error {
        case markerNotFound
    }

    private let requestID = "meal-a"

    /// The one sentence that stops a second real-world order. It is reproduced
    /// verbatim — never paraphrased — in every state where another Grubhub
    /// order would cost a student money, so it is asserted from one constant.
    static let safetySentence = "Don’t place another Grubhub order."

    /// Re-submitting to CommonPlate is safe wherever the backend would answer a
    /// repeat with REQUEST_ALREADY_PLACED. Where that retry is offered, the copy
    /// must separate it from ordering again.
    static let inAppRetryDisclaimer =
        "Trying again here only updates \(AppBrand.name). It does not place another Grubhub order."

    override func tearDown() {
        ClaimFlowURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Status vocabulary

    func testCurrentBackendListVocabularyDecodesAsOpen() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a", status: "open"),
            requestObject(id: "b", status: "open")
        ])))

        let requests = try await makeService().fetchActiveRequests(participantAuthority: "64c0000000000000000000a1.1.credential")

        XCTAssertEqual(requests.map(\.id), ["a", "b"])
        XCTAssertEqual(requests.map(\.status), [.open, .open])
    }

    func testClaimedAndPlacedWireValuesStillDecode() throws {
        XCTAssertEqual(try decodeStatus("open"), .open)
        XCTAssertEqual(try decodeStatus("claimed"), .claimed)
        XCTAssertEqual(try decodeStatus("placed"), .placed)
    }

    /// The superseded value is no longer part of the contract. It must fail to
    /// decode rather than quietly mapping to `.open`, which would let a stale
    /// backend look healthy.
    func testSupersededRequestedWireValueIsRejected() {
        XCTAssertThrowsError(try decodeStatus("requested"))
    }

    func testListFetchWithCurrentVocabularyDoesNotPublishAnError() async {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a", status: "open")
        ])))

        await store.fetchRequests()

        XCTAssertTrue(store.hasSuccessfullyFetchedRequests)
        XCTAssertNil(store.initialFetchError)
        XCTAssertEqual(store.requests.map(\.status), [.open])
    }

    // MARK: - Starting a claim

    func testTappingHelpSendsExactlyOneClaimRequest() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))

        try await store.claim(requestID: requestID)

        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedRequests.map(\.path),
            ["/api/request/\(requestID)/claim"]
        )
        XCTAssertEqual(ClaimFlowURLProtocol.capturedRequests.map(\.method), ["POST"])
    }

    func testRepeatedTapsWhileClaimingDoNotSendDuplicateClaims() async throws {
        let store = makeStore()
        let claimGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(), gate: claimGate))

        let firstClaim = Task { try await store.claim(requestID: requestID) }
        await waitUntil { claimGate.isWaiting }
        XCTAssertTrue(store.isClaiming)

        for _ in 0..<3 {
            do {
                try await store.claim(requestID: requestID)
                XCTFail("A duplicate claim should not start")
            } catch RequestServiceError.operationInProgress {
                // Expected: rejected before any request is built.
            } catch {
                XCTFail("Unexpected duplicate-claim error: \(error)")
            }
        }

        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.count, 1)

        claimGate.open()
        try await firstClaim.value

        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.count, 1)
        XCTAssertFalse(store.isClaiming)
    }

    func testNoNavigationAndNoPickupNameBeforeConfirmedSuccess() async throws {
        let store = makeStore()
        let claimGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(), gate: claimGate))

        let claim = Task { try await store.claim(requestID: requestID) }
        await waitUntil { claimGate.isWaiting }

        // In flight: loading is visible, but nothing claimant-private exists yet.
        XCTAssertTrue(store.isClaiming)
        XCTAssertNil(store.activeClaim)
        XCTAssertFalse(
            RequestDetailView.opensClaimedFlow(
                activeClaim: store.activeClaim,
                requestID: requestID
            )
        )

        claimGate.open()
        try await claim.value

        XCTAssertTrue(
            RequestDetailView.opensClaimedFlow(
                activeClaim: store.activeClaim,
                requestID: requestID
            )
        )
    }

    func testConfirmedClaimRevealsPickupNameAndOpensTheFulfillmentFlow() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(pickupName: "Taylor")))

        try await store.claim(requestID: requestID)

        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(claim.requestID, requestID)
        XCTAssertFalse(String(describing: claim).contains("Taylor"))
        XCTAssertEqual(store.requests.first?.status, .claimed)
        XCTAssertTrue(
            RequestDetailView.opensClaimedFlow(activeClaim: claim, requestID: requestID)
        )
        // A different request's screen must not open on someone else's claim.
        XCTAssertFalse(
            RequestDetailView.opensClaimedFlow(activeClaim: claim, requestID: "other-meal")
        )
    }

    /// W3-C1 continuity: the exact meal-swipe quantity the claim response
    /// returns survives, unchanged, into `activeClaim.request` — the same
    /// `FoodRequest` the active-reservation presentation and the fulfillment
    /// flow both read from. A distinctive value (4, not the file's usual
    /// default of 2) proves this is the claim response's own value flowing
    /// through, not a coincidental default.
    func testConfirmedClaimCarriesTheExactMealSwipeQuantityIntoActiveClaimRequest() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(
            .response(data: claimResponse(pickupName: "Taylor", mealSwipes: 4))
        )

        try await store.claim(requestID: requestID)

        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(claim.request.mealSwipes, 4)
        // The same request also reaches the public collection's own entry,
        // which `RequestDetailView` and Home both read.
        XCTAssertEqual(store.requests.first?.mealSwipes, 4)
    }

    /// W3-C1 regression: `RequestDetailView` opens fulfillment for the active
    /// claim through `fulfillmentDestination(activeClaim:)`. This proves that function
    /// itself returns the confirmed active claim's own request — not a
    /// value-type copy fetched before the claim existed — using a
    /// distinctive quantity (4) that differs from the pre-claim fetch's 1, so
    /// passing is proof the claim response's own value survived, not a
    /// coincidence of two fixtures sharing a default.
    func testFulfillmentDestinationUsesTheActiveClaimsOwnRequestNotAStalePreClaimCopy() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: requestID, mealSwipes: 1, status: "open")
        ])))
        await store.fetchRequests()
        let preClaimRequest = try XCTUnwrap(store.requests.first)
        XCTAssertEqual(preClaimRequest.mealSwipes, 1)

        ClaimFlowURLProtocol.enqueue(
            .response(data: claimResponse(mealSwipes: 4))
        )
        try await store.claim(requestID: requestID)

        let activeClaim = try XCTUnwrap(store.activeClaim)
        let destination = RequestDetailView.fulfillmentDestination(activeClaim: activeClaim)
        guard case .fulfillment(let deliveredRequest) = destination else {
            XCTFail("Expected a fulfillment destination")
            return
        }
        XCTAssertEqual(deliveredRequest.mealSwipes, 4)
        XCTAssertNotEqual(deliveredRequest.mealSwipes, preClaimRequest.mealSwipes)
    }

    /// Structural proof that `RequestDetailView`'s successful-claim transition
    /// opens Helping with the active claim's own request rather than a
    /// re-introduced `AppRoute.fulfillment(request)` using this screen's stale
    /// pre-claim value-type copy. W4-H1: the transition replaces the detail
    /// through `AppRoute.enteringHeldRequest(activeClaim, from:)`, which builds
    /// `.fulfillment(activeClaim.request)` (proved behaviorally in
    /// `HelperHeldRequestNavigationTests`), and the former Continue Helping
    /// link no longer exists on Request Detail.
    func testRequestDetailViewRoutesBothFulfillmentEntryPointsThroughTheActiveClaimsOwnRequest() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestDetailView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(
            source.contains("AppRoute.fulfillment(request)"),
            "no navigation site may open fulfillment with this screen's pre-claim value-type copy"
        )

        let claimConfirmedOnChange = try sourceSlice(
            of: source,
            from: ".onChange(of: store.activeClaim?.requestID, initial: true)",
            to: ".onChange(of: identityStore.identity)"
        )
        XCTAssertTrue(
            claimConfirmedOnChange.contains(
                "AppRoute.enteringHeldRequest(activeClaim, from: path)"
            ),
            "the immediate successful-claim transition must route through the active claim"
        )

        XCTAssertFalse(
            source.contains("private var continueHelpingLink: some View {"),
            "Request Detail is pre-claim only and has no Continue Helping link"
        )

        // The remaining Go to Active Reservation link still uses the shared
        // active-claim destination.
        let claimSection = try sourceSlice(
            of: source,
            from: "private var claimSection: some View {",
            to: "static let claimActionTitle"
        )
        XCTAssertTrue(
            claimSection.contains("Self.fulfillmentDestination(activeClaim: activeClaim)")
        )
    }

    /// The substring strictly between the first occurrence of `start` and the
    /// following occurrence of `end`. The substring's whitespace is normalized
    /// so assertions about its content are insensitive to indentation or
    /// wrapping — a slice-scoped assertion still holds after reformatting
    /// that leaves the code's actual structure unchanged.
    private func sourceSlice(of source: String, from start: String, to end: String) throws -> String {
        guard let startRange = source.range(of: start) else {
            XCTFail("Expected marker not found in source: \(start)")
            throw TestHelperError.markerNotFound
        }
        guard let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            XCTFail("Expected marker not found in source: \(end)")
            throw TestHelperError.markerNotFound
        }
        let slice = source[startRange.upperBound..<endRange.lowerBound]
        return normalizeWhitespace(String(slice))
    }

    /// Normalize whitespace: collapse internal runs to single spaces, preserve
    /// semantic structure for assertions about function calls and identifiers.
    private func normalizeWhitespace(_ text: String) -> String {
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func repositoryFile(_ relativePath: String) throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.pathComponents.count > 1 {
            let candidate = directory.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        XCTFail("Expected repository file not found: \(relativePath)")
        throw TestHelperError.markerNotFound
    }

    func testAmbiguousClaimCreatesNoClaimAndOpensNothing() async {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))

        do {
            try await store.claim(requestID: requestID)
            XCTFail("Transport loss after submission should be ambiguous")
        } catch RequestServiceError.ambiguousClaimOutcome {
            // Expected.
        } catch {
            XCTFail("Unexpected ambiguous-claim error: \(error)")
        }

        XCTAssertNil(store.activeClaim)
        XCTAssertNil(store.claimUnavailableNotice)
        XCTAssertEqual(
            ClaimPresentationError.map(try XCTUnwrap(store.claimError(for: requestID))),
            .ambiguous
        )
        XCTAssertEqual(
            ClaimPresentationError.ambiguous.message,
            "We couldn’t confirm whether your reservation succeeded. Don’t place a Grubhub order. \(AppBrand.name) can’t recover this result in the current session, and the request may disappear from the public list until an unresolved reservation expires."
        )
        XCTAssertFalse(
            ClaimPresentationError.ambiguous.message.contains("appear at the top")
        )
        // No automatic retry of a non-idempotent POST.
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.count, 1)
        // The action is withdrawn rather than offered again.
        XCTAssertFalse(RequestDetailView.showsClaimAction(for: .ambiguous))
    }

    func testUnstructuredHTTPFailureMakesClaimOutcomeAmbiguous() async {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 504,
            data: Data("Gateway Timeout".utf8)
        ))

        do {
            try await store.claim(requestID: requestID)
            XCTFail("A non-envelope HTTP failure cannot confirm whether the claim committed")
        } catch RequestServiceError.ambiguousClaimOutcome {
            // Expected.
        } catch {
            XCTFail("Unexpected claim error: \(error)")
        }

        XCTAssertNil(store.activeClaim)
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.count, 1)
    }

    func testMismatchedClaimResponseIDIsAmbiguous() async {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            responseRequestID: "different-request"
        )))

        do {
            try await store.claim(requestID: requestID)
            XCTFail("A mismatched response ID must not activate a claim")
        } catch RequestServiceError.ambiguousClaimOutcome {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertNil(store.activeClaim)
        XCTAssertEqual(
            ClaimPresentationError.map(store.claimError(for: requestID)!),
            .ambiguous
        )
    }

    func testSuccessfulClaimResponseWithOpenStatusIsAmbiguous() async {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            responseStatus: "open"
        )))

        do {
            try await store.claim(requestID: requestID)
            XCTFail("A claim response must confirm claimed status")
        } catch RequestServiceError.ambiguousClaimOutcome {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertNil(store.activeClaim)
        XCTAssertEqual(
            ClaimPresentationError.map(store.claimError(for: requestID)!),
            .ambiguous
        )
    }

    // MARK: - One active claim at a time

    /// A second confirmed claim would replace the first claim's presentation,
    /// its private token, and its lifecycle timer, leaving that request
    /// reserved on the backend with no local claimant state. Week 2 has no
    /// release endpoint, so the second claim must never start.
    func testSecondClaimIsRejectedWhileAnotherClaimIsActive() async throws {
        let requestB = "meal-b"
        let store = makeStore()
        let claimExpiresAt = Date().addingTimeInterval(10 * 60)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimToken: "token-for-a",
            claimExpiresAt: claimExpiresAt
        )))
        try await store.claim(requestID: requestID)

        let pathsAfterFirstClaim = ClaimFlowURLProtocol.capturedPaths

        do {
            try await store.claim(requestID: requestB)
            XCTFail("A second claim must not start while one is already held")
        } catch RequestServiceError.existingActiveClaim {
            // Expected: refused before any request is built, and reported as
            // "you already hold another reservation" rather than "this one is
            // already starting".
        } catch {
            XCTFail("Unexpected second-claim error: \(error)")
        }

        // Rejected before the network: no claim POST for B was ever sent.
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, pathsAfterFirstClaim)
        XCTAssertFalse(
            ClaimFlowURLProtocol.capturedPaths.contains("/api/request/\(requestB)/claim")
        )

        // A's presentation and deadline are untouched.
        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(claim.requestID, requestID)
        XCTAssertFalse(String(describing: claim).contains("Taylor"))
        XCTAssertEqual(
            claim.claimExpiresAt.timeIntervalSince1970,
            claimExpiresAt.timeIntervalSince1970,
            accuracy: 0.01
        )
        XCTAssertTrue(claim.isExtensionAvailable)
        XCTAssertNil(claim.claimExtendedAt)

        // B never opens a claimant flow; A's still does.
        XCTAssertFalse(
            RequestDetailView.opensClaimedFlow(activeClaim: store.activeClaim, requestID: requestB)
        )
        XCTAssertTrue(
            RequestDetailView.opensClaimedFlow(activeClaim: store.activeClaim, requestID: requestID)
        )

        // A still owns its lifecycle: its private token is the one that
        // extends, on A's endpoint, and the extension is still unused.
        ClaimFlowURLProtocol.enqueue(.response(data: extensionResponse(
            claimExpiresAt: claimExpiresAt.addingTimeInterval(5 * 60),
            claimExtendedAt: Date()
        )))
        await store.extendActiveClaim()

        let extensionRequest = try XCTUnwrap(ClaimFlowURLProtocol.capturedRequests.last)
        XCTAssertEqual(extensionRequest.path, "/api/request/\(requestID)/claim/extend")
        XCTAssertEqual(
            try XCTUnwrap(extensionRequest.bodyObject)["claimToken"] as? String,
            "token-for-a"
        )
    }

    /// The helper starts a claim and leaves the detail screen before it
    /// resolves. The confirmed claim still becomes the one active claim, and it
    /// cannot be displaced by a claim on whatever request they opened next.
    func testDelayedClaimSuccessBecomesTheSingleActiveClaimAndBlocksAnother() async throws {
        let requestB = "meal-b"
        let store = makeStore()
        let claimGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            data: claimResponse(claimToken: "token-for-a"),
            gate: claimGate
        ))

        let claimA = Task { try await store.claim(requestID: requestID) }
        await waitUntil { claimGate.isWaiting }

        // A's detail screen is no longer current: nothing claimant-private
        // exists yet, and no screen — A's or B's — opens a flow.
        XCTAssertNil(store.activeClaim)
        XCTAssertFalse(
            RequestDetailView.opensClaimedFlow(activeClaim: store.activeClaim, requestID: requestID)
        )
        XCTAssertFalse(
            RequestDetailView.opensClaimedFlow(activeClaim: store.activeClaim, requestID: requestB)
        )

        claimGate.open()
        try await claimA.value

        // The delayed success is still applied, as the single active claim.
        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(claim.requestID, requestID)
        XCTAssertFalse(store.isClaiming)

        let pathsAfterDelayedSuccess = ClaimFlowURLProtocol.capturedPaths
        do {
            try await store.claim(requestID: requestB)
            XCTFail("A delayed confirmed claim must still block a second claim")
        } catch RequestServiceError.existingActiveClaim {
            // Expected.
        } catch {
            XCTFail("Unexpected second-claim error: \(error)")
        }

        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, pathsAfterDelayedSuccess)
        XCTAssertEqual(try XCTUnwrap(store.activeClaim).requestID, requestID)
        XCTAssertEqual(try XCTUnwrap(store.activeClaim).requestID, claim.requestID)
    }

    /// Leaving the flow releases the local slot, so the helper can go on to
    /// help with something else. The guard blocks replacement, not all claiming.
    func testClaimingIsAvailableAgainAfterLeavingTheActiveClaimFlow() async throws {
        let requestB = "meal-b"
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)

        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        store.leaveActiveClaimFlow()
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }

        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            responseRequestID: requestB
        )))
        try await store.claim(requestID: requestB)

        XCTAssertEqual(try XCTUnwrap(store.activeClaim).requestID, requestB)
    }

    // MARK: - Request-scoped claim state

    /// The detail screen's claim action reads `isClaiming(requestID:)`, not the
    /// unscoped mutex, so an in-flight claim on A cannot silently grey out B's
    /// action while B is still perfectly claimable.
    func testInFlightClaimOnOneRequestLeavesAnotherRequestsStateUnaffected() async throws {
        let requestB = "meal-b"
        let store = makeStore()
        let claimGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(), gate: claimGate))

        let claimA = Task { try await store.claim(requestID: requestID) }
        await waitUntil { claimGate.isWaiting }

        // The store-wide mutex is engaged...
        XCTAssertTrue(store.isClaiming)
        // ...but only A is presented as claiming.
        XCTAssertTrue(store.isClaiming(requestID: requestID))
        XCTAssertFalse(store.isClaiming(requestID: requestB))

        // B shows no error and keeps its action on screen.
        XCTAssertNil(store.claimError(for: requestB))
        XCTAssertTrue(RequestDetailView.showsClaimAction(for: nil))

        // A concurrent attempt is still refused by the store, with copy that
        // explains itself rather than a silently dead control. B is not the
        // request that is already starting, so it gets its own sentence.
        do {
            try await store.claim(requestID: requestB)
            XCTFail("The store mutex must still refuse a concurrent claim")
        } catch {
            XCTAssertEqual(ClaimPresentationError.map(error), .otherClaimInProgress)
        }
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.count, 1)

        claimGate.open()
        try await claimA.value

        XCTAssertFalse(store.isClaiming(requestID: requestID))
        XCTAssertFalse(store.isClaiming(requestID: requestB))
    }

    // MARK: - Notice presentation

    /// Store publication is observed even when Active Requests was already on
    /// screen. This is the path used when a preserved reservation expires while
    /// the helper is looking at the list rather than returning from a detail.
    func testNoticePublishedWhileActiveRequestsIsVisibleIsPresentedImmediately() async throws {
        let store = makeStore()
        var presented: ClaimUnavailableNotice? = nil

        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimExpiresAt: Date().addingTimeInterval(0.2)
        )))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        try await store.claim(requestID: requestID)
        XCTAssertNil(store.claimUnavailableNotice)

        await waitUntil { store.claimUnavailableNotice?.reason == .claimExpired }

        let published = try XCTUnwrap(store.claimUnavailableNotice)
        presented = HelperRequestPresentation.noticeToPresent(
            presented: nil,
            storeNotice: store.claimUnavailableNotice,
            isViewVisible: true
        )

        XCTAssertEqual(presented?.id, published.id)
        XCTAssertEqual(presented?.reason, .claimExpired)
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    /// A notice raised while a detail screen covers Active Requests waits on the
    /// store and is presented once the list is visible again.
    func testNoticeRaisedBehindADetailScreenIsPresentedOnceTheListAppears() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorResponse(
                code: "REQUEST_ALREADY_CLAIMED",
                message: "Someone else just started helping with this request."
            )
        ))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        try? await store.claim(requestID: requestID)
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }

        let noticeA = try XCTUnwrap(store.claimUnavailableNotice)

        // While the detail screen is still up nothing is presented, and the
        // notice is not consumed — it survives on the store.
        var presented: ClaimUnavailableNotice? = nil
        XCTAssertNotNil(store.claimUnavailableNotice)
        presented = HelperRequestPresentation.noticeToPresent(
            presented: presented,
            storeNotice: store.claimUnavailableNotice,
            isViewVisible: false
        )
        XCTAssertNil(presented)

        // The list becomes visible: `onAppear` arms the alert with notice A.
        presented = HelperRequestPresentation.noticeToPresent(
            presented: presented,
            storeNotice: store.claimUnavailableNotice,
            isViewVisible: true
        )
        XCTAssertEqual(presented?.id, noticeA.id)

        // A newer notice B arrives while A is on screen. A is not swapped out.
        let requestB = "meal-b"
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 410,
            data: errorResponse(code: "REQUEST_EXPIRED", message: "No longer available.")
        ))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        try? await store.claim(requestID: requestB)
        await waitUntil {
            ClaimFlowURLProtocol.capturedPaths.filter { $0 == "/api/requests" }.count == 2
        }
        await waitUntil { !store.isFetching }

        let noticeB = try XCTUnwrap(store.claimUnavailableNotice(for: requestB))
        XCTAssertNotEqual(noticeB.id, noticeA.id)
        XCTAssertEqual(store.claimUnavailableNotices.map(\.id), [noticeA.id, noticeB.id])
        presented = HelperRequestPresentation.noticeToPresent(
            presented: presented,
            storeNotice: store.claimUnavailableNotice
        )
        XCTAssertEqual(presented?.id, noticeA.id, "An alert on screen is never swapped")

        // Acknowledging A by its exact ID cannot clear B.
        store.acknowledgeClaimUnavailableNotice(id: noticeA.id)
        XCTAssertEqual(store.claimUnavailableNotice?.id, noticeB.id)
        XCTAssertEqual(store.claimUnavailableNotice?.requestID, requestB)

        // Once A is dismissed, the queued notice B is presented next.
        presented = nil
        presented = HelperRequestPresentation.noticeToPresent(
            presented: presented,
            storeNotice: store.claimUnavailableNotice
        )
        XCTAssertEqual(presented?.id, noticeB.id)

        // And acknowledging B by ID finally empties the queue.
        store.acknowledgeClaimUnavailableNotice(id: noticeB.id)
        XCTAssertNil(store.claimUnavailableNotice)
        XCTAssertNil(
            HelperRequestPresentation.noticeToPresent(presented: nil, storeNotice: store.claimUnavailableNotice)
        )
    }

    func testTwoNoticesProducedBeforePresentationRemainFIFOAndPresentInOrder() async throws {
        let store = makeStore()
        let requestB = "meal-b"

        let noticeA = try await publishClaimUnavailableNotice(
            store: store,
            requestID: requestID,
            code: ClaimErrorCode.requestAlreadyClaimed,
            statusCode: 409,
            refreshStub: .response(data: listResponse([]))
        )

        var presented: ClaimUnavailableNotice? = HelperRequestPresentation.noticeToPresent(
            presented: nil,
            storeNotice: store.claimUnavailableNotice,
            isViewVisible: false
        )
        XCTAssertNil(presented)

        let noticeB = try await publishClaimUnavailableNotice(
            store: store,
            requestID: requestB,
            code: ClaimErrorCode.requestExpired,
            statusCode: 410,
            refreshStub: .response(data: listResponse([]))
        )

        XCTAssertEqual(store.claimUnavailableNotices.map(\.id), [noticeA.id, noticeB.id])
        XCTAssertEqual(store.claimUnavailableNotice?.id, noticeA.id)

        // The list first presents A even though B was appended before the list
        // became visible.
        presented = HelperRequestPresentation.noticeToPresent(
            presented: presented,
            storeNotice: store.claimUnavailableNotice,
            isViewVisible: true
        )
        XCTAssertEqual(presented?.id, noticeA.id)

        // Neither an unknown acknowledgement nor a later stale acknowledgement
        // may disturb B.
        let unknownID = UUID()
        store.acknowledgeClaimUnavailableNotice(id: unknownID)
        XCTAssertEqual(store.claimUnavailableNotices.map(\.id), [noticeA.id, noticeB.id])

        store.acknowledgeClaimUnavailableNotice(id: noticeA.id)
        XCTAssertEqual(store.claimUnavailableNotices.map(\.id), [noticeB.id])
        XCTAssertEqual(store.claimUnavailableNotice?.id, noticeB.id)

        store.acknowledgeClaimUnavailableNotice(id: noticeA.id)
        XCTAssertEqual(store.claimUnavailableNotices.map(\.id), [noticeB.id])

        presented = nil
        presented = HelperRequestPresentation.noticeToPresent(
            presented: presented,
            storeNotice: store.claimUnavailableNotice
        )
        XCTAssertEqual(presented?.id, noticeB.id)
    }

    func testThreeDistinctNoticesArePreservedWithoutOverwrite() async throws {
        let store = makeStore()
        let cases: [(requestID: String, code: String, statusCode: Int)] = [
            (requestID, ClaimErrorCode.requestAlreadyClaimed, 409),
            ("meal-b", ClaimErrorCode.requestExpired, 410),
            ("meal-c", ClaimErrorCode.requestInsufficientTime, 409)
        ]
        var expected: [ClaimUnavailableNotice] = []

        for entry in cases {
            expected.append(try await publishClaimUnavailableNotice(
                store: store,
                requestID: entry.requestID,
                code: entry.code,
                statusCode: entry.statusCode,
                refreshStub: .response(data: listResponse([]))
            ))
        }

        XCTAssertEqual(store.claimUnavailableNotices.map(\.id), expected.map(\.id))
        XCTAssertEqual(store.claimUnavailableNotices.map(\.requestID), cases.map(\.requestID))
        XCTAssertEqual(Set(store.claimUnavailableNotices.map(\.id)).count, 3)
        XCTAssertEqual(store.claimUnavailableNotice?.id, expected.first?.id)
    }

    func testExpirationForRequestAThenUnavailableRequestBPreservesBoth() async throws {
        let store = makeStore()
        let expiration = Date().addingTimeInterval(10 * 60)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimExpiresAt: expiration
        )))
        try await store.claim(requestID: requestID)

        let refreshesBeforeExpiration = requestListFetchCount
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        store.revalidateActiveClaimExpiration(now: expiration.addingTimeInterval(1))
        await waitUntil { self.requestListFetchCount == refreshesBeforeExpiration + 1 }
        await waitUntil { !store.isFetching }
        let expirationNotice = try XCTUnwrap(store.claimUnavailableNotice(for: requestID))
        XCTAssertEqual(expirationNotice.reason, .claimExpired)

        let requestB = "meal-b"
        let conflictNotice = try await publishClaimUnavailableNotice(
            store: store,
            requestID: requestB,
            code: ClaimErrorCode.requestAlreadyClaimed,
            statusCode: 409,
            refreshStub: .response(data: listResponse([]))
        )

        XCTAssertEqual(
            store.claimUnavailableNotices.map(\.id),
            [expirationNotice.id, conflictNotice.id]
        )
        XCTAssertEqual(store.claimUnavailableNotice?.reason, .claimExpired)
        XCTAssertEqual(store.claimUnavailableNotice(for: requestB)?.reason, .alreadyClaimed)
    }

    func testRequestDetailFindsOnlyItsMatchingNoticeBehindAnEarlierQueueHead() async throws {
        let store = makeStore()
        let noticeA = try await publishClaimUnavailableNotice(
            store: store,
            requestID: requestID,
            code: ClaimErrorCode.requestAlreadyClaimed,
            statusCode: 409,
            refreshStub: .response(data: listResponse([]))
        )
        let requestB = "meal-b"
        let noticeB = try await publishClaimUnavailableNotice(
            store: store,
            requestID: requestB,
            code: ClaimErrorCode.requestExpired,
            statusCode: 410,
            refreshStub: .response(data: listResponse([]))
        )

        XCTAssertEqual(store.claimUnavailableNotice?.id, noticeA.id)
        XCTAssertFalse(RequestDetailView.shouldDismiss(
            for: store.claimUnavailableNotice,
            requestID: requestB
        ))

        let matchingB = store.claimUnavailableNotice(for: requestB)
        XCTAssertEqual(matchingB?.id, noticeB.id)
        XCTAssertTrue(RequestDetailView.shouldDismiss(for: matchingB, requestID: requestB))
        XCTAssertEqual(store.claimUnavailableNotice(for: "meal-c"), nil)
    }

    func testFulfillmentClaimExpiredCannotBeLostBehindLaterOrdinaryClaimNotice() async throws {
        let store = makeStore()
        let expiration = Date().addingTimeInterval(10 * 60)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimExpiresAt: expiration
        )))
        try await store.claim(requestID: requestID)

        let refreshesBeforeExpiration = requestListFetchCount
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        try? await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil,
            now: expiration.addingTimeInterval(1)
        )
        await waitUntil { self.requestListFetchCount == refreshesBeforeExpiration + 1 }
        await waitUntil { !store.isFetching }
        let fulfillmentExpiration = try XCTUnwrap(
            store.claimUnavailableNotice(for: requestID)
        )
        XCTAssertEqual(fulfillmentExpiration.reason, .fulfillmentClaimExpired)

        let requestB = "meal-b"
        let ordinaryNotice = try await publishClaimUnavailableNotice(
            store: store,
            requestID: requestB,
            code: ClaimErrorCode.requestExpired,
            statusCode: 410,
            refreshStub: .response(data: listResponse([]))
        )

        XCTAssertEqual(
            store.claimUnavailableNotices.map(\.id),
            [fulfillmentExpiration.id, ordinaryNotice.id]
        )
        XCTAssertEqual(store.claimUnavailableNotice?.reason, .fulfillmentClaimExpired)
        XCTAssertEqual(store.claimUnavailableNotice(for: requestB)?.reason, .noLongerAvailable)
    }

    /// Failed refreshes must not swallow or reorder any queued safety notice.
    func testFailedRefreshDoesNotDiscardOrReorderQueuedNotices() async throws {
        let store = makeStore()
        let noticeA = try await publishClaimUnavailableNotice(
            store: store,
            requestID: requestID,
            code: ClaimErrorCode.requestAlreadyClaimed,
            statusCode: 409,
            refreshStub: .failure(.notConnectedToInternet)
        )
        let noticeB = try await publishClaimUnavailableNotice(
            store: store,
            requestID: "meal-b",
            code: ClaimErrorCode.requestExpired,
            statusCode: 410,
            refreshStub: .failure(.timedOut)
        )

        XCTAssertEqual(store.claimUnavailableNotices.map(\.id), [noticeA.id, noticeB.id])
        XCTAssertEqual(store.claimUnavailableNotice?.id, noticeA.id)
        XCTAssertNotNil(store.initialFetchError)
    }

    // MARK: - Token stays in memory

    func testConfirmedClaimKeepsTheRawTokenPrivateToTheStore() async throws {
        let token = "raw-claim-token-value"
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: token)))

        try await store.claim(requestID: requestID)

        let presentation = try XCTUnwrap(store.activeClaim)
        let presentationLabels = Set(
            Mirror(reflecting: presentation).children.compactMap(\.label)
        )
        XCTAssertFalse(presentationLabels.contains("claimToken"))
        XCTAssertFalse(presentationLabels.contains("token"))

        // The known fixture token was not copied into process-wide preferences.
        for value in UserDefaults.standard.dictionaryRepresentation().values {
            XCTAssertFalse(String(describing: value).contains(token))
        }

        // Not on the public request model that the list and detail screens read.
        let claimedRequest = try XCTUnwrap(store.requests.first)
        for child in Mirror(reflecting: claimedRequest).children {
            XCTAssertFalse(String(describing: child.value).contains(token))
        }

        // Dropped entirely when the flow ends; nothing outlives the session.
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        store.leaveActiveClaimFlow()
        XCTAssertNil(store.activeClaim)
        await store.extendActiveClaim()
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/claim/extend") }.count,
            0
        )
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    /// The public model and the list DTO must stay free of claimant-only fields
    /// even when a response carries them alongside the public projection.
    func testPublicRequestModelNeverReceivesClaimantOnlyFields() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a", status: "open")
        ])))
        let listed = try await makeService().fetchActiveRequests(participantAuthority: "64c0000000000000000000a1.1.credential")

        let claimantOnlyNames = ["pickupname", "claimtoken", "claimexpiresat", "email", "phone"]
        for child in Mirror(reflecting: try XCTUnwrap(listed.first)).children {
            let label = (child.label ?? "").lowercased()
            for name in claimantOnlyNames {
                XCTAssertNotEqual(label, name, "FoodRequest must not carry \(name)")
            }
        }

        // Inspect a real DTO instance rather than reflecting the metatype, which
        // has no stored-property children regardless of the DTO definition.
        let dto = RequestResponseDTO(
            id: "dto-a",
            vendor: "Crave NYU",
            food: "Rice bowl",
            pickupWindowText: "ASAP",
            mealSwipes: 2,
            menuPath: .mealExchange,
            mealItems: ["Rice bowl"],
            orderDetails: nil,
            estimatedDiningDollarsCents: nil,
            windowStart: nil,
            windowEnd: nil,
            status: .open,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(60),
            isOwnRequest: nil
        )
        let dtoLabels = Set(Mirror(reflecting: dto).children.compactMap(\.label))
        XCTAssertEqual(
            dtoLabels,
            Set([
                "id", "vendor", "food", "pickupWindowText", "mealSwipes",
                // W4-R4 structured representation. Same privacy class as
                // `food`, which is derived from it — requester-entered
                // request content, never a claimant-only field.
                "menuPath", "mealItems", "orderDetails",
                "estimatedDiningDollarsCents",
                "windowStart", "windowEnd", "status", "createdAt", "expiresAt",
                "isOwnRequest",
                // W4-R5: an opaque content revision, stated by the detail read
                // only; it names no person and no claim.
                "contentRevision"
            ])
        )
    }

    // MARK: - Lost claim

    func testAlreadyClaimedShowsLockedCopyRefreshesAndReturnsToActiveRequests() async {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: requestID, status: "open")
        ])))
        await store.fetchRequests()

        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorResponse(
                code: "REQUEST_ALREADY_CLAIMED",
                message: "Someone else just started helping with this request."
            )
        ))
        // The refresh the conflict triggers.
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

        do {
            try await store.claim(requestID: requestID)
            XCTFail("A lost claim must not succeed")
        } catch {
            XCTAssertEqual(ClaimPresentationError.map(error), .alreadyClaimed)
        }

        // Locked copy, verbatim.
        XCTAssertEqual(
            ClaimPresentationError.alreadyClaimed.message,
            "Someone else just started helping with this request."
        )
        XCTAssertEqual(
            HelperRequestPresentation.claimUnavailableTitle(for: .alreadyClaimed),
            "Someone else just started helping with this request."
        )

        // No claim, no navigation, and the helper is sent back.
        XCTAssertNil(store.activeClaim)
        XCTAssertEqual(store.claimUnavailableNotice?.reason, .alreadyClaimed)
        XCTAssertFalse(
            RequestDetailView.opensClaimedFlow(
                activeClaim: store.activeClaim,
                requestID: requestID
            )
        )

        // Backend truth replaces the stale row rather than the screen keeping it.
        await waitUntil { store.requests.isEmpty }
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.suffix(1),
            ["/api/requests"]
        )

        let noticeID = try? XCTUnwrap(store.claimUnavailableNotice?.id)
        if let noticeID {
            store.acknowledgeClaimUnavailableNotice(id: noticeID)
        }
        XCTAssertNil(store.claimUnavailableNotice)
    }

    func testConfirmedUnavailableCodesDoNotOpenFulfillmentAndReturnToActiveRequests() async {
        let unavailableCodes: [(code: String, status: Int)] = [
            ("REQUEST_EXPIRED", 410),
            ("REQUEST_INSUFFICIENT_TIME", 409),
            ("REQUEST_ALREADY_PLACED", 409),
            ("REQUEST_NOT_FOUND", 404),
            // W3-H2: a stale Reserve tap on a request this participant already
            // successfully held once before. Reuses this exact presentation —
            // no new copy — per the accepted marketplace-presentation contract.
            ("REQUEST_ALREADY_PARTICIPATED", 409)
        ]

        for entry in unavailableCodes {
            ClaimFlowURLProtocol.reset()
            let store = makeStore()
            ClaimFlowURLProtocol.enqueue(.response(
                statusCode: entry.status,
                data: errorResponse(code: entry.code, message: "backend detail")
            ))
            ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

            do {
                try await store.claim(requestID: requestID)
                XCTFail("\(entry.code) must not succeed")
            } catch {
                // The stable code survives to the store for diagnosis...
                guard case .serverError(let code, _)? = store.claimError(for: requestID) else {
                    XCTFail("Expected a serverError for \(entry.code)")
                    continue
                }
                XCTAssertEqual(code, entry.code)
                // ...while the copy groups them into one calm message.
                XCTAssertEqual(ClaimPresentationError.map(error), .noLongerAvailable)
            }

            XCTAssertNil(store.activeClaim, "\(entry.code) must not create a claim")
            XCTAssertEqual(store.claimUnavailableNotice?.reason, .noLongerAvailable)
            XCTAssertFalse(
                RequestDetailView.opensClaimedFlow(
                    activeClaim: store.activeClaim,
                    requestID: requestID
                )
            )
            await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
            await waitUntil { !store.isFetching }
        }
    }

    /// A paused or rate-limited backend is not "this request is gone", so the
    /// helper stays where they are instead of being bounced to the list.
    func testPausedAndRateLimitedClaimsKeepTheHelperOnTheDetailScreen() async {
        let cases: [(code: String, status: Int, expected: ClaimPresentationError)] = [
            ("PUBLIC_ACTIONS_PAUSED", 503, .publicActionsPaused),
            ("RATE_LIMITED", 429, .rateLimited)
        ]

        for entry in cases {
            ClaimFlowURLProtocol.reset()
            let store = makeStore()
            ClaimFlowURLProtocol.enqueue(.response(
                statusCode: entry.status,
                data: errorResponse(code: entry.code, message: "backend detail")
            ))

            do {
                try await store.claim(requestID: requestID)
                XCTFail("\(entry.code) must not succeed")
            } catch {
                XCTAssertEqual(ClaimPresentationError.map(error), entry.expected)
            }

            XCTAssertNil(store.activeClaim)
            XCTAssertNil(
                store.claimUnavailableNotice,
                "\(entry.code) is not a confirmed-unavailable outcome"
            )
            XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, ["/api/request/\(requestID)/claim"])
        }

        // The ordinary claim action stays withdrawn while the accepted pause
        // recovery is offered under its own explicit title.
        XCTAssertEqual(
            ClaimPresentationError.publicActionsPaused.message,
            "Helping with this meal is temporarily unavailable."
        )
        XCTAssertFalse(RequestDetailView.showsClaimAction(for: .publicActionsPaused))
        XCTAssertTrue(RequestDetailView.showsPauseRecoveryAction(for: .publicActionsPaused))
        XCTAssertEqual(RequestDetailView.pauseRecoveryActionTitle, "Check again")
        XCTAssertTrue(RequestDetailView.showsClaimAction(for: .rateLimited))
    }

    func testStructuredClaimInternalFailureIsAmbiguousAndOffersNoRepeat() async {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 500,
            data: errorResponse(
                code: ClaimErrorCode.internalFailure,
                message: "Unable to claim this request right now."
            )
        ))

        do {
            try await store.claim(requestID: requestID)
            XCTFail("A structured INTERNAL_FAILURE must not confirm a claim")
        } catch RequestServiceError.ambiguousClaimOutcome {
            // The route may have committed the reservation before its reply was
            // lost, so this uses the existing no-retry ambiguous-claim state.
        } catch {
            XCTFail("Unexpected claim error: \(error)")
        }

        let presentation = ClaimPresentationError.map(
            try! XCTUnwrap(store.claimError(for: requestID))
        )
        XCTAssertEqual(presentation, .ambiguous)
        XCTAssertEqual(presentation.message, ClaimPresentationError.ambiguous.message)
        XCTAssertNil(store.activeClaim)
        XCTAssertFalse(RequestDetailView.showsClaimAction(for: presentation))
        XCTAssertFalse(RequestDetailView.showsPauseRecoveryAction(for: presentation))
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, ["/api/request/\(requestID)/claim"])
    }

    func testPausedClaimWaitsForExplicitCheckAgainAndKeepsRecoveryIfStillPaused() async {
        let store = makeStore()
        let paused = ClaimFlowURLProtocol.Stub.response(
            statusCode: 503,
            data: errorResponse(code: "PUBLIC_ACTIONS_PAUSED", message: "Paused.")
        )
        ClaimFlowURLProtocol.enqueue(paused)

        do {
            try await store.claim(requestID: requestID)
            XCTFail("A paused claim must not succeed")
        } catch {
            XCTAssertEqual(ClaimPresentationError.map(error), .publicActionsPaused)
        }

        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.count, 1)
        XCTAssertTrue(RequestDetailView.showsPauseRecoveryAction(
            for: ClaimPresentationError.map(try! XCTUnwrap(store.claimError(for: requestID)))
        ))

        // Merely remaining on or re-entering the detail sends nothing. This next
        // stub cannot be consumed until the helper explicitly invokes claim again.
        ClaimFlowURLProtocol.enqueue(paused)
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.count, 1)

        do {
            try await store.claim(requestID: requestID)
            XCTFail("The backend is still paused")
        } catch {
            XCTAssertEqual(ClaimPresentationError.map(error), .publicActionsPaused)
        }

        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.count, 2)
        XCTAssertTrue(RequestDetailView.showsPauseRecoveryAction(
            for: ClaimPresentationError.map(try! XCTUnwrap(store.claimError(for: requestID)))
        ))
    }

    func testCheckAgainCanEnterTheNormalActiveReservationAfterPause() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 503,
            data: errorResponse(code: "PUBLIC_ACTIONS_PAUSED", message: "Paused.")
        ))
        try? await store.claim(requestID: requestID)

        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(pickupName: "Taylor")))
        try await store.claim(requestID: requestID)

        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(claim.requestID, requestID)
        XCTAssertFalse(String(describing: claim).contains("Taylor"))
        XCTAssertNil(store.claimError(for: requestID))
        XCTAssertTrue(RequestDetailView.opensClaimedFlow(
            activeClaim: claim,
            requestID: requestID
        ))
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.count, 2)
    }

    func testDuplicateCheckAgainTapsCannotSendConcurrentClaimPosts() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 503,
            data: errorResponse(code: "PUBLIC_ACTIONS_PAUSED", message: "Paused.")
        ))
        try? await store.claim(requestID: requestID)

        let gate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(), gate: gate))
        let checkAgain = Task { try await store.claim(requestID: requestID) }
        await waitUntil { gate.isWaiting }

        for _ in 0..<3 {
            do {
                try await store.claim(requestID: requestID)
                XCTFail("A duplicate Check again tap must be refused locally")
            } catch RequestServiceError.operationInProgress {
                // Expected.
            } catch {
                XCTFail("Unexpected duplicate-tap error: \(error)")
            }
        }
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.count, 2)

        gate.open()
        try await checkAgain.value
        XCTAssertNotNil(store.activeClaim)
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.count, 2)
    }

    func testOnlyPausedClaimsExposeCheckAgain() {
        XCTAssertTrue(RequestDetailView.showsPauseRecoveryAction(for: .publicActionsPaused))
        for error in [
            ClaimPresentationError.alreadyClaimed,
            .noLongerAvailable,
            .rateLimited,
            .ambiguous,
            .couldNotStart,
            .operationInProgress,
            .otherClaimInProgress,
            .existingActiveClaim,
        ] {
            XCTAssertFalse(RequestDetailView.showsPauseRecoveryAction(for: error), "\(error)")
        }
    }

    func testDelayedUnavailableFailureForRequestADoesNotAffectRequestBDetail() async {
        let requestB = "meal-b"
        let store = makeStore()
        let claimGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorResponse(
                code: "REQUEST_ALREADY_CLAIMED",
                message: "Someone else just started helping with this request."
            ),
            gate: claimGate
        ))
        let claimA = Task {
            try await store.claim(requestID: requestID)
        }
        await waitUntil { claimGate.isWaiting }

        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        claimGate.open()
        do {
            try await claimA.value
            XCTFail("Request A should be unavailable")
        } catch {
            XCTAssertEqual(ClaimPresentationError.map(error), .alreadyClaimed)
        }

        XCTAssertNil(store.claimError(for: requestB))
        XCTAssertFalse(
            RequestDetailView.shouldDismiss(
                for: store.claimUnavailableNotice,
                requestID: requestB
            )
        )
        XCTAssertTrue(RequestDetailView.showsClaimAction(for: nil))
        XCTAssertFalse(store.isClaiming(requestID: requestB))
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    func testAcknowledgingOldNoticeCannotClearNewerNotice() async {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorResponse(
                code: "REQUEST_ALREADY_CLAIMED",
                message: "Someone else just started helping with this request."
            )
        ))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        try? await store.claim(requestID: requestID)
        let noticeA = try? XCTUnwrap(store.claimUnavailableNotice)
        await waitUntil {
            ClaimFlowURLProtocol.capturedPaths.filter { $0 == "/api/requests" }.count == 1
        }
        await waitUntil { !store.isFetching }

        let requestB = "meal-b"
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 410,
            data: errorResponse(
                code: "REQUEST_EXPIRED",
                message: "This request is no longer available."
            )
        ))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        try? await store.claim(requestID: requestB)
        let noticeB = try? XCTUnwrap(store.claimUnavailableNotice(for: requestB))
        await waitUntil {
            ClaimFlowURLProtocol.capturedPaths.filter { $0 == "/api/requests" }.count == 2
        }
        await waitUntil { !store.isFetching }

        if let noticeA {
            store.acknowledgeClaimUnavailableNotice(id: noticeA.id)
        }

        XCTAssertEqual(store.claimUnavailableNotice?.id, noticeB?.id)
        XCTAssertEqual(store.claimUnavailableNotice?.requestID, requestB)
        XCTAssertEqual(store.claimUnavailableNotice?.reason, .noLongerAvailable)
    }

    // MARK: - Extension

    func testExtensionSendsTheActiveRawTokenAndAppliesTheBackendExpiration() async throws {
        let token = "raw-token-for-extension"
        let store = makeStore()
        let originalExpiration = Date().addingTimeInterval(10 * 60)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimToken: token,
            claimExpiresAt: originalExpiration
        )))
        try await store.claim(requestID: requestID)

        let extendedExpiration = originalExpiration.addingTimeInterval(5 * 60)
        let extendedAt = Date()
        ClaimFlowURLProtocol.enqueue(.response(data: extensionResponse(
            claimExpiresAt: extendedExpiration,
            claimExtendedAt: extendedAt
        )))

        await store.extendActiveClaim()

        let extensionRequest = try XCTUnwrap(ClaimFlowURLProtocol.capturedRequests.last)
        XCTAssertEqual(extensionRequest.path, "/api/request/\(requestID)/claim/extend")
        XCTAssertEqual(extensionRequest.method, "POST")

        let body = try XCTUnwrap(extensionRequest.bodyObject)
        XCTAssertEqual(body["claimToken"] as? String, token)
        // The backend rejects any body carrying more than the token.
        XCTAssertEqual(body.count, 1)

        // The backend's timestamps are authoritative, not a local +5 minutes.
        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(
            claim.claimExpiresAt.timeIntervalSince1970,
            extendedExpiration.timeIntervalSince1970,
            accuracy: 0.01
        )
        XCTAssertTrue(claim.hasUsedExtension)
        XCTAssertEqual(
            try XCTUnwrap(claim.claimExtendedAt).timeIntervalSince1970,
            extendedAt.timeIntervalSince1970,
            accuracy: 0.01
        )
        XCTAssertNil(store.claimExtensionError)
    }

    func testPendingExtensionSurvivesOriginalDeadlineThenAcceptsBackendSuccess() async throws {
        let store = makeStore()
        let originalExpiration = Date().addingTimeInterval(0.2)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimExpiresAt: originalExpiration
        )))
        try await store.claim(requestID: requestID)

        let extensionGate = RequestFetchingGate()
        let extendedExpiration = Date().addingTimeInterval(2)
        ClaimFlowURLProtocol.enqueue(.response(
            data: extensionResponse(
                claimExpiresAt: extendedExpiration,
                claimExtendedAt: Date()
            ),
            gate: extensionGate
        ))

        let extensionTask = Task {
            await store.extendActiveClaim()
        }
        await waitUntil { extensionGate.isWaiting }

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(store.activeClaim)
        XCTAssertTrue(store.isExtendingClaim)
        XCTAssertFalse(FulfillRequestView.isSubmissionEnabled(
            draft: FulfillmentFormDraft(
                orderNumber: "70154321",
                eta: FulfillmentReadyTime.asap.etaValue,
                readyTime: .asap
            ),
            hasPlacedOrderScreenshot: true,
            isOperationallyAvailable: store.canSubmitFulfillment(requestID: requestID)
        ))
        XCTAssertNil(store.claimUnavailableNotice)

        extensionGate.open()
        await extensionTask.value

        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(
            claim.claimExpiresAt.timeIntervalSince1970,
            extendedExpiration.timeIntervalSince1970,
            accuracy: 0.01
        )
        XCTAssertNotNil(claim.claimExtendedAt)
        XCTAssertFalse(store.isExtendingClaim)

        // The cancelled timer for the original deadline has already woken and
        // cannot clear the extended claim.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(store.activeClaim)
        XCTAssertNil(store.claimUnavailableNotice)
    }

    func testPendingRejectedExtensionPastOriginalDeadlineEndsTheFlow() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimExpiresAt: Date().addingTimeInterval(0.2)
        )))
        try await store.claim(requestID: requestID)

        let extensionGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 429,
            data: errorResponse(code: "RATE_LIMITED", message: "Wait."),
            gate: extensionGate
        ))
        let extensionTask = Task {
            await store.extendActiveClaim()
        }
        await waitUntil { extensionGate.isWaiting }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(store.activeClaim)

        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        extensionGate.open()
        await extensionTask.value

        XCTAssertNil(store.activeClaim)
        XCTAssertEqual(store.claimUnavailableNotice?.reason, .claimExpired)
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    func testPendingAmbiguousExtensionPastOriginalDeadlineEndsTheFlow() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimExpiresAt: Date().addingTimeInterval(0.2)
        )))
        try await store.claim(requestID: requestID)

        let extensionGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost, gate: extensionGate))
        let extensionTask = Task {
            await store.extendActiveClaim()
        }
        await waitUntil { extensionGate.isWaiting }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(store.activeClaim)

        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        extensionGate.open()
        await extensionTask.value

        XCTAssertNil(store.activeClaim)
        XCTAssertEqual(store.claimUnavailableNotice?.reason, .claimExpired)
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    /// W4-H1: the legacy T−3 prompt is gone. A claim this short (under five
    /// minutes total) reaches the warning moment immediately and passes the
    /// former T−3 moment, yet the Helping page's one extension control stays
    /// simply available — no timed prompt consumes, replaces, or duplicates it.
    func testExtensionIsOfferedOnTheHelpingPageWithoutAnyTimedPrompt() async throws {
        let store = makeStore()
        store.updateApplicationVisibility(isVisible: true)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimExpiresAt: Date().addingTimeInterval(3 * 60 + 0.2),
            requestExpiresAt: Date().addingTimeInterval(60 * 60)
        )))
        try await store.claim(requestID: requestID)

        XCTAssertEqual(
            FulfillRequestView.extensionControlState(for: try XCTUnwrap(store.activeClaim)),
            .available
        )
        await waitUntil { store.isShowingReservationWarning }
        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(FulfillRequestView.extensionControlState(for: claim), .available)
        XCTAssertTrue(store.canExtendActiveClaim)

        // Nothing here sent any request beyond the original claim.
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, ["/api/request/\(requestID)/claim"])
    }

    /// `extendActiveClaim()` is the Helping page's `+ Add 5 minutes`. A
    /// confirmed extension reads `5 minutes added` and a second attempt is
    /// refused locally: exactly one extension exists.
    func testSuccessfulExtensionReadsAddedAndBlocksASecondAttempt() async throws {
        let store = makeStore()
        store.updateApplicationVisibility(isVisible: true)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimExpiresAt: Date().addingTimeInterval(3 * 60 + 0.2),
            requestExpiresAt: Date().addingTimeInterval(60 * 60)
        )))
        try await store.claim(requestID: requestID)
        await waitUntil { store.isShowingReservationWarning }

        ClaimFlowURLProtocol.enqueue(.response(data: extensionResponse(
            claimExpiresAt: Date().addingTimeInterval(60 * 8),
            claimExtendedAt: Date()
        )))
        await store.extendActiveClaim()

        let extended = try XCTUnwrap(store.activeClaim)
        XCTAssertTrue(extended.hasUsedExtension)
        XCTAssertEqual(FulfillRequestView.extensionControlState(for: extended), .added)
        XCTAssertFalse(store.canExtendActiveClaim)

        // A second call is refused locally: only one extension exists.
        let pathsAfterFirstExtension = ClaimFlowURLProtocol.capturedPaths
        await store.extendActiveClaim()
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, pathsAfterFirstExtension)
    }

    /// The extension is never offered when the backend could only refuse it,
    /// because a full five minutes does not fit inside the request's own
    /// expiration: the control reads the noninteractive `Can't extend`.
    func testExtensionIsNotOfferedWhenAFullExtensionCannotFit() async throws {
        let store = makeStore()
        store.updateApplicationVisibility(isVisible: true)
        let claimExpiresAt = Date().addingTimeInterval(3 * 60 + 0.2)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimExpiresAt: claimExpiresAt,
            requestExpiresAt: claimExpiresAt.addingTimeInterval(60)
        )))
        try await store.claim(requestID: requestID)

        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(FulfillRequestView.extensionControlState(for: claim), .cantExtend)
        XCTAssertFalse(store.canExtendActiveClaim)
        await store.extendActiveClaim()
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, ["/api/request/\(requestID)/claim"])
    }

    func testFailedExtensionNeverAdvancesTheLocalExpiration() async throws {
        let failures: [(code: String, status: Int, expected: ClaimExtensionPresentationError)] = [
            ("CLAIM_EXTENSION_INSUFFICIENT_TIME", 409, .insufficientTime),
            ("PUBLIC_ACTIONS_PAUSED", 503, .publicActionsPaused),
            ("RATE_LIMITED", 429, .rateLimited),
            ("INTERNAL_FAILURE", 500, .couldNotExtend)
        ]

        for failure in failures {
            ClaimFlowURLProtocol.reset()
            let store = makeStore()
            let claimExpiresAt = Date().addingTimeInterval(10 * 60)
            ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
                claimExpiresAt: claimExpiresAt
            )))
            try await store.claim(requestID: requestID)

            ClaimFlowURLProtocol.enqueue(.response(
                statusCode: failure.status,
                data: errorResponse(code: failure.code, message: "backend detail")
            ))
            await store.extendActiveClaim()

            let claim = try XCTUnwrap(store.activeClaim, "\(failure.code) must keep the claim")
            XCTAssertEqual(
                claim.claimExpiresAt.timeIntervalSince1970,
                claimExpiresAt.timeIntervalSince1970,
                accuracy: 0.01,
                "\(failure.code) must not move the deadline"
            )
            XCTAssertEqual(
                ClaimExtensionPresentationError.map(store.claimExtensionError),
                failure.expected
            )
            let message = failure.expected.message
            XCTAssertTrue(message.contains("reservation time shown above"), message)
            XCTAssertFalse(message.localizedCaseInsensitiveContains("try again"), message)
            // The one offer was consumed by the attempt; it is never re-offered.
            XCTAssertFalse(claim.isExtensionAvailable)
            XCTAssertEqual(FulfillRequestView.extensionControlState(for: claim), .cantExtend)
            XCTAssertTrue(FulfillRequestView.showsExtensionSlot(
                for: claim, isExtending: false, isShowingAddedConfirmation: false
            ), "a failed attempt keeps the side-by-side pair and its feedback")
        }
    }

    func testAlreadyUsedExtensionStopsFurtherAttemptsWithoutInventingTime() async throws {
        let store = makeStore()
        let claimExpiresAt = Date().addingTimeInterval(10 * 60)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimExpiresAt: claimExpiresAt)))
        try await store.claim(requestID: requestID)

        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorResponse(
                code: "CLAIM_EXTENSION_ALREADY_USED",
                message: "This claim has already been extended."
            )
        ))
        await store.extendActiveClaim()

        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertFalse(claim.hasUsedExtension)
        XCTAssertNil(claim.claimExtendedAt)
        XCTAssertFalse(claim.isExtensionAvailable)
        XCTAssertEqual(FulfillRequestView.extensionControlState(for: claim), .cantExtend)
        let message = ClaimExtensionPresentationError.alreadyUsed.message
        XCTAssertTrue(message.contains("reservation time shown above"), message)
        XCTAssertFalse(message.localizedCaseInsensitiveContains("try again"), message)
        XCTAssertEqual(
            claim.claimExpiresAt.timeIntervalSince1970,
            claimExpiresAt.timeIntervalSince1970,
            accuracy: 0.01
        )

        let pathsAfterFailure = ClaimFlowURLProtocol.capturedPaths
        await store.extendActiveClaim()
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, pathsAfterFailure)
    }

    func testAmbiguousExtensionKeepsTheKnownDeadlineAndDoesNotRetry() async throws {
        let store = makeStore()
        let claimExpiresAt = Date().addingTimeInterval(10 * 60)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimExpiresAt: claimExpiresAt)))
        try await store.claim(requestID: requestID)

        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        await store.extendActiveClaim()

        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(
            claim.claimExpiresAt.timeIntervalSince1970,
            claimExpiresAt.timeIntervalSince1970,
            accuracy: 0.01
        )
        XCTAssertFalse(claim.hasUsedExtension)
        // W4-N1: an ambiguous attempt is never shown as success; the pair stays.
        XCTAssertNotEqual(FulfillRequestView.extensionControlState(for: claim), .added)
        XCTAssertTrue(FulfillRequestView.showsExtensionSlot(
            for: claim, isExtending: store.isExtendingClaim, isShowingAddedConfirmation: false
        ))
        XCTAssertEqual(
            ClaimExtensionPresentationError.map(store.claimExtensionError),
            .ambiguous
        )
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/claim/extend") }.count,
            1
        )
    }

    func testUnstructuredHTTPFailureMakesExtensionOutcomeAmbiguous() async throws {
        let store = makeStore()
        let claimExpiresAt = Date().addingTimeInterval(10 * 60)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimExpiresAt: claimExpiresAt)))
        try await store.claim(requestID: requestID)

        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 504,
            data: Data("Gateway Timeout".utf8)
        ))
        await store.extendActiveClaim()

        XCTAssertEqual(
            ClaimExtensionPresentationError.map(store.claimExtensionError),
            .ambiguous
        )
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/claim/extend") }.count,
            1
        )
    }

    func testOldExtensionSuccessCannotAlterReclaimedSameRequestOrNewLoadingState() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimToken: "old-token",
            claimExpiresAt: Date().addingTimeInterval(10 * 60)
        )))
        try await store.claim(requestID: requestID)

        let oldExtensionGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            data: extensionResponse(
                claimExpiresAt: Date().addingTimeInterval(20 * 60),
                claimExtendedAt: Date()
            ),
            gate: oldExtensionGate
        ))
        let oldExtension = Task {
            await store.extendActiveClaim()
        }
        await waitUntil { oldExtensionGate.isWaiting }

        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        store.leaveActiveClaimFlow()
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }

        let newOriginalExpiration = Date().addingTimeInterval(12 * 60)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimToken: "new-token",
            claimExpiresAt: newOriginalExpiration
        )))
        try await store.claim(requestID: requestID)

        let newExtensionGate = RequestFetchingGate()
        let newExtendedExpiration = Date().addingTimeInterval(17 * 60)
        ClaimFlowURLProtocol.enqueue(.response(
            data: extensionResponse(
                claimExpiresAt: newExtendedExpiration,
                claimExtendedAt: Date()
            ),
            gate: newExtensionGate
        ))
        let newExtension = Task {
            await store.extendActiveClaim()
        }
        await waitUntil { newExtensionGate.isWaiting }
        XCTAssertTrue(store.isExtendingClaim)

        oldExtensionGate.open()
        await oldExtension.value

        XCTAssertTrue(store.isExtendingClaim)
        XCTAssertNil(store.claimExtensionError)
        XCTAssertEqual(
            try XCTUnwrap(store.activeClaim).claimExpiresAt.timeIntervalSince1970,
            newOriginalExpiration.timeIntervalSince1970,
            accuracy: 0.01
        )

        newExtensionGate.open()
        await newExtension.value
        XCTAssertFalse(store.isExtendingClaim)
        XCTAssertEqual(
            try XCTUnwrap(store.activeClaim).claimExpiresAt.timeIntervalSince1970,
            newExtendedExpiration.timeIntervalSince1970,
            accuracy: 0.01
        )
    }

    func testOldExtensionFailureCannotPublishIntoReclaimedSameRequest() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimToken: "old-token"
        )))
        try await store.claim(requestID: requestID)

        let oldExtensionGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 500,
            data: errorResponse(code: "INTERNAL_FAILURE", message: "Old failure."),
            gate: oldExtensionGate
        ))
        let oldExtension = Task {
            await store.extendActiveClaim()
        }
        await waitUntil { oldExtensionGate.isWaiting }

        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        store.leaveActiveClaimFlow()
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }

        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimToken: "new-token"
        )))
        try await store.claim(requestID: requestID)

        let newExtensionGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            data: extensionResponse(
                claimExpiresAt: Date().addingTimeInterval(20 * 60),
                claimExtendedAt: Date()
            ),
            gate: newExtensionGate
        ))
        let newExtension = Task {
            await store.extendActiveClaim()
        }
        await waitUntil { newExtensionGate.isWaiting }

        oldExtensionGate.open()
        await oldExtension.value

        XCTAssertTrue(store.isExtendingClaim)
        XCTAssertNil(store.claimExtensionError)
        XCTAssertNotNil(store.activeClaim)

        newExtensionGate.open()
        await newExtension.value
        XCTAssertFalse(store.isExtendingClaim)
        XCTAssertNil(store.claimExtensionError)
    }

    // MARK: - Claim expiration

    func testClaimExpirationEndsTheFlowAndReturnsToRefreshedRequests() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimExpiresAt: Date().addingTimeInterval(0.2)
        )))
        // The refresh the expiration triggers.
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

        try await store.claim(requestID: requestID)
        XCTAssertNotNil(store.activeClaim)

        await waitUntil { store.claimUnavailableNotice?.reason == .claimExpired }

        // The flow is closed: no claim, no token, and no way back into it.
        XCTAssertNil(store.activeClaim)
        XCTAssertFalse(
            RequestDetailView.opensClaimedFlow(
                activeClaim: store.activeClaim,
                requestID: requestID
            )
        )
        XCTAssertFalse(store.isShowingReservationWarning)

        // The helper is told what happened and warned off placing an order.
        XCTAssertEqual(
            HelperRequestPresentation.claimUnavailableTitle(for: .claimExpired),
            "Your reservation expired."
        )
        let detail = try XCTUnwrap(
            HelperRequestPresentation.claimUnavailableDetail(for: .claimExpired)
        )
        XCTAssertTrue(detail.contains("don’t place an order"))

        // ...on a list refreshed from backend truth.
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    func testExpiredClaimReportedByTheExtensionEndpointEndsTheFlowToo() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimExpiresAt: Date().addingTimeInterval(10 * 60)
        )))
        try await store.claim(requestID: requestID)

        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorResponse(code: "CLAIM_EXPIRED", message: "This claim has expired.")
        ))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

        await store.extendActiveClaim()

        XCTAssertNil(store.activeClaim)
        XCTAssertEqual(store.claimUnavailableNotice?.reason, .claimExpired)
        // Handled by ending the flow, so no inline extension copy is shown.
        XCTAssertNil(ClaimExtensionPresentationError.map(store.claimExtensionError))
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    func testLeavingTheClaimFlowDropsTheClaimAndRefreshes() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

        store.leaveActiveClaimFlow()

        XCTAssertNil(store.activeClaim)
        XCTAssertFalse(store.isShowingReservationWarning)
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    // MARK: - Day 4 product-safety copy

    /// W4-H1 physical acceptance removed the explanatory reservation copy
    /// above `Start helping` (Figma 357:1085). Viewing a request still claims
    /// nothing: only the explicit tap does.
    func testViewingARequestClaimsNothingAndNoExplanatoryReservationCopyRemains() async throws {
        XCTAssertEqual(RequestDetailView.claimActionTitle, "Start helping")
        XCTAssertTrue(RequestDetailView.showsClaimAction(for: nil))
        let source = try String(
            contentsOf: repositoryFile("ios/CommonPlateios/CommonPlateios/Views/RequestDetailView.swift"),
            encoding: .utf8
        )
        for retired in [
            "claimConsequenceNotice",
            "claim-consequence-notice",
            "This holds the meal for you for a few minutes",
            "Section(\"Food request\")"
        ] {
            XCTAssertFalse(source.contains(retired), retired)
        }

        // Opening a request sends nothing; only the explicit tap does.
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: requestID, status: "open")
        ])))
        await store.fetchRequests()
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, ["/api/requests"])

        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths,
            ["/api/requests", "/api/request/\(requestID)/claim"]
        )
    }

    func testHomeScreenDescribesTheConnectedPlacementAndEmailAttemptTruthfully() {
        let steps = ContentView.howItWorksSteps

        XCTAssertFalse(steps.contains("3. They place the order and enter pickup details."))
        XCTAssertTrue(steps[2].localizedCaseInsensitiveContains("grubhub order"))
        XCTAssertTrue(steps[2].localizedCaseInsensitiveContains("then records"))
        XCTAssertTrue(steps[3].localizedCaseInsensitiveContains("attempts to email"))
        XCTAssertFalse(steps[3].localizedCaseInsensitiveContains("delivered"))
        XCTAssertFalse(steps[3].localizedCaseInsensitiveContains("read"))
        // One vocabulary across every surface: no engineering or role nouns.
        for step in steps {
            XCTAssertFalse(step.localizedCaseInsensitiveContains("external order"), step)
            XCTAssertFalse(step.localizedCaseInsensitiveContains("requester"), step)
        }
    }

    // W4-H1 removed the legacy T−3 prompt copy test with the prompt itself;
    // the Helping page's accepted reservation-control copy and the absence of
    // the legacy strings are proven in `HelperJourneyFulfillmentTests`.

    /// High-priority safety copy. Locked: do not weaken.
    func testLockedExpirationCopyIsUnchanged() {
        XCTAssertEqual(
            HelperRequestPresentation.claimUnavailableTitle(for: .claimExpired),
            "Your reservation expired."
        )
        XCTAssertEqual(
            HelperRequestPresentation.claimUnavailableDetail(for: .claimExpired),
            "Please don’t place an order for that request. Someone else may already be helping."
        )
        // The locked race-conflict sentence is likewise untouched.
        XCTAssertEqual(
            HelperRequestPresentation.claimUnavailableTitle(for: .alreadyClaimed),
            "Someone else just started helping with this request."
        )
        XCTAssertEqual(
            HelperRequestPresentation.claimUnavailableTitle(for: .noLongerAvailable),
            "This request is no longer available."
        )
    }

    // MARK: - Pinned active reservation

    func testConfirmedClaimProducesOnePinnedReservationItem() async throws {
        let store = makeStore()
        let claimExpiresAt = Date().addingTimeInterval(12 * 60)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimExpiresAt: claimExpiresAt)))
        try await store.claim(requestID: requestID)

        // The pinned item renders entirely from confirmed claim state, so it
        // survives the request leaving the public collection.
        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(claim.request.id, requestID)
        XCTAssertEqual(claim.request.diningSpot.name, "Crave NYU")
        XCTAssertEqual(claim.request.foodDescription, "Rice bowl")
        XCTAssertEqual(
            HelperRequestPresentation.reservedUntilText(claim.claimExpiresAt),
            "Reserved until \(claimExpiresAt.formatted(date: .omitted, time: .shortened))"
        )
        XCTAssertEqual(
            HelperRequestPresentation.activeReservationTitle,
            "You’re helping with a request"
        )

        // It is not a second copy of the public row: the claimed request is
        // withheld from the available list while it is held.
        XCTAssertEqual(store.requests.map(\.id), [requestID])
        XCTAssertTrue(
            HelperRequestPresentation.availableRequests(
                store.requests,
                activeClaimRequestID: claim.requestID
            ).isEmpty
        )
        // ...and nothing is filtered when no claim is held.
        XCTAssertEqual(
            HelperRequestPresentation.availableRequests(store.requests, activeClaimRequestID: nil)
                .map(\.id),
            [requestID]
        )
    }

    /// The claim confirms after its detail screen is gone and the backend has
    /// stopped advertising the request. Without a pinned entry point that is a
    /// live reservation with no route to it anywhere in the app.
    func testDelayedClaimSuccessIsReachableThroughThePinnedItem() async throws {
        let store = makeStore()
        let claimGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(), gate: claimGate))

        let claimTask = Task { try await store.claim(requestID: requestID) }
        await waitUntil { claimGate.isWaiting }
        // The detail screen is dismissed while the claim is still in flight.
        XCTAssertNil(store.activeClaim)

        claimGate.open()
        try await claimTask.value

        // The public list no longer carries the request — it is actively claimed.
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        await store.fetchRequests()
        XCTAssertTrue(store.requests.isEmpty)

        // The reservation is still reachable, with everything the pinned item
        // needs to identify and re-enter it.
        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(claim.requestID, requestID)
        XCTAssertFalse(String(describing: claim).contains("Taylor"))
        XCTAssertEqual(claim.request.foodDescription, "Rice bowl")
    }

    func testReenteringFromThePinnedItemSendsNoSecondClaim() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)

        let pathsAfterClaim = ClaimFlowURLProtocol.capturedPaths
        XCTAssertEqual(pathsAfterClaim, ["/api/request/\(requestID)/claim"])

        // Re-entry reads existing store state. Nothing re-fetches, and the flow
        // opens for exactly the claimed request.
        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertTrue(
            RequestDetailView.opensClaimedFlow(activeClaim: claim, requestID: requestID)
        )
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, pathsAfterClaim)

        // A claim call on the same request would be refused before the network,
        // so re-entry can never become a second reservation.
        do {
            try await store.claim(requestID: requestID)
            XCTFail("Re-entry must not start a second claim")
        } catch RequestServiceError.operationInProgress {
            // Expected: the same request, already held.
        } catch {
            XCTFail("Unexpected re-entry error: \(error)")
        }
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, pathsAfterClaim)
    }

    // MARK: - Non-destructive Back

    /// Back is navigation, not a decision to give up a reservation the backend
    /// still holds. Nothing in the store is cleared by leaving the screen, so
    /// the claim, its private token, its deadline, and its lifecycle timer all
    /// survive and the helper can re-enter. (The gesture itself is verified on
    /// device; this pins the store behavior it now depends on.)
    func testBackingOutOfTheClaimantFlowPreservesTheClaimAndAllowsReentry() async throws {
        let store = makeStore()
        let claimExpiresAt = Date().addingTimeInterval(10 * 60)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimToken: "token-for-a",
            claimExpiresAt: claimExpiresAt
        )))
        try await store.claim(requestID: requestID)

        let pathsAfterClaim = ClaimFlowURLProtocol.capturedPaths

        // Dismissing the claimant screen performs no store mutation at all.
        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(claim.requestID, requestID)
        XCTAssertFalse(String(describing: claim).contains("Taylor"))
        XCTAssertEqual(
            claim.claimExpiresAt.timeIntervalSince1970,
            claimExpiresAt.timeIntervalSince1970,
            accuracy: 0.01
        )
        XCTAssertTrue(claim.isExtensionAvailable)
        XCTAssertFalse(claim.hasUsedExtension)
        // No release request exists, and Back must not invent one.
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, pathsAfterClaim)

        // Re-entry is offered for this request...
        XCTAssertTrue(
            RequestDetailView.opensClaimedFlow(activeClaim: store.activeClaim, requestID: requestID)
        )

        // ...and token ownership survived, so the reservation is still fully
        // operable rather than a presentation with nothing behind it.
        ClaimFlowURLProtocol.enqueue(.response(data: extensionResponse(
            claimExpiresAt: claimExpiresAt.addingTimeInterval(5 * 60),
            claimExtendedAt: Date()
        )))
        await store.extendActiveClaim()

        let extensionRequest = try XCTUnwrap(ClaimFlowURLProtocol.capturedRequests.last)
        XCTAssertEqual(extensionRequest.path, "/api/request/\(requestID)/claim/extend")
        XCTAssertEqual(
            try XCTUnwrap(extensionRequest.bodyObject)["claimToken"] as? String,
            "token-for-a"
        )
        XCTAssertTrue(try XCTUnwrap(store.activeClaim).hasUsedExtension)
    }

    /// Expiration remains the thing that ends a claim — the pinned item and every
    /// claimant-private value go with it.
    func testExpirationClearsThePinnedItemAndPrivateClaimState() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimExpiresAt: Date().addingTimeInterval(0.2)
        )))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

        try await store.claim(requestID: requestID)
        XCTAssertNotNil(store.activeClaim)

        await waitUntil { store.claimUnavailableNotice?.reason == .claimExpired }

        // No claim means no pinned item, no pickup name, and no re-entry.
        XCTAssertNil(store.activeClaim)
        XCTAssertFalse(
            RequestDetailView.opensClaimedFlow(
                activeClaim: store.activeClaim,
                requestID: requestID
            )
        )
        XCTAssertFalse(store.isShowingReservationWarning)
        // Nothing is filtered out of the public list any more either.
        XCTAssertEqual(
            HelperRequestPresentation.availableRequests(
                store.requests,
                activeClaimRequestID: store.activeClaim?.requestID
            ).count,
            store.requests.count
        )

        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    // MARK: - Distinct claim-blocking messages

    func testInFlightDuplicateAndExistingClaimProduceDistinctMessages() async throws {
        let requestB = "meal-b"
        let store = makeStore()
        let claimGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(), gate: claimGate))

        // In flight on this request: nothing is held yet, the tap is simply
        // already running.
        let claimTask = Task { try await store.claim(requestID: requestID) }
        await waitUntil { claimGate.isWaiting }
        do {
            try await store.claim(requestID: requestID)
            XCTFail("A duplicate in-flight claim must be refused")
        } catch {
            XCTAssertEqual(ClaimPresentationError.map(error), .operationInProgress)
        }

        claimGate.open()
        try await claimTask.value

        // A confirmed reservation elsewhere is a different situation and gets a
        // different sentence.
        do {
            try await store.claim(requestID: requestB)
            XCTFail("A claim must be refused while another reservation is held")
        } catch {
            XCTAssertEqual(ClaimPresentationError.map(error), .existingActiveClaim)
        }

        XCTAssertNotEqual(
            ClaimPresentationError.operationInProgress.message,
            ClaimPresentationError.existingActiveClaim.message
        )
        XCTAssertEqual(
            ClaimPresentationError.existingActiveClaim.message,
            "You’re already helping with another request. Finish that one or wait for its reservation to end."
        )
        // The action is withdrawn rather than left to be tapped into the same
        // refusal; the screen offers a way back to the held reservation instead.
        XCTAssertFalse(RequestDetailView.showsClaimAction(for: .existingActiveClaim))
        XCTAssertTrue(RequestDetailView.showsClaimAction(for: .operationInProgress))
        XCTAssertEqual(try XCTUnwrap(store.activeClaim).requestID, requestID)
    }

    // W4-H1 removed "Declining an extension": the legacy T−3 decline
    // (`Keep my current time`) no longer exists. The Helping page offers the
    // one extension without a decision flow, so there is nothing to decline.

    // MARK: - Day 5 fulfillment

    func testFulfillmentEncodesTheExactAcceptedPayloadWithoutNoteOrPhone() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "raw-active-token")))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse(notificationStatus: "sent")))

        try await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: "Meet by the entrance"
        )

        let request = try XCTUnwrap(
            ClaimFlowURLProtocol.capturedRequests.first { $0.path.hasSuffix("/fulfill") }
        )
        let body = try XCTUnwrap(request.bodyObject)
        XCTAssertEqual(Set(body.keys), ["claimToken", "fulfillment"])
        XCTAssertEqual(body["claimToken"] as? String, "raw-active-token")
        let fulfillment = try XCTUnwrap(body["fulfillment"] as? [String: Any])
        XCTAssertEqual(
            Set(fulfillment.keys),
            ["orderNumber", "eta", "contactMessage", "placedOrderScreenshot"]
        )
        XCTAssertEqual(fulfillment["orderNumber"] as? String, "70154321")
        XCTAssertEqual(fulfillment["eta"] as? String, "15 minutes")
        XCTAssertEqual(fulfillment["contactMessage"] as? String, "Meet by the entrance")
        XCTAssertNil(fulfillment["note"])
        XCTAssertNil(fulfillment["helperPhone"])
        XCTAssertNil(fulfillment["helperPhoneNumber"])
        XCTAssertNil(body["status"])
        XCTAssertNil(body["placedAt"])
    }

    func testOmittedContactMessageIsTheOnlyOptionalFulfillmentField() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "raw-token")))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse(notificationStatus: "sent")))

        try await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )

        let request = try XCTUnwrap(ClaimFlowURLProtocol.capturedRequests.last)
        let fulfillment = try XCTUnwrap(request.bodyObject?["fulfillment"] as? [String: Any])
        XCTAssertEqual(Set(fulfillment.keys), ["orderNumber", "eta", "placedOrderScreenshot"])
    }

    func testEmptyClaimTokenNeverCreatesSubmittableClaimState() async {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "")))

        do {
            try await store.claim(requestID: requestID)
            XCTFail("An unusable raw token must not activate fulfillment")
        } catch RequestServiceError.ambiguousClaimOutcome {
            // A malformed success cannot safely expose a claimant flow.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertNil(store.activeClaim)
        XCTAssertFalse(store.canSubmitFulfillment(requestID: requestID))
        XCTAssertFalse(FulfillRequestView.isSubmissionEnabled(
            draft: FulfillmentFormDraft(
                orderNumber: "70154321",
                eta: FulfillmentReadyTime.asap.etaValue,
                readyTime: .asap
            ),
            hasPlacedOrderScreenshot: true,
            isOperationallyAvailable: store.canSubmitFulfillment(requestID: requestID)
        ))
        XCTAssertFalse(ClaimFlowURLProtocol.capturedPaths.contains { $0.hasSuffix("/fulfill") })
    }

    func testEmptyRequiredFulfillmentFieldsDisableSubmission() {
        let empty = FulfillmentFormDraft()
        XCTAssertFalse(FulfillRequestView.isSubmissionEnabled(
            draft: empty,
            hasPlacedOrderScreenshot: true,
            isOperationallyAvailable: true
        ))

        let complete = FulfillmentFormDraft(
            orderNumber: "70154321",
            eta: FulfillmentReadyTime.asap.etaValue,
            readyTime: .asap,
            contactMessage: ""
        )
        var missingEmail = complete
        missingEmail.orderNumber = " \n"
        var missingOrderNumber = complete
        missingOrderNumber.orderNumber = "  "
        var missingETA = complete
        missingETA.eta = "\n"

        for draft in [missingEmail, missingOrderNumber, missingETA] {
            XCTAssertFalse(FulfillRequestView.isSubmissionEnabled(
                draft: draft,
                hasPlacedOrderScreenshot: true,
                isOperationallyAvailable: true
            ))
        }
    }

    func testCompleteFulfillmentEnablesSubmissionWithoutAContactMessage() {
        let complete = FulfillmentFormDraft(
            orderNumber: "70154321",
            eta: FulfillmentReadyTime.fifteenMinutes.etaValue,
            readyTime: .fifteenMinutes,
            contactMessage: ""
        )

        XCTAssertTrue(FulfillRequestView.isSubmissionEnabled(
            draft: complete,
            hasPlacedOrderScreenshot: true,
            isOperationallyAvailable: true
        ))
    }

    /// W4-H1: `Finish helping` stays disabled until every required field is
    /// valid under the existing validation — there is no tap-to-validate path.
    func testMalformedButNonemptyFulfillmentValuesKeepSubmissionDisabled() {
        let malformed = FulfillmentFormDraft(
            orderNumber: "ORDER-123",
            eta: FulfillmentReadyTime.thirtyMinutes.etaValue,
            readyTime: .thirtyMinutes,
            contactMessage: ""
        )

        XCTAssertFalse(FulfillmentFormValidator.validate(
            orderNumber: malformed.orderNumber
        ).isEmpty)
        XCTAssertFalse(FulfillRequestView.isSubmissionEnabled(
            draft: malformed,
            hasPlacedOrderScreenshot: true,
            isOperationallyAvailable: true
        ))
    }

    func testSubmitButtonRetainsStoreOwnedClaimAndExpirationGates() async throws {
        XCTAssertEqual(FulfillRequestView.submitTitle, "Finish helping")

        let complete = FulfillmentFormDraft(
            orderNumber: "70154321",
            eta: FulfillmentReadyTime.asap.etaValue,
            readyTime: .asap,
            contactMessage: ""
        )

        let store = makeStore()
        // No claim.
        XCTAssertFalse(store.canSubmitFulfillment(requestID: requestID))
        XCTAssertFalse(FulfillRequestView.isSubmissionEnabled(
            draft: complete,
            hasPlacedOrderScreenshot: true,
            isOperationallyAvailable: store.canSubmitFulfillment(requestID: requestID)
        ))

        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        XCTAssertTrue(FulfillRequestView.isSubmissionEnabled(
            draft: complete,
            hasPlacedOrderScreenshot: true,
            isOperationallyAvailable: store.canSubmitFulfillment(requestID: requestID)
        ))

        // Wrong request, and a past deadline, still close it.
        XCTAssertFalse(FulfillRequestView.isSubmissionEnabled(
            draft: complete,
            hasPlacedOrderScreenshot: true,
            isOperationallyAvailable: store.canSubmitFulfillment(requestID: "different-request")
        ))
        XCTAssertFalse(FulfillRequestView.isSubmissionEnabled(
            draft: complete,
            hasPlacedOrderScreenshot: true,
            isOperationallyAvailable: store.canSubmitFulfillment(
                requestID: requestID,
                now: Date().addingTimeInterval(60 * 60)
            )
        ))
    }

    /// The settled unresolved state gained an exit. It has to be an exit and
    /// nothing more: the reservation stays held and blocked, the ambiguity
    /// stays unresolved, and no request leaves the device.
    func testUnresolvedAmbiguityReturnActionOnlyNavigates() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "claimed")))

        try? await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )

        let ambiguity = try XCTUnwrap(store.fulfillmentAmbiguity)
        XCTAssertFalse(ambiguity.isCheckingStatus)
        XCTAssertTrue(FulfillRequestView.showsAmbiguityReturnAction(isCheckingStatus: false))
        let pathsBefore = ClaimFlowURLProtocol.capturedPaths

        var navigated = 0
        FulfillRequestView.returnHome(from: store) { navigated += 1 }

        XCTAssertEqual(navigated, 1, "The action's only job is to navigate")
        // Nothing resolved, nothing cleared, nothing unblocked, nothing sent.
        XCTAssertEqual(store.fulfillmentAmbiguity?.id, ambiguity.id)
        XCTAssertEqual(store.fulfillmentAmbiguity?.isCheckingStatus, false)
        XCTAssertNotNil(store.activeClaim)
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertFalse(store.canSubmitFulfillment(requestID: requestID))
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, pathsBefore)

        // And a further submission attempt is still refused, unchanged.
        do {
            try await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
            XCTFail("Leaving must not reopen submission")
        } catch RequestServiceError.unresolvedFulfillment {
            // Expected: the block survives the navigation.
        }
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, pathsBefore)
    }

    /// By the time a confirmation exists the claim and the list row are both
    /// gone, so the confirmation carries the meal's public identity itself —
    /// public projection fields only.
    func testConfirmationCarriesVendorAndFoodThroughBothConfirmationPaths() async throws {
        // Path 1: a decoded placement response.
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse(notificationStatus: "sent")))
        try await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )

        let confirmed = try XCTUnwrap(store.fulfillmentConfirmation)
        XCTAssertEqual(confirmed.vendor, "Crave NYU")
        XCTAssertEqual(confirmed.foodDescription, "Rice bowl")
        XCTAssertEqual(confirmed.kind, .notificationSent)
        // Identity only: no claimant-private value may ride along.
        XCTAssertFalse(confirmed.vendor.contains("Taylor"))
        XCTAssertFalse(confirmed.foodDescription.contains("claim-token"))
        // Dismissal is by exact ID, clearing only this one (W4-H1 renamed it
        // from `acknowledge…`; the ID matching itself is unchanged).
        store.dismissFulfillmentConfirmation(id: UUID())
        XCTAssertNotNil(store.fulfillmentConfirmation)
        store.dismissFulfillmentConfirmation(id: confirmed.id)
        XCTAssertNil(store.fulfillmentConfirmation)

        // Path 2: an ambiguous POST resolved by the single placed detail read.
        ClaimFlowURLProtocol.reset()
        let resolved = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await resolved.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "placed")))
        try await resolved.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )

        let fromDetail = try XCTUnwrap(resolved.fulfillmentConfirmation)
        XCTAssertEqual(fromDetail.vendor, "Crave NYU")
        XCTAssertEqual(fromDetail.foodDescription, "Rice bowl")
        XCTAssertEqual(fromDetail.kind, .emailStatusUnknown)
        // W4-H1: an unknown email outcome has a headline and no secondary line.
        XCTAssertNil(HelperSuccessCopy.secondaryLine(for: fromDetail.kind))
    }

    func testDuplicateFulfillmentTapIsBlockedAndNothingIsRemovedOptimistically() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        let gate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            data: fulfillmentResponse(notificationStatus: "sent"),
            gate: gate
        ))

        let first = Task {
            try await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
        }
        await waitUntil { gate.isWaiting }

        XCTAssertTrue(store.isFulfilling)
        let completeDraft = FulfillmentFormDraft(
            orderNumber: "70154321",
            eta: FulfillmentReadyTime.fifteenMinutes.etaValue,
            readyTime: .fifteenMinutes
        )
        XCTAssertFalse(FulfillRequestView.isSubmissionEnabled(
            draft: completeDraft,
            hasPlacedOrderScreenshot: true,
            isOperationallyAvailable: store.canSubmitFulfillment(requestID: requestID)
        ))
        XCTAssertNotNil(store.activeClaim)
        XCTAssertEqual(store.requests.map(\.id), [requestID])
        do {
            try await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
            XCTFail("A duplicate fulfillment must be refused")
        } catch RequestServiceError.operationInProgress {
            // Refused before a second POST.
        } catch {
            XCTFail("Unexpected duplicate error: \(error)")
        }
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count, 1)

        gate.open()
        try await first.value
        XCTAssertNil(store.activeClaim)
        XCTAssertNotNil(store.fulfillmentConfirmation)
        XCTAssertFalse(FulfillRequestView.isSubmissionEnabled(
            draft: completeDraft,
            hasPlacedOrderScreenshot: true,
            isOperationallyAvailable: store.canSubmitFulfillment(requestID: requestID)
        ))
        XCTAssertTrue(store.requests.isEmpty)
    }

    func testClaimDeadlinePassingDuringFulfillmentDoesNotClearBeforeTerminalResponse() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimExpiresAt: Date().addingTimeInterval(0.2)
        )))
        try await store.claim(requestID: requestID)
        let gate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            data: fulfillmentResponse(notificationStatus: "sent"),
            gate: gate
        ))

        let fulfillment = Task {
            try await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
        }
        await waitUntil { gate.isWaiting }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertNotNil(store.activeClaim)
        XCTAssertTrue(store.isFulfilling)
        XCTAssertNil(store.claimUnavailableNotice)

        gate.open()
        try await fulfillment.value
        XCTAssertNil(store.activeClaim)
        XCTAssertEqual(store.fulfillmentConfirmation?.kind, .notificationSent)
        XCTAssertTrue(store.requests.isEmpty)
    }

    func testSentAndFailedNotificationBothConfirmPlacementAndRemoveOnlyAfterResponse() async throws {
        for (status, kind) in [
            ("sent", FulfillmentConfirmationKind.notificationSent),
            ("failed", FulfillmentConfirmationKind.notificationFailed)
        ] {
            ClaimFlowURLProtocol.reset()
            let store = makeStore()
            ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
            try await store.claim(requestID: requestID)
            ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse(notificationStatus: status)))

            try await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )

            XCTAssertEqual(store.fulfillmentConfirmation?.kind, kind)
            XCTAssertEqual(store.confirmedFulfillmentOutcome?.request.status, .placed)
            XCTAssertNil(store.activeClaim)
            XCTAssertTrue(store.requests.isEmpty)
        }
    }

    /// W4-H1 exact success copy, keyed by the authoritative email outcome.
    /// It never claims delivery, reading, or pickup, and never uses the
    /// retired `The order was placed.` / `Order recorded` framing.
    func testConfirmedPlacementCopySeparatesEmailOutcomes() {
        XCTAssertEqual(HelperSuccessCopy.headline, "Thanks for helping.")
        XCTAssertNil(HelperSuccessCopy.secondaryLine(for: .notificationSent))
        XCTAssertEqual(
            HelperSuccessCopy.secondaryLine(for: .notificationFailed),
            "We couldn't email the requester."
        )
        XCTAssertNil(HelperSuccessCopy.secondaryLine(for: .emailStatusUnknown))

        let everyLine = [HelperSuccessCopy.headline]
            + [FulfillmentConfirmationKind.notificationSent, .notificationFailed, .emailStatusUnknown]
                .compactMap(HelperSuccessCopy.secondaryLine(for:))
        for line in everyLine {
            for forbidden in [
                "The order was placed", "Order recorded", "received", "read the",
                "pick up", "picked up", "delivered", "student"
            ] {
                XCTAssertFalse(line.localizedCaseInsensitiveContains(forbidden), line)
            }
        }
    }

    func testExpiredClaimIsBlockedBeforeFulfillmentAndForegroundReturnClearsIt() async throws {
        let store = makeStore()
        let expiration = Date().addingTimeInterval(10 * 60)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimExpiresAt: expiration)))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

        XCTAssertFalse(store.canSubmitFulfillment(
            requestID: requestID,
            now: expiration.addingTimeInterval(1)
        ))
        store.revalidateActiveClaimExpiration(now: expiration.addingTimeInterval(1))

        XCTAssertNil(store.activeClaim)
        XCTAssertEqual(store.claimUnavailableNotice?.reason, .claimExpired)
        XCTAssertFalse(ClaimFlowURLProtocol.capturedPaths.contains { $0.hasSuffix("/fulfill") })
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
    }

    func testExpiredClaimAtSubmissionSendsNoPostAndUsesFulfillmentSafetyWarning() async throws {
        let store = makeStore()
        let expiration = Date().addingTimeInterval(10 * 60)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimExpiresAt: expiration)))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

        do {
            try await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil,
                now: expiration.addingTimeInterval(1)
            )
            XCTFail("An expired claim must be blocked before the POST")
        } catch RequestServiceError.claimExpired {
            // Local precondition failure.
        } catch {
            XCTFail("Unexpected expiration error: \(error)")
        }

        XCTAssertNil(store.activeClaim)
        XCTAssertEqual(store.claimUnavailableNotice?.reason, .fulfillmentClaimExpired)
        XCTAssertFalse(ClaimFlowURLProtocol.capturedPaths.contains { $0.hasSuffix("/fulfill") })
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
    }

    func testConfirmedFulfillmentConflictsClearOnlyTheMatchingClaimAndRefresh() async throws {
        let cases: [(String, Int, ClaimUnavailableReason)] = [
            (ClaimErrorCode.claimExpired, 409, .fulfillmentClaimExpired),
            (ClaimErrorCode.invalidClaimToken, 403, .reservationNoLongerValid),
            (ClaimErrorCode.requestNotClaimed, 409, .reservationNoLongerValid),
            (ClaimErrorCode.requestAlreadyPlaced, 409, .fulfillmentAlreadyPlaced),
            (ClaimErrorCode.requestNotFound, 404, .fulfillmentRequestNotFound)
        ]

        for (code, status, reason) in cases {
            ClaimFlowURLProtocol.reset()
            let store = makeStore()
            ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
            try await store.claim(requestID: requestID)
            ClaimFlowURLProtocol.enqueue(.response(
                statusCode: status,
                data: errorResponse(code: code, message: "Confirmed conflict")
            ))
            ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

            do {
                try await store.fulfillWithFixtureScreenshot(
                    requestID: requestID,
                    orderNumber: "70154321",
                    eta: "15 minutes",
                    contactMessage: nil
                )
                XCTFail("\(code) should be a confirmed rejection")
            } catch RequestServiceError.serverError(let returnedCode, _) {
                XCTAssertEqual(returnedCode, code)
            } catch {
                XCTFail("Unexpected \(code) error: \(error)")
            }

            XCTAssertNil(store.activeClaim, code)
            XCTAssertEqual(store.claimUnavailableNotice?.reason, reason, code)
            await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
            await waitUntil { !store.isFetching }
        }
    }

    func testFirstFulfillmentInternalFailureUsesOneReadAndOneControlledRecovery() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 500,
            data: errorResponse(code: ClaimErrorCode.internalFailure, message: "Could not persist")
        ))
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "claimed")))

        do {
            try await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
            XCTFail("A commit-uncertain failure must not be success")
        } catch RequestServiceError.ambiguousFulfillmentOutcome {
            // Expected after the one read-only status check.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertNotNil(store.activeClaim)
        let ambiguity = try XCTUnwrap(store.fulfillmentAmbiguity)
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count, 1)
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.filter { $0 == "/api/request/\(requestID)" }.count, 1)

        // INTERNAL_FAILURE can accompany a placement that may in fact have
        // committed, so the copy must not assert that nothing was recorded, and
        // must separate re-sending these CommonPlate details from placing a
        // second Grubhub order.
        XCTAssertFalse(store.canSubmitFulfillment(requestID: requestID))
        XCTAssertFalse(FulfillRequestView.isSubmissionEnabled(
            draft: FulfillmentFormDraft(
                orderNumber: "70154321",
                eta: FulfillmentReadyTime.fifteenMinutes.etaValue,
                readyTime: .fifteenMinutes
            ),
            hasPlacedOrderScreenshot: true,
            isOperationallyAvailable: store.canSubmitFulfillment(requestID: requestID)
        ))
        let message = FulfillRequestView.ambiguousDetail(isCheckingStatus: false)
        XCTAssertTrue(message.contains(Self.safetySentence))
        XCTAssertFalse(message.contains("place another external order"))

        // The only retry reuses the retained original payload and is consumed
        // before its POST starts.
        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse(notificationStatus: "sent")))
        try await store.resubmitAmbiguousFulfillment(
            ambiguityID: ambiguity.id,
            requestID: requestID
        )
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count, 2)
        let fulfillmentBodies = try ClaimFlowURLProtocol.capturedRequests
            .filter { $0.path.hasSuffix("/fulfill") }
            .map { try canonicalJSON($0.bodyObject) }
        XCTAssertEqual(fulfillmentBodies.count, 2)
        XCTAssertEqual(fulfillmentBodies[0], fulfillmentBodies[1])
        XCTAssertEqual(store.fulfillmentConfirmation?.kind, .notificationSent)
        do {
            try await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
            XCTFail("The ordinary submit remains unavailable after recovery")
        } catch RequestServiceError.noActiveClaim {
            // Expected: a second fulfillment POST is forbidden.
        }
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count, 2)
    }

    func testAmbiguousTransportPerformsOneReadAndBlocksEveryFurtherPost() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "claimed")))

        do {
            try await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
            XCTFail("Claimed detail remains inconclusive")
        } catch RequestServiceError.ambiguousFulfillmentOutcome {
            // Expected after the one read-only check.
        } catch {
            XCTFail("Unexpected ambiguity error: \(error)")
        }

        XCTAssertNotNil(store.activeClaim)
        XCTAssertNotNil(store.fulfillmentAmbiguity)
        XCTAssertFalse(store.canSubmitFulfillment(requestID: requestID))
        XCTAssertFalse(FulfillRequestView.isSubmissionEnabled(
            draft: FulfillmentFormDraft(
                orderNumber: "70154321",
                eta: FulfillmentReadyTime.fifteenMinutes.etaValue,
                readyTime: .fifteenMinutes
            ),
            hasPlacedOrderScreenshot: true,
            isOperationallyAvailable: store.canSubmitFulfillment(requestID: requestID)
        ))
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, [
            "/api/request/\(requestID)/claim",
            "/api/request/\(requestID)/fulfill",
            "/api/request/\(requestID)"
        ])

        do {
            try await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
            XCTFail("An unresolved POST must block another submission")
        } catch RequestServiceError.unresolvedFulfillment {
            // No second POST or GET.
        } catch {
            XCTFail("Unexpected blocked-state error: \(error)")
        }
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count, 1)
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.filter { $0 == "/api/request/\(requestID)" }.count, 1)

        let pathsBeforeExtension = ClaimFlowURLProtocol.capturedPaths
        await store.extendActiveClaim()
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, pathsBeforeExtension)
    }

    func testMismatchedOrNonPlacedFulfillmentSuccessIsAmbiguousNotConfirmed() async throws {
        for response in [
            fulfillmentResponse(
                notificationStatus: "sent",
                responseRequestID: "different-request"
            ),
            fulfillmentResponse(
                notificationStatus: "sent",
                responseStatus: "claimed"
            )
        ] {
            ClaimFlowURLProtocol.reset()
            let store = makeStore()
            ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
            try await store.claim(requestID: requestID)
            ClaimFlowURLProtocol.enqueue(.response(data: response))
            ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "claimed")))

            do {
                try await store.fulfillWithFixtureScreenshot(
                    requestID: requestID,
                    orderNumber: "70154321",
                    eta: "15 minutes",
                    contactMessage: nil
                )
                XCTFail("An untrusted success response must remain ambiguous")
            } catch RequestServiceError.ambiguousFulfillmentOutcome {
                // The one detail read did not positively confirm placement.
            } catch {
                XCTFail("Unexpected validation error: \(error)")
            }

            XCTAssertNotNil(store.activeClaim)
            XCTAssertNotNil(store.fulfillmentAmbiguity)
            XCTAssertNil(store.fulfillmentConfirmation)
            XCTAssertEqual(store.requests.first?.status, .claimed)
        }
    }

    func testUnstructuredServerResponseIsAmbiguousButStructuredServerErrorIsNot() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(statusCode: 500, data: Data("oops".utf8)))
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "open")))

        do {
            try await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
            XCTFail("An unstructured POST response cannot be trusted")
        } catch RequestServiceError.ambiguousFulfillmentOutcome {
            // Expected; the earlier structured-error test pins the opposite.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertNotNil(store.fulfillmentAmbiguity)
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count, 1)
    }

    func testOpenClaimed404AndFailedAmbiguityReadsRemainInconclusive() async throws {
        enum ReadResult {
            case status(String)
            case notFound
            case decodingFailure
            case failure
        }
        let results: [ReadResult] = [
            .status("open"), .status("claimed"), .notFound, .decodingFailure, .failure
        ]

        for result in results {
            ClaimFlowURLProtocol.reset()
            let store = makeStore()
            ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
            try await store.claim(requestID: requestID)
            ClaimFlowURLProtocol.enqueue(.failure(.timedOut))
            switch result {
            case .status(let status):
                ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: status)))
            case .notFound:
                ClaimFlowURLProtocol.enqueue(.response(
                    statusCode: 404,
                    data: errorResponse(code: ClaimErrorCode.requestNotFound, message: "Missing")
                ))
            case .decodingFailure:
                ClaimFlowURLProtocol.enqueue(.response(data: Data(#"{"request":{}}"#.utf8)))
            case .failure:
                ClaimFlowURLProtocol.enqueue(.failure(.notConnectedToInternet))
            }

            try? await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )

            XCTAssertNotNil(store.activeClaim)
            XCTAssertNotNil(store.fulfillmentAmbiguity)
            XCTAssertNil(store.fulfillmentConfirmation)
            XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count, 1)
            XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.filter { $0 == "/api/request/\(requestID)" }.count, 1)
        }
    }

    func testPlacedDetailResolvesAmbiguityWithEmailUnknownConfirmation() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "placed")))

        try await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )

        XCTAssertNil(store.activeClaim)
        XCTAssertNil(store.fulfillmentAmbiguity)
        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertEqual(store.fulfillmentConfirmation?.kind, .emailStatusUnknown)
        XCTAssertEqual(
            HelperSuccessCopy.accessibilityAnnouncement(for: .emailStatusUnknown),
            "Thanks for helping."
        )
    }

    func testAmbiguousSafetyAndManualRecoveryCopyAreExact() {
        XCTAssertEqual(
            FulfillRequestView.ambiguousTitle(isCheckingStatus: true),
            "We’re checking your order"
        )
        XCTAssertEqual(
            FulfillRequestView.ambiguousTitle(isCheckingStatus: false),
            "\(AppBrand.name) still can’t confirm the order details."
        )
        XCTAssertEqual(
            FulfillRequestView.ambiguousCheckingDetail,
            "Your order may already be saved. Don’t tap again or place another Grubhub order while we check."
        )
        XCTAssertEqual(
            FulfillRequestView.ambiguousUnresolvedDetail,
            "The original save or the one-time retry may have worked. Don’t place another Grubhub order. You can’t try saving again from this screen."
        )
        XCTAssertEqual(
            FulfillRequestView.ambiguityRecoveryContext,
            "\(AppBrand.name) still can’t confirm whether the first save worked, so these order details may already be recorded."
        )
        XCTAssertEqual(
            FulfillRequestView.ambiguityRecoveryTitle,
            "Try saving to \(AppBrand.name) once more?"
        )
        XCTAssertEqual(
            FulfillRequestView.ambiguityRecoveryDetail,
            "This sends the same order details to \(AppBrand.name) one more time. It will not place another Grubhub order or charge you again. Don’t place another Grubhub order."
        )
        XCTAssertEqual(
            FulfillRequestView.ambiguityRecoveryActionTitle,
            "Send details to \(AppBrand.name) once more"
        )
        XCTAssertEqual(FulfillRequestView.returnTitle, "Back to Home")
        XCTAssertFalse(FulfillRequestView.showsAmbiguityRecoveryAction(
            isCheckingStatus: true,
            isRecoveryAvailable: true
        ))
        XCTAssertTrue(FulfillRequestView.showsAmbiguityRecoveryAction(
            isCheckingStatus: false,
            isRecoveryAvailable: true
        ))
        XCTAssertFalse(FulfillRequestView.showsAmbiguityRecoveryAction(
            isCheckingStatus: false,
            isRecoveryAvailable: false
        ))

        // The context sentence travels with the decision: present while the
        // offer stands and while the one permitted repeat runs, gone once the
        // state is terminal and the question is no longer being asked.
        XCTAssertTrue(FulfillRequestView.showsAmbiguityRecoveryCopy(
            isRecoveryAvailable: true,
            isRecovering: false
        ))
        XCTAssertTrue(FulfillRequestView.showsAmbiguityRecoveryCopy(
            isRecoveryAvailable: false,
            isRecovering: true
        ))
        XCTAssertFalse(FulfillRequestView.showsAmbiguityRecoveryCopy(
            isRecoveryAvailable: false,
            isRecovering: false
        ))

        // The terminal state is reached by transport loss and by explicit
        // server refusal alike, so it may not name a cause it cannot know.
        for copy in [
            FulfillRequestView.ambiguousUnresolvedTitle,
            FulfillRequestView.ambiguousUnresolvedDetail
        ] {
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("lost the connection"), copy)
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("connection"), copy)
        }
        // It must still leave both writes open rather than asserting failure.
        XCTAssertTrue(
            FulfillRequestView.ambiguousUnresolvedDetail
                .contains("The original save or the one-time retry may have worked.")
        )

        // Every ambiguous state continues to forbid a second real-world order.
        for detail in [
            FulfillRequestView.ambiguousCheckingDetail,
            FulfillRequestView.ambiguousUnresolvedDetail,
            FulfillRequestView.ambiguityRecoveryDetail
        ] {
            XCTAssertTrue(detail.localizedCaseInsensitiveContains("grubhub order"), detail)
        }
        XCTAssertTrue(
            FulfillRequestView.ambiguousUnresolvedDetail.contains(Self.safetySentence)
        )
        for reason in [
            ClaimUnavailableReason.fulfillmentClaimExpired,
            .reservationNoLongerValid,
            .fulfillmentAlreadyPlaced,
            .fulfillmentRequestNotFound
        ] {
            let detail = HelperRequestPresentation.claimUnavailableDetail(for: reason) ?? ""
            XCTAssertTrue(
                detail.localizedCaseInsensitiveContains("grubhub order"),
                "Missing order warning for \(reason)"
            )
        }
    }

    /// One sentence, reproduced exactly, wherever a second real-world order
    /// would cost a student money. Paraphrase is the failure this locks out.
    func testEverySafetyStateUsesTheOneGrubhubOrderSentence() {
        let mustCarryTheSentence: [String] = [
            FulfillmentPresentationError.invalidDetails.message,
            FulfillmentPresentationError.rateLimited.message,
            FulfillmentPresentationError.temporarilyUnavailable.message,
            FulfillRequestView.ambiguousUnresolvedDetail,
            FulfillRequestView.ambiguityRecoveryDetail,
            HelperRequestPresentation.claimUnavailableDetail(for: .fulfillmentAlreadyPlaced) ?? "",
            HelperRequestPresentation.claimUnavailableDetail(for: .reservationNoLongerValid) ?? "",
            HelperRequestPresentation.claimUnavailableDetail(for: .fulfillmentRequestNotFound) ?? ""
        ]
        for copy in mustCarryTheSentence {
            XCTAssertTrue(
                copy.contains(Self.safetySentence),
                "Safety sentence missing or paraphrased: \(copy)"
            )
        }

        // The two states that must warn without that exact sentence — one is
        // mid-check, the other is the locked Day 4 pre-order expiration — still
        // have to forbid a real order in their own words.
        XCTAssertTrue(
            FulfillRequestView.ambiguousCheckingDetail
                .contains("Don’t tap again or place another Grubhub order while we check.")
        )
        let expiredAfterAttempt = HelperRequestPresentation
            .claimUnavailableDetail(for: .fulfillmentClaimExpired) ?? ""
        XCTAssertTrue(expiredAfterAttempt.contains("don’t place it again"))
        XCTAssertTrue(expiredAfterAttempt.contains("do not start now"))

        // Retired vocabulary must not creep back into any of it.
        let everySafetyString = mustCarryTheSentence + [
            FulfillmentPresentationError.couldNotRecord.message,
            FulfillRequestView.ambiguousCheckingDetail,
            expiredAfterAttempt,
            ClaimPresentationError.ambiguous.message,
            ClaimPresentationError.otherClaimInProgress.message
        ]
        for copy in everySafetyString {
            for retired in ["external order", "requester", "placement result", "marked placed"] {
                XCTAssertFalse(
                    copy.localizedCaseInsensitiveContains(retired),
                    "Retired term “\(retired)” in: \(copy)"
                )
            }
        }
    }

    /// A structured failure the helper can genuinely retry must say that the
    /// retry is in-app. An ambiguous one, which the store refuses, must not.
    func testRetryableFailuresSeparateInAppRetryFromAnotherGrubhubOrder() {
        XCTAssertTrue(
            FulfillmentPresentationError.couldNotRecord.message
                .contains(Self.inAppRetryDisclaimer)
        )
        // The other structured failures point at the same button without
        // implying the order itself needs repeating.
        XCTAssertTrue(
            FulfillmentPresentationError.rateLimited.message
                .contains("then tap “Finish helping” again")
        )
        XCTAssertTrue(
            FulfillmentPresentationError.temporarilyUnavailable.message
                .contains("Stay on this screen and try again in a moment.")
        )
        // Field-blind by design: the specific rule that failed is named on the
        // field, so the fallback names the two values the helper can re-check
        // without guessing which one the backend refused.
        XCTAssertTrue(
            FulfillmentPresentationError.invalidDetails.message
                .contains("then tap “Finish helping” again")
        )
        for error in [
            FulfillmentPresentationError.invalidDetails,
            .rateLimited,
            .temporarilyUnavailable,
            .couldNotRecord
        ] {
            XCTAssertFalse(
                error.message.localizedCaseInsensitiveContains("order again"),
                "Retry copy must never read as ordering again: \(error.message)"
            )
        }
    }

    func testStaleFulfillmentResponseCannotMutateAReplacementClaim() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "old-token")))
        try await store.claim(requestID: requestID)
        let oldGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            data: fulfillmentResponse(notificationStatus: "sent"),
            gate: oldGate
        ))
        let oldFulfillment = Task {
            try await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70150001",
                eta: "10 minutes",
                contactMessage: nil
            )
        }
        await waitUntil { oldGate.isWaiting }

        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        store.leaveActiveClaimFlow()
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "new-token")))
        try await store.claim(requestID: requestID)

        oldGate.open()
        try await oldFulfillment.value

        XCTAssertEqual(store.activeClaim?.requestID, requestID)
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertEqual(store.requests.first?.status, .claimed)
    }

    func testStaleAmbiguityReadCannotMutateAReplacementClaim() async throws {
        let store = makeStore()
        let oldExpiration = Date().addingTimeInterval(10 * 60)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimToken: "old-token",
            claimExpiresAt: oldExpiration
        )))
        try await store.claim(requestID: requestID)
        let readGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "placed"), gate: readGate))
        let oldFulfillment = Task {
            try? await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70150001",
                eta: "10 minutes",
                contactMessage: nil
            )
        }
        await waitUntil { readGate.isWaiting }

        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        store.revalidateActiveClaimExpiration(now: oldExpiration.addingTimeInterval(1))
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "new-token")))
        try await store.claim(requestID: requestID)

        readGate.open()
        await oldFulfillment.value

        XCTAssertEqual(store.activeClaim?.requestID, requestID)
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertNil(store.fulfillmentAmbiguity)
        XCTAssertEqual(store.requests.first?.status, .claimed)
    }

    func testBackNavigationGuaranteeStillPreservesPreSubmissionClaim() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "still-private")))
        try await store.claim(requestID: requestID)
        let paths = ClaimFlowURLProtocol.capturedPaths

        XCTAssertTrue(RequestDetailView.opensClaimedFlow(
            activeClaim: store.activeClaim,
            requestID: requestID
        ))
        XCTAssertTrue(store.canSubmitFulfillment(requestID: requestID))
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, paths)
        XCTAssertNil(store.fulfillmentAmbiguity)
    }

    // MARK: - Day 5 confirmation reachability

    /// The claim is cleared and the request is removed the moment placement is
    /// confirmed, so once the claimant screen is gone neither the pinned
    /// reservation nor the list can carry the result. The confirmation itself
    /// has to survive that, or the helper never learns the order was recorded
    /// and can never acknowledge it.
    func testConfirmedPlacementArrivingAfterThePresentingViewIsGoneStaysReachable() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        let gate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            data: fulfillmentResponse(notificationStatus: "failed"),
            gate: gate
        ))

        let submission = Task {
            try await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
        }
        await waitUntil { gate.isWaiting }
        gate.open()
        try await submission.value

        // Every claimant-screen anchor is gone: this is exactly the state a
        // helper who navigated Back mid-POST lands in.
        XCTAssertNil(store.activeClaim)
        XCTAssertTrue(store.requests.isEmpty)

        let confirmation = try XCTUnwrap(store.fulfillmentConfirmation)
        XCTAssertEqual(confirmation.requestID, requestID)
        XCTAssertEqual(confirmation.kind, .notificationFailed)
        XCTAssertEqual(
            HelperSuccessCopy.secondaryLine(for: confirmation.kind),
            "We couldn't email the requester."
        )
        // The confirmation still carries the meal's public identity.
        XCTAssertEqual(confirmation.vendor, "Crave NYU")
        XCTAssertEqual(confirmation.foodDescription, "Rice bowl")

        store.dismissFulfillmentConfirmation(id: confirmation.id)
        XCTAssertNil(store.fulfillmentConfirmation)
    }

    /// W4-H1 supersedes the former Got It gate. A still-displayed confirmation
    /// is presentation, so the next claim proceeds with it untouched on screen
    /// — no refusal, no recorded claim error, and a real POST is sent.
    func testAStillDisplayedConfirmationDoesNotGateTheNextClaim() async throws {
        let otherRequestID = "meal-b"
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse(notificationStatus: "failed")))
        try await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )
        let original = try XCTUnwrap(store.fulfillmentConfirmation)
        XCTAssertEqual(original.requestID, requestID)
        XCTAssertEqual(original.kind, .notificationFailed)
        let pathsAfterPlacement = ClaimFlowURLProtocol.capturedPaths

        // Deliberately NOT dismissed: eligibility must not depend on it.
        ClaimFlowURLProtocol.enqueue(.response(
            data: claimResponse(responseRequestID: otherRequestID)
        ))
        try await store.claim(requestID: otherRequestID)

        // The claim really went to the backend rather than being refused
        // locally, and no claim error was recorded for the second request.
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths,
            pathsAfterPlacement + ["/api/request/\(otherRequestID)/claim"]
        )
        XCTAssertNil(store.claimError(for: otherRequestID))
        XCTAssertEqual(store.activeClaim?.requestID, otherRequestID)

        // The prior result survives as presentation — helping again is not a
        // reason to drop a real sent/failed/unknown-email outcome.
        let held = try XCTUnwrap(store.fulfillmentConfirmation)
        XCTAssertEqual(held.id, original.id)
        XCTAssertEqual(held.requestID, requestID)
        XCTAssertEqual(held.kind, .notificationFailed)

        // And dismissing it, whenever that happens, changes no lifecycle state.
        store.dismissFulfillmentConfirmation(id: original.id)
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertEqual(store.activeClaim?.requestID, otherRequestID)
        XCTAssertTrue(store.canSubmitFulfillment(requestID: otherRequestID))

        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse(
            notificationStatus: "sent",
            responseRequestID: otherRequestID
        )))
        try await store.fulfillWithFixtureScreenshot(
            requestID: otherRequestID,
            orderNumber: "70159876",
            eta: "20 minutes",
            contactMessage: nil
        )
        XCTAssertEqual(store.fulfillmentConfirmation?.requestID, otherRequestID)
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") },
            ["/api/request/\(requestID)/fulfill", "/api/request/\(otherRequestID)/fulfill"]
        )
    }

    /// W4-H1: the acknowledgement refusal no longer exists to be explained.
    /// Every surviving `ClaimPresentationError` describes a real live
    /// constraint, and only the three that genuinely make claiming impossible
    /// or untruthful still withdraw the claim action.
    func testNoClaimRefusalDescribesAPlacementAcknowledgement() {
        let everyRefusalMessage: [String] = [
            ClaimPresentationError.alreadyClaimed,
            .noLongerAvailable,
            .notYetAvailable,
            .publicActionsPaused,
            .rateLimited,
            .ambiguous,
            .operationInProgress,
            .otherClaimInProgress,
            .existingActiveClaim,
            .couldNotStart
        ].map(\.message)

        for message in everyRefusalMessage {
            for retired in ["Got it", "Got It", "acknowledge", "last order"] {
                XCTAssertFalse(
                    message.localizedCaseInsensitiveContains(retired),
                    "Retired acknowledgement-gate term “\(retired)” in: \(message)"
                )
            }
        }

        // Exactly these three, and no completion state, withhold the action.
        XCTAssertFalse(RequestDetailView.showsClaimAction(for: .publicActionsPaused))
        XCTAssertFalse(RequestDetailView.showsClaimAction(for: .ambiguous))
        XCTAssertFalse(RequestDetailView.showsClaimAction(for: .existingActiveClaim))
        for permitted in [
            ClaimPresentationError.alreadyClaimed,
            .noLongerAvailable,
            .notYetAvailable,
            .rateLimited,
            .operationInProgress,
            .otherClaimInProgress,
            .couldNotStart
        ] {
            XCTAssertTrue(RequestDetailView.showsClaimAction(for: permitted), "\(permitted)")
        }
        XCTAssertTrue(RequestDetailView.showsClaimAction(for: nil))
    }

    func testDismissalClearsOnlyThatConfirmationAndChangesNoClaimEligibility() async throws {
        let otherRequestID = "meal-b"
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse(notificationStatus: "sent")))
        try await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )

        let confirmation = try XCTUnwrap(store.fulfillmentConfirmation)
        store.dismissFulfillmentConfirmation(id: UUID())
        XCTAssertNotNil(store.fulfillmentConfirmation, "A mismatched ID must not clear it")

        store.dismissFulfillmentConfirmation(id: confirmation.id)
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertNil(store.confirmedFulfillmentOutcome)

        ClaimFlowURLProtocol.enqueue(.response(
            data: claimResponse(responseRequestID: otherRequestID)
        ))
        try await store.claim(requestID: otherRequestID)
        XCTAssertTrue(store.canSubmitFulfillment(requestID: otherRequestID))

        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse(
            notificationStatus: "sent",
            responseRequestID: otherRequestID
        )))
        try await store.fulfillWithFixtureScreenshot(
            requestID: otherRequestID,
            orderNumber: "70159876",
            eta: "20 minutes",
            contactMessage: nil
        )
        XCTAssertEqual(store.fulfillmentConfirmation?.requestID, otherRequestID)
    }

    /// A fetch that started before the placement carries a pre-placement
    /// snapshot. `collectionRevision` must discard it rather than let it put the
    /// placed request back on the list behind the confirmation.
    func testPlacedRequestIsNotReinsertedByAFetchStartedBeforeConfirmation() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        XCTAssertEqual(store.requests.map(\.id), [requestID])

        let staleFetchGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            data: listResponse([requestObject(id: requestID, status: "open")]),
            gate: staleFetchGate
        ))
        let staleFetch = Task { await store.fetchRequests() }
        await waitUntil { staleFetchGate.isWaiting }

        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse(notificationStatus: "sent")))
        try await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )
        XCTAssertTrue(store.requests.isEmpty)

        staleFetchGate.open()
        await staleFetch.value

        XCTAssertTrue(store.requests.isEmpty, "A pre-placement snapshot must not reinsert it")
        XCTAssertEqual(store.fulfillmentConfirmation?.requestID, requestID)
    }

    // MARK: - Day 5 expiration and ambiguity presentation

    /// Drives the real lifecycle timer rather than the foreground seam: the
    /// warning must not depend on which path happens to notice the deadline.
    func testLifecycleTimerExpiryDuringUnresolvedAmbiguityUsesTheFulfillmentWarning() async throws {
        let store = makeStore()
        // Long enough that the stubbed POST and the one read finish well inside
        // it, so the post-attempt resume cannot pre-empt the timer and quietly
        // turn this into a test of the other path.
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimExpiresAt: Date().addingTimeInterval(2)
        )))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "claimed")))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

        try? await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )

        // The post-attempt resume must not have expired it yet, or this would be
        // testing that path instead of the timer.
        XCTAssertNotNil(store.activeClaim)
        XCTAssertNotNil(store.fulfillmentAmbiguity)
        XCTAssertNil(store.claimUnavailableNotice)

        await waitUntil(timeoutIterations: 800) { store.claimUnavailableNotice != nil }

        XCTAssertEqual(store.claimUnavailableNotice?.reason, .fulfillmentClaimExpired)
        XCTAssertEqual(
            HelperRequestPresentation.claimUnavailableTitle(for: .fulfillmentClaimExpired),
            "Your reservation ran out"
        )
        XCTAssertEqual(
            HelperRequestPresentation.claimUnavailableDetail(for: .fulfillmentClaimExpired),
            "If you already completed the Grubhub order, don’t place it again. CommonPlate may not have saved the details, so the student may not have been emailed. If you had not ordered yet, do not start now."
        )
        // The warning has to outlive the state it was derived from.
        XCTAssertNil(store.activeClaim)
        XCTAssertNil(store.fulfillmentAmbiguity)
        XCTAssertNotNil(store.claimUnavailableNotice)
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count, 1)
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    func testAmbiguityDistinguishesActiveCheckingFromSettledUncertainty() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        let readGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        ClaimFlowURLProtocol.enqueue(.response(
            data: detailResponse(status: "claimed"),
            gate: readGate
        ))

        let submission = Task {
            try? await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
        }
        await waitUntil { readGate.isWaiting }

        XCTAssertEqual(store.fulfillmentAmbiguity?.isCheckingStatus, true)
        XCTAssertEqual(store.fulfillmentAmbiguity?.isRecoveryAvailable, false)
        XCTAssertFalse(FulfillRequestView.showsAmbiguityRecoveryAction(
            isCheckingStatus: true,
            isRecoveryAvailable: true
        ))
        let checking = FulfillRequestView.ambiguousDetail(isCheckingStatus: true)
        XCTAssertEqual(checking, FulfillRequestView.ambiguousCheckingDetail)
        XCTAssertTrue(checking.contains("while we check"))

        readGate.open()
        await submission.value

        XCTAssertEqual(store.fulfillmentAmbiguity?.isCheckingStatus, false)
        XCTAssertEqual(store.fulfillmentAmbiguity?.isRecoveryAvailable, true)
        XCTAssertEqual(store.fulfillmentAmbiguity?.isRecovering, false)
        XCTAssertEqual(FulfillRequestView.ambiguityRecoveryTitle, "Try saving to \(AppBrand.name) once more?")
        XCTAssertEqual(
            FulfillRequestView.ambiguityRecoveryDetail,
            "This sends the same order details to \(AppBrand.name) one more time. It will not place another Grubhub order or charge you again. Don’t place another Grubhub order."
        )
        XCTAssertTrue(FulfillRequestView.showsAmbiguityRecoveryAction(
            isCheckingStatus: false,
            isRecoveryAvailable: true
        ))
        // It names an exit, so it has to offer one — and only the settled state
        // does, because the checking state is about to answer itself.
        XCTAssertTrue(FulfillRequestView.showsAmbiguityReturnAction(isCheckingStatus: false))
        XCTAssertFalse(FulfillRequestView.showsAmbiguityReturnAction(isCheckingStatus: true))
        XCTAssertEqual(FulfillRequestView.returnTitle, "Back to Home")

        // Settling performs no further work of any kind.
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, [
            "/api/request/\(requestID)/claim",
            "/api/request/\(requestID)/fulfill",
            "/api/request/\(requestID)"
        ])
        XCTAssertNotNil(store.activeClaim)
        XCTAssertFalse(store.canSubmitFulfillment(requestID: requestID))
    }

    func testManualRecoveryResendsThePrivateSnapshotExactlyOnceAndSurvivesReentry() async throws {
        let store = makeStore()
        let ambiguity = try await makeSettledFulfillmentAmbiguity(
            store: store,
            claimToken: "private-recovery-token",
            orderNumber: "00070154321",
            eta: "30 minutes",
            contactMessage: "Meet by the pickup shelf"
        )
        let originalRequest = try XCTUnwrap(
            ClaimFlowURLProtocol.capturedRequests.first { $0.path.hasSuffix("/fulfill") }
        )

        // A stale view callback cannot consume the live context.
        do {
            try await store.resubmitAmbiguousFulfillment(
                ambiguityID: UUID(),
                requestID: requestID
            )
            XCTFail("A mismatched ambiguity must not recover")
        } catch RequestServiceError.unresolvedFulfillment {
            // Expected.
        }
        XCTAssertEqual(store.fulfillmentAmbiguity?.id, ambiguity.id)
        XCTAssertEqual(store.fulfillmentAmbiguity?.isRecoveryAvailable, true)

        // Simulate leaving and recreating the screen. The view passes no form
        // values back, so the later wire body can only come from store state.
        var navigations = 0
        FulfillRequestView.returnHome(from: store) { navigations += 1 }
        XCTAssertEqual(navigations, 1)

        let recoveryGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            data: fulfillmentResponse(notificationStatus: "sent"),
            gate: recoveryGate
        ))
        let recovery = Task {
            try await store.resubmitAmbiguousFulfillment(
                ambiguityID: ambiguity.id,
                requestID: requestID
            )
        }
        await waitUntil { recoveryGate.isWaiting }

        // Consumed before the network response. Repeated taps cannot enqueue a
        // third POST even while the one permitted recovery is suspended.
        XCTAssertEqual(store.fulfillmentAmbiguity?.isRecoveryAvailable, false)
        XCTAssertEqual(store.fulfillmentAmbiguity?.isRecovering, true)
        for _ in 0..<2 {
            do {
                try await store.resubmitAmbiguousFulfillment(
                    ambiguityID: ambiguity.id,
                    requestID: requestID
                )
                XCTFail("A duplicate recovery tap must be refused")
            } catch RequestServiceError.operationInProgress {
                // Expected while the consumed attempt is running.
            }
        }

        let fulfillmentRequests = ClaimFlowURLProtocol.capturedRequests.filter {
            $0.path.hasSuffix("/fulfill")
        }
        XCTAssertEqual(fulfillmentRequests.count, 2)
        let recoveryRequest = try XCTUnwrap(fulfillmentRequests.last)
        XCTAssertEqual(
            try canonicalJSON(originalRequest.bodyObject),
            try canonicalJSON(recoveryRequest.bodyObject)
        )
        let recoveryBody = try XCTUnwrap(recoveryRequest.bodyObject)
        XCTAssertEqual(recoveryBody["claimToken"] as? String, "private-recovery-token")

        recoveryGate.open()
        try await recovery.value

        XCTAssertNil(store.fulfillmentAmbiguity)
        XCTAssertNil(store.activeClaim)
        XCTAssertEqual(store.fulfillmentConfirmation?.kind, .notificationSent)

        // The originating identity is gone. Re-entry with its old callback is
        // harmless and cannot produce a third POST.
        try? await store.resubmitAmbiguousFulfillment(
            ambiguityID: ambiguity.id,
            requestID: requestID
        )
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count,
            2
        )
    }

    func testLocallyExpiredManualRecoverySendsNoMutationAndUsesSafetyUnwind() async throws {
        let store = makeStore()
        let expiration = Date().addingTimeInterval(10 * 60)
        let ambiguity = try await makeSettledFulfillmentAmbiguity(
            store: store,
            claimExpiresAt: expiration
        )
        let postsBeforeRecovery = ClaimFlowURLProtocol.capturedPaths.filter {
            $0.hasSuffix("/fulfill")
        }.count
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

        do {
            try await store.resubmitAmbiguousFulfillment(
                ambiguityID: ambiguity.id,
                requestID: requestID,
                now: expiration.addingTimeInterval(1)
            )
            XCTFail("A locally expired claim must not be resubmitted")
        } catch RequestServiceError.claimExpired {
            // Expected.
        }

        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count,
            postsBeforeRecovery
        )
        XCTAssertNil(store.activeClaim)
        XCTAssertNil(store.fulfillmentAmbiguity)
        XCTAssertEqual(store.claimUnavailableNotice(for: requestID)?.reason, .fulfillmentClaimExpired)
        let warning = HelperRequestPresentation.claimUnavailableDetail(for: .fulfillmentClaimExpired) ?? ""
        XCTAssertTrue(warning.contains("don’t place it again"))
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    func testRecoveryPostCrossingTheDeadlineWaitsForItsTerminalResponse() async throws {
        let store = makeStore()
        let expiration = Date().addingTimeInterval(0.4)
        let ambiguity = try await makeSettledFulfillmentAmbiguity(
            store: store,
            claimExpiresAt: expiration
        )
        let recoveryGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            data: fulfillmentResponse(notificationStatus: "sent"),
            gate: recoveryGate
        ))
        let recovery = Task {
            try await store.resubmitAmbiguousFulfillment(
                ambiguityID: ambiguity.id,
                requestID: requestID
            )
        }
        await waitUntil { recoveryGate.isWaiting }

        store.revalidateActiveClaimExpiration(now: expiration.addingTimeInterval(1))
        XCTAssertNotNil(store.activeClaim, "An in-flight POST may already be committing")
        XCTAssertEqual(store.fulfillmentAmbiguity?.isRecovering, true)
        XCTAssertNil(store.claimUnavailableNotice(for: requestID))

        recoveryGate.open()
        try await recovery.value

        XCTAssertNil(store.activeClaim)
        XCTAssertNil(store.fulfillmentAmbiguity)
        XCTAssertEqual(store.fulfillmentConfirmation?.kind, .notificationSent)
    }

    func testAlreadyPlacedManualRecoveryResolvesWithoutClaimingEmailDelivery() async throws {
        let store = makeStore()
        let ambiguity = try await makeSettledFulfillmentAmbiguity(store: store)
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorResponse(
                code: ClaimErrorCode.requestAlreadyPlaced,
                message: "This request has already been placed."
            )
        ))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

        do {
            try await store.resubmitAmbiguousFulfillment(
                ambiguityID: ambiguity.id,
                requestID: requestID
            )
            XCTFail("The repeat reports the backend's already-placed verdict")
        } catch RequestServiceError.serverError(let code, _) {
            XCTAssertEqual(code, ClaimErrorCode.requestAlreadyPlaced)
        }

        XCTAssertNil(store.activeClaim)
        XCTAssertNil(store.fulfillmentAmbiguity)
        XCTAssertNil(store.fulfillmentConfirmation, "A 409 carries no email result")
        XCTAssertEqual(store.claimUnavailableNotice(for: requestID)?.reason, .fulfillmentAlreadyPlaced)
        XCTAssertEqual(
            HelperRequestPresentation.claimUnavailableTitle(for: .fulfillmentAlreadyPlaced),
            "This order is already recorded in CommonPlate."
        )
        // The 409 proves placement and nothing else. The original response was
        // never readable, so its notification result is unknown here and the
        // copy has to say so rather than declaring the helper finished.
        XCTAssertEqual(
            HelperRequestPresentation.claimUnavailableDetail(for: .fulfillmentAlreadyPlaced),
            "Don’t place another Grubhub order. We couldn’t confirm whether the student’s email was sent, so they may not know the order is ready."
        )
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count,
            2
        )
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    func testManualRecoveryAuthorizationFailuresUseExistingSafetyUnwind() async throws {
        let cases: [(code: String, statusCode: Int, reason: ClaimUnavailableReason)] = [
            (ClaimErrorCode.claimExpired, 409, .fulfillmentClaimExpired),
            (ClaimErrorCode.requestNotClaimed, 409, .reservationNoLongerValid),
            (ClaimErrorCode.invalidClaimToken, 403, .reservationNoLongerValid),
            (ClaimErrorCode.requestNotFound, 404, .fulfillmentRequestNotFound)
        ]

        for entry in cases {
            ClaimFlowURLProtocol.reset()
            let store = makeStore()
            let ambiguity = try await makeSettledFulfillmentAmbiguity(store: store)
            ClaimFlowURLProtocol.enqueue(.response(
                statusCode: entry.statusCode,
                data: errorResponse(code: entry.code, message: "Terminal recovery result")
            ))
            ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

            try? await store.resubmitAmbiguousFulfillment(
                ambiguityID: ambiguity.id,
                requestID: requestID
            )

            XCTAssertNil(store.activeClaim, entry.code)
            XCTAssertNil(store.fulfillmentAmbiguity, entry.code)
            XCTAssertEqual(store.claimUnavailableNotice(for: requestID)?.reason, entry.reason, entry.code)
            let warning = HelperRequestPresentation.claimUnavailableDetail(for: entry.reason) ?? ""
            XCTAssertTrue(
                warning.localizedCaseInsensitiveContains("grubhub order")
                    || warning.contains("don’t place it again"),
                entry.code
            )
            XCTAssertEqual(
                ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count,
                2,
                entry.code
            )
            await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
            await waitUntil { !store.isFetching }
        }
    }

    func testSecondAmbiguousResultChecksOnceThenPermanentlyBlocksRecovery() async throws {
        let store = makeStore()
        let ambiguity = try await makeSettledFulfillmentAmbiguity(store: store)
        ClaimFlowURLProtocol.enqueue(.failure(.timedOut))
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "claimed")))

        try? await store.resubmitAmbiguousFulfillment(
            ambiguityID: ambiguity.id,
            requestID: requestID
        )

        XCTAssertEqual(store.fulfillmentAmbiguity?.id, ambiguity.id)
        XCTAssertEqual(store.fulfillmentAmbiguity?.isCheckingStatus, false)
        XCTAssertEqual(store.fulfillmentAmbiguity?.isRecoveryAvailable, false)
        XCTAssertEqual(store.fulfillmentAmbiguity?.isRecovering, false)
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count,
            2
        )
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.filter { $0 == "/api/request/\(requestID)" }.count,
            2
        )

        try? await store.resubmitAmbiguousFulfillment(
            ambiguityID: ambiguity.id,
            requestID: requestID
        )
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count,
            2
        )
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.filter { $0 == "/api/request/\(requestID)" }.count,
            2
        )
    }

    /// Three backend answers that are neither ambiguous nor a claim verdict.
    /// All are decided before a transaction can commit, so they prove the
    /// recovery POST never reached placement and a further read could only
    /// re-report the original ambiguity — none of them earns one. The accepted
    /// rule still spends the one permitted attempt on them: the opportunity is
    /// consumed on the main actor before the request is sent, and nothing
    /// restores it. What must hold is that the resulting state stays honest —
    /// the original write is still unresolved, no further POST is reachable
    /// from any surface, and the copy does not blame a connection the server
    /// plainly answered. `INTERNAL_FAILURE` is excluded deliberately; it can
    /// accompany a committed placement and is covered separately.
    func testNonTerminalRecoveryRefusalsConsumeTheRecoveryAndStayHonest() async throws {
        let cases: [(code: String, statusCode: Int)] = [
            (ClaimErrorCode.rateLimited, 429),
            ("TRANSACTIONS_UNAVAILABLE", 503),
            ("INVALID_FULFILLMENT_PAYLOAD", 400)
        ]

        for entry in cases {
            ClaimFlowURLProtocol.reset()
            let store = makeStore()
            let ambiguity = try await makeSettledFulfillmentAmbiguity(store: store)
            let readsBeforeRecovery = ClaimFlowURLProtocol.capturedPaths.filter {
                $0 == "/api/request/\(requestID)"
            }.count
            ClaimFlowURLProtocol.enqueue(.response(
                statusCode: entry.statusCode,
                data: errorResponse(code: entry.code, message: "Refused without placing")
            ))

            do {
                try await store.resubmitAmbiguousFulfillment(
                    ambiguityID: ambiguity.id,
                    requestID: requestID
                )
                XCTFail("The refusal must surface, not resolve: \(entry.code)")
            } catch RequestServiceError.serverError(let code, _) {
                XCTAssertEqual(code, entry.code)
            }

            // None of these is a claim verdict, so the reservation survives and
            // the unresolved context keeps holding the token.
            XCTAssertNotNil(store.activeClaim, entry.code)
            let blocked = try XCTUnwrap(store.fulfillmentAmbiguity, entry.code)
            XCTAssertEqual(blocked.id, ambiguity.id, entry.code)
            XCTAssertFalse(blocked.isCheckingStatus, entry.code)
            XCTAssertFalse(blocked.isRecoveryAvailable, entry.code)
            XCTAssertFalse(blocked.isRecovering, entry.code)

            // A decoded server verdict is not an ambiguous outcome, so it buys
            // no extra read-only check — the one after the original POST was
            // the only one this flow performs.
            XCTAssertEqual(
                ClaimFlowURLProtocol.capturedPaths.filter { $0 == "/api/request/\(requestID)" }.count,
                readsBeforeRecovery,
                entry.code
            )

            // Terminal presentation: no POST action, an honest exit, and no
            // route back to the form.
            XCTAssertFalse(
                FulfillRequestView.showsAmbiguityRecoveryAction(
                    isCheckingStatus: blocked.isCheckingStatus,
                    isRecoveryAvailable: blocked.isRecoveryAvailable
                ),
                entry.code
            )
            XCTAssertFalse(
                FulfillRequestView.showsAmbiguityRecoveryCopy(
                    isRecoveryAvailable: blocked.isRecoveryAvailable,
                    isRecovering: blocked.isRecovering
                ),
                entry.code
            )
            XCTAssertTrue(
                FulfillRequestView.showsAmbiguityReturnAction(
                    isCheckingStatus: blocked.isCheckingStatus
                ),
                entry.code
            )
            XCTAssertFalse(store.canSubmitFulfillment(requestID: requestID), entry.code)

            // Neither surface can produce a third POST.
            do {
                try await store.resubmitAmbiguousFulfillment(
                    ambiguityID: ambiguity.id,
                    requestID: requestID
                )
                XCTFail("A consumed recovery must not resend: \(entry.code)")
            } catch RequestServiceError.unresolvedFulfillment {
                // Expected.
            }
            do {
                try await store.fulfillWithFixtureScreenshot(
                    requestID: requestID,
                    orderNumber: "70154321",
                    eta: "15 minutes",
                    contactMessage: nil
                )
                XCTFail("The form stays locked while unresolved: \(entry.code)")
            } catch RequestServiceError.unresolvedFulfillment {
                // Expected.
            }
            XCTAssertEqual(
                ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count,
                2,
                entry.code
            )

            // The wording the helper is left with must be true of a refusal.
            let settled = FulfillRequestView.ambiguousDetail(isCheckingStatus: false)
            XCTAssertEqual(settled, FulfillRequestView.ambiguousUnresolvedDetail, entry.code)
            XCTAssertFalse(settled.localizedCaseInsensitiveContains("connection"), entry.code)
            XCTAssertTrue(settled.contains(Self.safetySentence), entry.code)
        }
    }

    /// `INTERNAL_FAILURE` is the one decoded verdict that does not answer the
    /// question. The accepted contract records that it can accompany a
    /// placement that in fact committed, so the repeat earns the same single
    /// privacy-safe read an unreadable response gets — and a `placed` read
    /// resolves the whole flow without the helper being told anything about the
    /// student's email, which nobody here has read.
    func testRecoveryInternalFailureChecksOnceMoreAndResolvesConfirmedPlacement() async throws {
        let store = makeStore()
        let ambiguity = try await makeSettledFulfillmentAmbiguity(store: store)
        let readsBeforeRecovery = ClaimFlowURLProtocol.capturedPaths.filter {
            $0 == "/api/request/\(requestID)"
        }.count
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 500,
            data: errorResponse(
                code: ClaimErrorCode.internalFailure,
                message: "Unknown transaction result"
            )
        ))
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "placed")))

        // Resolved, so it returns rather than reporting the 500.
        try await store.resubmitAmbiguousFulfillment(
            ambiguityID: ambiguity.id,
            requestID: requestID
        )

        XCTAssertNil(store.activeClaim)
        XCTAssertNil(store.fulfillmentAmbiguity)
        XCTAssertTrue(store.requests.isEmpty)
        // A read proves persistence only. No notification status was ever
        // decoded, so the confirmation must be the unknown-email one.
        XCTAssertEqual(store.fulfillmentConfirmation?.kind, .emailStatusUnknown)
        XCTAssertNil(store.confirmedFulfillmentOutcome)
        XCTAssertNil(HelperSuccessCopy.secondaryLine(for: .emailStatusUnknown))

        // Exactly two POSTs, and exactly one read beyond the original check.
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count,
            2
        )
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.filter { $0 == "/api/request/\(requestID)" }.count,
            readsBeforeRecovery + 1
        )

        do {
            try await store.resubmitAmbiguousFulfillment(
                ambiguityID: ambiguity.id,
                requestID: requestID
            )
            XCTFail("A resolved flow has no recovery left")
        } catch RequestServiceError.unresolvedFulfillment {
            // Expected.
        }
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count,
            2
        )
    }

    /// The same extra read, when it answers nothing. `claimed` and a transport
    /// failure are both inconclusive — never proof that placement failed — so
    /// the flow lands in the permanently blocked state with the recovery still
    /// spent and no third POST available from any surface.
    func testRecoveryInternalFailureThatStaysUnknownEndsPermanentlyBlocked() async throws {
        let inconclusiveReads: [(name: String, stub: ClaimFlowURLProtocol.Stub)] = [
            ("claimed", .response(data: detailResponse(status: "claimed"))),
            ("transport", .failure(.networkConnectionLost))
        ]

        for entry in inconclusiveReads {
            ClaimFlowURLProtocol.reset()
            let store = makeStore()
            let ambiguity = try await makeSettledFulfillmentAmbiguity(store: store)
            let readsBeforeRecovery = ClaimFlowURLProtocol.capturedPaths.filter {
                $0 == "/api/request/\(requestID)"
            }.count
            ClaimFlowURLProtocol.enqueue(.response(
                statusCode: 500,
                data: errorResponse(
                    code: ClaimErrorCode.internalFailure,
                    message: "Unknown transaction result"
                )
            ))
            ClaimFlowURLProtocol.enqueue(entry.stub)

            do {
                try await store.resubmitAmbiguousFulfillment(
                    ambiguityID: ambiguity.id,
                    requestID: requestID
                )
                XCTFail("An unresolved repeat reports its verdict: \(entry.name)")
            } catch RequestServiceError.ambiguousFulfillmentOutcome {
                // The second commit-uncertain response remains ambiguous.
            }

            let blocked = try XCTUnwrap(store.fulfillmentAmbiguity, entry.name)
            XCTAssertEqual(blocked.id, ambiguity.id, entry.name)
            XCTAssertFalse(blocked.isCheckingStatus, entry.name)
            XCTAssertFalse(blocked.isRecoveryAvailable, entry.name)
            XCTAssertFalse(blocked.isRecovering, entry.name)
            XCTAssertNotNil(store.activeClaim, entry.name)
            XCTAssertNil(store.fulfillmentConfirmation, entry.name)
            XCTAssertFalse(store.canSubmitFulfillment(requestID: requestID), entry.name)
            XCTAssertFalse(
                FulfillRequestView.showsAmbiguityRecoveryAction(
                    isCheckingStatus: blocked.isCheckingStatus,
                    isRecoveryAvailable: blocked.isRecoveryAvailable
                ),
                entry.name
            )

            // One read for the original ambiguity, one after the repeat. No
            // polling, and no third POST from either surface.
            XCTAssertEqual(
                ClaimFlowURLProtocol.capturedPaths.filter { $0 == "/api/request/\(requestID)" }.count,
                readsBeforeRecovery + 1,
                entry.name
            )
            do {
                try await store.resubmitAmbiguousFulfillment(
                    ambiguityID: ambiguity.id,
                    requestID: requestID
                )
                XCTFail("A consumed recovery must not resend: \(entry.name)")
            } catch RequestServiceError.unresolvedFulfillment {
                // Expected.
            }
            do {
                try await store.fulfillWithFixtureScreenshot(
                    requestID: requestID,
                    orderNumber: "70154321",
                    eta: "15 minutes",
                    contactMessage: nil
                )
                XCTFail("The form stays locked while unresolved: \(entry.name)")
            } catch RequestServiceError.unresolvedFulfillment {
                // Expected.
            }
            XCTAssertEqual(
                ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count,
                2,
                entry.name
            )
        }
    }

    /// The decision point has to state the situation, not just the action. The
    /// locked question and detail describe what the button does; the sentence
    /// above them is the only place that says the first save may already have
    /// landed, and it has to survive the whole decision — including while the
    /// one permitted repeat is in flight.
    func testRecoveryDecisionStatesTheOrderMayAlreadyBeRecorded() async throws {
        let store = makeStore()
        let ambiguity = try await makeSettledFulfillmentAmbiguity(store: store)

        XCTAssertTrue(FulfillRequestView.showsAmbiguityRecoveryCopy(
            isRecoveryAvailable: ambiguity.isRecoveryAvailable,
            isRecovering: ambiguity.isRecovering
        ))
        XCTAssertTrue(
            FulfillRequestView.ambiguityRecoveryContext
                .localizedCaseInsensitiveContains("may already be recorded")
        )

        let recoveryGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            data: fulfillmentResponse(notificationStatus: "sent"),
            gate: recoveryGate
        ))
        let recovery = Task {
            try await store.resubmitAmbiguousFulfillment(
                ambiguityID: ambiguity.id,
                requestID: requestID
            )
        }
        await waitUntil { recoveryGate.isWaiting }

        let running = try XCTUnwrap(store.fulfillmentAmbiguity)
        XCTAssertTrue(FulfillRequestView.showsAmbiguityRecoveryCopy(
            isRecoveryAvailable: running.isRecoveryAvailable,
            isRecovering: running.isRecovering
        ))

        recoveryGate.open()
        try await recovery.value

        // Nothing in the unresolved half of this flow may tell the helper the
        // student was told. Only a decoded notification status may do that, and
        // these states never have one.
        let neverClaimsDelivery = [
            FulfillRequestView.ambiguityRecoveryContext,
            FulfillRequestView.ambiguityRecoveryDetail,
            FulfillRequestView.ambiguousCheckingDetail,
            FulfillRequestView.ambiguousUnresolvedDetail,
            HelperRequestPresentation.claimUnavailableDetail(for: .fulfillmentAlreadyPlaced) ?? "",
            HelperRequestPresentation.claimUnavailableDetail(for: .fulfillmentRequestNotFound) ?? "",
            HelperRequestPresentation.claimUnavailableDetail(for: .reservationNoLongerValid) ?? ""
        ]
        for copy in neverClaimsDelivery {
            for assertion in [
                "we sent",
                "we emailed",
                "we’ve emailed",
                "has been emailed",
                "was emailed",
                "the student knows",
                "nothing else to do"
            ] {
                XCTAssertFalse(
                    copy.localizedCaseInsensitiveContains(assertion),
                    "“\(assertion)” claims more than this state knows: \(copy)"
                )
            }
        }

        // The already-placed verdict proves persistence only, so it has to name
        // the notification gap the same way the unknown-email confirmation does.
        let alreadyPlaced = HelperRequestPresentation
            .claimUnavailableDetail(for: .fulfillmentAlreadyPlaced) ?? ""
        XCTAssertTrue(alreadyPlaced.localizedCaseInsensitiveContains("may not know"))
        XCTAssertTrue(alreadyPlaced.contains(Self.safetySentence))
    }

    func testStaleRecoveryStatusCheckCannotMutateAReplacementClaim() async throws {
        let store = makeStore()
        let oldExpiration = Date().addingTimeInterval(10 * 60)
        let ambiguity = try await makeSettledFulfillmentAmbiguity(
            store: store,
            claimToken: "old-recovery-token",
            claimExpiresAt: oldExpiration
        )
        let readGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        ClaimFlowURLProtocol.enqueue(.response(
            data: detailResponse(status: "placed"),
            gate: readGate
        ))
        let oldRecovery = Task {
            try? await store.resubmitAmbiguousFulfillment(
                ambiguityID: ambiguity.id,
                requestID: requestID
            )
        }
        await waitUntil { readGate.isWaiting }

        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        store.revalidateActiveClaimExpiration(now: oldExpiration.addingTimeInterval(1))
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }

        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "replacement-token")))
        try await store.claim(requestID: requestID)
        let replacementExpiration = store.activeClaim?.claimExpiresAt

        readGate.open()
        await oldRecovery.value

        XCTAssertEqual(store.activeClaim?.requestID, requestID)
        XCTAssertEqual(store.activeClaim?.claimExpiresAt, replacementExpiration)
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertNil(store.fulfillmentAmbiguity)
        XCTAssertTrue(store.canSubmitFulfillment(requestID: requestID))
    }

    /// The replacement reuses the same request ID, so only the per-claim
    /// identity separates it from the attempt whose response is still arriving.
    func testTerminalResponseFromAnOldAttemptCannotClearAReplacementClaim() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "old-token")))
        try await store.claim(requestID: requestID)

        let conflictGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorResponse(
                code: ClaimErrorCode.requestAlreadyPlaced,
                message: "Already placed"
            ),
            gate: conflictGate
        ))
        let oldAttempt = Task {
            try? await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70150001",
                eta: "10 minutes",
                contactMessage: nil
            )
        }
        await waitUntil { conflictGate.isWaiting }

        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        store.leaveActiveClaimFlow()
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }

        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "new-token")))
        try await store.claim(requestID: requestID)
        let replacementExpiration = store.activeClaim?.claimExpiresAt

        conflictGate.open()
        await oldAttempt.value

        XCTAssertEqual(store.activeClaim?.requestID, requestID)
        XCTAssertEqual(store.activeClaim?.claimExpiresAt, replacementExpiration)
        XCTAssertNil(store.claimUnavailableNotice, "An old conflict must not end the replacement")
        XCTAssertNil(store.fulfillError)
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertEqual(store.requests.first?.status, .claimed)
        XCTAssertTrue(store.canSubmitFulfillment(requestID: requestID))
    }

    // MARK: - Pre-flight claim refusals

    /// The refusal is decided before any attempt exists, and `startClaim()`
    /// discards the thrown error, so only a published event can carry the
    /// accepted copy to the screen.
    func testClaimingWhileHoldingAnotherReservationPublishesTheRefusal() async throws {
        let requestB = "meal-b"
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "token-for-a")))
        try await store.claim(requestID: requestID)
        let pathsAfterFirstClaim = ClaimFlowURLProtocol.capturedPaths

        do {
            try await store.claim(requestID: requestB)
            XCTFail("A second claim must not start while one is held")
        } catch RequestServiceError.existingActiveClaim {
            // Expected.
        } catch {
            XCTFail("Unexpected refusal: \(error)")
        }

        let recorded = try XCTUnwrap(
            store.claimError(for: requestB),
            "The refusal must reach the screen the helper tapped"
        )
        XCTAssertEqual(ClaimPresentationError.map(recorded), .existingActiveClaim)
        XCTAssertEqual(
            ClaimPresentationError.existingActiveClaim.message,
            "You’re already helping with another request. Finish that one or wait for its reservation to end."
        )
        XCTAssertFalse(RequestDetailView.showsClaimAction(for: .existingActiveClaim))

        // Request-scoped: unrelated details stay clean.
        XCTAssertNil(store.claimError(for: requestID))
        XCTAssertNil(store.claimError(for: "meal-c"))

        // No POST for B, and A is untouched and still re-enterable.
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, pathsAfterFirstClaim)
        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(claim.requestID, requestID)
        XCTAssertFalse(String(describing: claim).contains("Taylor"))
        XCTAssertTrue(RequestDetailView.opensClaimedFlow(
            activeClaim: store.activeClaim,
            requestID: requestID
        ))

        // The blocker going away retires the refusal it produced.
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        store.leaveActiveClaimFlow()
        XCTAssertNil(store.claimError(for: requestB))
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    func testDuplicateTapWhileAClaimIsInFlightPublishesOperationInProgress() async throws {
        let store = makeStore()
        let claimGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(), gate: claimGate))

        let firstClaim = Task { try await store.claim(requestID: requestID) }
        await waitUntil { claimGate.isWaiting }
        XCTAssertTrue(store.isClaiming(requestID: requestID))

        do {
            try await store.claim(requestID: requestID)
            XCTFail("A duplicate tap must not start a second claim")
        } catch RequestServiceError.operationInProgress {
            // Expected.
        } catch {
            XCTFail("Unexpected duplicate error: \(error)")
        }

        let recorded = try XCTUnwrap(store.claimError(for: requestID))
        XCTAssertEqual(ClaimPresentationError.map(recorded), .operationInProgress)
        XCTAssertEqual(
            ClaimPresentationError.operationInProgress.message,
            "You’re already starting to help with this request."
        )
        XCTAssertNil(store.claimError(for: "meal-b"), "The refusal is request-scoped")
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/claim") }.count,
            1,
            "Exactly one claim POST"
        )

        claimGate.open()
        try await firstClaim.value
        XCTAssertEqual(store.activeClaim?.requestID, requestID)
        XCTAssertNil(
            store.claimError(for: requestID),
            "The attempt finished starting, so the refusal is retired"
        )
    }

    /// The other request is not "already starting", so borrowing the
    /// same-request sentence would misdescribe the screen the helper is on.
    func testInFlightClaimOnAnotherRequestPublishesItsOwnHonestRefusal() async throws {
        let requestB = "meal-b"
        let store = makeStore()
        let claimGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(), gate: claimGate))

        let claimA = Task { try await store.claim(requestID: requestID) }
        await waitUntil { claimGate.isWaiting }

        do {
            try await store.claim(requestID: requestB)
            XCTFail("A concurrent claim must be refused")
        } catch RequestServiceError.otherClaimInProgress {
            // Expected: distinct from the same-request duplicate.
        } catch {
            XCTFail("Unexpected concurrent-claim error: \(error)")
        }

        let recorded = try XCTUnwrap(
            store.claimError(for: requestB),
            "The refusal must reach the screen the helper tapped"
        )
        XCTAssertEqual(ClaimPresentationError.map(recorded), .otherClaimInProgress)
        XCTAssertEqual(RequestDetailView.otherClaimInProgressTitle, "Please wait")
        XCTAssertEqual(
            RequestDetailView.otherClaimInProgressNotice,
            "We’re still reserving another request. Try this one again in a moment."
        )
        // A moment's wait, not "go finish that whole order first" — which is
        // what the existing-reservation refusal means.
        XCTAssertFalse(
            RequestDetailView.otherClaimInProgressNotice
                .localizedCaseInsensitiveContains("finish")
        )
        let message = ClaimPresentationError.otherClaimInProgress.message
        XCTAssertTrue(message.contains(RequestDetailView.otherClaimInProgressTitle))
        XCTAssertTrue(message.contains(RequestDetailView.otherClaimInProgressNotice))
        XCTAssertFalse(
            message.contains("this request."),
            "It must not claim that *this* request is already starting"
        )
        XCTAssertNotEqual(message, ClaimPresentationError.operationInProgress.message)
        // A short wait, not a commitment elsewhere: the action stays offered.
        XCTAssertTrue(RequestDetailView.showsClaimAction(for: .otherClaimInProgress))

        // Scoped to B only, and A's attempt is untouched.
        XCTAssertNil(store.claimError(for: requestID))
        XCTAssertNil(store.claimError(for: "meal-c"))
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/claim") }.count,
            1,
            "Exactly one claim POST"
        )
        XCTAssertTrue(store.isClaiming(requestID: requestID))
        XCTAssertFalse(store.isClaiming(requestID: requestB))

        claimGate.open()
        try await claimA.value

        // A completed normally and the refusal it caused is retired.
        XCTAssertEqual(store.activeClaim?.requestID, requestID)
        XCTAssertFalse(String(describing: store.activeClaim).contains("Taylor"))
        XCTAssertNil(
            store.claimError(for: requestB),
            "The blocker resolved, so the wait notice must go"
        )
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/claim") }.count,
            1
        )
    }

    /// Same request, same moment: this one really is already starting, and its
    /// existing sentence must not have been swapped for the new one.
    func testSameRequestDuplicateTapStillUsesTheOperationInProgressCopy() async throws {
        let store = makeStore()
        let claimGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(), gate: claimGate))

        let claimA = Task { try await store.claim(requestID: requestID) }
        await waitUntil { claimGate.isWaiting }

        do {
            try await store.claim(requestID: requestID)
            XCTFail("A duplicate tap must be refused")
        } catch RequestServiceError.operationInProgress {
            // Expected: unchanged from Day 4.
        } catch {
            XCTFail("Unexpected duplicate error: \(error)")
        }

        let recorded = try XCTUnwrap(store.claimError(for: requestID))
        XCTAssertEqual(ClaimPresentationError.map(recorded), .operationInProgress)
        XCTAssertEqual(
            ClaimPresentationError.operationInProgress.message,
            "You’re already starting to help with this request."
        )

        claimGate.open()
        try await claimA.value
        XCTAssertEqual(store.activeClaim?.requestID, requestID)
    }

    /// W4-H1: the preflight event mechanism still carries every surviving
    /// refusal, and confirmed completion is simply not one of them — the very
    /// next claim after a confirmed placement reaches the backend.
    func testPreflightRefusalsSurviveWhileConfirmedCompletionRefusesNothing() async throws {
        let requestB = "meal-b"
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse(notificationStatus: "sent")))
        try await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )
        XCTAssertNotNil(store.fulfillmentConfirmation)
        // Confirmed fulfillment released the reservation locally too.
        XCTAssertNil(store.activeClaim)

        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(responseRequestID: requestB)))
        try await store.claim(requestID: requestB)
        XCTAssertNil(store.claimError(for: requestB))
        XCTAssertEqual(store.activeClaim?.requestID, requestB)

        // The mechanism itself is intact: the now-active claim on B refuses a
        // third request through the ordinary one-active-reservation refusal.
        do {
            try await store.claim(requestID: "meal-c")
            XCTFail("An active reservation must still refuse another claim")
        } catch RequestServiceError.existingActiveClaim {
            // Expected.
        }
        let refused = try XCTUnwrap(store.claimError(for: "meal-c"))
        XCTAssertEqual(ClaimPresentationError.map(refused), .existingActiveClaim)
        XCTAssertNil(store.claimError(for: requestB))
    }

    // MARK: - Day 5 extension expiry

    func testExtensionExpiryWithoutAFulfillmentAttemptKeepsTheDay4Warning() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorResponse(code: ClaimErrorCode.claimExpired, message: "Claim expired")
        ))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

        await store.extendActiveClaim()

        XCTAssertEqual(store.claimUnavailableNotice?.reason, .claimExpired)
        XCTAssertEqual(
            HelperRequestPresentation.claimUnavailableDetail(for: .claimExpired),
            "Please don’t place an order for that request. Someone else may already be helping."
        )
        XCTAssertNil(store.activeClaim)
        XCTAssertFalse(ClaimFlowURLProtocol.capturedPaths.contains { $0.hasSuffix("/fulfill") })
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    /// A nonterminal fulfillment failure leaves the claim alive and the helper
    /// holding a real external order. If the backend then expires the claim on
    /// the extension call, that is the same situation the timer announces and
    /// must not be described as though nothing had been ordered.
    func testExtensionExpiryAfterAFulfillmentAttemptUsesTheFulfillmentWarning() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 429,
            data: errorResponse(code: ClaimErrorCode.rateLimited, message: "Too many attempts")
        ))
        try? await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )
        XCTAssertNotNil(store.activeClaim, "A nonterminal failure keeps the reservation")

        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorResponse(code: ClaimErrorCode.claimExpired, message: "Claim expired")
        ))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

        await store.extendActiveClaim()

        XCTAssertEqual(store.claimUnavailableNotice?.reason, .fulfillmentClaimExpired)
        XCTAssertEqual(
            HelperRequestPresentation.claimUnavailableDetail(for: .fulfillmentClaimExpired),
            "If you already completed the Grubhub order, don’t place it again. CommonPlate may not have saved the details, so the student may not have been emailed. If you had not ordered yet, do not start now."
        )
        // The warning has to outlive the claimant state it was derived from.
        XCTAssertNil(store.activeClaim)
        XCTAssertNotNil(store.claimUnavailableNotice)
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count, 1)
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    func testStaleExtensionFailureCannotMutateAReplacementClaim() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "old-token")))
        try await store.claim(requestID: requestID)

        let extensionGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorResponse(code: ClaimErrorCode.claimExpired, message: "Claim expired"),
            gate: extensionGate
        ))
        let staleExtension = Task { await store.extendActiveClaim() }
        await waitUntil { extensionGate.isWaiting }

        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        store.leaveActiveClaimFlow()
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }

        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "new-token")))
        try await store.claim(requestID: requestID)
        let replacementExpiration = store.activeClaim?.claimExpiresAt

        extensionGate.open()
        await staleExtension.value

        XCTAssertEqual(store.activeClaim?.requestID, requestID)
        XCTAssertEqual(store.activeClaim?.claimExpiresAt, replacementExpiration)
        XCTAssertNil(store.claimUnavailableNotice, "An old expiry must not end the replacement")
        XCTAssertNil(store.claimExtensionError)
        XCTAssertTrue(store.canSubmitFulfillment(requestID: requestID))
    }

    // MARK: - Helpers

    private var requestListFetchCount: Int {
        ClaimFlowURLProtocol.capturedPaths.filter { $0 == "/api/requests" }.count
    }

    private func publishClaimUnavailableNotice(
        store: RequestStore,
        requestID: String,
        code: String,
        statusCode: Int,
        refreshStub: ClaimFlowURLProtocol.Stub
    ) async throws -> ClaimUnavailableNotice {
        let refreshesBeforeClaim = requestListFetchCount
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: statusCode,
            data: errorResponse(code: code, message: "Confirmed unavailable")
        ))
        ClaimFlowURLProtocol.enqueue(refreshStub)

        try? await store.claim(requestID: requestID)

        await waitUntil { self.requestListFetchCount == refreshesBeforeClaim + 1 }
        await waitUntil { !store.isFetching }
        return try XCTUnwrap(store.claimUnavailableNotice(for: requestID))
    }

    private func makeSettledFulfillmentAmbiguity(
        store: RequestStore,
        claimToken: String = "claim-token",
        claimExpiresAt: Date = Date().addingTimeInterval(15 * 60),
        orderNumber: String = "70154321",
        eta: String = "15 minutes",
        contactMessage: String? = nil
    ) async throws -> FulfillmentAmbiguityPresentation {
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimToken: claimToken,
            claimExpiresAt: claimExpiresAt
        )))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "claimed")))

        do {
            try await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: orderNumber,
                eta: eta,
                contactMessage: contactMessage
            )
            XCTFail("The original submission should remain ambiguous")
        } catch RequestServiceError.ambiguousFulfillmentOutcome {
            // Expected after the one inconclusive status check.
        }

        let ambiguity = try XCTUnwrap(store.fulfillmentAmbiguity)
        XCTAssertFalse(ambiguity.isCheckingStatus)
        XCTAssertTrue(ambiguity.isRecoveryAvailable)
        XCTAssertFalse(ambiguity.isRecovering)
        return ambiguity
    }

    private func canonicalJSON(_ object: [String: Any]?) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: XCTUnwrap(object),
            options: [.sortedKeys]
        )
    }

    private func decodeStatus(_ value: String) throws -> RequestStatus {
        struct Wrapper: Decodable {
            let status: RequestStatusWire
        }
        let decoded = try JSONDecoder().decode(
            Wrapper.self,
            from: Data(#"{"status":"\#(value)"}"#.utf8)
        )
        return decoded.status.domainStatus
    }

    // MARK: - Leaving a confirmed placement

    /// The legacy list entry path: Active Requests → request detail → claim →
    /// Helping page. W4-H1: confirmed placement leaves the path for the success
    /// presentation, whose single automatic return lands on Home — not on
    /// Active Requests and not on an emptied Helping page.
    func testConfirmedPlacementReturnsHomeFromTheDetailEntryPath() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        let claimed = try XCTUnwrap(store.activeClaim?.request)

        // The stack this entry path actually builds. W4-H1: the confirmed
        // claim replaces the detail with Helping.
        var path: [AppRoute] = []
        path = AppRoute.appending(.requestDetail(claimed), to: path)
        path = AppRoute.enteringHeldRequest(try XCTUnwrap(store.activeClaim), from: path)
        XCTAssertEqual(path, [.fulfillment(claimed)])

        ClaimFlowURLProtocol.enqueue(
            .response(data: fulfillmentResponse(notificationStatus: "sent"))
        )
        try await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: FulfillmentReadyTime.asap.etaValue,
            contactMessage: nil
        )

        // Placement clears the claim immediately and leaves the confirmation
        // for the success presentation. The Helping page itself does not
        // truncate to a competing destination.
        let confirmation = try XCTUnwrap(store.fulfillmentConfirmation)
        XCTAssertNil(store.activeClaim)
        let unchanged = path
        path = FulfillRequestView.claimedFlowPath(
            path,
            activeRequestID: store.activeClaim?.requestID,
            confirmationRequestID: confirmation.requestID,
            requestID: requestID
        )
        XCTAssertEqual(path, unchanged)

        path = AppRoute.afterHelperSuccess(from: path)
        XCTAssertEqual(path, [], "successful completion returns to Home")
        XCTAssertFalse(AppRoute.containsHelperDestination(in: path, requestID: requestID))
        XCTAssertNil(store.activeClaim)
        XCTAssertFalse(store.requests.contains { $0.id == requestID })

        // W4-H1: with the confirmation still displayed and undismissed, the
        // next claim is attempted for real rather than refused locally.
        let pathsAfterPlacement = ClaimFlowURLProtocol.capturedPaths
        ClaimFlowURLProtocol.enqueue(
            .response(data: claimResponse(responseRequestID: "meal-b"))
        )
        try await store.claim(requestID: "meal-b")
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths,
            pathsAfterPlacement + ["/api/request/meal-b/claim"]
        )
        XCTAssertEqual(store.activeClaim?.requestID, "meal-b")

        store.dismissFulfillmentConfirmation(id: confirmation.id)
        XCTAssertNil(store.fulfillmentConfirmation)
    }

    /// The second supported entry: reopening the reservation from the pinned
    /// Active Requests item, with no request detail underneath. Same landing:
    /// Home.
    func testConfirmedPlacementReturnsHomeFromThePinnedEntryPath() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        let claimed = try XCTUnwrap(store.activeClaim?.request)

        var path: [AppRoute] = AppRoute.appending(
            .fulfillment(claimed),
            to: []
        )
        XCTAssertEqual(path, [.fulfillment(claimed)])

        ClaimFlowURLProtocol.enqueue(
            .response(data: fulfillmentResponse(notificationStatus: "failed"))
        )
        try await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: FulfillmentReadyTime.thirtyMinutes.etaValue,
            contactMessage: nil
        )

        let confirmation = try XCTUnwrap(store.fulfillmentConfirmation)
        XCTAssertEqual(confirmation.kind, .notificationFailed)

        path = FulfillRequestView.claimedFlowPath(
            path,
            activeRequestID: store.activeClaim?.requestID,
            confirmationRequestID: confirmation.requestID,
            requestID: requestID
        )
        XCTAssertEqual(path, [.fulfillment(claimed)])

        path = AppRoute.afterHelperSuccess(from: path)
        XCTAssertEqual(path, [])
        XCTAssertFalse(AppRoute.containsHelperDestination(in: path, requestID: requestID))
        XCTAssertEqual(store.fulfillmentConfirmation?.id, confirmation.id)
    }

    /// Whatever the helper flow stacked up, leaving it leaves nothing behind
    /// that Back could reach — including the detail for a *different* request
    /// that the blocked-claim shortcut pushes a reservation on top of.
    func testReturningNeverLeavesAHelperDestinationBackCouldReach() {
        let placed = foodRequest(id: requestID)
        let other = foodRequest(id: "meal-b")

        let stacks: [[AppRoute]] = [
            [.requestDetail(placed), .fulfillment(placed)],
            [.fulfillment(placed)],
            [.requestDetail(other), .fulfillment(placed)]
        ]

        for stack in stacks {
            let returned = AppRoute.returningHome(from: stack)
            XCTAssertEqual(returned, [], "\(stack)")
            XCTAssertNil(returned.last)
            XCTAssertFalse(
                AppRoute.containsHelperDestination(in: returned, requestID: requestID)
            )
            XCTAssertFalse(
                AppRoute.containsHelperDestination(in: returned, requestID: "meal-b")
            )
        }
    }

    /// Only a confirmed claim or an unacknowledged confirmation for *this*
    /// request keeps the claimant screen. When neither holds, the detail
    /// underneath is just as stale, so the whole flow unwinds rather than one
    /// level — otherwise the backend's verdict lands on a screen for a request
    /// the helper no longer holds.
    func testClaimEndingUnwindsTheDetailUnderneathToo() {
        let request = foodRequest(id: requestID)
        let path: [AppRoute] = [
            .requestDetail(request), .fulfillment(request)
        ]

        XCTAssertEqual(FulfillRequestView.claimedFlowPath(
            path,
            activeRequestID: nil,
            confirmationRequestID: nil,
            requestID: requestID
        ), [])
        XCTAssertEqual(FulfillRequestView.claimedFlowPath(
            path,
            activeRequestID: "meal-b",
            confirmationRequestID: nil,
            requestID: requestID
        ), [])
        XCTAssertEqual(FulfillRequestView.claimedFlowPath(
            path,
            activeRequestID: requestID,
            confirmationRequestID: nil,
            requestID: requestID
        ), path)
    }

    /// Entering is driven by republishable store state, so it has to be
    /// idempotent: one claim must never stack two identical destinations.
    /// W4-H1: Helping replaces the detail rather than sitting above it.
    func testConfirmedClaimPushesTheClaimantRouteOnlyOnce() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        let activeClaim = try XCTUnwrap(store.activeClaim)
        let base: [AppRoute] = [.requestDetail(activeClaim.request)]

        let opened = AppRoute.enteringHeldRequest(activeClaim, from: base)
        XCTAssertEqual(opened, [.fulfillment(activeClaim.request)])
        XCTAssertEqual(AppRoute.enteringHeldRequest(activeClaim, from: opened), opened)
        XCTAssertEqual(AppRoute.appending(.fulfillment(activeClaim.request), to: opened), opened)
    }

    /// The action names a destination, so it always produces one.
    func testReturnFallsBackToActiveRequestsWhenItIsNotOnThePath() {
        XCTAssertEqual(AppRoute.returningHome(from: []), [])
        XCTAssertEqual(
            AppRoute.returningHome(from: [.requestFood]),
            []
        )
    }

    /// W4-H1: after confirmed placement the destination is Home from every
    /// helper entry point — Home's board, the Active Requests list, and a
    /// helper new-request notification tap.
    func testSuccessfulCompletionReturnsHomeFromEveryHelperEntryPoint() {
        let request = foodRequest(id: requestID)
        // W4-H1: a confirmed claim replaces Request Detail with Helping, and a
        // held-request notification tap lands on Helping directly.
        let fromHome: [AppRoute] = [.fulfillment(request)]
        let fromActiveRequests: [AppRoute] = [.fulfillment(request)]
        let fromNotification = AppRoute.afterNotificationResolution(.heldByCurrentHelper(request))
        XCTAssertEqual(fromNotification, [.fulfillment(request)])

        for path in [fromHome, fromActiveRequests, fromNotification] {
            XCTAssertEqual(AppRoute.afterHelperSuccess(from: path), [], "\(path)")
        }
    }

    func testConfirmedPlacementAlwaysWinsOverAStaleActiveClaimWhenTruncating() {
        let request = foodRequest(id: requestID)
        let path: [AppRoute] = [
            .requestDetail(request), .fulfillment(request)
        ]

        // A confirmation for this request wins: the Helping page defers to the
        // success presentation rather than treating a stale claim as live, and
        // the one post-success destination is Home.
        let returned = FulfillRequestView.claimedFlowPath(
            path,
            activeRequestID: requestID,
            confirmationRequestID: requestID,
            requestID: requestID
        )

        XCTAssertEqual(returned, path)
        XCTAssertEqual(AppRoute.afterHelperSuccess(from: returned), [])
        XCTAssertEqual(FulfillRequestView.navigationTitle, "Helping")
    }

    func testFailedFulfillmentDoesNotPrematurelyUnwindNavigation() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        let claimed = try XCTUnwrap(store.activeClaim?.request)
        let path: [AppRoute] = [
            .requestDetail(claimed), .fulfillment(claimed)
        ]
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 503,
            data: errorResponse(code: "TRANSACTIONS_UNAVAILABLE", message: "Unavailable.")
        ))

        do {
            try await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
            XCTFail("A failed fulfillment must not confirm placement")
        } catch {
            // Expected.
        }

        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertEqual(store.activeClaim?.requestID, requestID)
        XCTAssertEqual(FulfillRequestView.claimedFlowPath(
            path,
            activeRequestID: store.activeClaim?.requestID,
            confirmationRequestID: store.fulfillmentConfirmation?.requestID,
            requestID: requestID
        ), path)
    }

    func testAmbiguousFulfillmentDoesNotPrematurelyUnwindNavigation() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        let claimed = try XCTUnwrap(store.activeClaim?.request)
        let path: [AppRoute] = [
            .requestDetail(claimed), .fulfillment(claimed)
        ]
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "open")))

        do {
            try await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
            XCTFail("An unresolved fulfillment must stay ambiguous")
        } catch RequestServiceError.ambiguousFulfillmentOutcome {
            // Expected.
        }

        XCTAssertNotNil(store.fulfillmentAmbiguity)
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertEqual(store.activeClaim?.requestID, requestID)
        XCTAssertEqual(FulfillRequestView.claimedFlowPath(
            path,
            activeRequestID: store.activeClaim?.requestID,
            confirmationRequestID: store.fulfillmentConfirmation?.requestID,
            requestID: requestID
        ), path)
    }

    // MARK: - When will it be ready?

    func testReadyTimeChoicesEncodeIntoTheUnchangedEtaField() {
        XCTAssertEqual(
            FulfillmentReadyTime.allCases.map(\.label),
            ["ASAP", "15 minutes", "30 minutes", "45 minutes", "60 minutes"]
        )

        for option in FulfillmentReadyTime.allCases {
            // What the helper picked is what the student is told: the visible
            // choice and the encoded `eta` string are the same text.
            XCTAssertEqual(option.etaValue, option.label)
            XCTAssertEqual(FulfillmentReadyTime.option(forETA: option.etaValue), option)
            XCTAssertFalse(option.etaValue.isEmpty)
        }

        XCTAssertEqual(FulfillRequestView.pickupETALabel, "Pickup ETA")
    }

    /// W4-H1: Pickup ETA is required and starts unchosen (`Choose time`), so
    /// `Finish helping` stays disabled until the helper picks one.
    func testPickupETAStartsUnchosenAndIsRequired() {
        let draft = FulfillmentFormDraft(orderNumber: "70154321")
        XCTAssertNil(draft.readyTime)
        XCTAssertEqual(draft.eta, "")
        XCTAssertEqual(FulfillRequestView.pickupETAPlaceholder, "Choose time")
        XCTAssertFalse(FulfillRequestView.isSubmissionEnabled(
            draft: draft,
            hasPlacedOrderScreenshot: true,
            isOperationallyAvailable: true
        ))
        // Free text that predates this control is not one of the choices, so it
        // is not silently rewritten into one.
        XCTAssertNil(FulfillmentReadyTime.option(forETA: "20 minutes"))
        XCTAssertEqual(FulfillmentReadyTime.option(forETA: " 45 MINUTES "), .fortyFiveMinutes)
    }

    /// The control is presentation only. The request body is byte-for-byte the
    /// already-accepted shape, with the selection carried in `eta`.
    func testPickedReadyTimeStillSendsTheExactAcceptedPayload() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "raw-token")))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(
            .response(data: fulfillmentResponse(notificationStatus: "sent"))
        )

        try await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: FulfillmentReadyTime.asap.etaValue,
            contactMessage: nil
        )

        let sent = try XCTUnwrap(
            ClaimFlowURLProtocol.capturedRequests.first { $0.path.hasSuffix("/fulfill") }
        )
        let body = try XCTUnwrap(sent.bodyObject)
        XCTAssertEqual(Set(body.keys), ["claimToken", "fulfillment"])
        let fulfillment = try XCTUnwrap(body["fulfillment"] as? [String: Any])
        XCTAssertEqual(Set(fulfillment.keys), ["orderNumber", "eta", "placedOrderScreenshot"])
        XCTAssertEqual(fulfillment["eta"] as? String, "ASAP")
        // The control's own vocabulary never reaches the wire.
        XCTAssertNil(fulfillment["readyTime"])
        XCTAssertNil(fulfillment["etaText"])
        XCTAssertNil(fulfillment["etaMinutes"])
    }

    // MARK: - Reservation form comprehension

    func testHelpingPageFormCopyUsesTheAcceptedLabels() {
        XCTAssertEqual(FulfillRequestView.afterYouOrderHeading, "After you order")
        XCTAssertEqual(FulfillRequestView.orderNumberLabel, "Order number")
        XCTAssertEqual(FulfillRequestView.pickupETALabel, "Pickup ETA")
        XCTAssertEqual(FulfillRequestView.messageLabel, "Message")
        XCTAssertEqual(FulfillRequestView.messageOptionalLabel, "Optional")
        XCTAssertEqual(FulfillRequestView.submitTitle, "Finish helping")

        let visibleFormCopy = [
            FulfillRequestView.afterYouOrderHeading,
            FulfillRequestView.orderNumberLabel,
            FulfillRequestView.orderNumberPlaceholder,
            FulfillRequestView.pickupETALabel,
            FulfillRequestView.pickupETAPlaceholder,
            FulfillRequestView.messagePlaceholder
        ]
        for copy in visibleFormCopy {
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("Ready in"), copy)
            for retired in ["external order", "requester", "I placed this order"] {
                XCTAssertFalse(copy.localizedCaseInsensitiveContains(retired), copy)
            }
        }
    }

    /// The pickup name is revealed only on the claimant Helping page, and the
    /// confirmation that outlives the claim carries public identity only.
    /// W4-R4 strengthens this: pickup name is gone from the request contract
    /// entirely, so a claim response that still carried one could not reach
    /// any presentation state at all.
    func testPickupNameStaysClaimantPrivateThroughConfirmation() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(pickupName: "Taylor")))
        try await store.claim(requestID: requestID)

        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertFalse(String(describing: claim).contains("Taylor"))

        ClaimFlowURLProtocol.enqueue(
            .response(data: fulfillmentResponse(notificationStatus: "sent"))
        )
        try await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: FulfillmentReadyTime.asap.etaValue,
            contactMessage: nil
        )

        // The confirmation outlives the claim and carries public identity only.
        let confirmation = try XCTUnwrap(store.fulfillmentConfirmation)
        XCTAssertNil(store.activeClaim)
        XCTAssertFalse(confirmation.vendor.contains("Taylor"))
        XCTAssertFalse(confirmation.foodDescription.contains("Taylor"))
    }

    // MARK: - Field-specific local validation

    func testInitialInvalidFulfillmentKeystrokesRemainQuiet() {
        let errors = FulfillmentFormValidator.validate(
            orderNumber: "ORDER"
        )
        let presentation = FulfillmentValidationPresentation()

        XCTAssertEqual(errors.map(\.field), [.orderNumber])
        XCTAssertTrue(presentation.visibleErrors(from: errors).isEmpty)
    }

    func testProductionFulfillmentFocusTransitionRevealsOnlyExitedInvalidField() {
        let errors = FulfillmentFormValidator.validate(
            orderNumber: "ORDER"
        )
        var presentation = FulfillmentValidationPresentation()

        presentation.handleFocusTransition(
            from: .orderNumber,
            to: nil,
            errors: errors
        )

        XCTAssertEqual(
            presentation.visibleErrors(from: errors).map(\.field),
            [.orderNumber]
        )
    }

    func testFulfillmentSubmitRevealsEveryErrorWithoutInvokingSubmission() async throws {
        let draft = FulfillmentFormDraft(
            orderNumber: "",
            eta: FulfillmentReadyTime.asap.etaValue,
            readyTime: .asap,
            contactMessage: "Keep the receipt"
        )
        var submissionCount = 0

        let result = try await FulfillRequestView.orchestrateSubmission(
            draft: draft,
            hasPlacedOrderScreenshot: true,
            presentation: FulfillmentValidationPresentation()
        ) { _ in
            submissionCount += 1
        }
        let errors = FulfillmentFormValidator.validate(
            orderNumber: draft.orderNumber
        )
        let visible = result.presentation.visibleErrors(from: errors)

        XCTAssertEqual(submissionCount, 0)
        XCTAssertFalse(result.didSubmit)
        XCTAssertEqual(visible.map(\.field), [.orderNumber])
        XCTAssertEqual(result.firstInvalidTextField, .orderNumber)
    }

    func testPresentedFulfillmentErrorUpdatesLiveWithoutActivatingSibling() {
        let initial = FulfillmentFormValidator.validate(
            orderNumber: "ORDER"
        )
        var presentation = FulfillmentValidationPresentation()
        presentation.presentAll(initial)
        XCTAssertEqual(presentation.presentedFields, [.orderNumber])

        let corrected = FulfillmentFormValidator.validate(
            orderNumber: "70154321"
        )
        XCTAssertTrue(
            presentation.visibleErrors(from: corrected).isEmpty,
            "The corrected order error clears live; email never errored, so its first keystroke stays quiet"
        )

        let invalidAgain = FulfillmentFormValidator.validate(
            orderNumber: "ORDER"
        )
        XCTAssertEqual(
            presentation.visibleErrors(from: invalidAgain).map(\.field),
            [.orderNumber]
        )

        let emptied = FulfillmentFormValidator.validate(
            orderNumber: ""
        )
        XCTAssertEqual(
            presentation.visibleErrors(from: emptied).first?.message,
            FulfillmentFormValidator.emptyOrderNumberMessage
        )
    }

    func testValidFulfillmentSubmitInvokesSubmissionOnceWithNormalizedValues() async throws {
        let draft = FulfillmentFormDraft(
            orderNumber: "  00070154321  ",
            eta: "  30 minutes  ",
            readyTime: .thirtyMinutes,
            contactMessage: "  Text me at pickup  "
        )
        var submissions: [FulfillmentSubmissionValues] = []

        let result = try await FulfillRequestView.orchestrateSubmission(
            draft: draft,
            hasPlacedOrderScreenshot: true,
            presentation: FulfillmentValidationPresentation()
        ) { values in
            submissions.append(values)
        }

        XCTAssertTrue(result.didSubmit)
        XCTAssertEqual(submissions.count, 1)
        XCTAssertEqual(submissions.first?.orderNumber, "00070154321")
        XCTAssertEqual(submissions.first?.eta, "30 minutes")
        XCTAssertEqual(submissions.first?.contactMessage, "Text me at pickup")
    }

    func testProgrammaticFulfillmentFocusChangesCannotSubmitOrRevealSiblings() {
        let errors = FulfillmentFormValidator.validate(
            orderNumber: "ORDER"
        )
        var presentation = FulfillmentValidationPresentation()
        let submissionCount = 0

        presentation.handleFocusTransition(from: nil, to: .orderNumber, errors: errors)
        XCTAssertTrue(presentation.visibleErrors(from: errors).isEmpty)

        presentation.handleFocusTransition(from: .orderNumber, to: nil, errors: errors)
        XCTAssertEqual(presentation.visibleErrors(from: errors).map(\.field), [.orderNumber])
        XCTAssertEqual(submissionCount, 0)
    }

    func testEmptyOrderNumberIsNamedOnItsOwnField() {
        XCTAssertEqual(
            FulfillmentFormValidator.orderNumberError(""),
            "Enter the Grubhub order number."
        )
        XCTAssertEqual(
            FulfillmentFormValidator.orderNumberError("  "),
            "Enter the Grubhub order number."
        )
        XCTAssertEqual(
            FulfillmentFormValidator.orderNumberError("\n\t"),
            "Enter the Grubhub order number."
        )
    }

    func testDigitsOnlyOrderNumbersAreAccepted() {
        for valid in ["1", "70154321", "  70154321  ", String(repeating: "7", count: 50)] {
            XCTAssertNil(FulfillmentFormValidator.orderNumberError(valid), valid)
        }
    }

    /// The reason this stays a string end to end. A numeric type would drop the
    /// zeroes and the value would no longer match the helper's confirmation.
    func testLeadingZeroOrderNumbersSurviveValidationExactly() {
        for withZeroes in ["0", "007", "00070154321", "0000000000"] {
            XCTAssertNil(FulfillmentFormValidator.orderNumberError(withZeroes), withZeroes)
        }
        XCTAssertNil(FulfillmentFormValidator.orderNumberError("00070154321"))
    }

    func testAnythingOtherThanDigitsIsRejectedWithUseNumbersOnly() {
        let nonNumeric = [
            "7015432A",       // one letter
            "A70154321",
            "7015 4321",      // space
            " 70 154 321 ",   // interior spaces survive trimming
            "7015-4321",      // dash
            "7015_4321",      // underscore
            "7015.4321",      // decimal point
            "+70154321",      // sign
            "-70154321",
            "70154321!",      // punctuation
            "ORDER123"        // the old contract's shape
        ]
        for invalid in nonNumeric {
            XCTAssertEqual(
                FulfillmentFormValidator.orderNumberError(invalid),
                "Use numbers only.",
                invalid
            )
        }
    }

    func testFiftyDigitsAreAcceptedAndFiftyOneAreNot() {
        XCTAssertNil(
            FulfillmentFormValidator.orderNumberError(String(repeating: "7", count: 50))
        )
        XCTAssertEqual(
            FulfillmentFormValidator.orderNumberError(String(repeating: "7", count: 51)),
            "Use 50 digits or fewer."
        )
    }

    /// Precedence: shortening has to happen first, so a value that breaks both
    /// rules is told it is too long rather than sent round the loop twice.
    func testLengthErrorTakesPrecedenceOverTheNumericError() {
        let tooLongAndNotNumeric = String(repeating: "7", count: 50) + "A"
        XCTAssertEqual(tooLongAndNotNumeric.count, 51)
        XCTAssertEqual(
            FulfillmentFormValidator.orderNumberError(tooLongAndNotNumeric),
            "Use 50 digits or fewer."
        )

        let letterFirst = "A" + String(repeating: "7", count: 50)
        XCTAssertEqual(
            FulfillmentFormValidator.orderNumberError(letterFirst),
            "Use 50 digits or fewer."
        )

        // At exactly 50 the length rule is satisfied, so the numeric rule is the
        // one that answers.
        XCTAssertEqual(
            FulfillmentFormValidator.orderNumberError(
                String(repeating: "7", count: 49) + "A"
            ),
            "Use numbers only."
        )
    }

    /// Every rule here is the backend's own, so a payload iOS accepts is one the
    /// backend's schema accepts too — which is what keeps the generic fallback
    /// genuinely reserved for rejections that carry no field attribution.
    func testLocalRulesMirrorTheBackendSchemaRatherThanInventingNewOnes() {
        // `orderNumber: /^[0-9]{1,50}$/`
        XCTAssertEqual(FulfillmentFormValidator.orderNumberMaximumLength, 50)
        XCTAssertNil(
            FulfillmentFormValidator.orderNumberError(String(repeating: "0", count: 50))
        )
        XCTAssertNotNil(
            FulfillmentFormValidator.orderNumberError(String(repeating: "0", count: 51))
        )
        // Ready time is a fixed-choice picker, so it has no local failure mode
        // and therefore no message of its own.
        XCTAssertEqual(FulfillmentFormField.allCases, [.orderNumber])
    }

    /// Every invalid field reports at once, in screen order, so the first one
    /// is also the one focused. Since W3-I1 the order number is the only
    /// locally validated field the reservation form has.
    func testValidationReportsEveryInvalidFieldInScreenOrder() {
        let errors = FulfillmentFormValidator.validate(
            orderNumber: "7015 4321"
        )
        XCTAssertEqual(errors.map(\.field), [.orderNumber])
        XCTAssertEqual(errors.first?.field, .orderNumber)
        XCTAssertEqual(
            errors.map(\.message),
            [
                "Use numbers only."
            ]
        )

        XCTAssertEqual(
            FulfillmentFormValidator.validate(
                orderNumber: "7015 4321"
            ).map(\.field),
            [.orderNumber]
        )
        XCTAssertTrue(
            FulfillmentFormValidator.validate(
                orderNumber: "70154321"
            ).isEmpty
        )
    }

    /// The point of validating locally: a formatting mistake never reaches the
    /// network, so nothing about a real Grubhub order is put at risk by it.
    func testLocallyInvalidDetailsSendNoFulfillmentPost() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)

        let draft = FulfillmentFormDraft(
            orderNumber: "ORDER-123",
            eta: FulfillmentReadyTime.thirtyMinutes.etaValue,
            readyTime: .thirtyMinutes,
            contactMessage: "Keep the receipt"
        )
        // W4-H1: `Finish helping` is disabled for this draft, and the
        // orchestration seam below still independently refuses it.
        XCTAssertTrue(store.canSubmitFulfillment(requestID: requestID))
        XCTAssertFalse(FulfillRequestView.isSubmissionEnabled(
            draft: draft,
            hasPlacedOrderScreenshot: true,
            isOperationallyAvailable: store.canSubmitFulfillment(requestID: requestID)
        ))
        let result = try await FulfillRequestView.orchestrateSubmission(
            draft: draft,
            hasPlacedOrderScreenshot: true,
            presentation: FulfillmentValidationPresentation()
        ) { values in
            try await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: values.orderNumber,
                eta: values.eta,
                contactMessage: values.contactMessage
            )
        }
        XCTAssertFalse(result.didSubmit)
        XCTAssertEqual(result.firstInvalidTextField, .orderNumber)
        let errors = FulfillmentFormValidator.validate(
            orderNumber: draft.orderNumber
        )
        XCTAssertEqual(
            result.presentation.visibleErrors(from: errors),
            [
                FulfillmentFieldError(
                    field: .orderNumber,
                    message: FulfillmentFormValidator.nonNumericOrderNumberMessage
                )
            ]
        )

        // The exact production orchestration seam returned before its injected
        // store closure, so the only captured call is still the claim.
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths,
            ["/api/request/\(requestID)/claim"]
        )
        XCTAssertFalse(ClaimFlowURLProtocol.capturedPaths.contains { $0.hasSuffix("/fulfill") })

        // Nothing about the reservation is disturbed by the rejection: the
        // claim is intact and a corrected submission is still permitted.
        XCTAssertEqual(store.activeClaim?.requestID, requestID)
        XCTAssertTrue(store.canSubmitFulfillment(requestID: requestID))
        XCTAssertNil(store.fulfillError)
        XCTAssertNil(store.fulfillmentConfirmation)
    }

    /// A backend rejection reports through the store without resetting any
    /// actual form draft, picker choice, message, or active claim.
    func testFulfillmentBackendFailurePreservesActualDraftAndClaim() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 429,
            data: errorResponse(code: ClaimErrorCode.rateLimited, message: "Too many attempts")
        ))

        let draft = FulfillmentFormDraft(
            orderNumber: "00070154321",
            eta: FulfillmentReadyTime.thirtyMinutes.etaValue,
            readyTime: .thirtyMinutes,
            contactMessage: "Text me at pickup"
        )
        let originalDraft = draft

        do {
            _ = try await FulfillRequestView.orchestrateSubmission(
                draft: draft,
                hasPlacedOrderScreenshot: true,
                presentation: FulfillmentValidationPresentation()
            ) { values in
                try await store.fulfillWithFixtureScreenshot(
                    requestID: requestID,
                    orderNumber: values.orderNumber,
                    eta: values.eta,
                    contactMessage: values.contactMessage
                )
            }
            XCTFail("The backend rejection must escape the production seam")
        } catch RequestServiceError.serverError(let code, _) {
            XCTAssertEqual(code, ClaimErrorCode.rateLimited)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(draft, originalDraft)
        XCTAssertEqual(draft.readyTime, .thirtyMinutes)
        XCTAssertEqual(draft.eta, "30 minutes")
        XCTAssertEqual(draft.contactMessage, "Text me at pickup")
        XCTAssertEqual(store.activeClaim?.requestID, requestID)
        XCTAssertEqual(FulfillmentPresentationError.map(store.fulfillError), .rateLimited)
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count,
            1
        )
    }

    /// The state this fallback actually describes: every locally checkable rule
    /// passed, the backend still refused, and its envelope carries no field
    /// attribution. So there is nothing highlighted to check — the message has
    /// to name the values the helper can re-read for themselves, without
    /// claiming which one was refused, and leave the same save action available.
    func testUnattributedPayloadRejectionNamesRecheckableValuesWithoutInventingFieldErrors() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 400,
            data: errorResponse(
                code: "INVALID_FULFILLMENT_PAYLOAD",
                message: "Invalid fulfillment payload"
            )
        ))

        let draft = FulfillmentFormDraft(
            orderNumber: "00070154321",
            eta: FulfillmentReadyTime.fortyFiveMinutes.etaValue,
            readyTime: .fortyFiveMinutes,
            contactMessage: "Leaving it at the front desk"
        )
        let originalDraft = draft
        // Mirrors `submitFulfillment`, which assigns the returned presentation
        // only on the success path. A thrown backend rejection must therefore
        // leave presentation history exactly as it was.
        var presentation = FulfillmentValidationPresentation()

        do {
            let result = try await FulfillRequestView.orchestrateSubmission(
                draft: draft,
                hasPlacedOrderScreenshot: true,
                presentation: presentation
            ) { values in
                try await store.fulfillWithFixtureScreenshot(
                    requestID: requestID,
                    orderNumber: values.orderNumber,
                    eta: values.eta,
                    contactMessage: values.contactMessage
                )
            }
            presentation = result.presentation
            XCTFail("The backend rejection must escape the production seam")
        } catch RequestServiceError.serverError(let code, _) {
            XCTAssertEqual(code, "INVALID_FULFILLMENT_PAYLOAD")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(
            FulfillmentPresentationError.map(store.fulfillError),
            .invalidDetails
        )
        XCTAssertEqual(
            FulfillmentPresentationError.invalidDetails.message,
            "We couldn’t save these details. Check the order number, then tap “Finish helping” again. Don’t place another Grubhub order."
        )

        // Nothing local failed, so nothing local may be named: the values are
        // still valid and no field error exists for this rejection to reveal.
        let fieldErrors = FulfillmentFormValidator.validate(
            orderNumber: draft.orderNumber
        )
        XCTAssertTrue(fieldErrors.isEmpty)
        XCTAssertTrue(presentation.presentedFields.isEmpty)
        XCTAssertTrue(presentation.visibleErrors(from: fieldErrors).isEmpty)
        // And the copy cannot send the helper looking for a marker that the
        // previous sentence promised and this state never renders.
        XCTAssertFalse(
            FulfillmentPresentationError.invalidDetails.message
                .localizedCaseInsensitiveContains("highlighted")
        )

        // The submission the helper would repeat is the one still on screen.
        XCTAssertEqual(draft, originalDraft)
        XCTAssertEqual(draft.orderNumber, "00070154321")
        XCTAssertEqual(draft.eta, "45 minutes")
        XCTAssertEqual(draft.readyTime, .fortyFiveMinutes)
        XCTAssertEqual(draft.contactMessage, "Leaving it at the front desk")

        // A rejected payload is not a claim verdict: the reservation stands and
        // the same CommonPlate save the message points at is still permitted.
        XCTAssertEqual(store.activeClaim?.requestID, requestID)
        XCTAssertTrue(store.canSubmitFulfillment(requestID: requestID))
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertNil(store.fulfillmentAmbiguity)
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count,
            1
        )

        // The action it names is the in-app save. The only Grubhub sentence is
        // the locked one that forbids a second order.
        XCTAssertTrue(
            FulfillmentPresentationError.invalidDetails.message
                .contains("tap “\(FulfillRequestView.submitTitle)” again")
        )
        XCTAssertTrue(
            FulfillmentPresentationError.invalidDetails.message.contains(Self.safetySentence)
        )
        XCTAssertEqual(
            FulfillmentPresentationError.invalidDetails.message
                .components(separatedBy: "Grubhub").count - 1,
            1
        )
        XCTAssertFalse(
            FulfillmentPresentationError.invalidDetails.message
                .localizedCaseInsensitiveContains("order again")
        )
    }

    /// The generic message is the fallback, never the first answer, and the
    /// sentence that made a formatting mistake look like a system failure is
    /// gone from the flow entirely.
    func testGenericFallbackIsReservedAndTheOldBlanketSentenceIsRetired() {
        XCTAssertEqual(
            FulfillmentPresentationError.invalidDetails.message,
            "We couldn’t save these details. Check the order number, then tap “Finish helping” again. Don’t place another Grubhub order."
        )
        // The locked safety sentence still applies to this state.
        XCTAssertTrue(
            FulfillmentPresentationError.invalidDetails.message.contains(Self.safetySentence)
        )

        let everyFulfillmentFlowString = [
            FulfillmentPresentationError.invalidDetails.message,
            FulfillmentPresentationError.rateLimited.message,
            FulfillmentPresentationError.temporarilyUnavailable.message,
            FulfillmentPresentationError.couldNotRecord.message,
            FulfillmentFormValidator.emptyOrderNumberMessage,
            FulfillmentFormValidator.nonNumericOrderNumberMessage,
            FulfillmentFormValidator.longOrderNumberMessage,
            FulfillRequestView.pickupETAPlaceholder,
            FulfillRequestView.submitTitle,
            FulfillRequestView.ambiguousCheckingDetail,
            FulfillRequestView.ambiguousUnresolvedDetail,
            HelperSuccessCopy.headline
        ] + [FulfillmentConfirmationKind.notificationSent, .notificationFailed, .emailStatusUnknown]
            .compactMap(HelperSuccessCopy.secondaryLine(for:))
        for copy in everyFulfillmentFlowString {
            XCTAssertFalse(
                copy.localizedCaseInsensitiveContains("Something here wasn’t accepted"),
                copy
            )
        }

        // Each field message names its own field's rule rather than deferring.
        for message in [
            FulfillmentFormValidator.emptyOrderNumberMessage,
            FulfillmentFormValidator.nonNumericOrderNumberMessage,
            FulfillmentFormValidator.longOrderNumberMessage
        ] {
            XCTAssertFalse(
                message.localizedCaseInsensitiveContains("highlighted fields"),
                message
            )
        }
    }

    /// The contract is digits-only, but the wire type is still a string. A
    /// leading-zero value proves both halves at once: it survives to the JSON
    /// unchanged, and it is quoted rather than emitted as a number.
    func testOrderNumberIsSentAsAStringWithLeadingZeroesIntact() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "raw-token")))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(
            .response(data: fulfillmentResponse(notificationStatus: "sent"))
        )

        try await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "00070154321",
            eta: FulfillmentReadyTime.asap.etaValue,
            contactMessage: nil
        )

        let sent = try XCTUnwrap(
            ClaimFlowURLProtocol.capturedRequests.first { $0.path.hasSuffix("/fulfill") }
        )
        let body = try XCTUnwrap(sent.bodyObject)
        let fulfillment = try XCTUnwrap(body["fulfillment"] as? [String: Any])

        // Decoded as a String, not an NSNumber, and byte-identical to the entry.
        XCTAssertEqual(fulfillment["orderNumber"] as? String, "00070154321")
        XCTAssertNil(fulfillment["orderNumber"] as? Int)
        XCTAssertNil(fulfillment["orderNumber"] as? Double)

        // And quoted on the wire, so no consumer can re-read it as a number.
        let rawJSON = try XCTUnwrap(String(data: try XCTUnwrap(sent.body), encoding: .utf8))
        XCTAssertTrue(rawJSON.contains("\"orderNumber\":\"00070154321\""), rawJSON)

        // The structure itself is untouched by the format change.
        XCTAssertEqual(Set(body.keys), ["claimToken", "fulfillment"])
        XCTAssertEqual(Set(fulfillment.keys), ["orderNumber", "eta", "placedOrderScreenshot"])
    }

    /// A non-numeric order number is refused locally, so a helper who has
    /// already paid for a real Grubhub order never spends a round trip on it.
    func testNonNumericOrderNumberSendsNoFulfillmentPost() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)

        for rejected in ["7015-4321", "ORDER123", String(repeating: "7", count: 51)] {
            XCTAssertFalse(
                FulfillmentFormValidator.validate(
                    orderNumber: rejected
                ).isEmpty,
                rejected
            )
        }

        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths,
            ["/api/request/\(requestID)/claim"]
        )
        XCTAssertFalse(ClaimFlowURLProtocol.capturedPaths.contains { $0.hasSuffix("/fulfill") })

        // The reservation is untouched, so the corrected value can still be sent.
        XCTAssertEqual(store.activeClaim?.requestID, requestID)
        XCTAssertTrue(store.canSubmitFulfillment(requestID: requestID))
        XCTAssertNil(store.fulfillError)
    }

    /// A public request value for navigation-path assertions. Route identity is
    /// what is under test, so the rest only has to be stable.
    private func foodRequest(id: String) -> FoodRequest {
        FoodRequest(
            id: id,
            diningSpot: DiningSpot(name: "Crave NYU", address: nil),
            foodDescription: "Rice bowl",
            pickupWindowText: "ASAP",
            mealSwipes: 2,
            windowStart: nil,
            windowEnd: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 3_600),
            status: .open
        )
    }

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
        configuration.protocolClasses = [ClaimFlowURLProtocol.self]
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

    private func listResponse(_ requestObjects: [String]) -> Data {
        Data(#"{"requests":[\#(requestObjects.joined(separator: ","))]}"#.utf8)
    }

    private func errorResponse(code: String, message: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"\#(message)","fields":null}}"#.utf8)
    }

    private func claimResponse(
        pickupName: String = "Taylor",
        claimToken: String = "claim-token",
        claimExpiresAt: Date = Date().addingTimeInterval(15 * 60),
        requestExpiresAt: Date = Date().addingTimeInterval(5 * 60 * 60),
        responseRequestID: String? = nil,
        responseStatus: String = "claimed",
        mealSwipes: Int = 2
    ) -> Data {
        Data("""
        {
          "request": \(requestObject(
            id: responseRequestID ?? requestID,
            mealSwipes: mealSwipes,
            status: responseStatus,
            expiresAt: iso8601String(requestExpiresAt)
          )),
          "claim": {
            "pickupName": "\(pickupName)",
            "claimToken": "\(claimToken)",
            "claimExpiresAt": "\(iso8601String(claimExpiresAt))"
          }
        }
        """.utf8)
    }

    private func extensionResponse(claimExpiresAt: Date, claimExtendedAt: Date) -> Data {
        Data("""
        {
          "claim": {
            "claimExpiresAt": "\(iso8601String(claimExpiresAt))",
            "claimExtendedAt": "\(iso8601String(claimExtendedAt))"
          }
        }
        """.utf8)
    }

    private func fulfillmentResponse(
        notificationStatus: String,
        responseRequestID: String? = nil,
        responseStatus: String = "placed"
    ) -> Data {
        Data("""
        {
          "request": \(requestObject(
            id: responseRequestID ?? requestID,
            status: responseStatus,
            expiresAt: iso8601String(Date().addingTimeInterval(5 * 60 * 60))
          )),
          "notification": { "status": "\(notificationStatus)" }
        }
        """.utf8)
    }

    private func detailResponse(status: String, responseRequestID: String? = nil) -> Data {
        Data("""
        {
          "request": \(requestObject(
            id: responseRequestID ?? requestID,
            status: status,
            expiresAt: iso8601String(Date().addingTimeInterval(5 * 60 * 60))
          ))
        }
        """.utf8)
    }

    private func requestObject(
        id: String,
        vendor: String = "Crave NYU",
        food: String = "Rice bowl",
        pickupWindowText: String = "ASAP",
        // Every request accepted since W3-C1 carries an integer 1-5, on every
        // accepted shape including the legacy web one, so an ordinary fixture
        // always supplies it.
        mealSwipes: Int = 2,
        status: String = "open",
        createdAt: String = "2026-07-20T18:30:00.000Z",
        expiresAt: String = "2026-07-20T23:30:00.000Z"
    ) -> String {
        """
        {
          "id": "\(id)",
          "vendor": "\(vendor)",
          "food": "\(food)",
          "pickupWindowText": "\(pickupWindowText)",
          "mealSwipes": \(mealSwipes),
          "menuPath": "meal-exchange",
          "mealItems": [],
          "orderDetails": null,
          "estimatedDiningDollarsCents": null,
          "windowStart": null,
          "windowEnd": null,
          "status": "\(status)",
          "createdAt": "\(createdAt)",
          "expiresAt": "\(expiresAt)"
        }
        """
    }

    private func waitUntil(
        timeoutIterations: Int = 200,
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
}
