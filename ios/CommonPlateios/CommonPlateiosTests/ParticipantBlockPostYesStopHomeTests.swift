//
//  ParticipantBlockPostYesStopHomeTests.swift
//  CommonPlateiosTests
//
// W4-U1.3 final review decisions C1 and C3, iOS side. Unit and source-structure
// proof that:
//
// - C1: a `Yes, already placed` the backend refuses with
//   `RESERVATION_STATE_CHANGED` is never a Block success — no restricted,
//   caller-owned, or post-Yes state is stored, nothing is retried, and the
//   existing `Couldn’t block` presentation carries the existing message;
// - C3: once the helper's own Unblock has restored normal Helping, a confirmed
//   Stop of a post-Yes reservation still ends at Home, live and after a
//   relaunch, because the destination comes from the authoritative
//   active-reservation read and never from Block ownership or process memory;
//   a stale or mismatched read cannot attach it to another reservation, and an
//   ordinary Stop is unchanged.
//
// Backend authority is proved by `participantBlockPostYes.mongo.test.ts`. Not
// device evidence of presentation or navigation feel.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
private final class StopHomeAuthorityBox {
    var value: String?
    init(_ value: String?) { self.value = value }
}

@MainActor
final class ParticipantBlockPostYesStopHomeTests: XCTestCase {
    private let requestID = "meal-a"
    private let otherRequestID = "meal-b"
    private let authority = "64c0000000000000000000a1.1.credential"
    private let reservationPath = "/api/participant/active-reservation"

    override func tearDown() {
        ParticipantBlockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - C1: a refused Yes is never a Block success

    func testRefusedYesIsNotABlockAndStoresNoRestrictedOrPostYesState() async throws {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(data: claimResponse(id: requestID)))
        try await store.claim(requestID: requestID)
        let before = try XCTUnwrap(store.activeClaim)
        ParticipantBlockURLProtocol.enqueue(.response(statusCode: 409, data: stateChangedBody()))

        let result = await store.blockHelpedRequester(externalOrderPlaced: true)

        XCTAssertEqual(result, .notBlocked)
        // No Block, no restriction, no caller-owned notice, no Home-routing
        // lifecycle, and no blocked student listed.
        XCTAssertFalse(store.contactSuppressedRequestIDs.contains(requestID))
        XCTAssertFalse(store.callerBlockedRequestIDs.contains(requestID))
        XCTAssertFalse(store.stopReturnsHomeRequestIDs.contains(requestID))
        XCTAssertFalse(store.stopHelpingEndsAtHome(requestID: requestID))
        XCTAssertTrue(store.currentBlockedStudents.isEmpty)
        // Nothing about the reservation is fabricated as released or placed.
        let after = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(after.requestID, before.requestID)
        XCTAssertEqual(after.claimExpiresAt, before.claimExpiresAt)
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertNil(store.confirmedFulfillmentOutcome)
        // The existing truthful failure presentation, with the existing copy.
        XCTAssertEqual(
            ParticipantBlockPresentationError.map(store.blockError),
            .reservationChanged
        )
        XCTAssertEqual(ParticipantBlockCopy.failureTitle, "Couldn’t block")
        XCTAssertEqual(
            ParticipantBlockPresentationError.reservationChanged.message,
            "Your reservation changed. Check its status and try again."
        )
        // Not retried; the Helping menu stays the ordinary pre-Block one.
        XCTAssertEqual(
            ParticipantBlockURLProtocol.capturedRequests.filter { $0.path.hasSuffix("/block") }.count,
            1
        )
        XCTAssertTrue(ParticipantBlockAvailability.helpingOffersBlock(
            canBlockHelpedRequester: store.canBlockHelpedRequester,
            blockIsActive: store.contactSuppressedRequestIDs.contains(requestID)
        ))
    }

    func testARefusedYesLeavesAnOrdinaryStopRoutingUnchanged() async throws {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(data: claimResponse(id: requestID)))
        try await store.claim(requestID: requestID)
        ParticipantBlockURLProtocol.enqueue(.response(statusCode: 409, data: stateChangedBody()))
        _ = await store.blockHelpedRequester(externalOrderPlaced: true)

        // The refusal established nothing that would send a later Stop Home.
        let request = FoodRequest.fixtureForStopHome(id: requestID)
        XCTAssertEqual(
            FulfillRequestView.claimedFlowPath(
                [.fulfillment(request)],
                activeRequestID: nil,
                confirmationRequestID: nil,
                requestID: requestID,
                endsAtHome: store.stopHelpingEndsAtHome(requestID: requestID)
            ),
            []
        )
    }

    // MARK: - C3 live: Yes → Unblock → normal Helping → Stop → Home

    func testYesThenUnblockRestoresNormalHelpingAndStopStillEndsAtHome() async throws {
        let store = try await heldAndBlockedViaYes()
        // While restricted, the existing rule already ends a Stop at Home.
        XCTAssertTrue(store.stopHelpingEndsAtHome(requestID: requestID))

        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"removed": true}"#.utf8)))
        ParticipantBlockURLProtocol.enqueue(.response(
            data: reservationResponse(restricted: false, stopReturnsHome: true)
        ))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
        await store.unblockStudent(id: "block-1")
        try await settleBoardRefresh(store, atLeast: 2)

        // F6d: normal Helping is back — no restriction, no caller-owned notice,
        // Message and the safety menu return, Add 5 and Stop unchanged.
        XCTAssertFalse(store.contactSuppressedRequestIDs.contains(requestID))
        XCTAssertFalse(store.callerBlockedRequestIDs.contains(requestID))
        XCTAssertTrue(store.canBlockHelpedRequester)
        XCTAssertTrue(store.canExtendActiveClaim)
        XCTAssertTrue(store.canReleaseActiveClaim)
        // C3: the post-Yes lifecycle survived the Unblock, from the backend read.
        XCTAssertTrue(store.stopReturnsHomeRequestIDs.contains(requestID))
        let endsAtHome = store.stopHelpingEndsAtHome(requestID: requestID)
        XCTAssertTrue(endsAtHome)

        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"released": true}"#.utf8)))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
        await store.releaseActiveClaim()

        // The ordinary Stop mutation, confirmed before anything local clears.
        XCTAssertNil(store.activeClaim)
        XCTAssertFalse(store.stopReturnsHomeRequestIDs.contains(requestID))
        XCTAssertFalse(
            ParticipantBlockURLProtocol.capturedRequests.contains { $0.path.hasSuffix("/fulfill") }
        )
        // Home, with no Active Requests beneath, from either stack origin.
        assertEndsAtHome(endsAtHome)
    }

    // MARK: - C3 relaunch: Yes → Unblock → relaunch → Stop → Home

    func testRelaunchAfterYesAndUnblockReconstructsTheHomeDestination() async throws {
        // A fresh process: no memory of the Yes, the Block, or the Unblock.
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(
            data: reservationResponse(restricted: false, stopReturnsHome: true)
        ))

        let outcome = try await store.continueActiveReservationIfNeeded()

        guard case .active = outcome else {
            return XCTFail("expected the reservation to be reconstructed")
        }
        // Normal Helping: nothing restricted, nothing caller-owned.
        XCTAssertFalse(store.contactSuppressedRequestIDs.contains(requestID))
        XCTAssertFalse(store.callerBlockedRequestIDs.contains(requestID))
        XCTAssertTrue(store.canExtendActiveClaim)
        XCTAssertTrue(store.canReleaseActiveClaim)
        let endsAtHome = store.stopHelpingEndsAtHome(requestID: requestID)
        XCTAssertTrue(endsAtHome)

        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"released": true}"#.utf8)))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
        await store.releaseActiveClaim()

        let sent = try XCTUnwrap(
            ParticipantBlockURLProtocol.capturedRequests.last { $0.path.hasSuffix("/claim/release") }
        )
        XCTAssertEqual(sent.headers[RequestService.participantAuthorityHeader], authority)
        XCTAssertNil(store.activeClaim)
        XCTAssertTrue(store.stopReturnsHomeRequestIDs.isEmpty)
        assertEndsAtHome(endsAtHome)
    }

    func testReconstructedRestrictedReadCarriesNoSignalAndStillEndsAtHome() async throws {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(
            data: reservationResponse(restricted: true, stopReturnsHome: false)
        ))

        _ = try await store.continueActiveReservationIfNeeded()

        // The existing restricted rule, not the lifecycle signal.
        XCTAssertTrue(store.contactSuppressedRequestIDs.contains(requestID))
        XCTAssertFalse(store.stopReturnsHomeRequestIDs.contains(requestID))
        XCTAssertTrue(store.stopHelpingEndsAtHome(requestID: requestID))
    }

    // MARK: - C3 authority and stale-response fencing

    func testOrdinaryStopWithoutThePostYesLifecycleIsUnchanged() async throws {
        let live = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(data: claimResponse(id: requestID)))
        try await live.claim(requestID: requestID)
        XCTAssertFalse(live.stopHelpingEndsAtHome(requestID: requestID))

        ParticipantBlockURLProtocol.reset()
        let rebuilt = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(
            data: reservationResponse(restricted: false, stopReturnsHome: false)
        ))
        _ = try await rebuilt.continueActiveReservationIfNeeded()
        XCTAssertFalse(rebuilt.stopHelpingEndsAtHome(requestID: requestID))

        // An ordinary non-success end still unwinds to Active Requests (R5).
        let request = FoodRequest.fixtureForStopHome(id: requestID)
        XCTAssertEqual(
            FulfillRequestView.claimedFlowPath(
                [.fulfillment(request)],
                activeRequestID: nil,
                confirmationRequestID: nil,
                requestID: requestID,
                endsAtHome: rebuilt.stopHelpingEndsAtHome(requestID: requestID)
            ),
            []
        )
    }

    func testAReadForADifferentReservationNeverAttachesTheSignal() async throws {
        let store = try await heldAndBlockedViaYes()
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"removed": true}"#.utf8)))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data("""
        {
          "reservation": {
            "request": \(requestObject(id: otherRequestID, status: "claimed")),
            "claimExpiresAt": "\(iso8601String(Date().addingTimeInterval(10 * 60)))",
            "claimExtendedAt": null,
            "stopReturnsHome": true
          },
          "placement": null
        }
        """.utf8)))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))

        await store.unblockStudent(id: "block-1")
        try await settleBoardRefresh(store, atLeast: 2)

        // Neither reservation gains it; the held one stays conservatively
        // restricted, which already ends a Stop at Home.
        XCTAssertTrue(store.stopReturnsHomeRequestIDs.isEmpty)
        XCTAssertFalse(store.stopHelpingEndsAtHome(requestID: otherRequestID))
        XCTAssertTrue(store.contactSuppressedRequestIDs.contains(requestID))
        XCTAssertTrue(store.stopHelpingEndsAtHome(requestID: requestID))
    }

    func testAFailedReadAfterUnblockStaysRestrictedAndStillEndsAtHome() async throws {
        let store = try await heldAndBlockedViaYes()
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"removed": true}"#.utf8)))
        ParticipantBlockURLProtocol.enqueue(.failure(.networkConnectionLost))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))

        await store.unblockStudent(id: "block-1")
        try await settleBoardRefresh(store, atLeast: 2)

        XCTAssertTrue(store.contactSuppressedRequestIDs.contains(requestID))
        XCTAssertFalse(store.stopReturnsHomeRequestIDs.contains(requestID))
        XCTAssertTrue(store.stopHelpingEndsAtHome(requestID: requestID))
    }

    func testAnUnrestrictedAuthoritativeReadReplacesWhatIsKnown() async throws {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(
            data: reservationResponse(restricted: false, stopReturnsHome: true)
        ))
        _ = try await store.continueActiveReservationIfNeeded()
        XCTAssertTrue(store.stopReturnsHomeRequestIDs.contains(requestID))

        // A new restriction appears (e.g. the helper blocks again via Helping);
        // a later unrestricted read without the signal replaces the knowledge.
        ParticipantBlockURLProtocol.enqueue(.response(
            data: blockResponse(id: "block-2", role: "requester", released: false)
        ))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
        let reblocked = await store.blockHelpedRequester(externalOrderPlaced: true)
        XCTAssertEqual(reblocked, .blocked(reservationReleased: false))
        try await settleBoardRefresh(store, atLeast: 1)
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"removed": true}"#.utf8)))
        ParticipantBlockURLProtocol.enqueue(.response(
            data: reservationResponse(restricted: false, stopReturnsHome: false)
        ))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
        await store.unblockStudent(id: "block-2")
        try await settleBoardRefresh(store, atLeast: 2)

        XCTAssertFalse(store.contactSuppressedRequestIDs.contains(requestID))
        XCTAssertFalse(store.stopReturnsHomeRequestIDs.contains(requestID))
    }

    func testTheSignalEndsWithItsClaimAndNeverReachesTheNextReservation() async throws {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(
            data: reservationResponse(restricted: false, stopReturnsHome: true)
        ))
        _ = try await store.continueActiveReservationIfNeeded()
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"released": true}"#.utf8)))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
        await store.releaseActiveClaim()
        XCTAssertNil(store.activeClaim)
        try await settleBoardRefresh(store, atLeast: 1)

        ParticipantBlockURLProtocol.enqueue(.response(data: claimResponse(id: otherRequestID)))
        try await store.claim(requestID: otherRequestID)

        XCTAssertEqual(store.activeClaim?.requestID, otherRequestID)
        XCTAssertTrue(store.stopReturnsHomeRequestIDs.isEmpty)
        XCTAssertFalse(store.stopHelpingEndsAtHome(requestID: otherRequestID))
    }

    func testFinishHelpingStillWinsOverTheHomeDestination() async throws {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(
            data: reservationResponse(restricted: false, stopReturnsHome: true)
        ))
        _ = try await store.continueActiveReservationIfNeeded()
        ParticipantBlockURLProtocol.enqueue(.response(data: fulfillmentResponse()))

        try await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )

        XCTAssertNotNil(store.fulfillmentConfirmation)
        XCTAssertNil(store.activeClaim)
        XCTAssertTrue(store.stopReturnsHomeRequestIDs.isEmpty)
        // The success presentation owns its own Home return.
        let request = FoodRequest.fixtureForStopHome(id: requestID)
        XCTAssertEqual(
            FulfillRequestView.claimedFlowPath(
                [.fulfillment(request)],
                activeRequestID: nil,
                confirmationRequestID: requestID,
                requestID: requestID,
                endsAtHome: true
            ),
            [.fulfillment(request)]
        )
    }

    // MARK: - Source structure

    func testTheDestinationNeverReadsBlockOwnershipAndIsKeptApartFromRestriction() throws {
        let store = try source("Stores/RequestStore.swift")
        let start = try XCTUnwrap(store.range(of: "func stopHelpingEndsAtHome(requestID: String) -> Bool {"))
        let body = String(store[start.lowerBound...].prefix(260))
        XCTAssertTrue(body.contains("contactSuppressedRequestIDs.contains(requestID)"))
        XCTAssertTrue(body.contains("stopReturnsHomeRequestIDs.contains(requestID)"))
        XCTAssertFalse(body.contains("callerBlockedRequestIDs"))
        // Only the authoritative read writes the lifecycle signal: the Block
        // mutation path never does.
        let blockStart = try XCTUnwrap(store.range(of: "func blockHelpedRequester("))
        let blockEnd = try XCTUnwrap(
            store.range(of: "func blockRequesterOfViewedRequest(", range: blockStart.upperBound..<store.endIndex)
        )
        XCTAssertFalse(
            String(store[blockStart.lowerBound..<blockEnd.lowerBound]).contains("stopReturnsHomeRequestIDs.insert")
        )
        XCTAssertEqual(store.components(separatedBy: "stopReturnsHomeRequestIDs.insert(").count - 1, 2)
        // The wire field names a lifecycle consequence, never an owner or the
        // backend's private authority.
        let dto = try source("DTOs/RequestDTOs.swift")
        XCTAssertTrue(dto.contains("case stopReturnsHome"))
        for forbidden in ["externalOrderAffirmed", "blockedByCaller", "callerOwnsBlock", "blockOwner"] {
            XCTAssertFalse(dto.contains(forbidden), forbidden)
        }
    }

    // MARK: - Helpers

    private func assertEndsAtHome(_ endsAtHome: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let request = FoodRequest.fixtureForStopHome(id: requestID)
        for path: [AppRoute] in [
            [.fulfillment(request)],
            [.fulfillment(request)],
        ] {
            XCTAssertEqual(
                FulfillRequestView.claimedFlowPath(
                    path,
                    activeRequestID: nil,
                    confirmationRequestID: nil,
                    requestID: requestID,
                    endsAtHome: endsAtHome
                ),
                [],
                file: file,
                line: line
            )
        }
    }

    private func root() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: root().appendingPathComponent(relative), encoding: .utf8)
    }

    /// Waits until at least `count` fire-and-forget board refreshes reached the
    /// shared transport, so none can consume a stub queued for a later call.
    private func settleBoardRefresh(_ store: RequestStore, atLeast count: Int) async throws {
        for _ in 0..<500 {
            let refreshes = ParticipantBlockURLProtocol.capturedRequests
                .filter { $0.path == "/api/requests" }.count
            if refreshes >= count, !store.isFetching { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for the board refresh")
    }

    /// A helper holding the reservation who answered `Yes, already placed` and
    /// was told their Block is active.
    private func heldAndBlockedViaYes() async throws -> RequestStore {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(data: claimResponse(id: requestID)))
        try await store.claim(requestID: requestID)
        ParticipantBlockURLProtocol.enqueue(.response(
            data: blockResponse(id: "block-1", role: "requester", released: false)
        ))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
        let result = await store.blockHelpedRequester(externalOrderPlaced: true)
        XCTAssertEqual(result, .blocked(reservationReleased: false))
        XCTAssertTrue(store.callerBlockedRequestIDs.contains(requestID))
        XCTAssertTrue(store.contactSuppressedRequestIDs.contains(requestID))
        try await settleBoardRefresh(store, atLeast: 1)
        return store
    }

    private func makeStore() -> RequestStore {
        let box = StopHomeAuthorityBox(authority)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ParticipantBlockURLProtocol.self]
        let service = RequestService(client: APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        ))
        return RequestStore(
            service: service,
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { box.value },
            participantAuthorityRejected: {}
        )
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func requestObject(id: String, status: String) -> String {
        """
        {
          "id": "\(id)",
          "vendor": "Jasper Kane Cafe",
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
          "createdAt": "2026-07-20T18:30:00.000Z",
          "expiresAt": "\(iso8601String(Date().addingTimeInterval(5 * 60 * 60)))"
        }
        """
    }

    private func claimResponse(id: String) -> Data {
        Data("""
        {
          "request": \(requestObject(id: id, status: "claimed")),
          "claim": {
            "claimToken": "claim-token",
            "claimExpiresAt": "\(iso8601String(Date().addingTimeInterval(15 * 60)))"
          }
        }
        """.utf8)
    }

    private func reservationResponse(restricted: Bool, stopReturnsHome: Bool) -> Data {
        let restriction = restricted ? #","directContactRestricted": true"# : ""
        let lifecycle = stopReturnsHome ? #","stopReturnsHome": true"# : ""
        return Data("""
        {
          "reservation": {
            "request": \(requestObject(id: requestID, status: "claimed")),
            "claimExpiresAt": "\(iso8601String(Date().addingTimeInterval(10 * 60)))",
            "claimExtendedAt": null\(restriction)\(lifecycle)
          },
          "placement": null
        }
        """.utf8)
    }

    private func blockResponse(id: String, role: String, released: Bool) -> Data {
        Data("""
        {
          "block": {
            "id": "\(id)",
            "blockedRole": "\(role)",
            "diningLocation": "Jasper Kane Cafe",
            "interactionAt": "2026-07-20T18:30:00.000Z",
            "createdAt": "2026-07-20T18:31:00.000Z"
          },
          "reservationReleased": \(released)
        }
        """.utf8)
    }

    private func stateChangedBody() -> Data {
        Data(#"""
        {"error": {"code": "RESERVATION_STATE_CHANGED", "message": "Your reservation changed. Check its status and try again.", "fields": null}}
        """#.utf8)
    }

    private func fulfillmentResponse() -> Data {
        Data("""
        {
          "request": \(requestObject(id: requestID, status: "placed")),
          "notification": { "status": "sent" }
        }
        """.utf8)
    }
}

private extension FoodRequest {
    static func fixtureForStopHome(id: String) -> FoodRequest {
        FoodRequest(
            id: id,
            diningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            foodDescription: "Rice bowl",
            pickupWindowText: "ASAP",
            mealSwipes: 1,
            windowStart: nil,
            windowEnd: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 3_600),
            status: .claimed
        )
    }
}
