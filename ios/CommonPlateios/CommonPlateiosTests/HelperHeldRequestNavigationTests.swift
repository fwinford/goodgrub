import Foundation
import XCTest
@testable import CommonPlateios

/// W4-H1 active-reservation navigation (2026-09-15 repair): Request Detail is
/// a pre-claim surface only, and Helping is the one destination for a request
/// the helper holds — after a successful `Start helping`, from every in-app
/// entry, and from a helper new-request notification tap for that request.
///
/// There is no UI-test target, so the stack itself is proven through the pure
/// `AppRoute` functions the views apply, the notification driver over a real
/// `RequestStore` and stubbed transport, and bounded source checks for the
/// view wiring. None of this establishes the physical Back gesture or
/// transition feel on a device.
@MainActor
final class HelperHeldRequestNavigationTests: XCTestCase {
    private let heldID = "held-meal"
    private let otherID = "other-meal"

    override func tearDown() {
        ClaimFlowURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Successful Start helping

    /// Home → Request Detail → Start helping succeeds → Helping. Back from
    /// Helping lands on Home, never on the request's stale detail.
    func testSuccessfulClaimFromHomeReplacesDetailSoBackReturnsHome() async throws {
        let store = makeStore()
        let preClaim = foodRequest(id: heldID, mealSwipes: 1)
        let detailPath = AppRoute.appending(.requestDetail(preClaim), to: [])
        XCTAssertEqual(detailPath, [.requestDetail(preClaim)])

        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(requestID: heldID, mealSwipes: 4)))
        try await store.claim(requestID: heldID)
        let activeClaim = try XCTUnwrap(store.activeClaim)
        XCTAssertTrue(RequestDetailView.opensClaimedFlow(activeClaim: activeClaim, requestID: heldID))

        let helping = AppRoute.enteringHeldRequest(activeClaim, from: detailPath)

        XCTAssertEqual(helping, [.fulfillment(activeClaim.request)])
        XCTAssertFalse(containsDetail(helping, requestID: heldID))
        guard case .fulfillment(let request)? = helping.last else {
            return XCTFail("expected Helping on top, got \(helping)")
        }
        // Helping carries the confirmed claim's own request, not the
        // pre-claim copy the detail was opened with.
        XCTAssertEqual(request.mealSwipes, 4)

        XCTAssertEqual(back(from: helping), [], "Back from Helping returns Home")
    }

    /// The same rule from the Active Requests list: Back lands on the list
    /// that preceded Request Detail.
    func testSuccessfulClaimFromActiveRequestsBacksToActiveRequests() async throws {
        let store = try await makeStoreHolding(heldID)
        let activeClaim = try XCTUnwrap(store.activeClaim)
        let detailPath: [AppRoute] = [.requestDetail(foodRequest(id: heldID))]

        let helping = AppRoute.enteringHeldRequest(activeClaim, from: detailPath)

        XCTAssertEqual(helping, [.fulfillment(activeClaim.request)])
        XCTAssertEqual(back(from: helping), [])
    }

    /// Store state can republish while Helping is already showing; applying
    /// the rule again never stacks a second Helping or restores the detail.
    func testEnteringTheHeldRequestIsIdempotentAndDropsAnyStaleHeldDestinations() async throws {
        let store = try await makeStoreHolding(heldID)
        let activeClaim = try XCTUnwrap(store.activeClaim)
        let held = activeClaim.request
        let unrelated = foodRequest(id: otherID)

        let once = AppRoute.enteringHeldRequest(activeClaim, from: [.requestDetail(held)])
        XCTAssertEqual(AppRoute.enteringHeldRequest(activeClaim, from: once), once)

        // A stack that still holds the pre-repair shape collapses to Helping.
        XCTAssertEqual(
            AppRoute.enteringHeldRequest(
                activeClaim,
                from: [.requestDetail(held), .fulfillment(held)]
            ),
            [.fulfillment(held)]
        )

        // Destinations for other requests beneath are untouched.
        XCTAssertEqual(
            AppRoute.enteringHeldRequest(
                activeClaim,
                from: [.requestDetail(unrelated), .requestDetail(held)]
            ),
            [.requestDetail(unrelated), .fulfillment(held)]
        )
    }

    /// The detail screen applies exactly that rule — replacement, not a push
    /// on top of itself — for a newly confirmed claim and, via
    /// `initial: true`, for a detail ever opened on an already-held request.
    func testRequestDetailReplacesItselfWithHelpingOnConfirmedClaim() throws {
        let source = try appSource("Views/RequestDetailView.swift")
        let onChange = try slice(
            of: source,
            from: ".onChange(of: store.activeClaim?.requestID, initial: true)",
            to: ".sheet(isPresented: isPresentingVerification)"
        )
        XCTAssertTrue(onChange.contains("Self.opensClaimedFlow(activeClaim: activeClaim, requestID: request.id)"))
        XCTAssertTrue(onChange.contains("path.contains(.requestDetail(request))"))
        XCTAssertTrue(onChange.contains("path = AppRoute.enteringHeldRequest(activeClaim, from: path)"))
        XCTAssertFalse(onChange.contains("AppRoute.appending("), "a confirmed claim must not push Helping above the detail")
    }

    // MARK: - Request Detail is pre-claim only

    func testRequestDetailHasNoActiveReservationPresentation() throws {
        let source = try appSource("Views/RequestDetailView.swift")
        for retired in [
            "Continue helping with this request",
            "continueHelpingLink",
            "continueHelpingTitle",
            "claim-continue",
            "reservedUntilText",
            "Reserved until",
            "extendActiveClaim",
            "releaseActiveClaim",
            "Open Grubhub",
            "store.fulfillWithFixtureScreenshot(",
            "isShowingReservationWarning",
            "Finish helping"
        ] {
            XCTAssertFalse(source.contains(retired), "\(retired) must not appear on Request Detail")
        }

        // A held request renders no action at all for the frame before the
        // replacement lands: no continuation state and no claim action.
        let heldBranch = try slice(
            of: source,
            from: "if Self.opensClaimedFlow(activeClaim: store.activeClaim, requestID: request.id) {",
            to: "} else if currentOwnership == .own {"
        )
        XCTAssertTrue(heldBranch.contains("EmptyView()"))
        XCTAssertFalse(heldBranch.contains("NavigationLink"))
        XCTAssertFalse(heldBranch.contains("claimSection"))
    }

    func testNoAppSourceRetainsTheContinueHelpingWithThisRequestState() throws {
        for file in try allAppSwiftFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(
                source.contains("Continue helping with this request"),
                file.lastPathComponent
            )
        }
    }

    // MARK: - Held-request re-entry

    /// Home's board and the Active Requests list share one filter: the held
    /// request is never offered as a row that could open Request Detail,
    /// while every unrelated open request still is.
    func testBoardAndListNeverOfferTheHeldRequestAsARequestDetailRow() {
        let held = foodRequest(id: heldID)
        let unrelated = foodRequest(id: otherID)

        let offered = HelperRequestPresentation.availableRequests(
            [held, unrelated],
            activeClaimRequestID: heldID
        )

        XCTAssertEqual(offered.map(\.id), [otherID])
        XCTAssertEqual(
            HelperRequestPresentation.availableRequests([held, unrelated], activeClaimRequestID: nil).map(\.id),
            [heldID, otherID]
        )
    }

    /// Home's live board over a real store: after claiming a fetched request,
    /// it is no longer a board row, while the unrelated request still is.
    func testHomeBoardDropsTheHeldRequestOnceClaimed() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: Data("""
        {"requests": [\(requestObject(id: heldID, status: "open")), \(requestObject(id: otherID, status: "open"))]}
        """.utf8)))
        await store.fetchRequests()
        guard case .populated(let before) = HomeExchangeView.boardState(store: store) else {
            return XCTFail("expected a populated board")
        }
        XCTAssertEqual(before.map(\.id), [heldID, otherID])

        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(requestID: heldID)))
        try await store.claim(requestID: heldID)

        guard case .populated(let after) = HomeExchangeView.boardState(store: store) else {
            return XCTFail("expected a populated board")
        }
        XCTAssertEqual(after.map(\.id), [otherID])
    }

    /// Every in-app entry that names the held request opens Helping directly:
    /// Home `Continue Helping`, the pinned Active Requests reservation item,
    /// and the board/list rows, which come from the shared filter above.
    func testEveryHeldRequestEntryRoutesToHelping() throws {
        let home = try appSource("Views/HomeExchangeView.swift")
        let continueHelping = try slice(
            of: home,
            from: "private var continueHelpingSection: some View {",
            to: "// MARK: - Your request(s)"
        )
        // W4-R3: every continuation renders through one card link; the active
        // claim opens Helping and each waiting placement opens its own detail.
        XCTAssertTrue(continueHelping.contains("store.helperContinuationItems()"))
        XCTAssertTrue(continueHelping.contains("HelperContinuationCardLink(item: item, isHomePresentation: true)"))
        let cardLink = try appSource("Views/HelperContinuationsListView.swift")
        let activeCase = try slice(
            of: cardLink,
            from: "case .active(let claim):",
            to: "case .waiting(let placement):"
        )
        XCTAssertTrue(activeCase.contains("NavigationLink(value: AppRoute.fulfillment(claim.request))"))
        XCTAssertFalse(activeCase.contains("requestDetail"))
        XCTAssertTrue(cardLink.contains("NavigationLink(value: AppRoute.helperWaiting(requestID: placement.id))"))
        XCTAssertFalse(cardLink.contains("AppRoute.requestDetail"))

        let board = try slice(
            of: home,
            from: "private func populatedBoard(_ requests: [FoodRequest]) -> some View {",
            to: "private var loadingState: some View {"
        )
        XCTAssertTrue(board.contains("Self.partitionByOwnership(requests).needsHelp"))
        XCTAssertTrue(home.contains("requests: HelperRequestPresentation.availableRequests("))

        // W4-R5 retired Active Requests, whose pinned reservation item and
        // list rows used to be proven here. Home's `Continue Helping` above is
        // now the one entry, and no legacy destination remains to enter by.
        let routes = try appSource("Navigation/AppRoute.swift")
        XCTAssertFalse(routes.contains("case activeRequests"))
    }

    /// Any detail that still reaches the stack for the held request is
    /// replaced by Helping, so it can never present that request.
    func testADetailOpenedForTheHeldRequestBecomesHelping() async throws {
        let store = try await makeStoreHolding(heldID)
        let activeClaim = try XCTUnwrap(store.activeClaim)
        let staleRow = foodRequest(id: heldID)

        XCTAssertEqual(
            AppRoute.enteringHeldRequest(activeClaim, from: [.ownRequests([]), .requestDetail(staleRow)]),
            [.ownRequests([]), .fulfillment(activeClaim.request)]
        )
    }

    // MARK: - Unrelated requests

    func testAnUnrelatedRequestStillOpensRequestDetail() async throws {
        let store = try await makeStoreHolding(heldID)
        let activeClaim = try XCTUnwrap(store.activeClaim)

        XCTAssertFalse(RequestDetailView.opensClaimedFlow(activeClaim: activeClaim, requestID: otherID))
        XCTAssertFalse(RequestDetailView.opensClaimedFlow(activeClaim: nil, requestID: otherID))
        XCTAssertEqual(
            AppRoute.appending(.requestDetail(foodRequest(id: otherID)), to: []),
            [.requestDetail(foodRequest(id: otherID))]
        )
    }

    /// An open request tapped from a notification still opens its detail,
    /// even while a different request is held, and consults no continuation.
    func testAnOpenNotificationRequestStillOpensDetailWhileAnotherIsHeld() async throws {
        let store = try await makeStoreHolding(heldID)
        let router = tap(otherID)
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(id: otherID, status: "open")))
        let pathsBefore = ClaimFlowURLProtocol.capturedPaths

        let resolved = await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)
        let path = try XCTUnwrap(resolved)

        XCTAssertEqual(path.count, 1)
        guard case .requestDetail(let request)? = path.last else {
            return XCTFail("expected Request Detail, got \(path)")
        }
        XCTAssertEqual(request.id, otherID)
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, pathsBefore + ["/api/request/\(otherID)"])
        XCTAssertNil(store.claimUnavailableNotice)
        XCTAssertNil(router.pendingRequestID)
    }

    // MARK: - Helper new-request notification for the held request

    /// Backgrounded case: the claim is still in memory.
    func testHeldRequestTapRoutesToHelpingFromTheInProcessClaim() async throws {
        let store = try await makeStoreHolding(heldID)
        let router = tap(heldID)
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(id: heldID, status: "claimed")))

        let resolved = await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)
        let path = try XCTUnwrap(resolved)

        let activeClaim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(path, [.fulfillment(activeClaim.request)])
        XCTAssertFalse(containsDetail(path, requestID: heldID))
        XCTAssertNil(store.claimUnavailableNotice, "no recovery notice for the held request")
        XCTAssertNil(router.pendingRequestID)
        XCTAssertEqual(back(from: path), [])
    }

    /// Terminated-launch case: continuation truth restores the reservation.
    func testHeldRequestTapRoutesToHelpingAfterContinuationConfirmsIt() async throws {
        let store = makeStore()
        let router = tap(heldID)
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(id: heldID, status: "claimed")))
        ClaimFlowURLProtocol.enqueue(.response(data: activeReservationResponse(requestID: heldID)))

        let resolved = await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)
        let path = try XCTUnwrap(resolved)

        let activeClaim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(activeClaim.requestID, heldID)
        XCTAssertEqual(path, [.fulfillment(activeClaim.request)])
        XCTAssertNil(store.claimUnavailableNotice)
        XCTAssertNil(router.pendingRequestID)
    }

    func testNotOpenTapWithNoReservationKeepsNoLongerAvailable() async throws {
        let store = makeStore()
        let router = tap(heldID)
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(id: heldID, status: "claimed")))
        ClaimFlowURLProtocol.enqueue(.response(data: Data(#"{"reservation":null}"#.utf8)))

        let path = await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)

        XCTAssertEqual(path, [])
        XCTAssertEqual(store.claimUnavailableNotice?.reason, .noLongerAvailable)
        XCTAssertEqual(store.claimUnavailableNotice?.requestID, heldID)
        XCTAssertNil(store.activeClaim, "absence never fabricates a reservation")
        XCTAssertNil(router.pendingRequestID)
    }

    func testNotOpenTapWhileHoldingADifferentRequestKeepsNoLongerAvailable() async throws {
        let store = try await makeStoreHolding(otherID)
        let router = tap(heldID)
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(id: heldID, status: "claimed")))

        let path = await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)

        XCTAssertEqual(path, [])
        XCTAssertEqual(store.claimUnavailableNotice?.reason, .noLongerAvailable)
        XCTAssertEqual(store.activeClaim?.requestID, otherID, "the other reservation is untouched")
    }

    func testNotOpenTapWhenContinuationNamesADifferentRequestKeepsNoLongerAvailable() async throws {
        let store = makeStore()
        let router = tap(heldID)
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(id: heldID, status: "claimed")))
        ClaimFlowURLProtocol.enqueue(.response(data: activeReservationResponse(requestID: otherID)))

        let path = await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)

        XCTAssertEqual(path, [])
        XCTAssertEqual(store.claimUnavailableNotice?.reason, .noLongerAvailable)
        XCTAssertEqual(store.activeClaim?.requestID, otherID)
    }

    /// Continuation truth that cannot be established uses the existing
    /// temporarily-unavailable recovery — never "gone", never a reservation.
    func testNotOpenTapWithUnknownContinuationUsesTemporarilyUnavailable() async throws {
        let store = makeStore()
        let router = tap(heldID)
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(id: heldID, status: "claimed")))
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))

        let path = await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)

        XCTAssertEqual(path, [])
        XCTAssertEqual(store.claimUnavailableNotice?.reason, .temporarilyUnavailable)
        XCTAssertNil(store.activeClaim)
        XCTAssertNil(router.pendingRequestID)
    }

    /// W4-R5: the detail read is verified-only, so a tap with no participant
    /// authority cannot be resolved at all. That is *unknown* — the existing
    /// temporarily-unavailable recovery — never a fabricated `no longer
    /// available`, and nothing is sent.
    func testNotOpenTapWithoutParticipantAuthorityIsTemporarilyUnavailableAndSendsNothing() async throws {
        let store = makeStore(authority: nil)
        let router = tap(heldID)

        let path = await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)

        XCTAssertEqual(path, [])
        XCTAssertEqual(store.claimUnavailableNotice?.reason, .temporarilyUnavailable)
        XCTAssertTrue(ClaimFlowURLProtocol.capturedPaths.isEmpty)
    }

    /// A cancelled held-request resolution is not an outcome: the tap stays
    /// pending for the next attempt and nothing is reported.
    func testCancelledHeldRequestResolutionLeavesTheTapPending() async throws {
        let resolver = CancellingHeldRequestResolver()
        let router = tap(heldID)

        let path = await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: resolver)

        XCTAssertNil(path)
        XCTAssertEqual(router.pendingRequestID, heldID)
        XCTAssertTrue(resolver.reports.isEmpty)
    }

    func testHeldResolutionPathContainsNoRequestDetail() {
        let held = foodRequest(id: heldID)
        XCTAssertEqual(
            AppRoute.afterNotificationResolution(.heldByCurrentHelper(held)),
            [.fulfillment(held)]
        )
    }

    // MARK: - Reservation warning (unchanged)

    /// The warning tap still builds Active Requests → Helping, so Back may
    /// return to Active Requests — never to a Request Detail.
    func testWarningTapStillBacksToActiveRequestsWithoutRequestDetail() async throws {
        let store = try await makeStoreHolding(heldID)
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: [
            "type": "reservation-warning",
            "requestId": heldID
        ])

        let resolved = await ReservationWarningRouteDriver.routeIfNeeded(router: router, resolver: store)
        let path = try XCTUnwrap(resolved)

        let activeClaim = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(path, [.fulfillment(activeClaim.request)])
        XCTAssertFalse(containsDetail(path, requestID: heldID))
        XCTAssertEqual(back(from: path), [])
    }

    func testForegroundWarningRouteIsUnchanged() throws {
        let contentView = try appSource("ContentView.swift")
        let warningRoute = try slice(
            of: contentView,
            from: ".onChange(of: requestStore.isShowingReservationWarning)",
            to: "// A requester-fulfillment tap resolves through R3"
        )
        // W4-R5: the foreground warning enters Helping in place (the former
        // `Active Requests -> Helping` rewrite, a deferred H1 defect, is gone
        // with that destination).
        XCTAssertTrue(warningRoute.contains("path = AppRoute.enteringHeldRequest(activeClaim, from: path)"))
        XCTAssertFalse(warningRoute.contains("activeRequests"))
    }

    /// The warning's destination is Helping itself, whatever is already open:
    /// already on Helping leaves the path alone, and Back from a warning raised
    /// elsewhere returns to the screen the helper was on, never a legacy list.
    func testForegroundWarningEntersHelpingInPlace() async throws {
        let store = try await makeStoreHolding(heldID)
        let activeClaim = try XCTUnwrap(store.activeClaim)
        let helping: [AppRoute] = [.fulfillment(activeClaim.request)]

        XCTAssertEqual(AppRoute.enteringHeldRequest(activeClaim, from: helping), helping)
        XCTAssertEqual(AppRoute.enteringHeldRequest(activeClaim, from: []), helping)
        XCTAssertEqual(
            AppRoute.enteringHeldRequest(activeClaim, from: [.settings]),
            [.settings, .fulfillment(activeClaim.request)]
        )
    }

    // MARK: - Reservation ending without placement (unchanged)

    /// Release, expiry, or lost reservation from the repaired stacks still
    /// unwinds to Active Requests, where its safety notice is presented.
    func testNonSuccessEndStillUnwindsToActiveRequestsFromRepairedStacks() {
        let held = foodRequest(id: heldID)
        let stacks: [[AppRoute]] = [
            [.fulfillment(held)],
            [.fulfillment(held)]
        ]
        for stack in stacks {
            for activeRequestID in [nil, otherID] {
                XCTAssertEqual(
                    FulfillRequestView.claimedFlowPath(
                        stack,
                        activeRequestID: activeRequestID,
                        confirmationRequestID: nil,
                        requestID: heldID
                    ),
                    [],
                    "\(stack) / \(String(describing: activeRequestID))"
                )
            }
            XCTAssertEqual(
                FulfillRequestView.claimedFlowPath(
                    stack,
                    activeRequestID: heldID,
                    confirmationRequestID: nil,
                    requestID: heldID
                ),
                stack
            )
            XCTAssertEqual(AppRoute.afterHelperSuccess(from: stack), [])
        }
    }

    // MARK: - Post-success Home return re-entry

    /// The Home return clears the path and then dismisses the confirmation,
    /// and the still-mounted Helping view reacts to that dismissal. With no
    /// claim and no confirmation, the already-cleared path must stay Home
    /// rather than being rebuilt as `[]`.
    func testClearedPathStaysHomeWhenConfirmationIsDismissedAfterSuccess() {
        XCTAssertEqual(
            FulfillRequestView.claimedFlowPath(
                [],
                activeRequestID: nil,
                confirmationRequestID: nil,
                requestID: heldID
            ),
            []
        )
    }

    /// A path with no helper destination for this request is not this
    /// request's flow to unwind.
    func testPathWithoutThisRequestsHelperDestinationIsLeftAlone() {
        let unrelated: [[AppRoute]] = [
            [.settings],
            [],
            [.fulfillment(foodRequest(id: otherID))],
            [.requestDetail(foodRequest(id: otherID))]
        ]
        for path in unrelated {
            for activeRequestID in [nil, otherID] {
                XCTAssertEqual(
                    FulfillRequestView.claimedFlowPath(
                        path,
                        activeRequestID: activeRequestID,
                        confirmationRequestID: nil,
                        requestID: heldID
                    ),
                    path,
                    "\(path) / \(String(describing: activeRequestID))"
                )
            }
        }
    }

    /// A request detail for this request still counts as its helper
    /// destination, so the non-success unwind is unchanged for it.
    func testRequestDetailForThisRequestStillUnwindsToActiveRequests() {
        let path: [AppRoute] = [.requestDetail(foodRequest(id: heldID))]
        XCTAssertEqual(
            FulfillRequestView.claimedFlowPath(
                path,
                activeRequestID: nil,
                confirmationRequestID: nil,
                requestID: heldID
            ),
            []
        )
    }

    /// Real store: claim → fulfill → the Home return clears the path and
    /// dismisses the confirmation → Helping's re-sync leaves the path Home.
    func testHomeReturnThenConfirmationDismissalKeepsPathHome() async throws {
        let store = try await makeStoreHolding(heldID)
        let held = try XCTUnwrap(store.activeClaim?.request)
        var path: [AppRoute] = [.fulfillment(held)]

        ClaimFlowURLProtocol.enqueue(.response(data: Data("""
        {
          "request": \(requestObject(id: heldID, status: "placed")),
          "notification": { "status": "sent" }
        }
        """.utf8)))
        try await store.fulfillWithFixtureScreenshot(
            requestID: heldID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )
        let confirmation = try XCTUnwrap(store.fulfillmentConfirmation)

        // While the confirmation is displayed, Helping leaves the path alone.
        path = FulfillRequestView.claimedFlowPath(
            path,
            activeRequestID: store.activeClaim?.requestID,
            confirmationRequestID: store.fulfillmentConfirmation?.requestID,
            requestID: heldID
        )
        XCTAssertEqual(path, [.fulfillment(held)])

        // ContentView's success return: replace the path, then dismiss.
        path = AppRoute.afterHelperSuccess(from: path)
        store.dismissFulfillmentConfirmation(id: confirmation.id)

        // Helping's onChange re-sync after the dismissal.
        path = FulfillRequestView.claimedFlowPath(
            path,
            activeRequestID: store.activeClaim?.requestID,
            confirmationRequestID: store.fulfillmentConfirmation?.requestID,
            requestID: heldID
        )

        XCTAssertEqual(path, [])
        XCTAssertNil(store.activeClaim)
        XCTAssertNil(store.fulfillmentConfirmation)
    }

    // MARK: - Helpers

    private func back(from path: [AppRoute]) -> [AppRoute] {
        Array(path.dropLast())
    }

    private func containsDetail(_ path: [AppRoute], requestID: String) -> Bool {
        path.contains { route in
            if case .requestDetail(let request) = route { return request.id == requestID }
            return false
        }
    }

    private func tap(_ requestID: String) -> HelperNotificationRouter {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: [
            "type": "new-request",
            "requestId": requestID
        ])
        return router
    }

    private func makeStore(
        authority: String? = "64c0000000000000000000a1.1.credential"
    ) -> RequestStore {
        RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { authority },
            participantAuthorityRejected: {}
        )
    }

    private func makeStoreHolding(_ requestID: String) async throws -> RequestStore {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(requestID: requestID)))
        try await store.claim(requestID: requestID)
        XCTAssertEqual(store.activeClaim?.requestID, requestID)
        return store
    }

    private func makeService() -> RequestService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaimFlowURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
        return RequestService(client: client)
    }

    private func foodRequest(id: String, mealSwipes: Int = 2) -> FoodRequest {
        FoodRequest(
            id: id,
            diningSpot: DiningSpot(name: "Crave NYU", address: nil),
            foodDescription: "Rice bowl",
            pickupWindowText: "ASAP",
            mealSwipes: mealSwipes,
            windowStart: nil,
            windowEnd: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 3_600),
            status: .open
        )
    }

    private func requestObject(id: String, status: String, mealSwipes: Int = 2) -> String {
        """
        {
          "id": "\(id)",
          "vendor": "Crave NYU",
          "food": "Rice bowl",
          "pickupWindowText": "ASAP",
          "mealSwipes": \(mealSwipes),
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

    private func detailResponse(id: String, status: String) -> Data {
        Data(#"{"request": \#(requestObject(id: id, status: status))}"#.utf8)
    }

    private func claimResponse(requestID: String, mealSwipes: Int = 2) -> Data {
        Data("""
        {
          "request": \(requestObject(id: requestID, status: "claimed", mealSwipes: mealSwipes)),
          "claim": {
            "pickupName": "Taylor",
            "claimToken": "claim-token",
            "claimExpiresAt": "\(iso8601String(Date().addingTimeInterval(15 * 60)))"
          }
        }
        """.utf8)
    }

    private func activeReservationResponse(requestID: String) -> Data {
        Data("""
        {
          "reservation": {
            "request": \(requestObject(id: requestID, status: "claimed")),
            "pickupName": "Taylor",
            "claimExpiresAt": "\(iso8601String(Date().addingTimeInterval(15 * 60)))",
            "claimExtendedAt": null
          }
        }
        """.utf8)
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func appSource(_ relativePath: String) throws -> String {
        try String(contentsOf: appDirectory().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func appDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
    }

    private func allAppSwiftFiles() throws -> [URL] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: appDirectory(), includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// The whitespace-normalized source strictly between `start` and the next
    /// `end`.
    private func slice(of source: String, from start: String, to end: String) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start), "missing marker: \(start)")
        let endRange = try XCTUnwrap(
            source.range(of: end, range: startRange.upperBound..<source.endIndex),
            "missing marker: \(end)"
        )
        return normalize(String(source[startRange.lowerBound..<endRange.lowerBound]))
    }

    private func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Resolves every tap as not open, then is cancelled while establishing
/// whether the request is held.
@MainActor
private final class CancellingHeldRequestResolver: HelperNotificationResolving {
    private(set) var reports: [String] = []

    func resolveHelperNotificationRequest(id: String) async throws -> HelperNotificationResolution {
        .unavailable
    }

    func resolveHeldRequestForNotification(requestID: String) async throws -> HeldRequestNotificationTruth {
        throw CancellationError()
    }

    func reportRequestUnavailableFromNotification(requestID: String) { reports.append(requestID) }
    func reportRequestNotYetAvailableFromNotification(requestID: String) { reports.append(requestID) }
    func reportRequestTemporarilyUnavailableFromNotification(requestID: String) { reports.append(requestID) }
}
