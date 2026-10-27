//
//  HomeRefreshOutcomeTests.swift
//  CommonPlateiosTests
//
// W4-H3 truthful-success signal. Behavioral tests of the real composition —
// the production `RequestStore.fetchRequests()`, the production
// `HomeExchangeView.resolveRefresh` (deadline race + the fetch's own outcome +
// the success predicate), and a real `URLSession` behind the existing
// `RequestFetchingURLProtocol` stub — not source-text assertions.
//
// They establish the one thing the view alone cannot: a successful
// current-generation fetch is distinguishable from a failed, timed-out,
// cancelled, or superseded refresh even when both leave healthy data on
// screen. They do not prove the physical pull, the micro-check rendering, or
// the VoiceOver announcement.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class HomeRefreshOutcomeTests: XCTestCase {
    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Store outcome

    func testInitialLoadThatAppliesReportsSucceeded() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([requestObject(id: "a")])))

        let outcome = await store.fetchRequests()

        XCTAssertEqual(outcome, .succeeded)
        XCTAssertEqual(store.requests.map(\.id), ["a"])
    }

    func testHealthyToHealthyRefreshWithIdenticalDataStillReportsSucceeded() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([requestObject(id: "a")])))
        await store.fetchRequests()

        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([requestObject(id: "a")])))
        let outcome = await store.fetchRequests()

        XCTAssertEqual(outcome, .succeeded, "a successful current-generation fetch counts even when nothing changed")
        XCTAssertEqual(store.requests.map(\.id), ["a"])
    }

    func testFailedRefreshOverStaleHealthyDataReportsDidNotSucceed() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([requestObject(id: "a")])))
        await store.fetchRequests()

        RequestFetchingURLProtocol.enqueue(.failure(.notConnectedToInternet))
        let outcome = await store.fetchRequests()

        XCTAssertEqual(outcome, .didNotSucceed)
        // The existing stale-healthy behavior is untouched: data stays, the
        // refresh error is recorded, Home stays populated.
        XCTAssertEqual(store.requests.map(\.id), ["a"])
        XCTAssertNotNil(store.refreshError)
        XCTAssertEqual(HomeExchangeView.boardState(store: store), .populated(store.requests))
    }

    func testFailedInitialLoadReportsDidNotSucceed() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.failure(.notConnectedToInternet))

        let outcome = await store.fetchRequests()

        XCTAssertEqual(outcome, .didNotSucceed)
        XCTAssertEqual(HomeExchangeView.boardState(store: store), .unavailable)
    }

    func testCancelledRefreshReportsDidNotSucceed() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([requestObject(id: "a")])))
        await store.fetchRequests()

        let gate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([requestObject(id: "late")]), gate: gate))
        let refresh = Task { await store.fetchRequests() }
        await waitUntil { gate.isWaiting }
        refresh.cancel()
        let outcome = await refresh.value
        gate.open()

        XCTAssertEqual(outcome, .didNotSucceed)
        XCTAssertEqual(store.requests.map(\.id), ["a"])
        XCTAssertNil(store.refreshError)
    }

    func testSupersededRefreshReportsDidNotSucceedAndTheNewerOneSucceeds() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([requestObject(id: "a")])))
        await store.fetchRequests()

        // The older refresh's response is held back; a newer fetch begins and
        // completes first, bumping the generation. Releasing the older one
        // afterwards must be a stale completion.
        let gate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([requestObject(id: "older")]), gate: gate))
        let older = Task { await store.fetchRequests() }
        await waitUntil { gate.isWaiting }

        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([requestObject(id: "newer")])))
        let newerOutcome = await store.fetchRequests()
        gate.open()
        let olderOutcome = await older.value

        XCTAssertEqual(newerOutcome, .succeeded)
        XCTAssertEqual(olderOutcome, .didNotSucceed, "a superseded completion is never a success")
        XCTAssertEqual(store.requests.map(\.id), ["newer"])
    }

    func testRefreshAppliedOnlyFailClosedAfterAParticipantChangeDoesNotReportSucceeded() async {
        var authority = "64c0000000000000000000a1.1.credential"
        let store = makeStore(participantAuthority: { authority })
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([requestObject(id: "a")])))
        await store.fetchRequests()

        let gate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([requestObject(id: "a")]), gate: gate))
        let refresh = Task { await store.fetchRequests() }
        await waitUntil { gate.isWaiting }
        authority = "64c0000000000000000000b2.1.credential"
        gate.open()
        let outcome = await refresh.value

        XCTAssertEqual(outcome, .didNotSucceed, "ownership could not be established for this call")
    }

    // MARK: - The production refresh composition

    func testHealthyToHealthyRefreshAcknowledgesSuccess() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([requestObject(id: "a")])))
        await store.fetchRequests()

        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([requestObject(id: "a")])))
        let acknowledges = await HomeExchangeView.resolveRefresh(store: store)

        XCTAssertTrue(acknowledges)
    }

    func testUnavailableToHealthyBoardRefreshAcknowledgesSuccess() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.fetchRequests()
        XCTAssertEqual(HomeExchangeView.boardState(store: store), .unavailable)

        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([requestObject(id: "a")])))
        let acknowledges = await HomeExchangeView.resolveRefresh(store: store)

        XCTAssertTrue(acknowledges)
        XCTAssertEqual(HomeExchangeView.boardState(store: store), .populated(store.requests))
    }

    func testUnavailableToEmptyHealthyRefreshAcknowledgesSuccess() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.fetchRequests()

        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([])))
        let acknowledges = await HomeExchangeView.resolveRefresh(store: store)

        XCTAssertTrue(acknowledges)
        XCTAssertEqual(HomeExchangeView.boardState(store: store), .empty)
    }

    func testUnavailableToOwnedRequestDestinationsAcknowledgeSuccess() async {
        // Continue Helping / Your request(s) are categories inside a populated
        // board; the acknowledgment belongs to the refresh operation, not the
        // destination, so an owned-request result is acknowledged identically.
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.fetchRequests()

        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "mine", isOwnRequest: true),
            requestObject(id: "theirs", isOwnRequest: false)
        ])))
        let acknowledges = await HomeExchangeView.resolveRefresh(store: store)

        XCTAssertTrue(acknowledges)
        guard case .populated(let requests) = HomeExchangeView.boardState(store: store) else {
            return XCTFail("expected a populated board")
        }
        XCTAssertEqual(HomeExchangeView.partitionByOwnership(requests).owned.map(\.id), ["mine"])
    }

    func testFailedRefreshOverStaleHealthyDataDoesNotAcknowledgeSuccess() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([requestObject(id: "a")])))
        await store.fetchRequests()

        RequestFetchingURLProtocol.enqueue(.failure(.timedOut))
        let acknowledges = await HomeExchangeView.resolveRefresh(store: store)

        XCTAssertFalse(acknowledges, "Home still looks healthy, but this refresh did not succeed")
        guard case .populated = HomeExchangeView.boardState(store: store) else {
            return XCTFail("existing stale-healthy behavior must be unchanged")
        }
    }

    func testUnavailableToUnavailableRefreshDoesNotAcknowledgeSuccess() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.fetchRequests()

        RequestFetchingURLProtocol.enqueue(.failure(.notConnectedToInternet))
        let acknowledges = await HomeExchangeView.resolveRefresh(store: store)

        XCTAssertFalse(acknowledges)
        XCTAssertEqual(HomeExchangeView.boardState(store: store), .unavailable)
    }

    func testDeadlineTimeoutDoesNotAcknowledgeSuccessAndLeavesTheStaleCollection() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([requestObject(id: "a")])))
        await store.fetchRequests()

        let neverOpened = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([requestObject(id: "too-late")]), gate: neverOpened))
        let acknowledges = await HomeExchangeView.resolveRefresh(store: store, deadline: .milliseconds(150))
        neverOpened.open()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(acknowledges)
        XCTAssertEqual(store.requests.map(\.id), ["a"])
        XCTAssertNil(store.refreshError, "a deadline timeout is not a refresh failure")
    }

    func testCancelledCallerStillReportsItsOwnAuthoritativeSuccess() async {
        // SwiftUI cancels `.refreshable`'s action task almost immediately on
        // every pull; the unstructured race keeps the fetch alive, so the
        // operation's own successful outcome must survive that cancellation.
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([requestObject(id: "a")])))
        await store.fetchRequests()

        let gate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([requestObject(id: "a"), requestObject(id: "b")]), gate: gate))
        let refresh = Task { await HomeExchangeView.resolveRefresh(store: store) }
        await waitUntil { gate.isWaiting }
        refresh.cancel()
        gate.open()
        let acknowledges = await refresh.value

        XCTAssertTrue(acknowledges)
        XCTAssertEqual(store.requests.map(\.id), ["a", "b"])
    }

    func testSupersededRefreshDoesNotAcknowledgeSuccess() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([requestObject(id: "a")])))
        await store.fetchRequests()

        let gate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([requestObject(id: "older")]), gate: gate))
        let older = Task { await HomeExchangeView.resolveRefresh(store: store) }
        await waitUntil { gate.isWaiting }

        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([requestObject(id: "newer")])))
        await store.fetchRequests()
        gate.open()
        let acknowledges = await older.value

        XCTAssertFalse(acknowledges, "a superseded refresh is never acknowledged")
        XCTAssertEqual(store.requests.map(\.id), ["newer"])
    }

    // MARK: - Fixtures

    private func makeStore(participantAuthority: @escaping () -> String? = { "64c0000000000000000000a1.1.credential" }) -> RequestStore {
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
            participantAuthorityProvider: participantAuthority,
            participantAuthorityRejected: {}
        )
    }

    private func listResponse(_ requestObjects: [String]) -> Data {
        Data(#"{"requests":[\#(requestObjects.joined(separator: ","))]}"#.utf8)
    }

    private func requestObject(id: String, isOwnRequest: Bool = false) -> String {
        """
        {
          "isOwnRequest": \(isOwnRequest),
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
