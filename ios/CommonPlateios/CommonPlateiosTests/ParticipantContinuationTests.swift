import Foundation
import XCTest
@testable import CommonPlateios

/// W3-I1 operation-scoped verification continuation. These cases drive the
/// same production coordinator entry points used by RequestFoodView and
/// RequestDetailView, together with the real verification/request stores.
@MainActor
final class ParticipantContinuationTests: XCTestCase {
    private let principal = "continuation@nyu.edu"
    private let authority =
        "64c0000000000000000000c1.1." + String(repeating: "C", count: 42) + "A"

    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    func testRequestCreationContinuationResumesItsExactDraftOnce() async throws {
        let identityStore = makeIdentityStore()
        let coordinator = makeCoordinator(identityStore)
        let requestStore = makeRequestStore(identityStore: identityStore)
        let draft = completedDraft(food: "The exact saved bowl")
        let path = [AppRoute.requestFood]

        XCTAssertTrue(coordinator.beginRequestCreation(draft: draft, path: path))
        let continuation = try XCTUnwrap(coordinator.pendingContinuation)
        await completeVerification(identityStore)

        let currentIdentity = try XCTUnwrap(identityStore.identity)
        let resume = coordinator.requesterIdentityDidChange(
            from: nil,
            to: currentIdentity,
            path: path
        )
        guard case .requestCreation(let resumedDraft)? = resume else {
            return XCTFail("expected the exact requester continuation")
        }
        XCTAssertEqual(resumedDraft, draft)
        // Cleared before the mutation entry point returns.
        XCTAssertNil(coordinator.pendingContinuation)
        XCTAssertNil(identityStore.pendingContinuation)

        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 201, data: createdResponse(food: "The exact saved bowl"))
        )
        let result = try await RequestFoodView.orchestrateSubmission(
            draft: resumedDraft,
            now: try date("2026-08-09T17:00:00.000Z"),
            calendar: utcCalendar,
            presentation: RequestFoodValidationPresentation()
        ) { payload in
            try await requestStore.createRequest(payload)
        }

        XCTAssertTrue(result.didSubmit)
        XCTAssertEqual(capturedRequestCount(path: "/api/request"), 1)
        let body = try XCTUnwrap(RequestFetchingURLProtocol.lastCapturedBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        // W4-R4: the resumed draft submits its exact structured entries;
        // `food` is derived by the backend and never sent. The wire shape is
        // structured `{ name, details }` objects, not bare strings.
        let mealItemsJSON = try XCTUnwrap(json["mealItems"] as? [[String: Any]])
        let decodedMealItems = try mealItemsJSON.map { entry -> MealItem in
            MealItem(name: try XCTUnwrap(entry["name"] as? String), details: entry["details"] as? String)
        }
        XCTAssertEqual(decodedMealItems, ["The exact saved bowl"])
        XCTAssertNil(json["food"])
        // The duplicate publication callback used by the view has nothing to
        // consume and cannot enqueue a second create.
        XCTAssertNil(coordinator.requesterIdentityDidChange(
            from: nil,
            to: currentIdentity,
            path: path
        ))
        XCTAssertFalse(identityStore.consumeContinuation(continuation))
        XCTAssertEqual(capturedRequestCount(path: "/api/request"), 1)
    }

    func testClaimContinuationResumesOnlyItsExactRequestOnce() async throws {
        let identityStore = makeIdentityStore()
        let coordinator = makeCoordinator(identityStore)
        let requestStore = makeRequestStore(identityStore: identityStore)
        let requestA = request(id: "64b0000000000000000000a1")
        let requestB = request(id: "64b0000000000000000000b2")
        let pathA: [AppRoute] = [.requestDetail(requestA)]

        XCTAssertTrue(coordinator.beginClaim(requestID: requestA.id, path: pathA))
        let continuationA = try XCTUnwrap(coordinator.pendingContinuation)
        await completeVerification(identityStore)
        let currentIdentity = try XCTUnwrap(identityStore.identity)

        // A requester screen and request-B detail are different owners. Neither
        // may consume request A merely because identity became global.
        XCTAssertNil(coordinator.requesterIdentityDidChange(
            from: nil,
            to: currentIdentity,
            path: [.requestFood]
        ))
        XCTAssertNil(coordinator.helperIdentityDidChange(
            requestID: requestB.id,
            from: nil,
            to: currentIdentity,
            path: [.requestDetail(requestB)]
        ))
        XCTAssertEqual(coordinator.pendingContinuation, continuationA)

        let resume = coordinator.helperIdentityDidChange(
            requestID: requestA.id,
            from: nil,
            to: currentIdentity,
            path: pathA
        )
        XCTAssertEqual(resume, .claim(requestID: requestA.id))
        XCTAssertNil(coordinator.pendingContinuation)
        XCTAssertNil(identityStore.pendingContinuation)

        RequestFetchingURLProtocol.enqueue(
            .response(
                statusCode: 200,
                // A distinctive quantity (4, not the file's usual default of
                // 2) proves the continuation's completed claim carries the
                // exact backend-confirmed value into `activeClaim.request`,
                // not a coincidental default (W3-C1).
                data: claimedResponse(requestID: requestA.id, mealSwipes: 4)
            )
        )
        try await requestStore.claim(requestID: requestA.id)

        XCTAssertNil(coordinator.helperIdentityDidChange(
            requestID: requestA.id,
            from: nil,
            to: currentIdentity,
            path: pathA
        ))
        XCTAssertFalse(identityStore.consumeContinuation(continuationA))
        XCTAssertEqual(capturedRequestCount(path: "/api/request/\(requestA.id)/claim"), 1)
        XCTAssertEqual(capturedRequestCount(path: "/api/request/\(requestB.id)/claim"), 0)
        XCTAssertEqual(requestStore.activeClaim?.requestID, requestA.id)
        XCTAssertEqual(requestStore.activeClaim?.request.mealSwipes, 4)
    }

    func testRequesterSuccessfulSheetDismissalBeforeIdentityPublicationPreservesExactResumeOnce() async throws {
        let identityStore = makeIdentityStore()
        let coordinator = makeCoordinator(identityStore)
        let requestStore = makeRequestStore(identityStore: identityStore)
        let draft = completedDraft(food: "Dismissed before requester publication")
        let path = [AppRoute.requestFood]

        XCTAssertTrue(coordinator.beginRequestCreation(draft: draft, path: path))
        let continuation = try XCTUnwrap(coordinator.pendingContinuation)
        await completeVerification(identityStore)
        let currentIdentity = try XCTUnwrap(identityStore.identity)

        // SwiftUI may dismiss the sheet after the store publishes verified
        // identity but before RequestFoodView receives its onChange callback.
        coordinator.requesterSheetDismissed()
        XCTAssertEqual(coordinator.pendingContinuation, continuation)
        XCTAssertEqual(identityStore.pendingContinuation, continuation)

        guard case .requestCreation(let resumedDraft)? =
                coordinator.requesterIdentityDidChange(
                    from: nil,
                    to: currentIdentity,
                    path: path
                ) else {
            return XCTFail("successful dismissal must preserve the requester resume")
        }
        XCTAssertEqual(resumedDraft, draft)

        RequestFetchingURLProtocol.enqueue(
            .response(
                statusCode: 201,
                data: createdResponse(food: "Dismissed before requester publication")
            )
        )
        let result = try await RequestFoodView.orchestrateSubmission(
            draft: resumedDraft,
            now: try date("2026-08-09T17:00:00.000Z"),
            calendar: utcCalendar,
            presentation: RequestFoodValidationPresentation()
        ) { payload in
            try await requestStore.createRequest(payload)
        }

        XCTAssertTrue(result.didSubmit)
        XCTAssertEqual(capturedRequestCount(path: "/api/request"), 1)
        XCTAssertNil(coordinator.pendingContinuation)
        XCTAssertNil(identityStore.pendingContinuation)
        XCTAssertNil(coordinator.requesterIdentityDidChange(
            from: nil,
            to: currentIdentity,
            path: path
        ))
        XCTAssertFalse(identityStore.consumeContinuation(continuation))
        XCTAssertEqual(capturedRequestCount(path: "/api/request"), 1)
    }

    func testRequesterIdentityPublicationBeforeSuccessfulSheetDismissalCannotRepeatResume() async throws {
        let identityStore = makeIdentityStore()
        let coordinator = makeCoordinator(identityStore)
        let requestStore = makeRequestStore(identityStore: identityStore)
        let draft = completedDraft(food: "Published before requester dismissal")
        let path = [AppRoute.requestFood]

        XCTAssertTrue(coordinator.beginRequestCreation(draft: draft, path: path))
        let continuation = try XCTUnwrap(coordinator.pendingContinuation)
        await completeVerification(identityStore)
        let currentIdentity = try XCTUnwrap(identityStore.identity)

        guard case .requestCreation(let resumedDraft)? =
                coordinator.requesterIdentityDidChange(
                    from: nil,
                    to: currentIdentity,
                    path: path
                ) else {
            return XCTFail("expected the requester resume before dismissal")
        }
        XCTAssertEqual(resumedDraft, draft)
        XCTAssertNil(coordinator.pendingContinuation)
        XCTAssertNil(identityStore.pendingContinuation)

        // The programmatic dismissal arrives after consumption. It must be a
        // no-op and cannot recreate or retire a replacement continuation.
        coordinator.requesterSheetDismissed()
        XCTAssertNil(coordinator.pendingContinuation)
        XCTAssertNil(identityStore.pendingContinuation)

        RequestFetchingURLProtocol.enqueue(
            .response(
                statusCode: 201,
                data: createdResponse(food: "Published before requester dismissal")
            )
        )
        let result = try await RequestFoodView.orchestrateSubmission(
            draft: resumedDraft,
            now: try date("2026-08-09T17:00:00.000Z"),
            calendar: utcCalendar,
            presentation: RequestFoodValidationPresentation()
        ) { payload in
            try await requestStore.createRequest(payload)
        }

        XCTAssertTrue(result.didSubmit)
        XCTAssertNil(coordinator.requesterIdentityDidChange(
            from: nil,
            to: currentIdentity,
            path: path
        ))
        XCTAssertFalse(identityStore.consumeContinuation(continuation))
        XCTAssertEqual(capturedRequestCount(path: "/api/request"), 1)
    }

    func testHelperSuccessfulSheetDismissalBeforeIdentityPublicationPreservesRequestAOnce() async throws {
        let identityStore = makeIdentityStore()
        let coordinator = makeCoordinator(identityStore)
        let requestStore = makeRequestStore(identityStore: identityStore)
        let requestA = request(id: "64b0000000000000000000a1")
        let requestB = request(id: "64b0000000000000000000b2")
        let pathA: [AppRoute] = [.requestDetail(requestA)]

        XCTAssertTrue(coordinator.beginClaim(requestID: requestA.id, path: pathA))
        let continuationA = try XCTUnwrap(coordinator.pendingContinuation)
        await completeVerification(identityStore)
        let currentIdentity = try XCTUnwrap(identityStore.identity)

        coordinator.helperSheetDismissed(requestID: requestA.id)
        XCTAssertEqual(coordinator.pendingContinuation, continuationA)
        XCTAssertEqual(identityStore.pendingContinuation, continuationA)

        XCTAssertEqual(coordinator.helperIdentityDidChange(
            requestID: requestA.id,
            from: nil,
            to: currentIdentity,
            path: pathA
        ), .claim(requestID: requestA.id))

        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 200, data: claimedResponse(requestID: requestA.id))
        )
        try await requestStore.claim(requestID: requestA.id)

        XCTAssertNil(coordinator.pendingContinuation)
        XCTAssertNil(identityStore.pendingContinuation)
        XCTAssertNil(coordinator.helperIdentityDidChange(
            requestID: requestA.id,
            from: nil,
            to: currentIdentity,
            path: pathA
        ))
        XCTAssertNil(coordinator.helperIdentityDidChange(
            requestID: requestB.id,
            from: nil,
            to: currentIdentity,
            path: [.requestDetail(requestB)]
        ))
        XCTAssertFalse(identityStore.consumeContinuation(continuationA))
        XCTAssertEqual(capturedRequestCount(path: "/api/request/\(requestA.id)/claim"), 1)
        XCTAssertEqual(capturedRequestCount(path: "/api/request/\(requestB.id)/claim"), 0)
    }

    func testHelperIdentityPublicationBeforeSuccessfulSheetDismissalCannotRepeatClaim() async throws {
        let identityStore = makeIdentityStore()
        let coordinator = makeCoordinator(identityStore)
        let requestStore = makeRequestStore(identityStore: identityStore)
        let requestA = request(id: "64b0000000000000000000a1")
        let pathA: [AppRoute] = [.requestDetail(requestA)]

        XCTAssertTrue(coordinator.beginClaim(requestID: requestA.id, path: pathA))
        let continuationA = try XCTUnwrap(coordinator.pendingContinuation)
        await completeVerification(identityStore)
        let currentIdentity = try XCTUnwrap(identityStore.identity)

        XCTAssertEqual(coordinator.helperIdentityDidChange(
            requestID: requestA.id,
            from: nil,
            to: currentIdentity,
            path: pathA
        ), .claim(requestID: requestA.id))
        XCTAssertNil(coordinator.pendingContinuation)
        XCTAssertNil(identityStore.pendingContinuation)

        coordinator.helperSheetDismissed(requestID: requestA.id)
        XCTAssertNil(coordinator.pendingContinuation)
        XCTAssertNil(identityStore.pendingContinuation)

        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 200, data: claimedResponse(requestID: requestA.id))
        )
        try await requestStore.claim(requestID: requestA.id)

        XCTAssertNil(coordinator.helperIdentityDidChange(
            requestID: requestA.id,
            from: nil,
            to: currentIdentity,
            path: pathA
        ))
        XCTAssertFalse(identityStore.consumeContinuation(continuationA))
        XCTAssertEqual(capturedRequestCount(path: "/api/request/\(requestA.id)/claim"), 1)
        XCTAssertEqual(requestStore.activeClaim?.requestID, requestA.id)
    }

    func testCompetingBeginAttemptsCannotReplaceTheFirstOperation() throws {
        let identityStore = makeIdentityStore()
        let coordinator = makeCoordinator(identityStore)
        let draft = completedDraft(food: "First operation")
        let helperRequest = request(id: "64b0000000000000000000a1")

        XCTAssertTrue(coordinator.beginRequestCreation(
            draft: draft,
            path: [.requestFood]
        ))
        let first = try XCTUnwrap(coordinator.pendingContinuation)
        XCTAssertFalse(coordinator.beginClaim(
            requestID: helperRequest.id,
            path: [.requestDetail(helperRequest)]
        ))
        XCTAssertFalse(coordinator.beginRequestCreation(
            draft: completedDraft(food: "Replacement operation"),
            path: [.requestFood]
        ))
        XCTAssertEqual(coordinator.pendingContinuation, first)
        XCTAssertEqual(identityStore.pendingContinuation, first)
    }

    func testExplicitRequesterCancellationRetiresTheOperation() {
        let identityStore = makeIdentityStore()
        let coordinator = makeCoordinator(identityStore)
        XCTAssertTrue(coordinator.beginRequestCreation(
            draft: completedDraft(food: "Cancelled"),
            path: [.requestFood]
        ))

        coordinator.requesterCancelled()

        assertRetired(coordinator, identityStore)
    }

    func testHelperSheetDismissalRetiresTheOperation() {
        let identityStore = makeIdentityStore()
        let coordinator = makeCoordinator(identityStore)
        let helperRequest = request(id: "64b0000000000000000000a1")
        XCTAssertTrue(coordinator.beginClaim(
            requestID: helperRequest.id,
            path: [.requestDetail(helperRequest)]
        ))

        coordinator.helperSheetDismissed(requestID: helperRequest.id)

        assertRetired(coordinator, identityStore)
    }

    func testRequesterSheetDismissalBeforeSuccessfulVerificationRetiresTheOperation() {
        let identityStore = makeIdentityStore()
        let coordinator = makeCoordinator(identityStore)
        XCTAssertTrue(coordinator.beginRequestCreation(
            draft: completedDraft(food: "Dismissed before verification"),
            path: [.requestFood]
        ))

        coordinator.requesterSheetDismissed()

        assertRetired(coordinator, identityStore)
    }

    func testRequesterNavigationReplacementRetiresTheOperation() {
        let identityStore = makeIdentityStore()
        let coordinator = makeCoordinator(identityStore)
        XCTAssertTrue(coordinator.beginRequestCreation(
            draft: completedDraft(food: "Replaced path"),
            path: [.requestFood]
        ))

        coordinator.requesterNavigationChanged(path: [])

        assertRetired(coordinator, identityStore)
    }

    func testHelperNavigationReplacementRetiresTheOperation() {
        let identityStore = makeIdentityStore()
        let coordinator = makeCoordinator(identityStore)
        let helperRequest = request(id: "64b0000000000000000000a1")
        XCTAssertTrue(coordinator.beginClaim(
            requestID: helperRequest.id,
            path: [.requestDetail(helperRequest)]
        ))

        coordinator.helperNavigationChanged(
            requestID: helperRequest.id,
            path: []
        )

        assertRetired(coordinator, identityStore)
    }

    func testRequesterDisappearanceRetiresTheOperation() {
        let identityStore = makeIdentityStore()
        let coordinator = makeCoordinator(identityStore)
        XCTAssertTrue(coordinator.beginRequestCreation(
            draft: completedDraft(food: "Disappeared"),
            path: [.requestFood]
        ))

        coordinator.requesterDisappeared()

        assertRetired(coordinator, identityStore)
    }

    func testHelperDisappearanceRetiresTheOperation() {
        let identityStore = makeIdentityStore()
        let coordinator = makeCoordinator(identityStore)
        let helperRequest = request(id: "64b0000000000000000000a1")
        XCTAssertTrue(coordinator.beginClaim(
            requestID: helperRequest.id,
            path: [.requestDetail(helperRequest)]
        ))

        coordinator.helperDisappeared(requestID: helperRequest.id)

        assertRetired(coordinator, identityStore)
    }

    func testRequestADestinationMismatchCannotClaimRequestB() async throws {
        let identityStore = makeIdentityStore()
        let coordinator = makeCoordinator(identityStore)
        let requestA = request(id: "64b0000000000000000000a1")
        let requestB = request(id: "64b0000000000000000000b2")
        XCTAssertTrue(coordinator.beginClaim(
            requestID: requestA.id,
            path: [.requestDetail(requestA)]
        ))
        await completeVerification(identityStore)
        let currentIdentity = try XCTUnwrap(identityStore.identity)

        XCTAssertNil(coordinator.helperIdentityDidChange(
            requestID: requestA.id,
            from: nil,
            to: currentIdentity,
            path: [.requestDetail(requestB)]
        ))

        assertRetired(coordinator, identityStore)
        XCTAssertEqual(capturedRequestCount(path: "/api/request/\(requestA.id)/claim"), 0)
        XCTAssertEqual(capturedRequestCount(path: "/api/request/\(requestB.id)/claim"), 0)
    }

    private func completeVerification(_ store: ParticipantIdentityStore) async {
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: verifiedResponse()))
        await store.requestCode(for: principal)
        let verified = await store.submitCode("424242")
        XCTAssertTrue(verified)
    }

    private func makeIdentityStore() -> ParticipantIdentityStore {
        ParticipantIdentityStore(
            service: ParticipantVerificationService(client: client()),
            storage: InMemoryParticipantIdentityStorage()
        )
    }

    private func makeCoordinator(
        _ identityStore: ParticipantIdentityStore
    ) -> ParticipantActionVerificationCoordinator {
        ParticipantActionVerificationCoordinator(identityStore: identityStore)
    }

    private func assertRetired(
        _ coordinator: ParticipantActionVerificationCoordinator,
        _ identityStore: ParticipantIdentityStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(coordinator.pendingContinuation, file: file, line: line)
        XCTAssertNil(identityStore.pendingContinuation, file: file, line: line)
        XCTAssertNil(identityStore.flow, file: file, line: line)
    }

    private func makeRequestStore(
        identityStore: ParticipantIdentityStore
    ) -> RequestStore {
        RequestStore(
            service: RequestService(client: client()),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { identityStore.currentAuthority() },
            participantAuthorityRejected: { identityStore.discardRejectedIdentity() }
        )
    }

    private func client() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        return APIClient(
            configuration: APIConfiguration(
                baseURL: URL(string: "https://commonplate.test")!
            ),
            session: URLSession(configuration: configuration)
        )
    }

    private func completedDraft(food: String) -> RequestFoodFormDraft {
        RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            menuPath: .mealExchange,
            timing: .asap,
            preferredPickupTime: try! date("2026-08-09T17:00:00.000Z"),
            mealSwipes: 1,
            mealEntries: [food, "", "", "", ""]
        )
    }

    private func request(id: String) -> FoodRequest {
        FoodRequest(
            id: id,
            diningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            foodDescription: "Rice bowl",
            pickupWindowText: "ASAP",
            mealSwipes: 2,
            windowStart: nil,
            windowEnd: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            status: .open
        )
    }

    private func capturedRequestCount(path: String) -> Int {
        RequestFetchingURLProtocol.capturedRequestedPaths.filter { $0 == path }.count
    }

    private func challengeResponse() -> Data {
        Data(#"{"verification":{"expiresAt":"2026-08-09T17:10:00.000Z","resendAvailableAt":"2026-08-09T17:01:00.000Z"}}"#.utf8)
    }

    private func verifiedResponse() -> Data {
        Data(#"{"participant":{"email":"\#(principal)"},"authority":"\#(authority)"}"#.utf8)
    }

    private func createdResponse(food: String) -> Data {
        Data(#"{"request":{"id":"64b0000000000000000000a1","vendor":"Jasper Kane Cafe","food":"\#(food)","pickupWindowText":"ASAP","mealSwipes":2,"menuPath":"meal-exchange","mealItems":["Meal 1","Meal 2"],"orderDetails":null,"estimatedDiningDollarsCents":null,"windowStart":null,"windowEnd":null,"status":"open","createdAt":"2026-08-09T17:00:00.000Z","expiresAt":"2026-08-09T20:00:00.000Z"}}"#.utf8)
    }

    private func claimedResponse(requestID: String, mealSwipes: Int = 2) -> Data {
        Data(#"{"request":{"id":"\#(requestID)","vendor":"Jasper Kane Cafe","food":"Rice bowl","pickupWindowText":"ASAP","mealSwipes":\#(mealSwipes),"menuPath":"meal-exchange","mealItems":[],"orderDetails":null,"estimatedDiningDollarsCents":null,"windowStart":null,"windowEnd":null,"status":"claimed","createdAt":"2026-08-09T17:00:00.000Z","expiresAt":"2036-08-09T20:00:00.000Z"},"claim":{"pickupName":"Taylor","claimToken":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","claimExpiresAt":"2036-08-09T17:15:00.000Z"}}"#.utf8)
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
}
