//
//  ParticipantBlockPostYesAutonomyTests.swift
//  CommonPlateiosTests
//
// W4-U1.3 post-Block helper autonomy. Unit and source-structure proof that,
// after `Block → Yes, already placed`:
//
// - `Add 5 minutes` stays on offer under exactly the ordinary extension rules,
//   in the live caller-known state and in the reconstructed direction-agnostic
//   state, so its presence reveals nothing about a Block or whose it is;
// - `Stop helping` stays, is the same server-authoritative release, and a
//   confirmed one clears local reservation truth and resolves to Home with no
//   Active Requests beneath it and nothing to continue;
// - the control set is identical in both states and the client carries no new
//   wire field for the backend's private post-Yes authority.
//
// Backend authority is proved by `participantBlockPostYes.mongo.test.ts`. Not
// device evidence of presentation or navigation feel.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
private final class PostYesAuthorityBox {
    var value: String?
    init(_ value: String?) { self.value = value }
}

@MainActor
final class ParticipantBlockPostYesAutonomyTests: XCTestCase {
    private let requestID = "meal-a"
    private let otherRequestID = "meal-b"
    private let authority = "64c0000000000000000000a1.1.credential"
    private let reservationPath = "/api/participant/active-reservation"

    override func tearDown() {
        ParticipantBlockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Add 5 minutes

    func testLiveCallerKnownRestrictedHelpingKeepsAddFiveAndStop() async throws {
        let store = try await heldAndBlockedViaYes()

        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertTrue(store.contactSuppressedRequestIDs.contains(requestID))
        XCTAssertTrue(store.callerBlockedRequestIDs.contains(requestID))
        XCTAssertTrue(claim.isExtensionAvailable)
        XCTAssertEqual(
            FulfillRequestView.extensionControlState(for: claim),
            .available
        )
        XCTAssertTrue(store.canExtendActiveClaim)
        XCTAssertTrue(store.canReleaseActiveClaim)
    }

    func testReconstructedNeutralRestrictedHelpingKeepsAddFiveAndStop() async throws {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(
            data: reservationResponse(restricted: true, extended: false, minutesLeft: 10)
        ))

        let outcome = try await store.continueActiveReservationIfNeeded()

        guard case .active(let claim) = outcome else {
            return XCTFail("expected the reservation to be reconstructed")
        }
        XCTAssertTrue(store.contactSuppressedRequestIDs.contains(requestID))
        // Direction-agnostic only: never the ownership notice.
        XCTAssertFalse(store.callerBlockedRequestIDs.contains(requestID))
        XCTAssertTrue(claim.isExtensionAvailable)
        XCTAssertEqual(FulfillRequestView.extensionControlState(for: claim), .available)
        XCTAssertTrue(store.canExtendActiveClaim)
        XCTAssertTrue(store.canReleaseActiveClaim)
    }

    func testTheControlSetIsIdenticalLiveAndReconstructedAndRevealsNoOwnership() async throws {
        let live = try await heldAndBlockedViaYes()
        let rebuilt = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(
            data: reservationResponse(restricted: true, extended: false, minutesLeft: 10)
        ))
        _ = try await rebuilt.continueActiveReservationIfNeeded()
        let unrestricted = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(
            data: reservationResponse(restricted: false, extended: false, minutesLeft: 10)
        ))
        _ = try await unrestricted.continueActiveReservationIfNeeded()

        func controls(_ store: RequestStore) throws -> [Bool] {
            let claim = try XCTUnwrap(store.activeClaim)
            return [
                store.canExtendActiveClaim,
                store.canReleaseActiveClaim,
                FulfillRequestView.extensionControlState(for: claim) == .available,
            ]
        }

        // Add 5 and Stop are present in every state; presence alone cannot tell
        // a helper-owned Block from a requester-owned one, or from none.
        XCTAssertEqual(try controls(live), [true, true, true])
        XCTAssertEqual(try controls(rebuilt), try controls(live))
        XCTAssertEqual(try controls(unrestricted), try controls(live))
    }

    func testAddFiveSendsTheOrdinaryExtensionAndReadsAsAddedAfterwards() async throws {
        let store = try await heldAndBlockedViaYes()
        let before = try XCTUnwrap(store.activeClaim)
        let extendedUntil = before.claimExpiresAt.addingTimeInterval(5 * 60)
        ParticipantBlockURLProtocol.enqueue(.response(data: Data("""
        {
          "claim": {
            "claimExpiresAt": "\(iso8601String(extendedUntil))",
            "claimExtendedAt": "\(iso8601String(Date()))"
          }
        }
        """.utf8)))

        await store.extendActiveClaim()

        let sent = try XCTUnwrap(
            ParticipantBlockURLProtocol.capturedRequests.last { $0.path.hasSuffix("/claim/extend") }
        )
        XCTAssertEqual(sent.path, "/api/request/\(requestID)/claim/extend")
        XCTAssertEqual(sent.method, "POST")
        // The same body and authority an unrestricted extension sends.
        XCTAssertEqual(sent.bodyObject as? [String: String], ["claimToken": "claim-token"])
        let after = try XCTUnwrap(store.activeClaim)
        XCTAssertTrue(after.hasUsedExtension)
        XCTAssertEqual(
            after.claimExpiresAt.timeIntervalSince1970,
            extendedUntil.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(FulfillRequestView.extensionControlState(for: after), .added)
        XCTAssertFalse(store.canExtendActiveClaim)
        // Restriction is untouched by an extension.
        XCTAssertTrue(store.contactSuppressedRequestIDs.contains(requestID))
        XCTAssertTrue(store.canReleaseActiveClaim)
    }

    func testOrdinaryExtensionFailureStaysOrdinaryAndNeverHidesStop() async throws {
        let store = try await heldAndBlockedViaYes()
        let before = try XCTUnwrap(store.activeClaim)
        ParticipantBlockURLProtocol.enqueue(.response(
            statusCode: 409,
            data: Data(#"""
            {"error": {"code": "CLAIM_EXTENSION_INSUFFICIENT_TIME", "message": "x", "fields": null}}
            """#.utf8)
        ))

        await store.extendActiveClaim()

        // The ordinary mapping, with the reservation exactly as it was.
        XCTAssertEqual(
            ClaimExtensionPresentationError.map(store.claimExtensionError),
            .insufficientTime
        )
        let after = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(after.claimExpiresAt, before.claimExpiresAt)
        XCTAssertEqual(FulfillRequestView.extensionControlState(for: after), .cantExtend)
        XCTAssertTrue(store.canReleaseActiveClaim)
        XCTAssertTrue(store.contactSuppressedRequestIDs.contains(requestID))
        // Not retried automatically.
        XCTAssertEqual(
            ParticipantBlockURLProtocol.capturedRequests.filter { $0.path.hasSuffix("/claim/extend") }.count,
            1
        )
    }

    func testReconstructedConsumedAndInsufficientTimeStatesFollowOrdinaryRules() async throws {
        let used = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(
            data: reservationResponse(restricted: true, extended: true, minutesLeft: 20)
        ))
        _ = try await used.continueActiveReservationIfNeeded()
        XCTAssertEqual(
            FulfillRequestView.extensionControlState(for: try XCTUnwrap(used.activeClaim)),
            .added
        )
        XCTAssertTrue(used.canReleaseActiveClaim)

        ParticipantBlockURLProtocol.reset()
        let tight = makeStore()
        // The request itself expires within five minutes of the reservation.
        ParticipantBlockURLProtocol.enqueue(.response(
            data: reservationResponse(
                restricted: true,
                extended: false,
                minutesLeft: 10,
                requestExpiresInMinutes: 12
            )
        ))
        _ = try await tight.continueActiveReservationIfNeeded()
        XCTAssertEqual(
            FulfillRequestView.extensionControlState(for: try XCTUnwrap(tight.activeClaim)),
            .cantExtend
        )
        XCTAssertFalse(tight.canExtendActiveClaim)
        XCTAssertTrue(tight.canReleaseActiveClaim)
    }

    // MARK: - Stop helping after Yes

    func testStopAfterYesIsTheOrdinaryReleaseAndClearsLocalReservationTruth() async throws {
        let store = try await heldAndBlockedViaYes()
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"released": true}"#.utf8)))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))

        await store.releaseActiveClaim()

        let sent = try XCTUnwrap(
            ParticipantBlockURLProtocol.capturedRequests.last { $0.path.hasSuffix("/claim/release") }
        )
        XCTAssertEqual(sent.path, "/api/request/\(requestID)/claim/release")
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.bodyObject as? [String: String], ["claimToken": "claim-token"])
        // Confirmed by the backend before anything local clears.
        XCTAssertNil(store.activeClaim)
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertNil(store.confirmedFulfillmentOutcome)
        XCTAssertNil(store.fulfillmentAmbiguity)
        XCTAssertNil(store.releaseClaimError)
        XCTAssertFalse(store.contactSuppressedRequestIDs.contains(requestID))
        XCTAssertFalse(store.callerBlockedRequestIDs.contains(requestID))
        // The Participant Block itself is untouched.
        XCTAssertEqual(store.currentBlockedStudents.map(\.id), ["block-1"])
        XCTAssertFalse(
            ParticipantBlockURLProtocol.capturedRequests.contains { $0.path.hasSuffix("/fulfill") }
        )
    }

    func testStopAfterYesFromAReconstructedReservationUsesParticipantAuthority() async throws {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(
            data: reservationResponse(restricted: true, extended: false, minutesLeft: 10)
        ))
        _ = try await store.continueActiveReservationIfNeeded()
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"released": true}"#.utf8)))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))

        await store.releaseActiveClaim()

        let sent = try XCTUnwrap(
            ParticipantBlockURLProtocol.capturedRequests.last { $0.path.hasSuffix("/claim/release") }
        )
        XCTAssertNil(sent.bodyObject?["claimToken"])
        XCTAssertEqual(
            sent.headers[RequestService.participantAuthorityHeader],
            authority
        )
        XCTAssertNil(store.activeClaim)
        XCTAssertFalse(store.contactSuppressedRequestIDs.contains(requestID))
    }

    func testNothingIsContinuableAfterAConfirmedStop() async throws {
        let store = try await heldAndBlockedViaYes()
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"released": true}"#.utf8)))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
        await store.releaseActiveClaim()
        XCTAssertNil(store.activeClaim)
        try await settleReleaseRefresh(store)

        // The backend, asked again (a relaunch), has no reservation to restore.
        ParticipantBlockURLProtocol.enqueue(.response(
            data: Data(#"{"reservation": null, "placement": null}"#.utf8)
        ))
        let outcome = try await store.continueActiveReservationIfNeeded()

        guard case .none = outcome else {
            return XCTFail("expected no reservation to continue")
        }
        XCTAssertNil(store.activeClaim)
        XCTAssertNil(store.fulfillmentConfirmation)
    }

    func testTheStoppedHelperIsFreeToReserveAnotherRequest() async throws {
        let store = try await heldAndBlockedViaYes()
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"released": true}"#.utf8)))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
        await store.releaseActiveClaim()
        XCTAssertNil(store.activeClaim)
        try await settleReleaseRefresh(store)
        ParticipantBlockURLProtocol.enqueue(.response(data: claimResponse(id: otherRequestID)))

        try await store.claim(requestID: otherRequestID)

        XCTAssertEqual(store.activeClaim?.requestID, otherRequestID)
        // The fresh reservation carries none of the previous one's restriction.
        XCTAssertFalse(store.contactSuppressedRequestIDs.contains(otherRequestID))
        XCTAssertTrue(store.activeClaim?.isExtensionAvailable ?? false)
    }

    func testAFailedStopLeavesEverythingAsItWasAndIsNotRetried() async throws {
        let store = try await heldAndBlockedViaYes()
        let before = try XCTUnwrap(store.activeClaim)
        ParticipantBlockURLProtocol.enqueue(.failure(.networkConnectionLost))

        await store.releaseActiveClaim()

        // Never fabricated as released: still held, still restricted, and the
        // helper can try again deliberately.
        let after = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(after.requestID, before.requestID)
        XCTAssertEqual(after.claimExpiresAt, before.claimExpiresAt)
        XCTAssertNotNil(store.releaseClaimError)
        XCTAssertTrue(store.contactSuppressedRequestIDs.contains(requestID))
        XCTAssertEqual(
            ParticipantBlockURLProtocol.capturedRequests.filter { $0.path.hasSuffix("/claim/release") }.count,
            1
        )
        XCTAssertTrue(store.canReleaseActiveClaim)
    }

    func testStopCannotStartWhileAYesBlockIsStillInFlight() async throws {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(data: claimResponse(id: requestID)))
        try await store.claim(requestID: requestID)
        XCTAssertTrue(store.canReleaseActiveClaim)
        ParticipantBlockURLProtocol.enqueue(.delayed(
            0.6,
            data: blockResponse(id: "block-1", role: "requester", released: false)
        ))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))

        let blocking = Task { await store.blockHelpedRequester(externalOrderPlaced: true) }
        for _ in 0..<200 where !store.isBlockingParticipant {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(store.isBlockingParticipant)

        // A Stop that committed ahead of the Yes would release the request
        // through the ordinary branch, so it is not offered while one is in
        // flight, and the store refuses it even if it were tapped.
        XCTAssertFalse(store.canReleaseActiveClaim)
        await store.releaseActiveClaim()
        XCTAssertFalse(
            ParticipantBlockURLProtocol.capturedRequests.contains { $0.path.hasSuffix("/claim/release") }
        )
        XCTAssertEqual(store.activeClaim?.requestID, requestID)

        let result = await blocking.value
        XCTAssertEqual(result, .blocked(reservationReleased: false))
        try await settleBoardRefresh(store)
        // Once the Block has settled, Stop is available again as the same
        // ordinary release.
        XCTAssertFalse(store.isBlockingParticipant)
        XCTAssertTrue(store.canReleaseActiveClaim)
    }

    func testFinishHelpingStillRecordsTheOrderWhenStopHasNotWon() async throws {
        let store = try await heldAndBlockedViaYes()
        ParticipantBlockURLProtocol.enqueue(.response(data: fulfillmentResponse()))

        try await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )

        XCTAssertNotNil(store.fulfillmentConfirmation)
        XCTAssertNil(store.activeClaim)
        XCTAssertFalse(store.contactSuppressedRequestIDs.contains(requestID))
    }

    // MARK: - Navigation

    func testConfirmedRestrictedStopResolvesToHomeNeverActiveRequests() {
        let request = FoodRequest.fixtureForPostYes(id: requestID)
        for path: [AppRoute] in [
            [.fulfillment(request)],
            [.fulfillment(request)],
            [.settings, .requestDetail(request), .fulfillment(request)],
        ] {
            XCTAssertEqual(
                FulfillRequestView.claimedFlowPath(
                    path,
                    activeRequestID: nil,
                    confirmationRequestID: nil,
                    requestID: requestID,
                    endsAtHome: true
                ),
                []
            )
        }
    }

    func testAnOrdinaryNonSuccessEndStillReturnsToActiveRequests() {
        // Active Requests is retired (W4-R5): every non-success end returns Home.
        let request = FoodRequest.fixtureForPostYes(id: requestID)
        XCTAssertEqual(
            FulfillRequestView.claimedFlowPath(
                [.fulfillment(request)],
                activeRequestID: nil,
                confirmationRequestID: nil,
                requestID: requestID
            ),
            []
        )
    }

    func testTheHomeResultNeverOverridesPlacementOrAnActiveReservation() {
        let request = FoodRequest.fixtureForPostYes(id: requestID)
        let path: [AppRoute] = [.fulfillment(request)]
        // Fulfillment won: the success presentation owns the one Home return.
        XCTAssertEqual(
            FulfillRequestView.claimedFlowPath(
                path,
                activeRequestID: nil,
                confirmationRequestID: requestID,
                requestID: requestID,
                endsAtHome: true
            ),
            path
        )
        // The reservation is still this one: nothing to navigate away from.
        XCTAssertEqual(
            FulfillRequestView.claimedFlowPath(
                path,
                activeRequestID: requestID,
                confirmationRequestID: nil,
                requestID: requestID,
                endsAtHome: true
            ),
            path
        )
    }

    // MARK: - Source structure

    func testStopCapturesTheRestrictedStateBeforeTheReleaseAndAddsNoOwnershipBranch() throws {
        let fulfill = try source("Views/FulfillRequestView.swift")
        let control = try XCTUnwrap(fulfill.range(of: "private var stopHelpingControl: some View {"))
        let body = String(fulfill[control.lowerBound...].prefix(1_400))
        // C3: the captured destination is the store's restriction-or-lifecycle
        // rule, never Block ownership (`ParticipantBlockPostYesStopHomeTests`).
        let captured = try XCTUnwrap(
            body.range(of: "let endsAtHome = store.stopHelpingEndsAtHome(requestID: request.id)")
        )
        let release = try XCTUnwrap(body.range(of: "await store.releaseActiveClaim()"))
        XCTAssertLessThan(captured.lowerBound, release.lowerBound)
        // Control presence never reads Block ownership: the caller-owned set is
        // consulted exactly once, by the notice copy.
        XCTAssertEqual(fulfill.components(separatedBy: "callerBlockedRequestIDs").count - 1, 1)
        XCTAssertFalse(fulfill.contains("if !isBlockActive {"))
    }

    func testTheClientCarriesNoWireFieldOrBookkeepingForThePrivateAuthority() throws {
        for relative in [
            "DTOs/RequestDTOs.swift",
            "Services/RequestService.swift",
            "Stores/RequestStore.swift",
            "Views/FulfillRequestView.swift",
        ] {
            let text = try source(relative)
            XCTAssertFalse(text.contains("externalOrderAffirmed"), relative)
            XCTAssertFalse(text.contains("extensionOfferWithheld"), relative)
        }
        // A Block never consumes the single extension offer.
        let store = try source("Stores/RequestStore.swift")
        let start = try XCTUnwrap(store.range(of: "func blockHelpedRequester("))
        let end = try XCTUnwrap(
            store.range(of: "func blockRequesterOfViewedRequest(", range: start.upperBound..<store.endIndex)
        )
        XCTAssertFalse(String(store[start.lowerBound..<end.lowerBound]).contains("consumeExtensionOffer"))
        // Reconstruction derives extension availability from the ordinary rule
        // alone, never from the direction-agnostic restriction.
        let reconstruction = try XCTUnwrap(
            store.range(of: "isExtensionAvailable: Self.extensionIsAvailable(")
        )
        XCTAssertFalse(
            store[..<reconstruction.lowerBound].suffix(200).contains("directContactRestricted")
        )
    }

    // MARK: - Helpers

    private func root() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: root().appendingPathComponent(relative), encoding: .utf8)
    }

    /// A confirmed release starts its own fire-and-forget board refresh after
    /// the one the Block started; wait for it so it cannot consume a stub
    /// queued for a later call.
    private func settleReleaseRefresh(_ store: RequestStore) async throws {
        for _ in 0..<500 {
            let refreshes = ParticipantBlockURLProtocol.capturedRequests
                .filter { $0.path == "/api/requests" }.count
            if refreshes >= 2, !store.isFetching { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for the post-release board refresh")
    }

    private func settleBoardRefresh(_ store: RequestStore) async throws {
        for _ in 0..<500 {
            if ParticipantBlockURLProtocol.capturedRequests.contains(where: { $0.path == "/api/requests" }),
               !store.isFetching {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for the post-block board refresh")
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
        try await settleBoardRefresh(store)
        return store
    }

    private func makeStore() -> RequestStore {
        let box = PostYesAuthorityBox(authority)
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

    private func requestObject(
        id: String,
        status: String,
        expiresInMinutes: Int = 5 * 60
    ) -> String {
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
          "expiresAt": "\(iso8601String(Date().addingTimeInterval(TimeInterval(expiresInMinutes * 60))))"
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

    private func reservationResponse(
        restricted: Bool,
        extended: Bool,
        minutesLeft: Int,
        requestExpiresInMinutes: Int = 5 * 60
    ) -> Data {
        let flag = restricted ? #","directContactRestricted": true"# : ""
        let extendedAt = extended ? "\"\(iso8601String(Date()))\"" : "null"
        return Data("""
        {
          "reservation": {
            "request": \(requestObject(id: requestID, status: "claimed", expiresInMinutes: requestExpiresInMinutes)),
            "claimExpiresAt": "\(iso8601String(Date().addingTimeInterval(TimeInterval(minutesLeft * 60))))",
            "claimExtendedAt": \(extendedAt)\(flag)
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
    static func fixtureForPostYes(id: String) -> FoodRequest {
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
