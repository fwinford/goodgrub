//
//  HomeRefreshCallerCancellationTests.swift
//  CommonPlateiosTests
//
// W4-H4 physical-device refresh defect. Faith seeded new open requests while
// Home was already running, pulled to refresh, and the board did not change;
// the same requests appeared immediately after a force-quit relaunch.
//
// Instrumented simulator reproduction established the cause: SwiftUI cancels
// `.refreshable`'s own action task as soon as the view owning the modifier is
// invalidated, and the refresh itself invalidates Home the instant it starts
// (`RequestStore.fetchRequests()` publishes `isRefreshingRequests`, which
// `HomeExchangeView` observes). That cancellation landed ~15-40 ms into every
// pull. `HomeExchangeView.awaitWithDeadline` ran the authoritative fetch as a
// *structured child* of that task, so the child inherited the cancellation and
// the in-flight `GET /api/requests` was cancelled before it could resolve.
// `fetchRequests()` then correctly treated `CancellationError` as "no answer"
// and returned without touching `requests` — so newly available authoritative
// requests could never reach the rendered board without relaunching, while the
// cold-launch `.task` load (never tied to the refresh action's lifetime)
// always worked.
//
// These are behavioral tests of the real composition — the production
// `awaitWithDeadline`, the production `RequestStore.fetchRequests()`, and a
// real `URLSession` behind the existing `RequestFetchingURLProtocol` stub —
// not source-text assertions. They do not, and cannot, prove the physical pull
// gesture itself; they prove the refresh path applies authoritative data when
// the calling task is cancelled exactly the way SwiftUI cancels it.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class HomeRefreshCallerCancellationTests: XCTestCase {
    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    /// The defect itself. The caller's task is cancelled while the refresh is
    /// in flight — as SwiftUI does on every pull — and the authoritative
    /// response must still be applied to the store.
    func testRefreshAppliesNewAuthoritativeRequestsWhenTheCallingTaskIsCancelled() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "already-visible")
        ])))
        await store.fetchRequests()
        XCTAssertEqual(store.requests.map(\.id), ["already-visible"])

        // The refresh's response is gated so the caller can be cancelled while
        // the request is genuinely still in flight, reproducing the real
        // ordering rather than a race that happens to resolve first.
        let gate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(
            data: listResponse([
                requestObject(id: "already-visible"),
                requestObject(id: "seeded-while-home-was-open")
            ]),
            gate: gate
        ))

        let refresh = Task { () -> Bool in
            await HomeExchangeView.awaitWithDeadline(HomeExchangeView.manualRefreshDeadline) {
                await store.fetchRequests()
            }
        }
        await waitUntil { gate.isWaiting }

        refresh.cancel()
        gate.open()
        let didResolveInTime = await refresh.value

        XCTAssertTrue(
            didResolveInTime,
            "a refresh whose caller was cancelled must still report its own authoritative outcome"
        )
        XCTAssertEqual(
            store.requests.map(\.id),
            ["already-visible", "seeded-while-home-was-open"],
            "newly available authoritative requests must reach the store without an app relaunch"
        )
        XCTAssertNil(store.refreshError)
        XCTAssertFalse(store.isFetching)
    }

    /// Repeated refreshes stay safe: the second pull's result is the one that
    /// survives, through `RequestStore`'s existing
    /// `fetchGeneration`/`collectionRevision` fence rather than anything added
    /// here. A late-landing first attempt can never overwrite it.
    func testRepeatedCancelledRefreshesLeaveTheLatestAuthoritativeResult() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "first")
        ])))
        await store.fetchRequests()

        let olderGate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(
            data: listResponse([requestObject(id: "older-refresh")]),
            gate: olderGate
        ))
        let older = Task {
            await HomeExchangeView.awaitWithDeadline(HomeExchangeView.manualRefreshDeadline) {
                await store.fetchRequests()
            }
        }
        await waitUntil { olderGate.isWaiting }
        older.cancel()

        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "newer-refresh")
        ])))
        let newer = Task {
            await HomeExchangeView.awaitWithDeadline(HomeExchangeView.manualRefreshDeadline) {
                await store.fetchRequests()
            }
        }
        newer.cancel()
        _ = await newer.value

        // Release the older attempt only now: its response is authoritative
        // for a superseded generation and must be discarded.
        olderGate.open()
        _ = await older.value
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(store.requests.map(\.id), ["newer-refresh"])
        XCTAssertNil(store.refreshError)
    }

    /// HQ decision 8 is unchanged by the fix: an operation that loses the race
    /// to the deadline is still cancelled, still reports `false`, and still
    /// leaves the previously loaded collection exactly as it was.
    func testDeadlineStillCancelsTheLosingFetchAndReportsFailure() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "already-visible")
        ])))
        await store.fetchRequests()

        let neverOpened = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(
            data: listResponse([requestObject(id: "too-late")]),
            gate: neverOpened
        ))

        let start = Date()
        let didResolveInTime = await HomeExchangeView.awaitWithDeadline(.milliseconds(150)) {
            await store.fetchRequests()
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(didResolveInTime)
        XCTAssertLessThan(elapsed, 2.0, "the deadline must end the wait rather than block on the fetch")
        XCTAssertEqual(store.requests.map(\.id), ["already-visible"])
        XCTAssertNil(store.refreshError, "a deadline timeout is not a refresh failure")
        XCTAssertFalse(store.isFetching)

        neverOpened.open()
    }

    /// A refresh whose caller is never cancelled behaves exactly as before.
    func testUncancelledRefreshStillAppliesAndReportsSuccess() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "already-visible")
        ])))
        await store.fetchRequests()

        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "refreshed")
        ])))
        let didResolveInTime = await HomeExchangeView.awaitWithDeadline(
            HomeExchangeView.manualRefreshDeadline
        ) {
            await store.fetchRequests()
        }

        XCTAssertTrue(didResolveInTime)
        XCTAssertEqual(store.requests.map(\.id), ["refreshed"])
        XCTAssertNil(store.refreshError)
    }

    // MARK: - Fixtures

    private func makeStore() -> RequestStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return RequestStore(
            service: RequestService(client: client),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { "64c0000000000000000000a1.1.credential" },
            participantAuthorityRejected: {}
        )
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
        timeoutIterations: Int = 200,
        condition: @Sendable () -> Bool
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
