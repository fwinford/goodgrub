//
//  HomeExchangeContinueHelpingDedupTests.swift
//  CommonPlateiosTests
//
// W4-H2-FIX review triage (finding 1): after an in-process claim,
// `store.requests` still carries the just-claimed request until the next
// `GET /api/requests` naturally excludes it server-side — the exact window
// `HelperRequestPresentation.availableRequests` already exists to cover for the
// older surface (see its own doc comment). `HomeExchangeView`'s board must
// reuse that same filter so the same request is never pinned above via
// Continue Helping *and* duplicated below on the shared board. Exercised
// against a real `RequestStore` driven by the existing `RequestFetchingURLProtocol`
// stub (reused from `RequestFetchingTests.swift`, which is `internal`, not
// `private`), not a hand-built `FoodRequest` fixture, so this proves the
// actual claim pipeline's shape, not an assumed one.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class HomeExchangeContinueHelpingDedupTests: XCTestCase {
    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    func testClaimedRequestIsExcludedFromTheSharedBoardWhileOthersKeepTheirOrder() async throws {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "meal-a"),
            requestObject(id: "meal-b"),
            requestObject(id: "meal-c")
        ])))
        await store.fetchRequests()

        RequestFetchingURLProtocol.enqueue(.response(data: claimResponse(
            requestObject: requestObject(id: "meal-b", status: "claimed")
        )))
        try await store.claim(requestID: "meal-b")

        // The backend has not been asked again yet, so `store.requests`
        // still literally contains "meal-b" — this is the exact window the
        // fix must cover.
        XCTAssertEqual(store.requests.map(\.id), ["meal-a", "meal-b", "meal-c"])
        XCTAssertNotNil(store.activeClaim)
        XCTAssertEqual(store.activeClaim?.requestID, "meal-b")

        let state = HomeExchangeView.boardState(store: store)
        guard case .populated(let boardRequests) = state else {
            return XCTFail("expected a populated board with meal-a and meal-c")
        }
        XCTAssertEqual(
            boardRequests.map(\.id),
            ["meal-a", "meal-c"],
            "the actively-claimed request must be excluded, and the remaining requests must keep their existing order"
        )
    }

    /// No active claim at all: the board is unfiltered, matching
    /// `HelperRequestPresentation.availableRequests`'s own no-op guard.
    func testNoActiveClaimLeavesTheBoardUnfiltered() async {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "meal-a"),
            requestObject(id: "meal-b")
        ])))
        await store.fetchRequests()

        let state = HomeExchangeView.boardState(store: store)
        guard case .populated(let boardRequests) = state else {
            return XCTFail("expected a populated board")
        }
        XCTAssertEqual(boardRequests.map(\.id), ["meal-a", "meal-b"])
    }

    func testPlacedHelperContinuationUsesSharedCardWithoutPickupActionOrRequesterPrivateData() throws {
        XCTAssertEqual(RequestCardView.waitingForPickupLabel, "Waiting for pickup")
        let homeSource = try source("Views/HomeExchangeView.swift")
        let cardSource = try source("Views/RequestCardView.swift")
        let start = try XCTUnwrap(homeSource.range(of: "// MARK: - Continue Helping"))
        let end = try XCTUnwrap(homeSource.range(of: "// MARK: - Your request(s)", range: start.upperBound..<homeSource.endIndex))
        let section = String(homeSource[start.lowerBound..<end.lowerBound])

        let listSource = try source("Views/HelperContinuationsListView.swift")
        XCTAssertTrue(section.contains("store.helperContinuationItems()"))
        XCTAssertTrue(listSource.contains(".waitingForPickup("))
        XCTAssertTrue(listSource.contains("RequestCardView("))
        XCTAssertTrue(listSource.contains("AppRoute.helperWaiting(requestID: placement.id)"))
        XCTAssertFalse(listSource.contains("AppRoute.requestDetail"), "helper-owned placement must not use the public availability path")
        for scanned in [section, listSource] {
            XCTAssertFalse(scanned.contains("Button("))
            XCTAssertFalse(scanned.contains("requesterPickupConfirmedAt"))
            XCTAssertFalse(scanned.contains("requesterParticipantId"))
        }
        XCTAssertTrue(cardSource.contains("Text(\"Waiting for pickup\")") || cardSource.contains("Self.waitingForPickupLabel"))
        XCTAssertFalse(cardSource.contains("Order #\\(orderNumber)"), "compact Home card does not repeat the order number")
        XCTAssertFalse(cardSource.contains("Estimated pickup: \\(etaText)"), "compact Home card does not repeat the ETA")
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

    private func requestObject(id: String, status: String = "open") -> String {
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
          "status": "\(status)",
          "createdAt": "2026-07-20T18:30:00.000Z",
          "expiresAt": "2026-07-20T23:30:00.000Z"
        }
        """
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
