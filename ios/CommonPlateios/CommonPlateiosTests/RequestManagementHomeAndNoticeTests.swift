//
//  RequestManagementHomeAndNoticeTests.swift
//  CommonPlateiosTests
//
// Focused W4-R5 coverage of the Home integration and the notification-tap
// reconciliation: what Home treats as the participant's own requests, when it
// refuses to present an empty exchange, which notices are banners versus
// safety alerts, and how a tap resolves against verified backend truth
// (withdrawn, expired, updated since the notification, still available).
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class RequestManagementHomeAndNoticeTests: XCTestCase {
    private typealias Home = HomeExchangeView
    private let authorityA = canonicalParticipantAuthorityFixture
    private let authorityB = replacementParticipantAuthorityFixture

    override func tearDown() {
        ClaimFlowURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Home: which requests are the participant's own

    func testOnceLoadedTheOwnerListDecidesMembershipIncludingScheduledAndReserved() {
        let scheduled = owner("s", phase: .scheduled, created: 300)
        let reserved = owner("r", phase: .reserved, created: 200)
        let available = owner("a", phase: .available, created: 100)

        let owned = Home.ownRequests(
            displayedBoardState: .empty,
            createdRequestContinuity: nil,
            ownerRequests: [available, scheduled, reserved]
        )

        XCTAssertEqual(owned.map(\.id), ["s", "r", "a"], "newest first, scheduled and reserved included")
    }

    func testAPublicBoardRequestKnownToBeOwnFillsAGapAndNeverDuplicates() {
        let known = owner("a", phase: .available, created: 100)
        let justCreated = food("new", ownership: .own, created: 500)
        let others = food("x", ownership: .notOwn, created: 50)

        let owned = Home.ownRequests(
            displayedBoardState: .populated([known.request, justCreated, others]),
            createdRequestContinuity: nil,
            ownerRequests: [known]
        )

        XCTAssertEqual(owned.map(\.id), ["new", "a"])
    }

    func testWithoutAnOwnerReadHomeKeepsItsExistingDerivation() {
        let own = food("o", ownership: .own, created: 100)
        let other = food("x", ownership: .notOwn, created: 90)

        XCTAssertEqual(
            Home.ownRequests(displayedBoardState: .populated([own, other]), createdRequestContinuity: nil).map(\.id),
            ["o"]
        )
        XCTAssertEqual(
            Home.ownRequests(displayedBoardState: .empty, createdRequestContinuity: nil),
            []
        )
        XCTAssertEqual(
            Home.ownRequests(displayedBoardState: .unavailable, createdRequestContinuity: nil),
            []
        )
    }

    func testAnEmptyOwnerListIsAnAuthoritativeNoneNotAFallbackToTheBoard() {
        XCTAssertEqual(
            Home.ownRequests(displayedBoardState: .empty, createdRequestContinuity: nil, ownerRequests: []),
            []
        )
    }

    func testTheOwnerCardOpensTheRequesterOwnedDetail() throws {
        let source = try appSource("Views/HomeExchangeView.swift")
        XCTAssertTrue(source.contains("NavigationLink(value: ownRequestRoute(for: request))"))
        XCTAssertTrue(source.contains("return .ownerRequest(ownerSnapshot(for: request))"))
        XCTAssertTrue(source.contains("return .placedOrder(requestID: request.id)"))
        XCTAssertTrue(source.contains("Task { await store.fetchOwnerRequests() }"))
    }

    func testAProvisionalSnapshotCarriesNoAuthority() {
        let provisional = OwnerRequest.provisional(from: food("p", ownership: .own, created: 100))
        XCTAssertNil(provisional.contentRevision)
        XCTAssertFalse(provisional.canEdit)
        XCTAssertFalse(provisional.canWithdraw)
    }

    // MARK: - Home: never an empty exchange when owner truth is unknown

    func testUnverifiedOwnerTruthMakesAResolvedBoardUnavailableNeverEmpty() {
        for requests in [[FoodRequest](), [food("x", ownership: .notOwn, created: 1)]] {
            XCTAssertEqual(
                Home.boardState(
                    hasSuccessfullyFetchedRequests: true,
                    hasAttemptedRequestFetch: true,
                    hasFailedInitialFetchAtLeastOnce: false,
                    isFetching: false,
                    requests: requests,
                    isOwnerTruthUnverified: true
                ),
                .unavailable
            )
        }
        // The default keeps every existing caller exactly as it was.
        XCTAssertEqual(
            Home.boardState(
                hasSuccessfullyFetchedRequests: true,
                hasAttemptedRequestFetch: true,
                hasFailedInitialFetchAtLeastOnce: false,
                isFetching: false,
                requests: []
            ),
            .empty
        )
    }

    func testOwnerTruthIsUnverifiedOnlyAfterAFailedReadWithNothingLoaded() async {
        let store = makeStore(MutableAuthority(authorityA))
        XCTAssertFalse(Home.isOwnerTruthUnverified(store: store), "not attempted is not a verdict")

        ClaimFlowURLProtocol.enqueue(.failure(.timedOut))
        await store.fetchOwnerRequests()
        XCTAssertTrue(Home.isOwnerTruthUnverified(store: store))

        ClaimFlowURLProtocol.enqueue(.response(data: Data(#"{"requests":[]}"#.utf8)))
        await store.fetchOwnerRequests()
        XCTAssertFalse(Home.isOwnerTruthUnverified(store: store))

        // A later failure keeps the loaded list: stale-healthy, like the board.
        ClaimFlowURLProtocol.enqueue(.failure(.timedOut))
        await store.fetchOwnerRequests()
        XCTAssertFalse(Home.isOwnerTruthUnverified(store: store))
    }

    // MARK: - Notices: banner versus safety alert

    func testSafetyReasonsStayAlertsAndEverythingElseIsABanner() {
        let alerts: [ClaimUnavailableReason] = [
            .alreadyClaimed, .claimExpired, .fulfillmentClaimExpired,
            .reservationNoLongerValid, .fulfillmentAlreadyPlaced, .fulfillmentRequestNotFound,
        ]
        let banners: [ClaimUnavailableReason] = [
            .noLongerAvailable, .notYetAvailable, .temporarilyUnavailable, .withdrawn, .expired,
        ]
        for reason in alerts {
            XCTAssertEqual(HelperRequestPresentation.homeNoticeStyle(for: reason), .alert, "\(reason)")
        }
        for reason in banners {
            XCTAssertEqual(HelperRequestPresentation.homeNoticeStyle(for: reason), .banner, "\(reason)")
        }
        // A reason with a second safety sentence must be read, so it is an alert.
        for reason in alerts where HelperRequestPresentation.claimUnavailableDetail(for: reason) != nil {
            XCTAssertEqual(HelperRequestPresentation.homeNoticeStyle(for: reason), .alert)
        }
    }

    func testBannerTextUsesTheApprovedFigmaAndConciseTruthfulWording() {
        let unavailable = HelperRequestPresentation.bannerText(for: .temporarilyUnavailable)
        XCTAssertEqual(unavailable.title, "Couldn’t open this request")
        XCTAssertEqual(unavailable.detail, "Please try again.")
        XCTAssertEqual(HelperRequestPresentation.bannerText(for: .withdrawn).title, "This request was withdrawn.")
        XCTAssertEqual(HelperRequestPresentation.bannerText(for: .expired).title, "This request expired.")
        XCTAssertNil(HelperRequestPresentation.bannerText(for: .withdrawn).detail)
    }

    // MARK: - Tap resolution against verified backend truth

    func testAWithdrawnTargetResolvesWithdrawnAndAnExpiredTargetExpired() async throws {
        let store = makeStore(MutableAuthority(authorityA))
        ClaimFlowURLProtocol.enqueue(.response(data: detail(status: "withdrawn", revision: 4)))
        let withdrawn = try await store.resolveHelperNotificationRequest(id: "t1", notifiedRevision: 4)
        XCTAssertEqual(withdrawn, .withdrawn)

        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 410,
            data: Data(#"{"error":{"code":"REQUEST_EXPIRED","message":"x","fields":null}}"#.utf8)
        ))
        let expired = try await store.resolveHelperNotificationRequest(id: "t1", notifiedRevision: 4)
        XCTAssertEqual(expired, .expired)
    }

    func testTheBackendsContentlessWithdrawnAnswerResolvesWithdrawnNotTemporarilyUnavailable() async throws {
        let store = makeStore(MutableAuthority(authorityA))
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 410,
            data: Data(#"{"error":{"code":"REQUEST_WITHDRAWN","message":"x","fields":null}}"#.utf8)
        ))

        let resolved = try await store.resolveHelperNotificationRequest(id: "t1", notifiedRevision: 4)

        XCTAssertEqual(resolved, .withdrawn)
    }

    func testANewerRevisionIsAnUpdatedAvailableRequestAndOtherwiseItIsAvailable() async throws {
        let store = makeStore(MutableAuthority(authorityA))

        ClaimFlowURLProtocol.enqueue(.response(data: detail(status: "open", revision: 3)))
        let newer = try await store.resolveHelperNotificationRequest(id: "t1", notifiedRevision: 2)
        guard case .availableUpdated(let updated) = newer else {
            return XCTFail("a newer revision must be reported as updated")
        }
        XCTAssertEqual(updated.contentRevision, 3)

        for notified in [3, nil] as [Int?] {
            ClaimFlowURLProtocol.enqueue(.response(data: detail(status: "open", revision: 3)))
            let same = try await store.resolveHelperNotificationRequest(id: "t1", notifiedRevision: notified)
            guard case .available = same else {
                return XCTFail("equal or absent notified revision is plainly available")
            }
        }

        // No revision on the response can never be claimed as "updated".
        ClaimFlowURLProtocol.enqueue(.response(data: detail(status: "open", revision: nil)))
        let unknown = try await store.resolveHelperNotificationRequest(id: "t1", notifiedRevision: 1)
        guard case .available = unknown else {
            return XCTFail("an unknown current revision is never an update")
        }
    }

    func testAnUnreadableAnswerIsStillTemporarilyUnavailableNeverWithdrawnOrExpired() async throws {
        let store = makeStore(MutableAuthority(authorityA))
        for stub in [
            ClaimFlowURLProtocol.Stub.failure(.timedOut),
            .response(statusCode: 503, data: Data(#"{"error":{"code":"PARTICIPANT_VERIFICATION_UNAVAILABLE","message":"x","fields":null}}"#.utf8)),
            .response(statusCode: 200, data: Data("{}".utf8)),
        ] {
            ClaimFlowURLProtocol.enqueue(stub)
            let resolution = try await store.resolveHelperNotificationRequest(id: "t1", notifiedRevision: 1)
            XCTAssertEqual(resolution, .temporarilyUnavailable)
        }
    }

    // MARK: - Tap routing end to end (driver)

    func testAnUpdatedTapOpensTheLatestDetailAndQueuesTheVerifiedUpdateNotice() async throws {
        let store = makeStore(MutableAuthority(authorityA))
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: [
            "type": "new-request", "requestId": "t1", "contentRevision": 1,
        ])
        XCTAssertEqual(router.pendingHelperIntent?.contentRevision, 1)
        ClaimFlowURLProtocol.enqueue(.response(data: detail(status: "open", revision: 2)))

        let routed = await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)
        let path = try XCTUnwrap(routed)

        XCTAssertEqual(path.count, 1)
        guard case .requestDetail(let request) = path[0] else { return XCTFail("expected detail") }
        XCTAssertEqual(request.id, "t1")
        XCTAssertEqual(store.updatedSinceNotificationRequestID, "t1")
        XCTAssertNil(store.claimUnavailableNotice)
        store.acknowledgeUpdatedSinceNotification(requestID: "t1")
        XCTAssertNil(store.updatedSinceNotificationRequestID)
    }

    func testWithdrawnAndExpiredTapsReturnHomeWithTheirOneTimeNotice() async throws {
        for (stub, expected) in [
            (ClaimFlowURLProtocol.Stub.response(data: detail(status: "withdrawn", revision: 2)), ClaimUnavailableReason.withdrawn),
            (.response(statusCode: 410, data: Data(#"{"error":{"code":"REQUEST_EXPIRED","message":"x","fields":null}}"#.utf8)), .expired),
        ] {
            let store = makeStore(MutableAuthority(authorityA))
            let router = HelperNotificationRouter()
            router.handleUserActedOnNotification(userInfo: ["type": "new-request", "requestId": "t1"])
            ClaimFlowURLProtocol.enqueue(stub)

            let routed = await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)
            let path = try XCTUnwrap(routed)

            XCTAssertEqual(path, [], "Home is the destination")
            XCTAssertEqual(store.claimUnavailableNotice?.reason, expected)
            XCTAssertNil(router.pendingRequestID, "the tap is retired exactly once")
        }
    }

    func testTheNotificationPayloadParsesAPositiveRevisionOnlyAsAnInteger() {
        func parse(_ revision: Any?) -> Int?? {
            var info: [AnyHashable: Any] = ["type": "new-request", "requestId": "t1"]
            if let revision { info["contentRevision"] = revision }
            return HelperNotificationPayloadParser.parse(userInfo: info).map(\.contentRevision)
        }
        XCTAssertEqual(parse(3), .some(3))
        XCTAssertEqual(parse(nil), .some(nil))
        for unusable: Any in [0, -2, "2", 1.5 as Double] {
            XCTAssertEqual(parse(unusable), .some(nil), "\(unusable)")
        }
    }

    func testHomeIsTheBaseOfEveryNotificationDestination() {
        let request = food("t1", ownership: .notOwn, created: 1)
        XCTAssertEqual(AppRoute.afterNotificationResolution(.available(request)), [.requestDetail(request)])
        XCTAssertEqual(AppRoute.afterNotificationResolution(.availableUpdated(request)), [.requestDetail(request)])
        XCTAssertEqual(AppRoute.afterNotificationResolution(.heldByCurrentHelper(request)), [.fulfillment(request)])
        for resolution: HelperNotificationResolution in [
            .unavailable, .withdrawn, .expired, .notYetAvailable, .temporarilyUnavailable,
        ] {
            XCTAssertEqual(AppRoute.afterNotificationResolution(resolution), [], "\(resolution)")
        }
    }

    func testAnIdentityReplacementAlsoRetiresOwnerCarriedRoutes() {
        let owned = owner("o", phase: .available, created: 1)
        let path: [AppRoute] = [.ownerRequest(owned), .editRequest(owned), .settings]
        XCTAssertEqual(AppRoute.afterIdentityReplacement(from: path), [.settings])
    }

    // MARK: - Store notices

    func testAVerifiedExpiryDropsTheStaleCardAndLeavesAOneTimeNotice() async {
        let store = makeStore(MutableAuthority(authorityA))
        ClaimFlowURLProtocol.enqueue(.response(data: ownerList([ownerJSON("o1")])))
        await store.fetchOwnerRequests()
        let owned = store.ownerRequests[0]

        store.reportOwnRequestExpired(owned)

        XCTAssertTrue(store.ownerRequests.isEmpty)
        XCTAssertEqual(store.requesterNotice, .expired(vendor: "Crave NYU", mealSwipes: 1))
        store.dismissRequesterNotice()
        XCTAssertNil(store.requesterNotice)
    }

    func testAWithdrawalLeavesTheWithdrawnNoticeAndAnEditLeavesChangesSaved() async throws {
        let store = makeStore(MutableAuthority(authorityA))
        ClaimFlowURLProtocol.enqueue(.response(data: ownerList([ownerJSON("o1"), ownerJSON("o2")])))
        await store.fetchOwnerRequests()

        ClaimFlowURLProtocol.enqueue(.response(data: Data(
            #"{"outcome":"edited","resultingRevision":2,"request":\#(ownerJSON("o2", revision: 2))}"#.utf8
        )))
        _ = try await store.editRequest(requestID: "o2", payload: payload(revision: 1))
        XCTAssertEqual(store.changesSavedRequestID, "o2")
        store.acknowledgeChangesSaved(requestID: "o2")
        XCTAssertNil(store.changesSavedRequestID)

        ClaimFlowURLProtocol.enqueue(.response(data: Data(#"{"outcome":"withdrawn","requestId":"o1"}"#.utf8)))
        try await store.withdrawRequest(requestID: "o1")
        XCTAssertEqual(store.requesterNotice, .withdrawn)
    }

    func testNoticesEarnedByAReplacedParticipantAreNotTheNewOnes() async throws {
        let authority = MutableAuthority(authorityA)
        let store = makeStore(authority)
        ClaimFlowURLProtocol.enqueue(.response(data: ownerList([ownerJSON("o1")])))
        await store.fetchOwnerRequests()
        ClaimFlowURLProtocol.enqueue(.response(data: Data(#"{"outcome":"withdrawn","requestId":"o1"}"#.utf8)))
        try await store.withdrawRequest(requestID: "o1")
        XCTAssertEqual(store.requesterNotice, .withdrawn)

        authority.set(authorityB)
        XCTAssertTrue(store.invalidateRequestDataIfIdentityReplaced())

        XCTAssertNil(store.requesterNotice)
        XCTAssertNil(store.changesSavedRequestID)
    }

    // MARK: - Fixtures

    private final class MutableAuthority: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        init(_ value: String?) { self.value = value }
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ new: String?) { lock.lock(); value = new; lock.unlock() }
    }

    private func makeStore(_ authority: MutableAuthority) -> RequestStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaimFlowURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
        return RequestStore(
            service: RequestService(client: client),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { authority.get() },
            participantAuthorityRejected: {}
        )
    }

    private func food(_ id: String, ownership: RequestOwnership, created: TimeInterval) -> FoodRequest {
        FoodRequest(
            id: id,
            diningSpot: DiningSpot(name: "Crave NYU", address: nil),
            foodDescription: "Rice bowl",
            pickupWindowText: "ASAP",
            mealSwipes: 1,
            windowStart: nil,
            windowEnd: nil,
            createdAt: Date(timeIntervalSince1970: created),
            expiresAt: Date(timeIntervalSince1970: created + 10_800),
            status: .open,
            ownership: ownership
        )
    }

    private func owner(_ id: String, phase: OwnerRequestPhase, created: TimeInterval) -> OwnerRequest {
        OwnerRequest(
            request: food(id, ownership: .own, created: created),
            phase: phase,
            contentRevision: 1,
            canEdit: phase != .reserved,
            canWithdraw: phase != .reserved,
            latestScheduledStart: Date(timeIntervalSince1970: created + 3_600)
        )
    }

    private func payload(revision: Int) -> EditRequestPayload {
        EditRequestPayload(
            vendor: "Crave NYU",
            menuPath: .mealExchange,
            mealSwipes: 1,
            mealItems: [MealItem(name: "Rice bowl")],
            orderDetails: nil,
            estimatedDiningDollarsCents: nil,
            timing: .unchanged,
            windowStart: nil,
            expectedContentRevision: revision
        )
    }

    private func detail(status: String, revision: Int?) -> Data {
        let revisionField = revision.map { ",\"contentRevision\": \($0)" } ?? ""
        return Data("""
        {"request": {
          "id": "t1", "vendor": "Crave NYU", "food": "Rice bowl", "pickupWindowText": "ASAP",
          "mealSwipes": 1, "menuPath": "meal-exchange", "mealItems": [{"name": "Rice bowl"}],
          "orderDetails": null, "estimatedDiningDollarsCents": null,
          "windowStart": null, "windowEnd": null, "status": "\(status)",
          "createdAt": "2026-07-20T18:30:00.000Z", "expiresAt": "2099-07-20T23:30:00.000Z",
          "isOwnRequest": false\(revisionField)
        }}
        """.utf8)
    }

    private func ownerList(_ objects: [String]) -> Data {
        Data(#"{"requests":[\#(objects.joined(separator: ","))]}"#.utf8)
    }

    private func ownerJSON(_ id: String, revision: Int = 1) -> String {
        """
        {
          "id": "\(id)", "vendor": "Crave NYU", "food": "Rice bowl",
          "pickupWindowText": "ASAP", "mealSwipes": 1, "menuPath": "meal-exchange",
          "mealItems": [{"name": "Rice bowl"}], "orderDetails": null,
          "estimatedDiningDollarsCents": null, "windowStart": null, "windowEnd": null,
          "createdAt": "2026-07-20T18:30:00.000Z", "expiresAt": "2099-07-20T23:30:00.000Z",
          "timing": "asap", "phase": "available", "contentRevision": \(revision),
          "canEdit": true, "canWithdraw": true,
          "latestScheduledStart": "2026-07-21T03:30:00.000Z"
        }
        """
    }

    private func appSource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("CommonPlateios")
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
