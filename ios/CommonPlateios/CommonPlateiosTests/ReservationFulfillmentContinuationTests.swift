//
//  ReservationFulfillmentContinuationTests.swift
//  CommonPlateiosTests
//
// Focused coverage for W3-H1 MUST FIX 1: fulfillment authorization after
// active-reservation continuation. `RequestStore.fulfill()` and
// `.canSubmitFulfillment()` must accept a claim restored by
// `continueActiveReservationIfNeeded()` — which never has the raw claim
// token, since it was never persisted — using verified participant authority
// instead, exactly the additive path `extendActiveClaim()`/
// `releaseActiveClaim()` already accept. The still-in-process raw-token path
// is proved unchanged alongside it.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class ReservationFulfillmentContinuationTests: XCTestCase {
    private let requestID = "fulfillment-continuation-target"
    private let participantAuthority = "64c0000000000000000000a1.1.credential"

    override func tearDown() {
        ClaimFlowURLProtocol.reset()
        super.tearDown()
    }

    func testFulfillsAConfirmedClaimUsingTheRawTokenUnchanged() async throws {
        let store = try await makeStoreWithActiveClaim(claimToken: "the-raw-token")
        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse()))

        try await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )

        let request = try XCTUnwrap(ClaimFlowURLProtocol.capturedRequests.first {
            $0.path == "/api/request/\(requestID)/fulfill"
        })
        XCTAssertEqual(request.bodyObject?["claimToken"] as? String, "the-raw-token")
        XCTAssertNotNil(store.fulfillmentConfirmation)
    }

    /// The MUST FIX 1 correction: a claim restored by continuation carries no
    /// raw token at all, so the fulfillment POST must authorize with the
    /// verified participant credential and an empty-token body instead —
    /// never blocked outright, and never fabricating or persisting a token
    /// that does not exist.
    func testFulfillsAContinuationRestoredClaimUsingParticipantAuthorityInsteadOfAToken() async throws {
        var currentAuthority = participantAuthority
        let store = makeStore(participantAuthorityProvider: { currentAuthority })
        ClaimFlowURLProtocol.enqueue(.response(data: activeReservationResponse()))
        _ = try await store.continueActiveReservationIfNeeded()
        currentAuthority = replacementParticipantAuthorityFixture
        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse()))

        try await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )

        let request = try XCTUnwrap(ClaimFlowURLProtocol.capturedRequests.first {
            $0.path == "/api/request/\(requestID)/fulfill"
        })
        XCTAssertNil(request.bodyObject?["claimToken"], "no raw token exists to send")
        XCTAssertEqual(request.headers[RequestService.participantAuthorityHeader], participantAuthority)
        XCTAssertNotNil(store.fulfillmentConfirmation)
    }

    func testAmbiguousContinuationFulfillmentResendsExactPayloadWithOriginalAuthorityAfterIdentityReplacement() async throws {
        var currentAuthority = participantAuthority
        let store = makeStore(participantAuthorityProvider: { currentAuthority })
        ClaimFlowURLProtocol.enqueue(.response(data: activeReservationResponse()))
        _ = try await store.continueActiveReservationIfNeeded()
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "claimed")))

        do {
            try await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "00070154321",
                eta: "30 minutes",
                contactMessage: "Meet by the pickup shelf"
            )
            XCTFail("the first write must remain ambiguous")
        } catch RequestServiceError.ambiguousFulfillmentOutcome {
            // Expected after the one inconclusive read.
        }
        let ambiguity = try XCTUnwrap(store.fulfillmentAmbiguity)
        let original = try XCTUnwrap(ClaimFlowURLProtocol.capturedRequests.first {
            $0.path == "/api/request/\(requestID)/fulfill"
        })

        currentAuthority = replacementParticipantAuthorityFixture
        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse()))
        try await store.resubmitAmbiguousFulfillment(
            ambiguityID: ambiguity.id,
            requestID: requestID
        )

        let posts = ClaimFlowURLProtocol.capturedRequests.filter {
            $0.path == "/api/request/\(requestID)/fulfill"
        }
        XCTAssertEqual(posts.count, 2)
        let recovery = try XCTUnwrap(posts.last)
        XCTAssertEqual(original.headers[RequestService.participantAuthorityHeader], participantAuthority)
        XCTAssertEqual(recovery.headers[RequestService.participantAuthorityHeader], participantAuthority)
        XCTAssertEqual(
            try canonicalJSON(original.bodyObject),
            try canonicalJSON(recovery.bodyObject)
        )
        XCTAssertNil(recovery.bodyObject?["claimToken"])
        XCTAssertNil(store.activeClaim)
        XCTAssertNotNil(store.fulfillmentConfirmation)
    }

    func testParticipantFulfillmentRejectionRetiresOnlyTheMatchingCurrentCredential() async throws {
        var currentAuthority: String? = participantAuthority
        var rejectionCount = 0
        let store = makeStore(
            participantAuthorityProvider: { currentAuthority },
            participantAuthorityRejected: {
                rejectionCount += 1
                currentAuthority = nil
            }
        )
        ClaimFlowURLProtocol.enqueue(.response(data: activeReservationResponse()))
        _ = try await store.continueActiveReservationIfNeeded()
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 401,
            data: authorityInvalidResponse()
        ))

        try? await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )

        XCTAssertEqual(rejectionCount, 1)
        XCTAssertNil(currentAuthority)
        XCTAssertEqual(store.activeClaim?.requestID, requestID)

        var replacementCurrent: String? = participantAuthority
        var staleRejectionCount = 0
        let replacementStore = makeStore(
            participantAuthorityProvider: { replacementCurrent },
            participantAuthorityRejected: {
                staleRejectionCount += 1
                replacementCurrent = nil
            }
        )
        ClaimFlowURLProtocol.enqueue(.response(data: activeReservationResponse()))
        _ = try await replacementStore.continueActiveReservationIfNeeded()
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "claimed")))
        try? await replacementStore.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )
        let ambiguity = try XCTUnwrap(replacementStore.fulfillmentAmbiguity)
        replacementCurrent = replacementParticipantAuthorityFixture
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 401,
            data: authorityInvalidResponse()
        ))

        try? await replacementStore.resubmitAmbiguousFulfillment(
            ambiguityID: ambiguity.id,
            requestID: requestID
        )

        XCTAssertEqual(staleRejectionCount, 0)
        XCTAssertEqual(replacementCurrent, replacementParticipantAuthorityFixture)
        XCTAssertEqual(replacementStore.activeClaim?.requestID, requestID)
        XCTAssertEqual(replacementStore.fulfillmentAmbiguity?.isRecoveryAvailable, false)
    }

    func testCanSubmitFulfillmentIsTrueAfterContinuationRestoresAClaimWithNoToken() async throws {
        let store = try await makeStoreRestoredByContinuation()

        XCTAssertTrue(store.canSubmitFulfillment(requestID: requestID))
    }

    /// A backend refusal on the continuation path (e.g. the reservation was
    /// released or expired by the time the POST landed) must be reported
    /// exactly like an ordinary fulfillment failure — never silently treated
    /// as success, and never treated as though a raw token were missing when
    /// participant authority was the credential actually submitted.
    func testAConflictingBackendRefusalOnTheContinuationPathIsReportedNormally() async throws {
        let store = try await makeStoreRestoredByContinuation()
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 409,
            data: Data(#"{"error":{"code":"REQUEST_NOT_CLAIMED","message":"This request does not have an active claim.","fields":null}}"#.utf8)
        ))

        do {
            try await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
            XCTFail("expected the backend refusal to propagate")
        } catch {
            // Expected: the backend truthfully refused, and continuation did
            // not fabricate a placement.
        }
        XCTAssertNil(store.fulfillmentConfirmation)
    }

    // MARK: - Helpers

    private func makeStore(
        participantAuthorityProvider: (() -> String?)? = nil,
        participantAuthorityRejected: @escaping () -> Void = {}
    ) -> RequestStore {
        let authorityProvider = participantAuthorityProvider ?? { self.participantAuthority }
        return RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: authorityProvider,
            participantAuthorityRejected: participantAuthorityRejected
        )
    }

    private func makeService() -> RequestService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaimFlowURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return RequestService(client: client)
    }

    private func makeStoreWithActiveClaim(claimToken: String = "claim-token") async throws -> RequestStore {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: claimToken)))
        try await store.claim(requestID: requestID)
        return store
    }

    private func makeStoreRestoredByContinuation() async throws -> RequestStore {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: activeReservationResponse()))
        _ = try await store.continueActiveReservationIfNeeded()
        XCTAssertNotNil(store.activeClaim, "precondition: continuation must have restored a claim")
        return store
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func requestObject(status: String = "claimed") -> String {
        """
        {
          "id": "\(requestID)",
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
          "expiresAt": "\(iso8601String(Date().addingTimeInterval(5 * 60 * 60)))"
        }
        """
    }

    private func claimResponse(
        claimToken: String = "claim-token"
    ) -> Data {
        Data("""
        {
          "request": \(requestObject(status: "claimed")),
          "claim": {
            "pickupName": "Taylor",
            "claimToken": "\(claimToken)",
            "claimExpiresAt": "\(iso8601String(Date().addingTimeInterval(15 * 60)))"
          }
        }
        """.utf8)
    }

    private func activeReservationResponse() -> Data {
        Data("""
        {
          "reservation": {
            "request": \(requestObject(status: "claimed")),
            "pickupName": "Taylor",
            "claimExpiresAt": "\(iso8601String(Date().addingTimeInterval(15 * 60)))",
            "claimExtendedAt": null
          }
        }
        """.utf8)
    }

    private func fulfillmentResponse() -> Data {
        Data("""
        {
          "request": \(requestObject(status: "placed")),
          "notification": { "status": "sent" }
        }
        """.utf8)
    }

    private func detailResponse(status: String) -> Data {
        Data("""
        { "request": \(requestObject(status: status)) }
        """.utf8)
    }

    private func authorityInvalidResponse() -> Data {
        Data(#"{"error":{"code":"PARTICIPANT_AUTHORITY_INVALID","message":"Credential rejected","fields":null}}"#.utf8)
    }

    private func canonicalJSON(_ object: [String: Any]?) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: XCTUnwrap(object),
            options: [.sortedKeys]
        )
    }
}
