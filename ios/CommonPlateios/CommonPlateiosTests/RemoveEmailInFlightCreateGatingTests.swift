//
//  RemoveEmailInFlightCreateGatingTests.swift
//  CommonPlateiosTests
//
// Focused W4-D2 FIX coverage (2026-09-18 independent-review MUST FIX):
// `RequestStore.hasUnresolvedCreateAmbiguity` deliberately excludes the
// just-issued operation while it is still in flight (own record is not a
// block while it is being posted), so the accepted Remove Email gate
// (`SettingsView.isRemoveEmailBlocked`, mirrored here by source inspection
// exactly as `RemoveEmailTests.swift` already does) must add
// `|| requestStore.isCreating` to stay fail-closed for that window too. Reuses
// `RequestFetchingURLProtocol`/`RequestFetchingGate` from
// `RequestFetchingTests.swift` to hold a create POST in flight.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class RemoveEmailInFlightCreateGatingTests: XCTestCase {
    private let baseURL = URL(string: "https://commonplate.test")!

    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    func testRemoveEmailStaysBlockedWhileACreateIsInFlightThenResumesNormalRulesAfterItResolves() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(storage: storage)

        // 1. Establish removal safety's cold-launch readiness with nothing
        // outstanding, exactly as `RemoveEmailTests`'s own "no blocking work"
        // baseline does, so any block observed below must come from the
        // in-flight create itself, not from unresolved cold-launch checks.
        _ = await store.reconcilePendingCreateOperationIfNeeded()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: Data(#"{"reservation":null}"#.utf8)))
        _ = try await store.continueActiveReservationIfNeeded()
        XCTAssertTrue(store.hasEstablishedRemovalSafety)
        XCTAssertFalse(isRemoveEmailBlocked(store))

        let createGate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(id: "in-flight-1"),
            gate: createGate
        ))

        // 2. Create begins.
        let createTask = Task { try await store.createRequest(payload()) }
        await waitUntil { createGate.isWaiting }

        // 3. The durable pending operation exists, and POST remains
        // intentionally in flight. `hasUnresolvedCreateAmbiguity` is
        // deliberately still `false` here — the just-issued operation is not
        // a block while it is being posted — which is exactly the gap the
        // old Remove Email formula missed.
        XCTAssertTrue(store.isCreating)
        XCTAssertEqual(storage.loadAll().map(\.operationId).count, 1)
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)

        // 4. Remove Email is disabled/blocked.
        XCTAssertTrue(
            isRemoveEmailBlocked(store),
            "an issued create's outcome is still unknown; Remove Email must stay fail-closed"
        )

        // 5. Settings presentation does not clear or mutate the operation.
        XCTAssertEqual(storage.loadAll().map(\.operationId).count, 1)

        createGate.open()
        try await createTask.value

        // 6. After the create reaches an authoritative safe terminal state,
        // normal Remove Email readiness rules resume.
        XCTAssertFalse(store.isCreating)
        XCTAssertFalse(isRemoveEmailBlocked(store))
    }

    /// Proves the block above is scoped to `isCreating`'s own window, not a
    /// lingering side effect of having once created — an ordinary,
    /// already-resolved create must not leave Remove Email blocked.
    func testAnOrdinaryUnrelatedStateDoesNotRemainBlockedAfterTheCreateSafelyResolves() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(storage: storage)
        _ = await store.reconcilePendingCreateOperationIfNeeded()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: Data(#"{"reservation":null}"#.utf8)))
        _ = try await store.continueActiveReservationIfNeeded()

        RequestFetchingURLProtocol.enqueue(.response(statusCode: 201, data: createResponse(id: "resolved-1")))
        try await store.createRequest(payload())

        XCTAssertFalse(store.isCreating)
        XCTAssertFalse(isRemoveEmailBlocked(store))
    }

    // MARK: - Helpers

    /// Mirrors `SettingsView.isRemoveEmailBlocked` exactly, by source
    /// inspection — the same approach `RemoveEmailTests.swift` already uses
    /// to test this gate's underlying `RequestStore` signals without
    /// instantiating SwiftUI view code.
    private func isRemoveEmailBlocked(_ store: RequestStore) -> Bool {
        !store.hasEstablishedRemovalSafety
            || store.activeClaim != nil
            || store.hasUnresolvedCreateAmbiguity
            || store.isCreating
    }

    private func makeStore(storage: PendingRequestOperationStorage) -> RequestStore {
        RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { canonicalParticipantAuthorityFixture },
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
