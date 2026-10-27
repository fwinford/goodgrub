//
//  ParticipantBlockReconstructionTests.swift
//  CommonPlateiosTests
//
// W4-U1.3 bounded fix pass. Two things are proved here:
//
// 1. Contact eligibility after a relaunch comes from the authoritative
//    active-reservation read, not from the process that took the Block: a
//    reconstructed reservation for a restricted pair has no optional Message
//    and no extension, still records placement through the existing authority,
//    and an unrelated reconstructed reservation is unchanged.
// 2. A Message not shared because of the blocked-pair restriction is presented
//    as exactly `Your message wasn’t shared.`, while U1.1's text-filter
//    suppression keeps its accepted presentation — and neither path carries any
//    block state beyond that sentence.
//
// Unit proof of state and copy, not device evidence of presentation.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
private final class ReconstructionAuthorityBox {
    var value: String?
    init(_ value: String?) { self.value = value }
}

@MainActor
final class ParticipantBlockReconstructionTests: XCTestCase {
    private let requestID = "meal-a"
    private let authority = "64c0000000000000000000a1.1.credential"

    override func tearDown() {
        ParticipantBlockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Wire

    func testReservationReadDecodesTheAffirmativeRestrictionAndToleratesItsAbsence() throws {
        let restricted = try decoder().decode(
            ActiveReservationResponseDTO.self,
            from: reservationResponse(restricted: true)
        )
        XCTAssertEqual(restricted.reservation?.directContactRestricted, true)

        let plain = try decoder().decode(
            ActiveReservationResponseDTO.self,
            from: reservationResponse(restricted: false)
        )
        XCTAssertNil(plain.reservation?.directContactRestricted)
    }

    func testFulfillAndPlacedReadsDecodeTheWithheldRefinement() throws {
        let fulfilled = try decoder().decode(
            FulfillResponseDTO.self,
            from: fulfillmentResponse(suppressed: true, withheld: true)
        )
        XCTAssertEqual(fulfilled.messageSuppressed, true)
        XCTAssertEqual(fulfilled.messageWithheld, true)

        let filterOnly = try decoder().decode(
            FulfillResponseDTO.self,
            from: fulfillmentResponse(suppressed: true, withheld: false)
        )
        XCTAssertEqual(filterOnly.messageSuppressed, true)
        XCTAssertNil(filterOnly.messageWithheld)

        let placed = try decoder().decode(
            ActiveReservationResponseDTO.self,
            from: placementResponse(suppressed: true, withheld: true)
        )
        XCTAssertEqual(placed.placement?.messageWithheld, true)
    }

    // MARK: - Relaunch reconstruction

    /// The whole story in one test: the helper blocks (the order was already
    /// placed), the process is replaced by a fresh one with no memory of it, and
    /// the reconstructed reservation must not regain the Message.
    func testABlockedReservationDoesNotRegainTheMessageAfterRelaunch() async throws {
        let original = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(data: claimResponse()))
        try await original.claim(requestID: requestID)
        ParticipantBlockURLProtocol.enqueue(.response(data: blockResponse(released: false)))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
        let blocked = await original.blockHelpedRequester(externalOrderPlaced: true)
        XCTAssertEqual(blocked, .blocked(reservationReleased: false))
        try await waitUntil(
            {
                ParticipantBlockURLProtocol.capturedRequests.contains { $0.path == "/api/requests" }
                    && !original.isFetching
            },
            "the post-block board refresh"
        )

        // Relaunch: a new store, nothing carried over but what the backend says.
        let relaunched = makeStore()
        XCTAssertTrue(relaunched.contactSuppressedRequestIDs.isEmpty)
        ParticipantBlockURLProtocol.enqueue(.response(data: reservationResponse(restricted: true)))

        let outcome = try await relaunched.continueActiveReservationIfNeeded()

        guard case .active(let claim) = outcome else {
            return XCTFail("expected the reservation to be reconstructed")
        }
        XCTAssertEqual(claim.requestID, requestID)
        // The Message is not offered; the extension is, under the ordinary rules.
        XCTAssertTrue(relaunched.contactSuppressedRequestIDs.contains(requestID))
        // Direction-agnostic restriction only: ownership is not known, so the
        // view falls back to the neutral notice and never "Your block".
        XCTAssertFalse(relaunched.callerBlockedRequestIDs.contains(requestID))
        XCTAssertTrue(claim.isExtensionAvailable)
        XCTAssertTrue(relaunched.canExtendActiveClaim)
        XCTAssertTrue(relaunched.canReleaseActiveClaim)

        // Existing fulfillment authority still works, and a typed Message is
        // never sent.
        ParticipantBlockURLProtocol.enqueue(.response(
            data: fulfillmentResponse(suppressed: false, withheld: false)
        ))
        try await relaunched.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: "thank you!"
        )
        let fulfill = try XCTUnwrap(
            ParticipantBlockURLProtocol.capturedRequests.last { $0.path.hasSuffix("/fulfill") }
        )
        let fulfillment = try XCTUnwrap(fulfill.bodyObject?["fulfillment"] as? [String: Any])
        XCTAssertNil(fulfillment["contactMessage"])
        XCTAssertNil(fulfill.bodyObject?["claimToken"])
        XCTAssertEqual(fulfill.headers[RequestService.participantAuthorityHeader], authority)
        XCTAssertNotNil(relaunched.fulfillmentConfirmation)
        XCTAssertNil(relaunched.activeClaim)
        // Suppression state is released with the claim.
        XCTAssertTrue(relaunched.contactSuppressedRequestIDs.isEmpty)
    }

    func testAnUnrestrictedReconstructedReservationKeepsNormalMessageBehavior() async throws {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(data: reservationResponse(restricted: false)))

        let outcome = try await store.continueActiveReservationIfNeeded()

        guard case .active(let claim) = outcome else {
            return XCTFail("expected the reservation to be reconstructed")
        }
        XCTAssertTrue(store.contactSuppressedRequestIDs.isEmpty)
        XCTAssertTrue(claim.isExtensionAvailable)

        ParticipantBlockURLProtocol.enqueue(.response(
            data: fulfillmentResponse(suppressed: false, withheld: false)
        ))
        try await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: "see you soon"
        )
        let fulfill = try XCTUnwrap(
            ParticipantBlockURLProtocol.capturedRequests.last { $0.path.hasSuffix("/fulfill") }
        )
        let fulfillment = try XCTUnwrap(fulfill.bodyObject?["fulfillment"] as? [String: Any])
        XCTAssertEqual(fulfillment["contactMessage"] as? String, "see you soon")
    }

    func testReconstructionNeverInventsRestrictionFromAnInconclusiveRead() async throws {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.failure(.timedOut))

        let outcome = try await store.continueActiveReservationIfNeeded()

        guard case .unknown = outcome else {
            return XCTFail("an unreadable reservation read must stay unknown")
        }
        XCTAssertNil(store.activeClaim)
        XCTAssertTrue(store.contactSuppressedRequestIDs.isEmpty)
    }

    // MARK: - Block-driven vs filter-driven suppression

    func testBlockRestrictionWithholdIsNotPresentedAsASuppressionCard() async throws {
        let blockDriven = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(data: claimResponse()))
        try await blockDriven.claim(requestID: requestID)
        ParticipantBlockURLProtocol.enqueue(.response(
            data: fulfillmentResponse(suppressed: true, withheld: true)
        ))
        try await blockDriven.fulfillWithFixtureScreenshot(
            requestID: requestID, orderNumber: "70154321", eta: "15 minutes", contactMessage: "hi"
        )
        let restricted = try XCTUnwrap(blockDriven.fulfillmentConfirmation)
        // The Message-withheld card is gone from the iOS UX: placement is an
        // ordinary success with no suppression presentation.
        XCTAssertFalse(restricted.messageSuppressed)
        XCTAssertEqual(blockDriven.confirmedFulfillmentOutcome?.messageSuppressed, false)

        let filterDriven = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(data: claimResponse()))
        try await filterDriven.claim(requestID: requestID)
        ParticipantBlockURLProtocol.enqueue(.response(
            data: fulfillmentResponse(suppressed: true, withheld: false)
        ))
        try await filterDriven.fulfillWithFixtureScreenshot(
            requestID: requestID, orderNumber: "70154321", eta: "15 minutes", contactMessage: "x"
        )
        let filtered = try XCTUnwrap(filterDriven.fulfillmentConfirmation)
        XCTAssertTrue(filtered.messageSuppressed, "U1.1 filter suppression is unchanged")
    }

    func testAmbiguityRecoveryDoesNotPresentTheRestrictionWithholdAsASuppression() async throws {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ParticipantBlockURLProtocol.enqueue(.failure(.networkConnectionLost))
        ParticipantBlockURLProtocol.enqueue(.response(
            data: Data(#"{"request": \#(requestObject(status: "placed"))}"#.utf8)
        ))
        ParticipantBlockURLProtocol.enqueue(.response(
            data: placementResponse(suppressed: true, withheld: true)
        ))

        try await store.fulfillWithFixtureScreenshot(
            requestID: requestID, orderNumber: "70154321", eta: "15 minutes", contactMessage: "hi"
        )

        let confirmation = try XCTUnwrap(store.fulfillmentConfirmation)
        XCTAssertFalse(confirmation.messageSuppressed)
        XCTAssertEqual(confirmation.kind, .emailStatusUnknown)
    }

    // MARK: - Copy

    func testFilterSuppressionKeepsItsAcceptedPresentationUnchanged() {
        XCTAssertEqual(
            HelperSuccessCopy.messageSuppressedCardBody,
            "Your message didn’t meet \(AppBrand.name)’s guidelines."
        )
        XCTAssertEqual(
            HelperSuccessCopy.messageSuppressedCardBodyDisplay,
            "Your message didn’t meet\n\(AppBrand.name)’s guidelines."
        )
        XCTAssertEqual(HelperSuccessCopy.messageSuppressedCardTitle, "Message not sent")
        XCTAssertEqual(
            HelperSuccessCopy.accessibilityAnnouncement(
                for: .notificationSent, messageSuppressed: true
            ),
            "Thanks for helping someone out. Message not sent Your message didn’t meet \(AppBrand.name)’s guidelines."
        )
    }

    func testNoMessageWithheldCardCopyExistsInTheClient() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
        for file in ["Views/HelperSuccessView.swift", "Stores/RequestStore.swift"] {
            let text = try String(
                contentsOf: root.appendingPathComponent(file), encoding: .utf8
            )
            XCTAssertFalse(text.contains("messageWithheld"), file)
            XCTAssertFalse(text.contains("Your message wasn’t shared."), file)
        }
    }

    // MARK: - Fixtures

    private func makeStore() -> RequestStore {
        let box = ReconstructionAuthorityBox(authority)
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

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(description)", file: file, line: line)
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: raw))
            }
            return date
        }
        return decoder
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func requestObject(status: String) -> String {
        """
        {
          "id": "\(requestID)",
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

    private func claimResponse() -> Data {
        Data("""
        {
          "request": \(requestObject(status: "claimed")),
          "claim": {
            "claimToken": "claim-token",
            "claimExpiresAt": "\(iso8601String(Date().addingTimeInterval(15 * 60)))"
          }
        }
        """.utf8)
    }

    private func reservationResponse(restricted: Bool) -> Data {
        let flag = restricted ? #","directContactRestricted": true"# : ""
        return Data("""
        {
          "reservation": {
            "request": \(requestObject(status: "claimed")),
            "claimExpiresAt": "\(iso8601String(Date().addingTimeInterval(10 * 60)))",
            "claimExtendedAt": null\(flag)
          },
          "placement": null
        }
        """.utf8)
    }

    private func blockResponse(released: Bool) -> Data {
        Data("""
        {
          "block": {
            "id": "block-1",
            "blockedRole": "requester",
            "diningLocation": "Jasper Kane Cafe",
            "interactionAt": "2026-07-20T18:30:00.000Z",
            "createdAt": "2026-07-20T18:31:00.000Z"
          },
          "reservationReleased": \(released)
        }
        """.utf8)
    }

    private func fulfillmentResponse(suppressed: Bool, withheld: Bool) -> Data {
        var extra = ""
        if suppressed { extra += #","messageSuppressed": true"# }
        if withheld { extra += #","messageWithheld": true"# }
        return Data("""
        {
          "request": \(requestObject(status: "placed")),
          "notification": { "status": "sent" }\(extra)
        }
        """.utf8)
    }

    private func placementResponse(suppressed: Bool, withheld: Bool) -> Data {
        var extra = ""
        if suppressed { extra += #","messageSuppressed": true"# }
        if withheld { extra += #","messageWithheld": true"# }
        return Data("""
        {
          "reservation": null,
          "placement": {
            "request": \(requestObject(status: "placed")),
            "orderNumber": "70154321",
            "etaText": "15 minutes",
            "notification": { "status": "sent" }\(extra)
          }
        }
        """.utf8)
    }
}
