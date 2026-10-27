//
//  RequestCreateDurablePersistenceFailureTests.swift
//  CommonPlateiosTests
//
// Focused W4-D2 FIX coverage (2026-09-18 independent-review MUST FIX):
// `RequestStore.createRequest(_:)` must never transmit `POST /api/request`
// unless the exact-operation recovery record was durably persisted first. A
// storage test double whose `save(_:)` always returns `false` proves the
// pre-transmission guard: no create request, no terminal-reconciliation
// request, no fabricated unresolved-operation state, and a simulated relaunch
// finds nothing to block on. A companion case proves the existing
// successful-save issuance path is unchanged by the guard. Reuses
// `RequestFetchingURLProtocol` from `RequestFetchingTests.swift`.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class RequestCreateDurablePersistenceFailureTests: XCTestCase {
    private let authorityA = "64c0000000000000000000a1.1." + String(repeating: "A", count: 42) + "A"
    private let baseURL = URL(string: "https://commonplate.test")!

    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    func testRejectedDurableSavePreventsAnyNetworkTransmission() async throws {
        let storage = RejectingPendingRequestOperationStorage()
        let store = makeStore(storage: storage, currentAuthority: authorityA)

        do {
            try await store.createRequest(payload())
            XCTFail("A create must not transmit when its durable recovery record failed to persist")
        } catch RequestServiceError.durablePersistenceFailed {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(storage.saveAttempts, 1)
        // No create POST and no terminal-reconciliation call — the entire
        // FIFO-tracked request surface stayed untouched.
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
        // No unresolved-operation state is fabricated: nothing was recorded,
        // so nothing blocks a later attempt.
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertNil(store.unresolvedCreateError)
        XCTAssertEqual(store.createRecoveryPresentation, .none)
        XCTAssertFalse(store.isCreating)
    }

    func testSimulatedRelaunchAfterRejectedSaveFindsNothingToBlockOn() async throws {
        let storage = RejectingPendingRequestOperationStorage()
        let firstProcessStore = makeStore(storage: storage, currentAuthority: authorityA)

        do {
            try await firstProcessStore.createRequest(payload())
            XCTFail("Expected the durable-persistence guard to fire")
        } catch RequestServiceError.durablePersistenceFailed {
            // Expected.
        }

        // A fresh store over the same (still-empty) storage models relaunch.
        // Storage never actually held a record — it always refuses `save` —
        // so relaunch reconciliation must not find a phantom operation, and
        // must send no network request while establishing that.
        let relaunchedStore = makeStore(storage: storage, currentAuthority: authorityA)
        let didCreate = await relaunchedStore.reconcilePendingCreateOperationIfNeeded()

        XCTAssertFalse(didCreate)
        XCTAssertFalse(relaunchedStore.hasUnresolvedCreateAmbiguity)
        XCTAssertTrue(relaunchedStore.hasResolvedPendingCreateStateForRemoval)
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)

        // The user is not left in an unsafe state: a subsequent, independent
        // create attempt (now backed by ordinary in-memory storage that can
        // actually persist) proceeds normally rather than being wedged.
        let workingStorage = InMemoryPendingRequestOperationStorage()
        let recoveredStore = makeStore(storage: workingStorage, currentAuthority: authorityA)
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 201, data: createResponse(id: "after-relaunch")))
        try await recoveredStore.createRequest(payload())
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, ["/api/request"])
    }

    /// Companion case: the guard added for the rejected-save path must not
    /// disturb the existing accepted issuance behavior when persistence
    /// actually succeeds.
    func testSuccessfulDurableSaveStillTransmitsExactlyAsBefore() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(storage: storage, currentAuthority: authorityA)
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 201, data: createResponse(id: "created-1")))

        try await store.createRequest(payload())

        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, ["/api/request"])
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertFalse(store.isCreating)
    }

    // MARK: - Helpers

    private func makeStore(
        storage: PendingRequestOperationStorage,
        currentAuthority: String?
    ) -> RequestStore {
        RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { currentAuthority },
            participantAuthorityRejected: {},
            operationStorage: storage
        )
    }

    private func makeService() -> RequestService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        return RequestService(client: APIClient(
            configuration: APIConfiguration(baseURL: baseURL),
            session: URLSession(configuration: configuration)
        ))
    }

    private func payload() -> CreateRequestPayload {
        CreateRequestPayload(
            vendor: "Jasper Kane Cafe",
            timing: .asap,
            windowStart: nil,
            menuPath: .mealExchange,
            mealSwipes: 1,
            mealItems: ["Chicken over rice"],
            orderDetails: nil,
            estimatedDiningDollarsCents: nil
        )
    }

    private func createResponse(id: String) -> Data {
        Data("""
        {"request":{"id":"\(id)","vendor":"Jasper Kane Cafe","food":"Meal","pickupWindowText":"ASAP","mealSwipes":1,"menuPath":"meal-exchange","mealItems":["Meal"],"orderDetails":null,"estimatedDiningDollarsCents":null,"windowStart":null,"windowEnd":null,"status":"open","createdAt":"2026-09-18T17:00:00.000Z","expiresAt":"2026-09-18T20:00:00.000Z"}}
        """.utf8)
    }
}

/// Always refuses to persist, matching `PendingRequestOperationStorage.save`'s
/// documented contract for storage that "cannot be stored without disturbing
/// entries already there": changes nothing, reports `false`.
private final class RejectingPendingRequestOperationStorage: PendingRequestOperationStorage {
    private(set) var saveAttempts = 0

    func restoreAll() -> [PendingRequestOperationEntry] { [] }

    func save(_ record: PendingRequestOperationRecord) -> Bool {
        saveAttempts += 1
        return false
    }

    func clear(operationId: String) {}
}
