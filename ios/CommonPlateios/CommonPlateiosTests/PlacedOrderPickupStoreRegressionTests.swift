import Foundation
import XCTest
@testable import CommonPlateios

/// W4-R3 review fixes: stale list responses, latched pickup storage, and stale
/// R5 owner rows after a placed order is finished.
@MainActor
final class PlacedOrderPickupStoreRegressionTests: XCTestCase {
    private let authority = "64c0000000000000000000a1.1.credential"
    private let principal = "64c0000000000000000000a1"

    override func tearDown() {
        PickupRegressionURLProtocol.reset()
        super.tearDown()
    }

    func testListFetchInFlightDuringConfirmationCannotResurrectTheConfirmedOrder() async throws {
        let store = makeStore()
        PickupRegressionURLProtocol.enqueue(.init(statusCode: 200, data: listResponse(ids: ["r1", "r2"])))
        await store.fetchPlacedOrders()
        XCTAssertEqual(Set(store.placedOrders.map(\.id)), ["r1", "r2"])

        let gate = DispatchSemaphore(value: 0)
        PickupRegressionURLProtocol.enqueue(.init(
            statusCode: 200,
            data: listResponse(ids: ["r1", "r2"]),
            gate: gate
        ))
        let staleFetch = Task { await store.fetchPlacedOrders() }
        try await waitForCapturedRequestCount(2)

        PickupRegressionURLProtocol.enqueue(.init(statusCode: 200, data: pickupResponse(requestID: "r1")))
        let result = await store.confirmPlacedOrderPickup(requestID: "r1")
        XCTAssertEqual(result, .confirmed)

        gate.signal()
        let staleOutcome = await staleFetch.value

        XCTAssertEqual(staleOutcome, .didNotSucceed)
        XCTAssertEqual(store.placedOrders.map(\.id), ["r2"])
        XCTAssertFalse(store.isLoadingPlacedOrders)
    }

    func testUnreadablePickupStorageIsReprobedSoPickupStaysUsable() async {
        let storage = FlakyPickupStorage()
        storage.isReadable = false
        let store = makeStore(storage: storage)

        let blocked = await store.confirmPlacedOrderPickup(requestID: "r1")
        XCTAssertEqual(blocked, .unresolved)
        XCTAssertTrue(store.isPickupRecoveryNeeded(requestID: "r1"))
        XCTAssertTrue(
            PickupRegressionURLProtocol.capturedRequests.isEmpty,
            "nothing is transmitted before the pending record is durable"
        )

        storage.isReadable = true
        PickupRegressionURLProtocol.enqueue(.init(statusCode: 200, data: detailResponse(id: "r1", pickupStatus: "pending")))
        PickupRegressionURLProtocol.enqueue(.init(statusCode: 200, data: pickupResponse(requestID: "r1")))
        let retried = await store.confirmPlacedOrderPickup(requestID: "r1", userInitiatedRetry: true)

        XCTAssertEqual(retried, .confirmed)
        XCTAssertEqual(PickupRegressionURLProtocol.capturedRequests.map(\.method), ["GET", "POST"])
        XCTAssertEqual(storage.load(), .records([]))
    }

    func testTryAgainWithUnreadableStorageStillReconcilesReadOnlyButNeverMutates() async {
        let storage = FlakyPickupStorage()
        storage.isReadable = false
        let store = makeStore(storage: storage)

        PickupRegressionURLProtocol.enqueue(.init(statusCode: 200, data: detailResponse(id: "r1", pickupStatus: "pending")))
        let pending = await store.confirmPlacedOrderPickup(requestID: "r1", userInitiatedRetry: true)
        XCTAssertEqual(pending, .unresolved)
        XCTAssertEqual(PickupRegressionURLProtocol.capturedRequests.map(\.method), ["GET"])

        PickupRegressionURLProtocol.enqueue(.init(statusCode: 200, data: detailResponse(id: "r1", pickupStatus: "confirmed")))
        let confirmed = await store.confirmPlacedOrderPickup(requestID: "r1", userInitiatedRetry: true)
        XCTAssertEqual(confirmed, .confirmed)
        XCTAssertEqual(PickupRegressionURLProtocol.capturedRequests.map(\.method), ["GET", "GET"])
    }

    func testConfirmedPickupAlsoDropsTheRequestFromR5OwnerRows() async {
        let store = makeStore()
        PickupRegressionURLProtocol.enqueue(.init(statusCode: 200, data: ownerList([ownerObject(id: "r1"), ownerObject(id: "r2")])))
        await store.fetchOwnerRequests()
        PickupRegressionURLProtocol.enqueue(.init(statusCode: 200, data: listResponse(ids: ["r1"])))
        await store.fetchPlacedOrders()
        XCTAssertEqual(store.ownerRequests.map(\.id), ["r1", "r2"])

        PickupRegressionURLProtocol.enqueue(.init(statusCode: 200, data: pickupResponse(requestID: "r1")))
        let result = await store.confirmPlacedOrderPickup(requestID: "r1")

        XCTAssertEqual(result, .confirmed)
        XCTAssertEqual(store.ownerRequests.map(\.id), ["r2"])
        XCTAssertTrue(store.placedOrders.isEmpty)
    }

    func testPickupRetirementFencesStaleOwnerFetchAndAllowsFreshRefresh() async throws {
        let store = makeStore()
        PickupRegressionURLProtocol.enqueue(.init(statusCode: 200, data: ownerList([ownerObject(id: "r1")])))
        await store.fetchOwnerRequests()
        PickupRegressionURLProtocol.enqueue(.init(statusCode: 200, data: listResponse(ids: ["r1"])))
        await store.fetchPlacedOrders()
        XCTAssertEqual(store.ownerRequests.map(\.id), ["r1"])

        let ownerReadStarted = expectation(description: "stale owner list request started")
        let gate = DispatchSemaphore(value: 0)
        PickupRegressionURLProtocol.enqueue(.init(
            statusCode: 200,
            data: ownerList([ownerObject(id: "r1")]),
            gate: gate,
            started: ownerReadStarted
        ))
        let staleFetch = Task { await store.fetchOwnerRequests() }
        await fulfillment(of: [ownerReadStarted], timeout: 2)
        XCTAssertTrue(store.isLoadingOwnerRequests)

        PickupRegressionURLProtocol.enqueue(.init(statusCode: 200, data: pickupResponse(requestID: "r1")))
        let pickup = await store.confirmPlacedOrderPickup(requestID: "r1")
        XCTAssertEqual(pickup, .confirmed)
        XCTAssertTrue(store.ownerRequests.isEmpty)
        XCTAssertFalse(store.isLoadingOwnerRequests)

        gate.signal()
        let staleOutcome = await staleFetch.value
        XCTAssertEqual(staleOutcome, .didNotSucceed)
        XCTAssertTrue(store.ownerRequests.isEmpty)
        XCTAssertFalse(store.isLoadingOwnerRequests)

        PickupRegressionURLProtocol.enqueue(.init(statusCode: 200, data: ownerList([ownerObject(id: "r2")])))
        let freshOutcome = await store.fetchOwnerRequests()
        XCTAssertEqual(freshOutcome, .succeeded)
        XCTAssertEqual(store.ownerRequests.map(\.id), ["r2"])
        XCTAssertFalse(store.isLoadingOwnerRequests)
    }

    func testNotFoundRetirementAlsoDropsTheRequestFromR5OwnerRows() async {
        let store = makeStore()
        PickupRegressionURLProtocol.enqueue(.init(statusCode: 200, data: ownerList([ownerObject(id: "r1")])))
        await store.fetchOwnerRequests()
        PickupRegressionURLProtocol.enqueue(.init(statusCode: 404, data: errorBody("PLACED_ORDER_NOT_FOUND")))

        let result = await store.confirmPlacedOrderPickup(requestID: "r1", userInitiatedRetry: true)

        XCTAssertEqual(result, .notFound)
        XCTAssertTrue(store.ownerRequests.isEmpty)
        XCTAssertFalse(store.hasPickupConfirmationNotice)
    }

    func testStaleHelperPlacementReadCannotRestoreContinuationAfterPickupRefresh() async throws {
        let store = makeStore()
        let gate = DispatchSemaphore(value: 0)
        PickupRegressionURLProtocol.enqueue(.init(
            statusCode: 200,
            data: helperContinuationResponse(id: "r1"),
            gate: gate
        ))
        let staleRead = Task {
            try? await store.continueActiveReservationIfNeeded()
        }
        try await waitForCapturedRequestCount(1)

        PickupRegressionURLProtocol.enqueue(.init(
            statusCode: 200,
            data: Data(#"{"reservation":null,"placement":null}"#.utf8)
        ))
        _ = try await store.continueActiveReservationIfNeeded()
        XCTAssertNil(store.helperPlacedContinuation)

        gate.signal()
        _ = await staleRead.value
        XCTAssertNil(store.helperPlacedContinuation)
    }

    // MARK: - Fixtures

    private func waitForCapturedRequestCount(_ count: Int) async throws {
        for _ in 0..<200 where PickupRegressionURLProtocol.capturedRequests.count < count {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(PickupRegressionURLProtocol.capturedRequests.count, count)
    }

    private func makeStore(storage: PendingPlacedPickupStorage? = nil) -> RequestStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PickupRegressionURLProtocol.self]
        let service = RequestService(client: APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate-regression.test")!),
            session: URLSession(configuration: configuration)
        ))
        return RequestStore(
            service: service,
            installationCredentialProvider: { "test-installation" },
            participantAuthorityProvider: { self.authority },
            participantAuthorityRejected: {},
            participantPrincipalProvider: { self.principal },
            pendingPlacedPickupStorage: storage ?? InMemoryPendingPlacedPickupStorage()
        )
    }

    private var timestamp: String { "2026-10-19T17:00:00.000Z" }

    private func pickupResponse(requestID: String) -> Data {
        json(["requestId": requestID, "pickupConfirmation": ["status": "confirmed", "confirmedAt": timestamp]])
    }

    private func listResponse(ids: [String]) -> Data {
        json(["orders": ids.map { placedOrderObject(id: $0) }, "serverNow": timestamp])
    }

    private func detailResponse(id: String, pickupStatus: String) -> Data {
        var order = placedOrderObject(id: id)
        order["pickupConfirmation"] = [
            "status": pickupStatus,
            "confirmedAt": pickupStatus == "confirmed" ? timestamp : NSNull()
        ] as [String: Any]
        return json(["order": order, "serverNow": timestamp])
    }

    private func helperContinuationResponse(id: String) -> Data {
        json([
            "reservation": NSNull(),
            "placement": [
                "request": placedOrderObject(id: id),
                "orderNumber": "70154321",
                "etaText": "15 minutes",
                "notification": ["status": "sent"]
            ]
        ])
    }

    private func placedOrderObject(id: String) -> [String: Any] {
        [
            "id": id, "vendor": "Crave NYU", "food": "Rice bowl", "pickupWindowText": "ASAP",
            "mealSwipes": 2, "menuPath": "meal-exchange", "mealItems": [],
            "orderDetails": NSNull(), "estimatedDiningDollarsCents": NSNull(),
            "windowStart": NSNull(), "windowEnd": NSNull(), "status": "placed",
            "createdAt": timestamp, "expiresAt": "2026-10-20T17:00:00.000Z",
            "isOwnRequest": true, "orderNumber": "70154321", "etaText": "15 minutes",
            "placedAt": timestamp, "estimatedReadyAt": "2026-10-19T17:15:00.000Z"
        ]
    }

    private func errorBody(_ code: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"detail","fields":null}}"#.utf8)
    }

    private func ownerList(_ objects: [String]) -> Data {
        Data(#"{"requests":[\#(objects.joined(separator: ","))]}"#.utf8)
    }

    private func ownerObject(id: String) -> String {
        """
        {
          "id": "\(id)", "vendor": "Crave NYU", "food": "Rice bowl",
          "pickupWindowText": "ASAP", "mealSwipes": 1, "menuPath": "meal-exchange",
          "mealItems": [{"name": "Rice bowl"}], "orderDetails": null,
          "estimatedDiningDollarsCents": null, "windowStart": null, "windowEnd": null,
          "createdAt": "2026-07-20T18:30:00.000Z", "expiresAt": "2099-07-20T23:30:00.000Z",
          "timing": "asap", "phase": "reserved", "contentRevision": 1,
          "canEdit": false, "canWithdraw": false,
          "latestScheduledStart": "2026-07-21T03:30:00.000Z"
        }
        """
    }

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }
}

private final class FlakyPickupStorage: PendingPlacedPickupStorage {
    var isReadable = true
    private var records: [PendingPlacedPickup] = []

    func load() -> PendingPlacedPickupLoad { isReadable ? .records(records) : .unreadable }

    func save(_ record: PendingPlacedPickup) -> Bool {
        guard isReadable else { return false }
        records.removeAll { $0 == record }
        records.append(record)
        return true
    }

    func clear(_ record: PendingPlacedPickup) -> Bool {
        guard isReadable else { return false }
        records.removeAll { $0 == record }
        return true
    }

    func clear(participantPrincipal: String) -> Bool {
        guard isReadable else { return false }
        records.removeAll { $0.participantPrincipal == participantPrincipal }
        return true
    }
}

private final class PickupRegressionURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let data: Data
        let gate: DispatchSemaphore?
        let started: XCTestExpectation?

        init(
            statusCode: Int,
            data: Data,
            gate: DispatchSemaphore? = nil,
            started: XCTestExpectation? = nil
        ) {
            self.statusCode = statusCode
            self.data = data
            self.gate = gate
            self.started = started
        }
    }

    struct Captured {
        let path: String
        let method: String
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var stubs: [Stub] = []
    private nonisolated(unsafe) static var captured: [Captured] = []

    static func enqueue(_ stub: Stub) {
        lock.lock(); defer { lock.unlock() }
        stubs.append(stub)
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        stubs.removeAll()
        captured.removeAll()
    }

    static var capturedRequests: [Captured] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    private static func take(_ request: URLRequest) -> Stub? {
        lock.lock(); defer { lock.unlock() }
        captured.append(Captured(path: request.url?.path ?? "", method: request.httpMethod ?? ""))
        return stubs.isEmpty ? nil : stubs.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "commonplate-regression.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = Self.take(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        stub.started?.fulfill()
        let deliver = { [self] in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: stub.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                  ) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
        }
        if let gate = stub.gate {
            DispatchQueue.global().async {
                gate.wait()
                deliver()
            }
        } else {
            deliver()
        }
    }

    override func stopLoading() {}
}
