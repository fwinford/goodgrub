import Foundation
import XCTest
@testable import CommonPlateios

/// W3-I1 gates: what the requester and helper paths do about an unverified
/// installation, what they send when it is verified, and what survives the gate.
@MainActor
final class ParticipantGateTests: XCTestCase {
    private let authorityHeader = "x-commonplate-participant"
    private let credential = canonicalParticipantAuthorityFixture

    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - The credential travels with the participant actions

    func testCreateCarriesTheParticipantCredentialAndNoAddress() async throws {
        let store = makeRequestStore(authority: credential)
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 201, data: createdResponse()))

        try await store.createRequest(payload())

        XCTAssertEqual(
            RequestFetchingURLProtocol.lastCapturedHeaders?[authorityHeader],
            credential
        )
        let body = try XCTUnwrap(RequestFetchingURLProtocol.lastCapturedBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        // The requester is the credential, not the payload.
        XCTAssertNil(json["email"])
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("@"))
    }

    func testClaimCarriesTheParticipantCredential() async throws {
        let store = makeRequestStore(authority: credential)
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: claimedResponse()))

        try await store.claim(requestID: "64b000000000000000000001")

        XCTAssertEqual(
            RequestFetchingURLProtocol.lastCapturedHeaders?[authorityHeader],
            credential
        )
    }

    /// An unverified installation sends no header at all rather than an empty
    /// one: "has not verified" and "presented something unusable" are different
    /// backend answers, and only the first is true.
    func testAnUnverifiedInstallationSendsNoCredentialHeader() async throws {
        let store = makeRequestStore(authority: nil)
        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 401, data: errorResponse(code: ParticipantErrorCode.verificationRequired))
        )

        do {
            try await store.createRequest(payload())
            XCTFail("an unverified create must be refused")
        } catch {
            // Expected.
        }

        XCTAssertNil(RequestFetchingURLProtocol.lastCapturedHeaders?[authorityHeader])
    }

    func testFulfillmentSendsNoHelperAddress() async throws {
        let store = makeRequestStore(authority: credential)
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: claimedResponse()))
        try await store.claim(requestID: "64b000000000000000000001")
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: placedResponse()))

        try await store.fulfillWithFixtureScreenshot(
            requestID: "64b000000000000000000001",
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )

        let body = try XCTUnwrap(RequestFetchingURLProtocol.lastCapturedBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let fulfillment = try XCTUnwrap(json["fulfillment"] as? [String: Any])
        // The helper is whoever the claim is bound to. Sending an address would
        // be refused, and it is exactly how the requester's coordination email
        // could otherwise name someone else.
        XCTAssertNil(fulfillment["fulfillerEmail"])
        XCTAssertEqual(Set(fulfillment.keys), ["orderNumber", "eta", "placedOrderScreenshot"])
    }

    // MARK: - Applying the backend's verdict on a stored credential

    func testARefusedCredentialDiscardsTheStoredIdentity() async throws {
        var rejections = 0
        let store = makeRequestStore(authority: credential) { rejections += 1 }
        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 401, data: errorResponse(code: ParticipantErrorCode.authorityInvalid))
        )

        do {
            try await store.createRequest(payload())
            XCTFail("a refused credential must not create a request")
        } catch {
            // Expected.
        }

        XCTAssertEqual(rejections, 1)
        // A definitive refusal, so the process-lifetime create block stays off:
        // nothing was written and re-verifying is the recovery.
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
    }

    /// "You have not verified" is not "your identity was revoked". Treating the
    /// first as the second would let an unrelated call wipe a valid identity.
    func testVerificationRequiredDoesNotDiscardAnything() async throws {
        var rejections = 0
        let store = makeRequestStore(authority: credential) { rejections += 1 }
        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 401, data: errorResponse(code: ParticipantErrorCode.verificationRequired))
        )

        do {
            try await store.createRequest(payload())
            XCTFail("the refusal must propagate")
        } catch {
            // Expected.
        }

        XCTAssertEqual(rejections, 0)
    }

    func testAnUnavailableGateDiscardsNothing() async throws {
        var rejections = 0
        let store = makeRequestStore(authority: credential) { rejections += 1 }
        RequestFetchingURLProtocol.enqueue(
            .response(
                statusCode: 503,
                data: errorResponse(code: ParticipantErrorCode.verificationUnavailable)
            )
        )

        do {
            try await store.createRequest(payload())
            XCTFail("the refusal must propagate")
        } catch {
            // Expected.
        }

        // The backend could not check. That is not a verdict about the
        // credential, so nothing local may be thrown away over it.
        XCTAssertEqual(rejections, 0)
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
    }

    func testARefusedClaimCredentialDiscardsTheStoredIdentityAndReservesNothing() async throws {
        var rejections = 0
        let store = makeRequestStore(authority: credential) { rejections += 1 }
        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 401, data: errorResponse(code: ParticipantErrorCode.authorityInvalid))
        )

        try? await store.claim(requestID: "64b000000000000000000001")

        XCTAssertEqual(rejections, 1)
        XCTAssertNil(store.activeClaim)
    }

    // MARK: - The requester draft survives the gate

    /// The draft is `@State` on a screen that stays mounted behind the
    /// verification sheet, so this proves the property that makes that work:
    /// nothing in the submission path mutates or consumes the draft, on any
    /// outcome. A form that was complete before verification is complete after.
    func testTheCompletedDraftIsUnchangedByEveryRefusedSubmission() async throws {
        let outcomes: [(Int, String)] = [
            (401, ParticipantErrorCode.verificationRequired),
            (401, ParticipantErrorCode.authorityInvalid),
            (503, ParticipantErrorCode.verificationUnavailable),
            (403, ParticipantErrorCode.principalMismatch)
        ]

        for (status, code) in outcomes {
            RequestFetchingURLProtocol.reset()
            let store = makeRequestStore(authority: credential)
            RequestFetchingURLProtocol.enqueue(
                .response(statusCode: status, data: errorResponse(code: code))
            )
            let draft = completedDraft()
            let original = draft

            let result = try? await RequestFoodView.orchestrateSubmission(
                draft: draft,
                now: try date("2026-07-28T16:00:00.000Z"),
                calendar: utcCalendar,
                presentation: RequestFoodValidationPresentation()
            ) { payload in
                try await store.createRequest(payload)
            }

            XCTAssertNil(result, code)
            XCTAssertEqual(draft, original, code)
            XCTAssertEqual(draft.selectedDiningSpot?.name, "Jasper Kane Cafe", code)
            XCTAssertEqual(draft.mealEntries[0], "Chicken bowl", code)
            XCTAssertEqual(draft.menuPath, .mealExchange, code)
            XCTAssertEqual(draft.timing, .later, code)
            XCTAssertEqual(draft.preferredPickupTime, original.preferredPickupTime, code)
            // Nothing was created, so resuming after verification is safe.
            XCTAssertTrue(store.requests.isEmpty, code)
            XCTAssertFalse(store.hasUnresolvedCreateAmbiguity, code)
        }
    }

    /// The same completed draft, submitted again after verification, still
    /// produces the same payload — the resumed submission asks for nothing.
    func testTheSameDraftSubmitsUnchangedOnceVerified() async throws {
        let store = makeRequestStore(authority: credential)
        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 401, data: errorResponse(code: ParticipantErrorCode.verificationRequired))
        )
        let draft = completedDraft()
        let now = try date("2026-07-28T16:00:00.000Z")

        _ = try? await RequestFoodView.orchestrateSubmission(
            draft: draft,
            now: now,
            calendar: utcCalendar,
            presentation: RequestFoodValidationPresentation()
        ) { payload in
            try await store.createRequest(payload)
        }

        RequestFetchingURLProtocol.enqueue(.response(statusCode: 201, data: createdResponse()))
        var submitted: CreateRequestPayload?
        let result = try await RequestFoodView.orchestrateSubmission(
            draft: draft,
            now: now,
            calendar: utcCalendar,
            presentation: RequestFoodValidationPresentation()
        ) { payload in
            submitted = payload
            try await store.createRequest(payload)
        }

        XCTAssertTrue(result.didSubmit)
        XCTAssertEqual(submitted?.vendor, "Jasper Kane Cafe")
        XCTAssertEqual(submitted?.menuPath, .mealExchange)
        XCTAssertEqual(submitted?.mealItems, ["Chicken bowl"])
        XCTAssertEqual(submitted?.windowStart, draft.preferredPickupTime)
    }

    // MARK: - Copy

    func testRequestDetailNoLongerPreannouncesVerificationBesideStartHelping() throws {
        // The requester-side standing notice moved to Home (W3-I3). W4-H1a
        // (Faith D-A2) retires the helper-side note too: Request Detail shows no
        // prerequisite paragraph and no replacement. Verification BEHAVIOR is
        // unchanged and proved by the gate tests in this file and the claim
        // flow tests; only the copy is gone.
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestDetailView.swift")
        XCTAssertFalse(source.contains("verificationRequiredNotice"))
        XCTAssertFalse(source.contains("claim-verification-notice"))
        XCTAssertFalse(source.contains("You’ll verify your NYU email once before helping"))
        XCTAssertFalse(source.contains("Nothing is reserved until it’s verified"))
        // Start helping itself is untouched.
        XCTAssertTrue(source.contains("static let claimActionTitle = \"Start helping\""))
        XCTAssertTrue(source.contains("startClaim()"))
    }

    func testHomeDoesNotPreannounceVerificationBeforeAnActionNeedsIt() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/ContentView.swift")
        XCTAssertFalse(source.contains(
            "You’ll verify an NYU email once before posting or helping with a request."
        ))
    }

    // MARK: - Fixtures

    private func completedDraft() -> RequestFoodFormDraft {
        RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: "140 E 14th St"),
            menuPath: .mealExchange,
            timing: .later,
            preferredPickupTime: try! date("2026-07-28T17:00:00.000Z"),
            mealSwipes: 1,
            mealEntries: ["Chicken bowl", "", "", "", ""]
        )
    }

    private func payload() -> CreateRequestPayload {
        CreateRequestPayload(
            vendor: "Jasper Kane Cafe",
            timing: .asap,
            windowStart: nil,
            menuPath: .mealExchange,
            mealSwipes: 2,
            mealItems: ["Chicken bowl", "Side salad"],
            orderDetails: nil,
            estimatedDiningDollarsCents: nil
        )
    }

    private func makeRequestStore(
        authority: String?,
        onRejection: @escaping () -> Void = {}
    ) -> RequestStore {
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
            participantAuthorityProvider: { authority },
            participantAuthorityRejected: onRejection
        )
    }

    private func createdResponse() -> Data {
        Data(#"""
        {"request":{
          "id": "64b000000000000000000001",
          "vendor": "Jasper Kane Cafe",
          "food": "Chicken bowl",
          "pickupWindowText": "ASAP",
          "mealSwipes": 2,
          "menuPath": "meal-exchange",
          "mealItems": ["Meal 1", "Meal 2"],
          "orderDetails": null,
          "estimatedDiningDollarsCents": null,
          "windowStart": null,
          "windowEnd": null,
          "status": "open",
          "createdAt": "2026-07-28T16:00:00.000Z",
          "expiresAt": "2026-07-28T19:00:00.000Z"
        }}
        """#.utf8)
    }

    private func claimedResponse() -> Data {
        Data(#"""
        {
          "request": {
            "id": "64b000000000000000000001",
            "vendor": "Jasper Kane Cafe",
            "food": "Chicken bowl",
            "pickupWindowText": "ASAP",
            "mealSwipes": 2,
            "menuPath": "meal-exchange",
            "mealItems": ["Meal 1", "Meal 2"],
            "orderDetails": null,
            "estimatedDiningDollarsCents": null,
            "windowStart": null,
            "windowEnd": null,
            "status": "claimed",
            "createdAt": "2026-07-28T16:00:00.000Z",
            "expiresAt": "2036-07-28T19:00:00.000Z"
          },
          "claim": {
            "pickupName": "Taylor",
            "claimToken": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "claimExpiresAt": "2036-07-28T16:15:00.000Z"
          }
        }
        """#.utf8)
    }

    private func placedResponse() -> Data {
        Data(#"""
        {
          "request": {
            "id": "64b000000000000000000001",
            "vendor": "Jasper Kane Cafe",
            "food": "Chicken bowl",
            "pickupWindowText": "ASAP",
            "mealSwipes": 2,
            "menuPath": "meal-exchange",
            "mealItems": ["Meal 1", "Meal 2"],
            "orderDetails": null,
            "estimatedDiningDollarsCents": null,
            "windowStart": null,
            "windowEnd": null,
            "status": "placed",
            "createdAt": "2026-07-28T16:00:00.000Z",
            "expiresAt": "2036-07-28T19:00:00.000Z"
          },
          "notification": { "status": "sent" }
        }
        """#.utf8)
    }

    private func errorResponse(code: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"detail","fields":null}}"#.utf8)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try XCTUnwrap(formatter.date(from: value))
    }

    private func fileSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
