//
//  ManualRefreshCancellationTests.swift
//  CommonPlateiosTests
//
// W4-H2-FIX review triage (finding 3): the manual-refresh deadline
// (`HomeExchangeView.awaitWithDeadline`) cancels the losing fetch `Task`
// rather than implementing any new store/timeout mechanism. These tests
// exercise that same real cancellation path end to end — `RequestStore.
// fetchRequests()` → `RequestService` → `APIClient` → an actual
// `URLSession` (backed by the existing `RequestFetchingURLProtocol` stub,
// reused from `RequestFetchingTests.swift` since it is `internal`, not
// `private`) — rather than a synthetic child task, to establish whether
// real `URLSessionTask` cancellation resolves promptly and whether it is
// classified as `CancellationError` rather than a spurious refresh error.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class ManualRefreshCancellationTests: XCTestCase {
    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    /// Cancelling an in-flight refresh's `Task` must resolve promptly
    /// (URLSession's async `data(for:)` cancels the underlying
    /// `URLSessionTask` and its await throws immediately — it does not wait
    /// for the gated stub response to ever arrive), must not leave any
    /// spurious `refreshError` behind, and must leave the previously loaded
    /// collection untouched.
    func testCancellingAnInFlightRefreshReturnsPromptlyWithNoSpuriousRefreshError() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "already-visible")
        ])))
        await store.fetchRequests()

        let gate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(
            data: listResponse([requestObject(id: "late-and-should-be-discarded")]),
            gate: gate
        ))

        let start = Date()
        let refreshTask = Task { await store.fetchRequests() }
        await waitUntil { store.isRefreshingRequests }

        refreshTask.cancel()
        await refreshTask.value
        let elapsed = Date().timeIntervalSince(start)

        // Well under any user-perceptible ceiling (in particular, well under
        // HomeExchangeView.manualRefreshDeadline) and specifically without
        // ever waiting for `gate.open()`, which is never called here.
        XCTAssertLessThan(elapsed, 1.0)
        XCTAssertFalse(store.isRefreshingRequests)
        XCTAssertNil(store.refreshError)
        XCTAssertEqual(store.requests.map(\.id), ["already-visible"])

        // A later fetch must win even if the cancelled attempt's gated
        // response is eventually released — the existing fetchGeneration
        // fence, not this delta, is what guarantees this.
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "newer-authoritative")
        ])))
        await store.fetchRequests()
        XCTAssertEqual(store.requests.map(\.id), ["newer-authoritative"])

        gate.open()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.requests.map(\.id), ["newer-authoritative"])
        XCTAssertNil(store.refreshError)
    }

    /// Direct proof at the `RequestService` boundary of the actual thrown
    /// error type: `APIClient.execute` reclassifies whatever `URLSession`
    /// throws on cancellation (`CancellationError` or `URLError(.cancelled)`
    /// alike) into `CancellationError` via its `Task.isCancelled` fallback,
    /// so callers never have to distinguish the two.
    func testCancellationSurfacesAsCancellationErrorAtTheServiceBoundary() async {
        let gate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(
            data: listResponse([requestObject(id: "irrelevant")]),
            gate: gate
        ))

        let service = makeService()
        let task = Task<Result<[FoodRequest], Error>, Never> {
            do {
                return .success(try await service.fetchActiveRequests(participantAuthority: "64c0000000000000000000a1.1.credential"))
            } catch {
                return .failure(error)
            }
        }
        await waitUntil { gate.isWaiting }

        task.cancel()
        let result = await task.value
        gate.open()

        guard case .failure(let error) = result else {
            return XCTFail("expected the cancelled fetch to fail")
        }
        XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
    }

    private func makeStore() -> RequestStore {
        RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
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

    private func requestObject(id: String) -> String {
        """
        {
          "id": "\(id)",
          "vendor": "Crave NYU",
          "food": "Rice bowl",
          "pickupWindowText": "ASAP",
          "mealSwipes": 2,
          "menuPath": "meal-exchange",
          "mealItems": ["Meal 1", "Meal 2"],
          "orderDetails": null,
          "estimatedDiningDollarsCents": null,
          "windowStart": null,
          "windowEnd": null,
          "status": "open",
          "createdAt": "2026-07-20T18:30:00.000Z",
          "expiresAt": "2026-07-20T23:30:00.000Z"
        }
        """
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
