//
//  ReservationReleaseTests.swift
//  CommonPlateiosTests
//
// Focused coverage for W3-H1 explicit release:
// `RequestStore.releaseActiveClaim()` — `POST /api/request/:id/claim/release`
// via the raw token when it is still available, or verified participant
// authority when continuation restored the claim without one. Backend-
// confirmed before any local state clears, and safe to simply retry on
// failure since release is idempotent-refused rather than duplicated.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class ReservationReleaseTests: XCTestCase {
    private let requestID = "release-target"
    private let authorityA = canonicalParticipantAuthorityFixture
    private let authorityB = replacementParticipantAuthorityFixture

    override func tearDown() {
        ClaimFlowURLProtocol.reset()
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    func testReleasingAConfirmedClaimClearsLocalStateAndRefreshesRequests() async throws {
        let store = try await makeStoreWithActiveClaim()
        XCTAssertTrue(store.canReleaseActiveClaim)
        ClaimFlowURLProtocol.enqueue(.response(data: releaseResponse()))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

        await store.releaseActiveClaim()

        XCTAssertNil(store.activeClaim)
        XCTAssertFalse(store.canReleaseActiveClaim)
        XCTAssertFalse(store.isReleasingClaim)
        XCTAssertNil(store.releaseClaimError)
        await waitForReleaseRefreshToFinish(store)
    }

    func testReleaseSendsTheHeldRawClaimToken() async throws {
        let store = try await makeStoreWithActiveClaim(claimToken: "the-raw-token")
        ClaimFlowURLProtocol.enqueue(.response(data: releaseResponse()))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

        await store.releaseActiveClaim()

        await waitForReleaseRefreshToFinish(store)

        let request = try XCTUnwrap(ClaimFlowURLProtocol.capturedRequests.first {
            $0.path == "/api/request/\(requestID)/claim/release"
        })
        XCTAssertEqual(request.bodyObject?["claimToken"] as? String, "the-raw-token")
    }

    /// A failed or unconfirmed release must never clear the reservation the
    /// backend still holds.
    func testAFailedReleaseLeavesTheClaimHeld() async throws {
        let store = try await makeStoreWithActiveClaim()
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorResponse(code: "CLAIM_EXPIRED", message: "This claim has expired.")
        ))

        await store.releaseActiveClaim()

        XCTAssertNotNil(store.activeClaim, "backend truth was not confirmed; nothing local may change")
        XCTAssertFalse(store.isReleasingClaim)
        XCTAssertNotNil(store.releaseClaimError)
        XCTAssertTrue(store.canReleaseActiveClaim)
    }

    /// Release is always safe to retry: a repeat attempt after a failure
    /// must not be blocked by any leftover in-flight state.
    func testReleaseCanBeRetriedAfterAFailure() async throws {
        let store = try await makeStoreWithActiveClaim()
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        await store.releaseActiveClaim()
        XCTAssertNotNil(store.activeClaim)
        XCTAssertTrue(store.canReleaseActiveClaim)

        ClaimFlowURLProtocol.enqueue(.response(data: releaseResponse()))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        await store.releaseActiveClaim()

        XCTAssertNil(store.activeClaim)
        await waitForReleaseRefreshToFinish(store)
    }

    func testHTTPReleaseResponseMustExplicitlyConfirmReleasedTrue() async throws {
        let store = try await makeStoreWithActiveClaim()
        ClaimFlowURLProtocol.enqueue(.response(data: Data(#"{"released":false}"#.utf8)))

        await store.releaseActiveClaim()

        XCTAssertEqual(store.activeClaim?.requestID, requestID)
        XCTAssertNotNil(store.releaseClaimError)
        XCTAssertFalse(store.isReleasingClaim)
        XCTAssertTrue(store.canExtendActiveClaim)
        XCTAssertTrue(store.canSubmitFulfillment(requestID: requestID))

        ClaimFlowURLProtocol.enqueue(.response(data: releaseResponse()))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        await store.releaseActiveClaim()

        XCTAssertNil(store.activeClaim)
        await waitForReleaseRefreshToFinish(store)
    }

    func testDuplicateConcurrentReleaseCallsSendOnlyOneRequest() async throws {
        let store = try await makeStoreWithActiveClaim()
        let gate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: releaseResponse(), gate: gate))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

        async let first: Void = store.releaseActiveClaim()
        await waitUntil { store.isReleasingClaim }
        XCTAssertFalse(store.canReleaseActiveClaim)
        async let second: Void = store.releaseActiveClaim()
        gate.open()
        _ = await (first, second)

        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedRequests.filter { $0.path.hasSuffix("/claim/release") }.count,
            1
        )
        await waitForReleaseRefreshToFinish(store)
    }

    /// W3-H1 continuation: no raw token is available, so release authorizes
    /// with the verified participant credential instead — an empty JSON
    /// object body plus the credential header.
    func testContinuationReleaseAuthorizesWithParticipantAuthorityInsteadOfAToken() async throws {
        let store = try await makeStoreRestoredByContinuation()
        ClaimFlowURLProtocol.enqueue(.response(data: releaseResponse()))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

        await store.releaseActiveClaim()

        await waitForReleaseRefreshToFinish(store)

        let request = try XCTUnwrap(ClaimFlowURLProtocol.capturedRequests.first {
            $0.path == "/api/request/\(requestID)/claim/release"
        })
        XCTAssertEqual(request.bodyObject?.count, 0, "an empty JSON object, carrying no token")
        XCTAssertNil(store.activeClaim)
    }

    func testRestoredReservationKeepsAuthorityAForExtensionAndReleaseAfterIdentityChangesToB() async throws {
        var currentAuthority = authorityA
        let store = makeStore(participantAuthorityProvider: { currentAuthority })
        ClaimFlowURLProtocol.enqueue(.response(data: activeReservationResponse()))
        _ = try await store.continueActiveReservationIfNeeded()

        currentAuthority = authorityB
        ClaimFlowURLProtocol.enqueue(.response(data: extensionResponse()))
        await store.extendActiveClaim()

        ClaimFlowURLProtocol.enqueue(.response(data: releaseResponse()))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))
        await store.releaseActiveClaim()
        await waitForReleaseRefreshToFinish(store)

        let extensionRequest = try XCTUnwrap(ClaimFlowURLProtocol.capturedRequests.first {
            $0.path == "/api/request/\(requestID)/claim/extend"
        })
        let release = try XCTUnwrap(ClaimFlowURLProtocol.capturedRequests.first {
            $0.path == "/api/request/\(requestID)/claim/release"
        })
        XCTAssertEqual(extensionRequest.headers[RequestService.participantAuthorityHeader], authorityA)
        XCTAssertEqual(release.headers[RequestService.participantAuthorityHeader], authorityA)
        XCTAssertNil(store.activeClaim)

        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "future-token")))
        try await store.claim(requestID: requestID)
        let futureClaim = try XCTUnwrap(ClaimFlowURLProtocol.capturedRequests.last {
            $0.path == "/api/request/\(requestID)/claim"
        })
        XCTAssertEqual(
            futureClaim.headers[RequestService.participantAuthorityHeader],
            authorityB,
            "the current identity still owns future participant actions"
        )
    }

    func testReleaseInFlightBlocksEveryCompetingReservationMutationAndFailureRestoresActions() async throws {
        let store = try await makeStoreWithActiveClaim()
        let gate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 503,
            data: errorResponse(code: "INTERNAL_FAILURE", message: "Release unavailable"),
            gate: gate
        ))

        let release = Task { await store.releaseActiveClaim() }
        await waitUntil { store.isReleasingClaim }

        XCTAssertFalse(store.canReleaseActiveClaim)
        XCTAssertFalse(store.canExtendActiveClaim)
        XCTAssertFalse(store.canSubmitFulfillment(requestID: requestID))
        let mutationCountBeforeBlockedActions = ClaimFlowURLProtocol.capturedRequests.count

        await store.extendActiveClaim()
        do {
            try await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
            XCTFail("fulfillment must not start while release is in flight")
        } catch RequestServiceError.operationInProgress {
            // Expected.
        }
        do {
            try await store.resubmitAmbiguousFulfillment(
                ambiguityID: UUID(),
                requestID: requestID
            )
            XCTFail("ambiguity recovery must not start while release is in flight")
        } catch RequestServiceError.operationInProgress {
            // Expected before any ambiguity lookup or network work.
        }
        XCTAssertEqual(ClaimFlowURLProtocol.capturedRequests.count, mutationCountBeforeBlockedActions)

        gate.open()
        await release.value

        XCTAssertEqual(store.activeClaim?.requestID, requestID)
        XCTAssertTrue(store.canReleaseActiveClaim)
        XCTAssertTrue(store.canExtendActiveClaim)
        XCTAssertTrue(store.canSubmitFulfillment(requestID: requestID))

        ClaimFlowURLProtocol.enqueue(.response(data: extensionResponse()))
        await store.extendActiveClaim()
        XCTAssertNotNil(store.activeClaim?.claimExtendedAt)
        XCTAssertTrue(store.canSubmitFulfillment(requestID: requestID))
    }

    func testExtensionInFlightDisablesReleaseAndTheMethodSendsNothing() async throws {
        let store = try await makeStoreWithActiveClaim()
        let extensionGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: extensionResponse(), gate: extensionGate))

        let extensionOperation = Task { await store.extendActiveClaim() }
        await waitUntil { store.isExtendingClaim }
        XCTAssertFalse(store.canReleaseActiveClaim)
        let releaseCount = releaseRequestCount

        await store.releaseActiveClaim()

        XCTAssertEqual(releaseRequestCount, releaseCount)
        extensionGate.open()
        await extensionOperation.value
        XCTAssertTrue(store.canReleaseActiveClaim)
    }

    func testFulfillmentInFlightDisablesReleaseAndTheMethodSendsNothing() async throws {
        let store = try await makeStoreWithActiveClaim()
        let fulfillmentGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            data: fulfillmentResponse(),
            gate: fulfillmentGate
        ))

        let fulfillment = Task {
            try await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
        }
        await waitUntil { store.isFulfilling }
        XCTAssertFalse(store.canReleaseActiveClaim)
        let releaseCount = releaseRequestCount

        await store.releaseActiveClaim()

        XCTAssertEqual(releaseRequestCount, releaseCount)
        fulfillmentGate.open()
        try await fulfillment.value
        XCTAssertFalse(store.canReleaseActiveClaim)
        XCTAssertNil(store.activeClaim)
    }

    func testFulfillmentAmbiguityDisablesReleaseAndTheMethodSendsNothing() async throws {
        let store = try await makeStoreWithActiveClaim()
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "claimed")))

        do {
            try await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
            XCTFail("the ambiguous submission must not become confirmed fulfillment")
        } catch RequestServiceError.ambiguousFulfillmentOutcome {
            // Expected after the one read-only status check remains claimed.
        }
        XCTAssertNotNil(store.fulfillmentAmbiguity)
        XCTAssertFalse(store.canReleaseActiveClaim)
        let releaseCount = releaseRequestCount

        await store.releaseActiveClaim()

        XCTAssertEqual(releaseRequestCount, releaseCount)
        XCTAssertNotNil(store.activeClaim)
        XCTAssertNotNil(store.fulfillmentAmbiguity)
    }

    func testExpiredReservationDisablesReleaseAndTheMethodSendsNothing() async throws {
        let store = try await makeStoreWithActiveClaim(
            claimExpiresAt: Date().addingTimeInterval(-1)
        )
        XCTAssertFalse(store.canReleaseActiveClaim)
        let releaseCount = releaseRequestCount

        await store.releaseActiveClaim()

        XCTAssertEqual(releaseRequestCount, releaseCount)
    }

    func testReleaseButtonUsesTheSameStorePredicateAsTheReleaseMethod() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/FulfillRequestView.swift"
            ),
            encoding: .utf8
        )
        // W4-H1: `× Stop helping` on the Helping page is the release control.
        let sectionStart = try XCTUnwrap(
            source.range(of: "private var stopHelpingControl")
        )
        let sectionEnd = try XCTUnwrap(
            source.range(
                of: "static func extensionControlState",
                range: sectionStart.upperBound..<source.endIndex
            )
        )
        let releaseSection = String(source[sectionStart.lowerBound..<sectionEnd.lowerBound])

        XCTAssertTrue(releaseSection.contains(".disabled(!store.canReleaseActiveClaim)"))
        XCTAssertFalse(
            releaseSection.contains(".disabled(store.isExtendingClaim || store.isReleasingClaim)")
        )
    }

    func testRejectedReservationAuthorityRetiresCurrentIdentityButNotANewerReplacement() async throws {
        let storage = InMemoryParticipantIdentityStorage(stored: identityRecord(
            principal: "owner@nyu.edu",
            authority: authorityA
        ))
        let identityStore = makeIdentityStore(storage: storage)
        let store = makeStore(
            participantAuthorityProvider: { identityStore.currentAuthority() },
            participantAuthorityRejected: { identityStore.discardRejectedIdentity() }
        )
        ClaimFlowURLProtocol.enqueue(.response(data: activeReservationResponse()))
        _ = try await store.continueActiveReservationIfNeeded()
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 401,
            data: errorResponse(
                code: ParticipantErrorCode.authorityInvalid,
                message: "Credential rejected"
            )
        ))

        await store.releaseActiveClaim()

        XCTAssertNil(identityStore.currentAuthority())
        XCTAssertTrue(identityStore.wasIdentityRevoked)
        XCTAssertNil(storage.stored)
        XCTAssertEqual(store.activeClaim?.requestID, requestID)

        let replacementStorage = InMemoryParticipantIdentityStorage(stored: identityRecord(
            principal: "owner@nyu.edu",
            authority: authorityA
        ))
        let replacementIdentityStore = makeIdentityStore(storage: replacementStorage)
        let replacementStore = makeStore(
            participantAuthorityProvider: { replacementIdentityStore.currentAuthority() },
            participantAuthorityRejected: { replacementIdentityStore.discardRejectedIdentity() }
        )
        ClaimFlowURLProtocol.enqueue(.response(data: activeReservationResponse()))
        _ = try await replacementStore.continueActiveReservationIfNeeded()
        await replaceIdentityWithB(replacementIdentityStore)
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 401,
            data: errorResponse(
                code: ParticipantErrorCode.authorityInvalid,
                message: "Old credential rejected"
            )
        ))

        await replacementStore.releaseActiveClaim()

        XCTAssertEqual(replacementIdentityStore.currentAuthority(), authorityB)
        XCTAssertEqual(replacementStorage.stored?.authority, authorityB)
        XCTAssertFalse(replacementIdentityStore.wasIdentityRevoked)
        XCTAssertEqual(replacementStore.activeClaim?.requestID, requestID)
    }

    func testRejectedContinuationExtensionRetiresTheMatchingCurrentCredential() async throws {
        var currentAuthority: String? = authorityA
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
            data: errorResponse(
                code: ParticipantErrorCode.authorityInvalid,
                message: "Credential rejected"
            )
        ))

        await store.extendActiveClaim()

        XCTAssertEqual(rejectionCount, 1)
        XCTAssertNil(currentAuthority)
        XCTAssertEqual(store.activeClaim?.requestID, requestID)
        XCTAssertNotNil(store.claimExtensionError)
    }

    func testReleasingWithNoActiveClaimIsANoOp() async {
        let store = makeStore()
        XCTAssertFalse(store.canReleaseActiveClaim)

        await store.releaseActiveClaim()

        XCTAssertFalse(store.isReleasingClaim)
        XCTAssertNil(store.releaseClaimError)
        XCTAssertTrue(ClaimFlowURLProtocol.capturedRequests.isEmpty)
    }

    // MARK: - Helpers

    private func makeStore(
        participantAuthorityProvider: (() -> String?)? = nil,
        participantAuthorityRejected: @escaping () -> Void = {}
    ) -> RequestStore {
        let authorityProvider = participantAuthorityProvider ?? {
            "64c0000000000000000000a1.1.credential"
        }
        return RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: authorityProvider,
            participantAuthorityRejected: participantAuthorityRejected
        )
    }

    private func makeIdentityStore(
        storage: ParticipantIdentityStorage
    ) -> ParticipantIdentityStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
        let store = ParticipantIdentityStore(
            service: ParticipantVerificationService(client: client),
            storage: storage
        )
        store.configureInstallationAssociation { _ in }
        return store
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

    private func makeStoreWithActiveClaim(
        claimToken: String = "claim-token",
        claimExpiresAt: Date = Date().addingTimeInterval(15 * 60)
    ) async throws -> RequestStore {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(
            claimToken: claimToken,
            claimExpiresAt: claimExpiresAt
        )))
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

    private func listResponse(_ requestObjects: [String]) -> Data {
        Data(#"{"requests":[\#(requestObjects.joined(separator: ","))]}"#.utf8)
    }

    private func errorResponse(code: String, message: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"\#(message)","fields":null}}"#.utf8)
    }

    private func releaseResponse() -> Data {
        Data(#"{"released":true}"#.utf8)
    }

    private func detailResponse(status: String) -> Data {
        Data(#"{"request":\#(requestObject(status: status))}"#.utf8)
    }

    private func fulfillmentResponse() -> Data {
        Data(#"{"request":\#(requestObject(status: "placed")),"notification":{"status":"sent"}}"#.utf8)
    }

    private func extensionResponse() -> Data {
        Data("""
        {
          "claim": {
            "claimExpiresAt": "\(iso8601String(Date().addingTimeInterval(20 * 60)))",
            "claimExtendedAt": "\(iso8601String(Date()))"
          }
        }
        """.utf8)
    }

    private func identityRecord(
        principal: String,
        authority: String
    ) -> ParticipantIdentityRecord {
        ParticipantIdentityRecord(
            principal: principal,
            authority: authority,
            verifiedAt: Date()
        )
    }

    private func replaceIdentityWithB(_ store: ParticipantIdentityStore) async {
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: Data("""
        {
          "verification": {
            "expiresAt": "2026-08-09T19:00:00.000Z",
            "resendAvailableAt": "2026-08-09T18:51:00.000Z"
          }
        }
        """.utf8)))
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: Data(
            #"{"participant":{"email":"replacement@stern.nyu.edu"},"authority":"\#(authorityB)"}"#.utf8
        )))
        store.beginEmailReplacement()
        await store.requestCode(for: "replacement@stern.nyu.edu")
        let verified = await store.submitCode("424242")
        XCTAssertTrue(verified)
    }

    private func requestObject(status: String = "open") -> String {
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
        pickupName: String = "Taylor",
        claimToken: String = "claim-token",
        claimExpiresAt: Date = Date().addingTimeInterval(15 * 60)
    ) -> Data {
        Data("""
        {
          "request": \(requestObject(status: "claimed")),
          "claim": {
            "pickupName": "\(pickupName)",
            "claimToken": "\(claimToken)",
            "claimExpiresAt": "\(iso8601String(claimExpiresAt))"
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

    /// Successful release starts a detached request-list refresh. Waiting for
    /// the path alone is insufficient: teardown could reset the shared
    /// URLProtocol queue while that response was still being consumed.
    private func waitForReleaseRefreshToFinish(_ store: RequestStore) async {
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }
    }

    private var releaseRequestCount: Int {
        ClaimFlowURLProtocol.capturedRequests.filter { $0.path.hasSuffix("/claim/release") }.count
    }

    private func repositoryFile(_ relativePath: String) throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CommonPlateiosTests
            .deletingLastPathComponent() // CommonPlateios
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repository root
        let url = root.appendingPathComponent(relativePath)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "expected \(relativePath) at \(url.path)"
        )
        return url
    }
}
