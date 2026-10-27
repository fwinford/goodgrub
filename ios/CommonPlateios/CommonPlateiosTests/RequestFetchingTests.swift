import Foundation
import XCTest
@testable import CommonPlateios

final class RequestFetchingGate: @unchecked Sendable {
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

final class RequestFetchingURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let data: Data
        let errorCode: URLError.Code?
        let delay: TimeInterval
        let gate: RequestFetchingGate?

        static func response(
            statusCode: Int = 200,
            data: Data,
            delay: TimeInterval = 0,
            gate: RequestFetchingGate? = nil
        ) -> Stub {
            Stub(
                statusCode: statusCode,
                data: data,
                errorCode: nil,
                delay: delay,
                gate: gate
            )
        }

        static func failure(
            _ errorCode: URLError.Code,
            delay: TimeInterval = 0,
            gate: RequestFetchingGate? = nil
        ) -> Stub {
            Stub(
                statusCode: 0,
                data: Data(),
                errorCode: errorCode,
                delay: delay,
                gate: gate
            )
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var stubs: [Stub] = []
    private nonisolated(unsafe) static var requestedPaths: [String] = []
    // W3-I1: the participant credential travels in a header, and the create
    // payload must be provably free of an address, so both are captured.
    private nonisolated(unsafe) static var capturedHeaders: [[String: String]] = []
    private nonisolated(unsafe) static var capturedBodies: [Data] = []

    static func enqueue(_ stub: Stub) {
        lock.lock()
        stubs.append(stub)
        lock.unlock()
    }

    // W4-D2: `RequestStore` reads the operation ledger
    // (`GET /api/request-operation/authority`) before every participant-bound
    // create and before every recovery. Those reads are answered here, outside
    // the FIFO queue and outside `capturedRequestedPaths`, so a test about any
    // other request keeps its exact sequence. Queued ledger answers are used
    // first; with none queued the answer is `defaultOperationLedger`. D2 tests
    // assert on the captured ledger reads directly.
    static let operationLedgerPath = "/api/request-operation/authority"
    static let defaultOperationLedger = "7d8f1c2a-3b4e-4f60-8a71-92b3c4d5e6f7"
    private nonisolated(unsafe) static var operationLedgerStubs: [Stub] = []
    private nonisolated(unsafe) static var operationLedgerReads = 0

    static func enqueueOperationLedger(_ stub: Stub) {
        lock.lock()
        operationLedgerStubs.append(stub)
        lock.unlock()
    }

    static func operationLedgerResponse(_ ledger: String = defaultOperationLedger) -> Stub {
        .response(data: Data(#"{"operationAuthority":"\#(ledger)"}"#.utf8))
    }

    static var capturedOperationLedgerReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return operationLedgerReads
    }

    static func reset() {
        lock.lock()
        stubs.removeAll()
        requestedPaths.removeAll()
        capturedHeaders.removeAll()
        capturedBodies.removeAll()
        operationLedgerStubs.removeAll()
        operationLedgerReads = 0
        lock.unlock()
    }

    private static func dequeueOperationLedger() -> Stub {
        lock.lock()
        defer { lock.unlock() }
        operationLedgerReads += 1
        guard !operationLedgerStubs.isEmpty else {
            return operationLedgerResponse()
        }
        return operationLedgerStubs.removeFirst()
    }

    static var capturedRequestedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requestedPaths
    }

    /// Header field names are matched case-insensitively, because `URLSession`
    /// is free to normalize them and a case-sensitive lookup would silently
    /// pass a test that should fail.
    static var lastCapturedHeaders: [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        return capturedHeaders.last
    }

    static var lastCapturedBody: Data? {
        lock.lock()
        defer { lock.unlock() }
        return capturedBodies.last
    }

    private static func dequeue() -> Stub? {
        lock.lock()
        defer { lock.unlock() }
        guard !stubs.isEmpty else { return nil }
        return stubs.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        // `URLProtocol` hands the body through `httpBodyStream` for POST
        // requests built by `URLSession`, not `httpBody`.
        let body: Data
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            body = data
        } else {
            body = request.httpBody ?? Data()
        }
        var headers: [String: String] = [:]
        for (field, value) in request.allHTTPHeaderFields ?? [:] {
            headers[field.lowercased()] = value
        }

        let stub: Stub
        if request.url?.path == Self.operationLedgerPath {
            stub = Self.dequeueOperationLedger()
        } else {
            Self.lock.lock()
            Self.requestedPaths.append(request.url?.path ?? "")
            Self.capturedHeaders.append(headers)
            Self.capturedBodies.append(body)
            Self.lock.unlock()

            guard let queued = Self.dequeue() else {
                client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
                return
            }
            stub = queued
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
        } else if stub.delay > 0 {
            DispatchQueue.global().asyncAfter(
                deadline: .now() + stub.delay,
                execute: completeRequest
            )
        } else {
            completeRequest()
        }
    }

    override func stopLoading() {}
}

extension URLProtocol {
    /// W4-D2: `RequestStore` reads the operation ledger before every
    /// participant-bound create. A stub that models only other requests
    /// answers that read here with `RequestFetchingURLProtocol`'s default
    /// ledger, outside whatever it captures or queues. Returns whether it did.
    func answerOperationLedgerReadIfNeeded() -> Bool {
        guard request.url?.path == RequestFetchingURLProtocol.operationLedgerPath,
              let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            return false
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: RequestFetchingURLProtocol.operationLedgerResponse().data)
        client?.urlProtocolDidFinishLoading(self)
        return true
    }
}

@MainActor
final class RequestFetchingTests: XCTestCase {
    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    func testFinalizedListWrapperDecodesAndMapsPublicRequest() async throws {
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(
                id: "server-request-id",
                vendor: "Jasper Kane Cafe",
                food: "Chicken bowl",
                pickupWindowText: "Around 7:00 PM",
                windowStart: "2026-07-20T19:00:00.000Z",
                windowEnd: "2026-07-20T19:30:00.000Z",
                status: "open",
                createdAt: "2026-07-20T18:30:00.123Z",
                expiresAt: "2026-07-20T23:30:00.000Z"
            )
        ])))

        let requests = try await makeService().fetchActiveRequests(participantAuthority: "64c0000000000000000000a1.1.credential")
        let request = try XCTUnwrap(requests.first)

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.id, "server-request-id")
        XCTAssertEqual(request.diningSpot.name, "Jasper Kane Cafe")
        XCTAssertNil(request.diningSpot.address)
        XCTAssertEqual(request.foodDescription, "Chicken bowl")
        XCTAssertEqual(request.pickupWindowText, "Around 7:00 PM")
        XCTAssertEqual(request.windowStart, try iso8601Date("2026-07-20T19:00:00.000Z"))
        XCTAssertEqual(request.windowEnd, try iso8601Date("2026-07-20T19:30:00.000Z"))
        XCTAssertEqual(request.status, .open)
        XCTAssertEqual(request.createdAt, try iso8601Date("2026-07-20T18:30:00.123Z"))
        XCTAssertEqual(request.expiresAt, try iso8601Date("2026-07-20T23:30:00.000Z"))
    }

    func testInitialFetchSuccessOwnsCollectionAndLaterSuccessReplacesIt() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "first")
        ])))

        await store.fetchRequests()

        XCTAssertTrue(store.hasSuccessfullyFetchedRequests)
        XCTAssertEqual(store.requests.map(\.id), ["first"])
        XCTAssertNil(store.initialFetchError)

        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "replacement-a"),
            requestObject(id: "replacement-b")
        ])))

        await store.fetchRequests()

        XCTAssertEqual(store.requests.map(\.id), ["replacement-a", "replacement-b"])
        XCTAssertNil(store.refreshError)
    }

    func testSuccessfulEmptyInitialResponseIsDistinctFromInitialFailure() async {
        let emptyStore = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([])))

        await emptyStore.fetchRequests()

        XCTAssertTrue(emptyStore.hasSuccessfullyFetchedRequests)
        XCTAssertTrue(emptyStore.requests.isEmpty)
        XCTAssertNil(emptyStore.initialFetchError)

        let failedStore = makeStore()
        RequestFetchingURLProtocol.enqueue(.failure(.notConnectedToInternet))

        await failedStore.fetchRequests()

        XCTAssertFalse(failedStore.hasSuccessfullyFetchedRequests)
        XCTAssertTrue(failedStore.requests.isEmpty)
        XCTAssertNotNil(failedStore.initialFetchError)
        XCTAssertNil(failedStore.refreshError)
    }

    func testRetryAfterInitialFailureUsesTheSameFetchPath() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.failure(.notConnectedToInternet))

        await store.fetchRequests()

        XCTAssertFalse(store.hasSuccessfullyFetchedRequests)
        XCTAssertNotNil(store.initialFetchError)

        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "loaded-on-retry")
        ])))

        await store.fetchRequests()

        XCTAssertTrue(store.hasSuccessfullyFetchedRequests)
        XCTAssertEqual(store.requests.map(\.id), ["loaded-on-retry"])
        XCTAssertNil(store.initialFetchError)
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            ["/api/requests", "/api/requests"]
        )
    }

    /// An initial fetch whose snapshot is invalidated by a confirmed mutation
    /// publishes no error, so `initialFetchError` alone cannot tell the view
    /// whether to offer recovery. The store must still report that a fetch was
    /// attempted and has finished, which is what Home uses to
    /// show "Try Again" instead of an endless `ProgressView`.
    func testInitialFetchInvalidatedByConfirmedMutationEndsInRetryableState() async throws {
        let store = makeStore()
        XCTAssertFalse(store.hasAttemptedRequestFetch)

        let initialFetchGate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(
            data: listResponse([requestObject(id: "never-applied")]),
            gate: initialFetchGate
        ))
        let initialFetch = Task {
            await store.fetchRequests()
        }
        await waitUntil { initialFetchGate.isWaiting }

        XCTAssertTrue(store.hasAttemptedRequestFetch)
        XCTAssertTrue(store.isLoadingInitialRequests)

        RequestFetchingURLProtocol.enqueue(.response(data: claimResponse(
            requestObject: requestObject(id: "meal-a", status: "claimed")
        )))
        try await store.claim(requestID: "meal-a")

        initialFetchGate.open()
        await initialFetch.value

        // The confirmed mutation still owns the collection.
        XCTAssertEqual(store.requests.map(\.id), ["meal-a"])
        XCTAssertEqual(store.requests.first?.status, .claimed)

        // Loading ended, no successful fetch was recorded, and no error exists...
        XCTAssertFalse(store.isFetching)
        XCTAssertFalse(store.isLoadingInitialRequests)
        XCTAssertFalse(store.isRefreshingRequests)
        XCTAssertFalse(store.hasSuccessfullyFetchedRequests)
        XCTAssertNil(store.initialFetchError)
        XCTAssertNil(store.refreshError)

        // ...but the attempt is recorded, so recovery is offered.
        XCTAssertTrue(store.hasAttemptedRequestFetch)
    }

    /// Same terminal shape, reached by cancelling the initial fetch instead.
    func testCancelledInitialFetchEndsInRetryableState() async {
        let store = makeStore()
        let cancelledFetchGate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(
            data: listResponse([requestObject(id: "never-applied")]),
            gate: cancelledFetchGate
        ))

        let initialFetch = Task {
            await store.fetchRequests()
        }
        await waitUntil { cancelledFetchGate.isWaiting }

        initialFetch.cancel()
        cancelledFetchGate.open()
        await initialFetch.value

        XCTAssertFalse(store.isFetching)
        XCTAssertFalse(store.hasSuccessfullyFetchedRequests)
        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertNil(store.initialFetchError)
        XCTAssertTrue(store.hasAttemptedRequestFetch)
    }

    func testRefreshFailurePreservesLoadedRequestsWhileRefreshingAndAfterFailure() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "still-visible")
        ])))
        await store.fetchRequests()

        RequestFetchingURLProtocol.enqueue(
            .failure(.timedOut, delay: 0.15)
        )
        let refreshTask = Task {
            await store.fetchRequests()
        }

        await waitUntil { store.isRefreshingRequests }

        XCTAssertFalse(store.isLoadingInitialRequests)
        XCTAssertTrue(store.isRefreshingRequests)
        XCTAssertEqual(store.requests.map(\.id), ["still-visible"])

        await refreshTask.value

        XCTAssertTrue(store.hasSuccessfullyFetchedRequests)
        XCTAssertFalse(store.isRefreshingRequests)
        XCTAssertEqual(store.requests.map(\.id), ["still-visible"])
        XCTAssertNotNil(store.refreshError)
        XCTAssertNil(store.initialFetchError)
    }

    func testNewestFetchWinsWhenOlderFetchCompletesLast() async {
        let store = makeStore()
        let olderFetchGate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(
            data: listResponse([requestObject(id: "older")]),
            gate: olderFetchGate
        ))

        let olderFetch = Task {
            await store.fetchRequests()
        }
        await waitUntil { olderFetchGate.isWaiting }

        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "newer")
        ])))
        let newerFetch = Task {
            await store.fetchRequests()
        }
        await newerFetch.value

        XCTAssertEqual(store.requests.map(\.id), ["newer"])
        XCTAssertFalse(store.isLoadingInitialRequests)

        olderFetchGate.open()
        await olderFetch.value

        XCTAssertEqual(store.requests.map(\.id), ["newer"])
        XCTAssertTrue(store.hasSuccessfullyFetchedRequests)
        XCTAssertFalse(store.isLoadingInitialRequests)
        XCTAssertFalse(store.isRefreshingRequests)
    }

    func testConfirmedClaimInvalidatesOlderFetchSnapshot() async throws {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "meal-a")
        ])))
        await store.fetchRequests()

        let olderRefreshGate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(
            data: listResponse([requestObject(id: "meal-a", status: "open")]),
            gate: olderRefreshGate
        ))
        let olderRefresh = Task {
            await store.fetchRequests()
        }
        await waitUntil { olderRefreshGate.isWaiting }

        RequestFetchingURLProtocol.enqueue(.response(data: claimResponse(
            requestObject: requestObject(id: "meal-a", status: "claimed")
        )))
        try await store.claim(requestID: "meal-a")

        XCTAssertEqual(store.requests.first?.status, .claimed)
        XCTAssertTrue(store.isRefreshingRequests)

        olderRefreshGate.open()
        await olderRefresh.value

        XCTAssertEqual(store.requests.map(\.id), ["meal-a"])
        XCTAssertEqual(store.requests.first?.status, .claimed)
        XCTAssertFalse(store.isRefreshingRequests)
        XCTAssertNil(store.refreshError)
    }

    func testFetchStartedAfterConfirmedMutationCanReplaceCollection() async throws {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "meal-a")
        ])))
        await store.fetchRequests()

        RequestFetchingURLProtocol.enqueue(.response(data: claimResponse(
            requestObject: requestObject(id: "meal-a", status: "claimed")
        )))
        try await store.claim(requestID: "meal-a")
        XCTAssertEqual(store.requests.first?.status, .claimed)

        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "currently-available")
        ])))
        await store.fetchRequests()

        XCTAssertEqual(store.requests.map(\.id), ["currently-available"])
        XCTAssertEqual(store.requests.first?.status, .open)
        XCTAssertNil(store.refreshError)
    }

    func testConfirmedMutationMakesOlderFetchFailureSilentAndCleansRefreshState() async throws {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "meal-a")
        ])))
        await store.fetchRequests()

        let olderRefreshGate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.failure(
            .timedOut,
            gate: olderRefreshGate
        ))
        let olderRefresh = Task {
            await store.fetchRequests()
        }
        await waitUntil { olderRefreshGate.isWaiting }

        RequestFetchingURLProtocol.enqueue(.response(data: claimResponse(
            requestObject: requestObject(id: "meal-a", status: "claimed")
        )))
        try await store.claim(requestID: "meal-a")

        XCTAssertEqual(store.requests.first?.status, .claimed)
        XCTAssertTrue(store.isRefreshingRequests)

        olderRefreshGate.open()
        await olderRefresh.value

        XCTAssertEqual(store.requests.first?.status, .claimed)
        XCTAssertNil(store.refreshError)
        XCTAssertFalse(store.isLoadingInitialRequests)
        XCTAssertFalse(store.isRefreshingRequests)
    }

    func testIgnoredStaleResponsesPreserveNewerErrorAndDoNotPublishStaleError() async {
        let storeWithNewerError = makeStore()
        let staleSuccessGate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(
            data: listResponse([requestObject(id: "stale-success")]),
            gate: staleSuccessGate
        ))
        let staleSuccess = Task {
            await storeWithNewerError.fetchRequests()
        }
        await waitUntil { staleSuccessGate.isWaiting }

        RequestFetchingURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await storeWithNewerError.fetchRequests()

        XCTAssertNotNil(storeWithNewerError.initialFetchError)
        XCTAssertFalse(storeWithNewerError.isLoadingInitialRequests)

        staleSuccessGate.open()
        await staleSuccess.value

        XCTAssertNotNil(storeWithNewerError.initialFetchError)
        XCTAssertFalse(storeWithNewerError.hasSuccessfullyFetchedRequests)
        XCTAssertTrue(storeWithNewerError.requests.isEmpty)
        XCTAssertFalse(storeWithNewerError.isLoadingInitialRequests)

        let storeWithNewerSuccess = makeStore()
        let staleFailureGate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.failure(
            .timedOut,
            gate: staleFailureGate
        ))
        let staleFailure = Task {
            await storeWithNewerSuccess.fetchRequests()
        }
        await waitUntil { staleFailureGate.isWaiting }

        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "newer-success")
        ])))
        await storeWithNewerSuccess.fetchRequests()

        staleFailureGate.open()
        await staleFailure.value

        XCTAssertEqual(storeWithNewerSuccess.requests.map(\.id), ["newer-success"])
        XCTAssertNil(storeWithNewerSuccess.initialFetchError)
        XCTAssertNil(storeWithNewerSuccess.refreshError)
        XCTAssertFalse(storeWithNewerSuccess.isLoadingInitialRequests)
        XCTAssertFalse(storeWithNewerSuccess.isRefreshingRequests)
    }

    func testCreateDecodesWrappedCanonicalResponseAndMapsOpenStatus() async throws {
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: requestObject(
                id: "created-asap",
                vendor: "Jasper Kane Cafe",
                food: "Chicken bowl",
                pickupWindowText: "ASAP (available for the next 3 hours)",
                status: "open",
                createdAt: "2026-07-28T16:00:00.123Z",
                expiresAt: "2026-07-28T19:00:00.123Z"
            ))
        ))

        let created = try await makeService().createRequest(makeCreatePayload())

        XCTAssertEqual(created.id, "created-asap")
        XCTAssertEqual(created.status, .open)
        XCTAssertEqual(created.diningSpot.name, "Jasper Kane Cafe")
        XCTAssertEqual(created.foodDescription, "Chicken bowl")
        XCTAssertEqual(created.pickupWindowText, "ASAP (available for the next 3 hours)")
        XCTAssertNil(created.windowStart)
        XCTAssertNil(created.windowEnd)
        XCTAssertEqual(created.createdAt, try iso8601Date("2026-07-28T16:00:00.123Z"))
        XCTAssertEqual(created.expiresAt, try iso8601Date("2026-07-28T19:00:00.123Z"))
    }

    func testCreatePreservesStructuredBackendErrorCodes() async {
        let expectedCodes = [
            "INVALID_REQUEST",
            "REQUEST_LIMIT_REACHED",
            "PUBLIC_ACTIONS_PAUSED",
            "REQUEST_CREATION_FAILED"
        ]

        for code in expectedCodes {
            RequestFetchingURLProtocol.enqueue(.response(
                statusCode: 400,
                data: Data(
                    #"{"error":{"code":"\#(code)","message":"backend detail"}}"#.utf8
                )
            ))

            do {
                _ = try await makeService().createRequest(makeCreatePayload())
                XCTFail("Expected \(code) to be rejected")
            } catch RequestServiceError.serverError(let actualCode, let message) {
                XCTAssertEqual(actualCode, code)
                XCTAssertEqual(message, "backend detail")
            } catch {
                XCTFail("Unexpected error for \(code): \(error)")
            }
        }
    }

    func testUnstructuredHTTPFailureMakesCreateOutcomeAmbiguous() async {
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 504,
            data: Data("Gateway Timeout".utf8)
        ))

        do {
            _ = try await makeService().createRequest(makeCreatePayload())
            XCTFail("A non-envelope HTTP failure cannot confirm whether creation committed")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected.
        } catch {
            XCTFail("Unexpected create error: \(error)")
        }
    }

    func testDuplicateCreateIsRejectedBeforeSecondRequestStarts() async throws {
        let store = makeStore()
        let createGate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: requestObject(id: "created-once")),
            gate: createGate
        ))

        let firstCreate = Task {
            try await store.createRequest(makeCreatePayload())
        }
        await waitUntil { createGate.isWaiting }

        XCTAssertTrue(store.isCreating)
        do {
            try await store.createRequest(makeCreatePayload())
            XCTFail("A duplicate create should not start")
        } catch RequestServiceError.operationInProgress {
            // Expected.
        } catch {
            XCTFail("Unexpected duplicate-create error: \(error)")
        }
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, ["/api/request"])

        createGate.open()
        try await firstCreate.value

        XCTAssertFalse(store.isCreating)
        // W4-D2 Success→Home continuity: a fresh create under the still-
        // current authority now inserts immediately, ownership-resolved
        // `.own`.
        XCTAssertEqual(store.requests.map(\.id), ["created-once"])
        XCTAssertEqual(store.requests.first?.ownership, .own)
    }

    func testConfirmedCreateUpsertsCanonicalRequestByBackendID() async throws {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "same-id", food: "Old food")
        ])))
        await store.fetchRequests()

        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: requestObject(
                id: "same-id",
                food: "Canonical created food",
                createdAt: "2026-07-28T16:00:00.000Z"
            ))
        ))
        try await store.createRequest(makeCreatePayload())

        XCTAssertEqual(store.requests.count, 1)
        XCTAssertEqual(store.requests.first?.id, "same-id")
        XCTAssertEqual(store.requests.first?.foodDescription, "Canonical created food")
        XCTAssertEqual(
            store.requests.first?.createdAt,
            try iso8601Date("2026-07-28T16:00:00.000Z")
        )
    }

    /// W4-D2 Success→Home continuity: a fresh create under the still-current
    /// authority now inserts immediately (superseding the W4-R2 2026-09-05
    /// sync item 5 behavior this narrowly replaces), but the
    /// collection-revision bump `createRequest` performs is unchanged, so an
    /// older in-flight fetch started before the create must still be
    /// discarded as stale rather than clobbering the newly-inserted request
    /// once it later completes.
    func testConfirmedCreateInvalidatesOlderFetchSnapshot() async throws {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "already-visible")
        ])))
        await store.fetchRequests()

        let olderRefreshGate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(
            data: listResponse([requestObject(id: "already-visible")]),
            gate: olderRefreshGate
        ))
        let olderRefresh = Task {
            await store.fetchRequests()
        }
        await waitUntil { olderRefreshGate.isWaiting }

        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: requestObject(id: "newly-created"))
        ))
        try await store.createRequest(makeCreatePayload())

        XCTAssertEqual(store.requests.map(\.id), ["already-visible", "newly-created"])
        XCTAssertTrue(store.isRefreshingRequests)

        olderRefreshGate.open()
        await olderRefresh.value

        XCTAssertEqual(store.requests.map(\.id), ["already-visible", "newly-created"])
        XCTAssertFalse(store.isRefreshingRequests)
        XCTAssertNil(store.refreshError)
    }

    func testAmbiguousCreateDoesNotInsertRequest() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))

        do {
            try await store.createRequest(makeCreatePayload())
            XCTFail("Transport loss after submission should be ambiguous")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected.
        } catch {
            XCTFail("Unexpected ambiguous-create error: \(error)")
        }

        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertFalse(store.isCreating)
        if case .ambiguousCreateOutcome? = store.createError {
            // Expected.
        } else {
            XCTFail("The store should publish the ambiguous outcome")
        }

        // The POST may already have succeeded server-side, so exactly one
        // create must have been sent — no automatic retry.
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths.filter {
                $0 == "/api/request"
            }.count,
            1
        )
    }

    func testAmbiguousCreateBlocksLaterCreateAndRepublishesOutcome() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))

        do {
            try await store.createRequest(makeCreatePayload())
            XCTFail("The first create should be ambiguous")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected.
        } catch {
            XCTFail("Unexpected first-create error: \(error)")
        }

        do {
            try await store.createRequest(makeCreatePayload())
            XCTFail("An unresolved create must block every later create")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // The stored ambiguity is republished to a re-entered form.
        } catch {
            XCTFail("Unexpected blocked-create error: \(error)")
        }

        if case .ambiguousCreateOutcome? = store.createError {
            // Expected.
        } else {
            XCTFail("The store should republish the unresolved ambiguity")
        }
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths.filter {
                $0 == "/api/request"
            }.count,
            1
        )
    }

    func testCreatedResponseRemainsSuccessWithoutAnEmailDeliveryField() async throws {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: requestObject(id: "created-despite-email"))
        ))

        try await store.createRequest(makeCreatePayload())

        // The create itself still succeeds (no thrown error) despite no
        // email-delivery field in the response. W4-D2 Success→Home
        // continuity: a fresh create under the still-current authority now
        // inserts immediately, ownership-resolved `.own`.
        XCTAssertEqual(store.requests.map(\.id), ["created-despite-email"])
        XCTAssertEqual(store.requests.first?.ownership, .own)
        XCTAssertNil(store.createError)
    }

    // MARK: - Request-creation availability (GET /api/public-actions)

    func testAvailabilityStartsUnknownAndProbesNothingUntilAsked() {
        let store = makeStore()

        XCTAssertEqual(store.requestCreationAvailability, .unknown)
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
    }

    func testUnpausedBackendMakesRequestCreationAvailable() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: publicActionsResponse(paused: false)))

        await store.refreshRequestCreationAvailability()

        XCTAssertEqual(store.requestCreationAvailability, .available)
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            ["/api/public-actions"]
        )
    }

    /// The probe is the only request made while paused: nothing the requester
    /// could have typed is transmitted, because no form was ever offered.
    func testPausedBackendBlocksCreationAndSendsNoCreateRequest() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: publicActionsResponse(paused: true)))

        await store.refreshRequestCreationAvailability()

        XCTAssertEqual(store.requestCreationAvailability, .paused)
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            ["/api/public-actions"]
        )
        XCTAssertFalse(
            RequestFetchingURLProtocol.capturedRequestedPaths.contains("/api/request")
        )
        XCTAssertFalse(store.isCreating)
        XCTAssertNil(store.createError)
        XCTAssertTrue(store.requests.isEmpty)
    }

    func testTransportFailureDuringAvailabilityCheckFailsClosed() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.failure(.notConnectedToInternet))

        await store.refreshRequestCreationAvailability()

        XCTAssertEqual(store.requestCreationAvailability, .unavailable)
        XCTAssertFalse(
            RequestFetchingURLProtocol.capturedRequestedPaths.contains("/api/request")
        )
    }

    func testNonSuccessStatusDuringAvailabilityCheckFailsClosed() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 500,
            data: Data(#"{"error":{"code":"SERVER_ERROR","message":"boom"}}"#.utf8)
        ))

        await store.refreshRequestCreationAvailability()

        XCTAssertEqual(store.requestCreationAvailability, .unavailable)
    }

    func testUndecodableAvailabilityBodyFailsClosed() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: Data(#"{"paused":"maybe"}"#.utf8)))

        await store.refreshRequestCreationAvailability()

        XCTAssertEqual(store.requestCreationAvailability, .unavailable)
    }

    /// A stale `.available` answer must not survive into the next check, or a
    /// re-entered screen would show the fields before the current probe replies.
    func testAvailabilityResetsToUnknownWhileRecheckingAfterAnAvailableAnswer() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: publicActionsResponse(paused: false)))
        await store.refreshRequestCreationAvailability()
        XCTAssertEqual(store.requestCreationAvailability, .available)

        let gate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(
            data: publicActionsResponse(paused: true),
            gate: gate
        ))

        let recheck = Task { await store.refreshRequestCreationAvailability() }
        await waitUntil { gate.isWaiting }

        XCTAssertEqual(store.requestCreationAvailability, .unknown)

        gate.open()
        await recheck.value

        XCTAssertEqual(store.requestCreationAvailability, .paused)
    }

    /// The submit-time backstop still classifies a `503 PUBLIC_ACTIONS_PAUSED`
    /// for the case where the backend pauses after the screen's probe resolved.
    func testCreateRefusedAfterAvailabilityCheckStillMapsToTheLockedPauseCopy() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: publicActionsResponse(paused: false)))
        await store.refreshRequestCreationAvailability()
        XCTAssertEqual(store.requestCreationAvailability, .available)

        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 503,
            data: Data(#"""
            {"error":{"code":"PUBLIC_ACTIONS_PAUSED","message":"Posting meal requests is temporarily unavailable"}}
            """#.utf8)
        ))

        do {
            try await store.createRequest(makeCreatePayload())
            XCTFail("Expected a paused refusal")
        } catch {
            guard case .serverError(let code, _) = error as? RequestServiceError else {
                return XCTFail("Expected a serverError, got \(error)")
            }
            XCTAssertEqual(code, "PUBLIC_ACTIONS_PAUSED")
            XCTAssertEqual(
                RequestCreatePresentationError.map(error),
                .publicActionsPaused
            )
            XCTAssertEqual(
                RequestCreatePresentationError.map(error).message,
                "Posting a meal request is temporarily unavailable."
            )
        }

        XCTAssertTrue(store.requests.isEmpty)
    }

    private func publicActionsResponse(paused: Bool) -> Data {
        Data(#"{"paused":\#(paused)}"#.utf8)
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
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return RequestService(client: client)
    }

    private func listResponse(_ requestObjects: [String]) -> Data {
        Data(#"{"requests":[\#(requestObjects.joined(separator: ","))]}"#.utf8)
    }

    /// The claim expiration is expressed relative to now, as a real claim
    /// response always is. A fixed past timestamp would make every claimed
    /// fixture immediately expire and start the store's end-of-claim handling,
    /// which is not what these collection-ownership tests are about.
    private func claimResponse(requestObject: String) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let claimExpiresAt = formatter.string(from: Date().addingTimeInterval(15 * 60))

        return Data("""
        {
          "request": \(requestObject),
          "claim": {
            "pickupName": "Taylor",
            "claimToken": "claim-token",
            "claimExpiresAt": "\(claimExpiresAt)"
          }
        }
        """.utf8)
    }

    private func createResponse(requestObject: String) -> Data {
        Data(#"{"request":\#(requestObject)}"#.utf8)
    }

    private func makeCreatePayload() -> CreateRequestPayload {
        CreateRequestPayload(
            vendor: "Jasper Kane Cafe",
            timing: .asap,
            windowStart: nil,
            menuPath: .mealExchange,
            mealSwipes: 2,
            mealItems: ["Chicken bowl"],
            orderDetails: nil,
            estimatedDiningDollarsCents: nil
        )
    }

    private func requestObject(
        id: String,
        vendor: String = "Crave NYU",
        food: String = "Rice bowl",
        pickupWindowText: String = "ASAP",
        mealSwipes: Int = 2,
        windowStart: String? = nil,
        windowEnd: String? = nil,
        status: String = "open",
        createdAt: String = "2026-07-20T18:30:00.000Z",
        expiresAt: String = "2026-07-20T23:30:00.000Z"
    ) -> String {
        let windowStartJSON = windowStart.map { "\"\($0)\"" } ?? "null"
        let windowEndJSON = windowEnd.map { "\"\($0)\"" } ?? "null"

        return """
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
          "windowStart": \(windowStartJSON),
          "windowEnd": \(windowEndJSON),
          "status": "\(status)",
          "createdAt": "\(createdAt)",
          "expiresAt": "\(expiresAt)"
        }
        """
    }

    private func iso8601Date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try XCTUnwrap(formatter.date(from: value))
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
}
