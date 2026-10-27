//
//  HelperNotificationTerminatedLaunchRoutingTests.swift
//  CommonPlateiosTests
//
// The terminated-launch helper-tap defect, at the highest level an automated
// test can actually reach.
//
// Reproduced on a physical iPhone: CommonPlate force-quit, a helper
// new-request push delivered, the notification tapped, the app launched — and
// landed on Home instead of the tapped request. Foreground and background taps
// routed correctly, so the defect was never in the payload, the delegate, the
// backend resolution, or the destination mapping; all of those are already
// covered in `HelperNotificationRoutingTests`.
//
// What is different about a cold launch is that the tap is captured before the
// SwiftUI scene and its stores exist, and the first routing attempt can be
// cancelled while that hierarchy is still being established. The old code read
// and cleared the pending tap in one step *before* awaiting
// `GET /api/request/:id`, then swallowed the resulting `CancellationError` —
// so a cancelled first attempt destroyed the only record of the tap and left
// navigation at Home permanently, with no second attempt able to recover it.
//
// These tests drive `HelperNotificationRouteDriver` — the exact code
// `ContentView`'s `.task` and its scene-active retry both call — against a
// real `HelperNotificationRouter` and a real `RequestStore` over a stubbed
// transport, so the resolution rules under test are the production ones. The
// only thing simulated is the cancellation, which is the whole point.
//
// What no test here can establish: whether the OS actually delivers the
// launch-time `didReceive response:` callback to the delegate at all on a real
// terminated launch. `UNNotificationResponse` has no public initializer, so
// that boundary stays physical-device acceptance territory.
import Foundation
import XCTest
@testable import CommonPlateios

/// A resolver whose suspension point the test controls, so the orderings that
/// matter here — two attempts both past resolution, or one attempt cancelled
/// strictly *after* resolution completed — are established by coordination
/// rather than by hoping a `Task.yield()` lands in the right place.
///
/// Deliberately a double rather than the real `RequestStore`: the cases below
/// are about when the driver may act, not about how a backend response is
/// classified, and classification is already proven against a real store over
/// a stubbed transport elsewhere in this file. `@MainActor`, matching the
/// protocol, so every counter here is read and written on the same actor the
/// driver runs on.
@MainActor
final class ControlledHelperNotificationResolver: HelperNotificationResolving {
    var resolution: HelperNotificationResolution

    /// How many attempts entered resolution, and how many got all the way
    /// back out of it. The second is what proves an "after resolution" test
    /// really did reach that boundary.
    private(set) var startedResolutionCount = 0
    private(set) var completedResolutionCount = 0

    private(set) var unavailableReports: [String] = []
    private(set) var notYetAvailableReports: [String] = []
    private(set) var temporarilyUnavailableReports: [String] = []

    /// Every recovery notice this resolver was asked to produce, of any kind.
    var allReports: [String] {
        unavailableReports + notYetAvailableReports + temporarilyUnavailableReports
    }

    private var suspendedAttempts: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [(required: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(resolution: HelperNotificationResolution) {
        self.resolution = resolution
    }

    func resolveHelperNotificationRequest(id: String) async throws -> HelperNotificationResolution {
        await withCheckedContinuation { continuation in
            suspendedAttempts.append(continuation)
            startedResolutionCount += 1
            releaseArrivalWaiters()
        }
        completedResolutionCount += 1
        return resolution
    }

    /// Returns once `count` attempts are parked inside resolution — the
    /// barrier the overlapping-attempt and post-resolution cases both build
    /// on.
    func waitUntilAttemptsAreInsideResolution(_ count: Int) async {
        guard startedResolutionCount < count else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append((required: count, continuation: continuation))
        }
    }

    /// Lets every parked attempt return its resolution.
    func releaseAllResolutions() {
        let parked = suspendedAttempts
        suspendedAttempts = []
        parked.forEach { $0.resume() }
    }

    private func releaseArrivalWaiters() {
        let satisfied = arrivalWaiters.filter { startedResolutionCount >= $0.required }
        arrivalWaiters.removeAll { startedResolutionCount >= $0.required }
        satisfied.forEach { $0.continuation.resume() }
    }

    /// W4-H1: consulted only for an `.unavailable` resolution. Confirmed
    /// absence by default, so these timing cases keep the accepted
    /// `no longer available` outcome.
    var heldRequestTruth: HeldRequestNotificationTruth = .notHeld

    func resolveHeldRequestForNotification(requestID: String) async throws -> HeldRequestNotificationTruth {
        heldRequestTruth
    }

    func reportRequestUnavailableFromNotification(requestID: String) {
        unavailableReports.append(requestID)
    }

    func reportRequestNotYetAvailableFromNotification(requestID: String) {
        notYetAvailableReports.append(requestID)
    }

    func reportRequestTemporarilyUnavailableFromNotification(requestID: String) {
        temporarilyUnavailableReports.append(requestID)
    }
}

@MainActor
final class HelperNotificationTerminatedLaunchRoutingTests: XCTestCase {
    private let requestID = "cold-launch-request"

    override func tearDown() {
        HelperNotificationRoutingURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - The defect

    /// The regression test for the reported bug, in one piece: a tap arrives
    /// before anything is ready to route it, the first attempt is cancelled
    /// mid-flight, and the tap must *still* end up selecting that specific
    /// request rather than leaving the app on Home.
    func testATapCancelledBeforeReadinessStillRoutesToItsRequestOnTheNextAttempt() async throws {
        let router = HelperNotificationRouter()
        let store = makeStore()

        // The launch-time tap, captured by the router before any view exists.
        router.handleUserActedOnNotification(userInfo: [
            "type": "new-request",
            "requestId": requestID
        ])

        // Attempt one, cancelled the way SwiftUI cancels the root view's
        // `.task` while the scene is still being built. This class is
        // @MainActor, so the task body cannot begin until this scope
        // suspends; `cancel()` therefore lands before its first cancellation
        // check, matching the pattern in `HelperNotificationRoutingTests`.
        let cancelledAttempt = Task {
            await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)
        }
        cancelledAttempt.cancel()

        let cancelledResult = await cancelledAttempt.value
        XCTAssertNil(cancelledResult, "a cancelled attempt must not invent a destination")
        XCTAssertEqual(
            router.pendingRequestID,
            requestID,
            "this is the defect: a cancelled attempt must leave the tap pending, not destroy it"
        )

        // Attempt two: the rebuilt view's own `.task`, or the scene becoming
        // active. It must now reach the tapped request.
        HelperNotificationRoutingURLProtocol.enqueue(.response(data: detailResponse(status: "open")))
        let resolvedPath = await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)

        let path = try XCTUnwrap(resolvedPath, "the surviving tap must produce a destination")
        XCTAssertEqual(path.count, 1, "Home is the root; the tapped destination is the only route")
        guard case .requestDetail(let request) = try XCTUnwrap(path.last) else {
            return XCTFail("expected the tapped request's detail on top, got \(path)")
        }
        XCTAssertEqual(request.id, requestID)
        XCTAssertNotEqual(path, [], "landing on Home is the reported bug")
    }

    /// The same guarantee for a cancellation that lands *after* backend truth
    /// came back: the answer is real, but this attempt is not the one that
    /// will apply it, so it must not retire the tap either.
    ///
    /// The ordering is coordinated, not assumed. The attempt is parked inside
    /// resolution; only once it is provably there does the test cancel it and
    /// then let resolution return, so execution is guaranteed to arrive at
    /// the driver's post-resolution cancellation check with a completed
    /// resolution behind it. `completedResolutionCount` is asserted for
    /// exactly that reason: without it this test would still pass if
    /// cancellation had short-circuited the resolution instead, which is the
    /// *other* case and is covered separately above.
    func testATapCancelledAfterResolutionCompletedIsStillPendingForTheNextAttempt() async throws {
        let router = HelperNotificationRouter()
        let resolver = ControlledHelperNotificationResolver(resolution: .unavailable)
        router.handleUserActedOnNotification(userInfo: [
            "type": "new-request",
            "requestId": requestID
        ])

        let attempt = Task {
            await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: resolver)
        }
        await resolver.waitUntilAttemptsAreInsideResolution(1)

        attempt.cancel()
        resolver.releaseAllResolutions()
        let result = await attempt.value

        XCTAssertEqual(
            resolver.completedResolutionCount,
            1,
            "the test must actually reach the post-resolution boundary, not cancel before it"
        )
        XCTAssertNil(result, "a cancelled attempt must not apply a destination")
        XCTAssertEqual(resolver.allReports, [], "a cancelled attempt must not queue a recovery notice")
        XCTAssertEqual(
            router.pendingRequestID,
            requestID,
            "an attempt that could not apply its outcome must leave the tap pending"
        )
    }

    // MARK: - Exclusive ownership across overlapping attempts
    //
    // `ContentView` starts helper routing from two independent triggers — the
    // root `.task(id:)` and scene activation — so two attempts can be in
    // flight against one captured tap. Retirement deliberately advances no
    // counter, so the tap-sequence fence stays satisfied for both of them;
    // only exact-intent ownership can decide between them.

    func testTwoOverlappingAttemptsApplyOneAvailableTapExactlyOnce() async throws {
        let router = HelperNotificationRouter()
        let resolver = ControlledHelperNotificationResolver(resolution: .available(makeRequest()))
        router.handleUserActedOnNotification(userInfo: [
            "type": "new-request",
            "requestId": requestID
        ])

        let first = Task { await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: resolver) }
        let second = Task { await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: resolver) }
        await resolver.waitUntilAttemptsAreInsideResolution(2)
        resolver.releaseAllResolutions()

        let results = [await first.value, await second.value]
        XCTAssertEqual(resolver.startedResolutionCount, 2, "both attempts must really have begun against one intent")
        let applied = results.compactMap { $0 }
        XCTAssertEqual(applied.count, 1, "exactly one attempt may produce a routing result")
        let path = try XCTUnwrap(applied.first)
        XCTAssertEqual(path.count, 1, "Home is the root; the tapped destination is the only route")
        guard case .requestDetail(let request) = try XCTUnwrap(path.last) else {
            return XCTFail("expected the tapped request's detail on top, got \(path)")
        }
        XCTAssertEqual(request.id, requestID)
        XCTAssertNil(router.pendingRequestID, "the intent must be retired exactly once, by the winner")
    }

    /// The user-visible half of the same guarantee: a recovery notice is a
    /// duplicate-able effect, so at most one may be produced for one tap.
    func testTwoOverlappingAttemptsProduceAtMostOneRecoveryNotice() async throws {
        let router = HelperNotificationRouter()
        let resolver = ControlledHelperNotificationResolver(resolution: .unavailable)
        router.handleUserActedOnNotification(userInfo: [
            "type": "new-request",
            "requestId": requestID
        ])

        let first = Task { await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: resolver) }
        let second = Task { await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: resolver) }
        await resolver.waitUntilAttemptsAreInsideResolution(2)
        resolver.releaseAllResolutions()

        let results = [await first.value, await second.value]
        XCTAssertEqual(results.compactMap { $0 }, [[]], "exactly one recovery route")
        XCTAssertEqual(resolver.unavailableReports, [requestID], "exactly one recovery notice")
        XCTAssertEqual(resolver.allReports.count, 1)
        XCTAssertNil(router.pendingRequestID)
    }

    /// The losing attempt must be inert, not merely late: it applies nothing
    /// even though it holds a complete, valid resolution, so it can never
    /// reapply navigation over whatever happened after the winner.
    func testTheLosingOverlappingAttemptAppliesNothingEvenAfterTheWinnerFinished() async throws {
        let router = HelperNotificationRouter()
        let resolver = ControlledHelperNotificationResolver(resolution: .temporarilyUnavailable)
        router.handleUserActedOnNotification(userInfo: [
            "type": "new-request",
            "requestId": requestID
        ])

        // Staggered rather than simultaneous: the second attempt begins only
        // once the first is provably already inside resolution, and still
        // snapshots the same live intent — the exact shape of `.task` and
        // scene activation overlapping.
        let earlier = Task { await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: resolver) }
        await resolver.waitUntilAttemptsAreInsideResolution(1)
        let later = Task { await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: resolver) }
        await resolver.waitUntilAttemptsAreInsideResolution(2)
        resolver.releaseAllResolutions()

        let earlierResult = await earlier.value
        let laterResult = await later.value
        XCTAssertEqual(resolver.completedResolutionCount, 2, "both attempts must have obtained a resolution")
        XCTAssertEqual([earlierResult, laterResult].compactMap { $0 }.count, 1)
        XCTAssertEqual(resolver.temporarilyUnavailableReports, [requestID], "no duplicated recovery notice")
        XCTAssertNil(router.pendingRequestID)
    }

    /// Ownership must be by exact intent, not by request id: an attempt that
    /// began against an older tap must neither retire nor act on the newer
    /// tap that replaced it — even when both taps name the same request.
    func testAnOlderAttemptCannotRetireOrActOnTheNewerTapThatReplacedIt() async throws {
        let router = HelperNotificationRouter()
        let resolver = ControlledHelperNotificationResolver(resolution: .available(makeRequest()))
        router.handleUserActedOnNotification(userInfo: [
            "type": "new-request",
            "requestId": requestID
        ])

        let olderAttempt = Task {
            await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: resolver)
        }
        await resolver.waitUntilAttemptsAreInsideResolution(1)
        // A second helper tap for the same request lands while the older
        // attempt is parked, taking the slot with its own fresh sequence.
        router.handleUserActedOnNotification(userInfo: [
            "type": "new-request",
            "requestId": requestID
        ])
        let newerTapSequence = try XCTUnwrap(router.pendingRequestTapSequence)
        resolver.releaseAllResolutions()

        let olderResult = await olderAttempt.value

        XCTAssertNil(olderResult, "an older attempt must not apply a route for a tap it no longer owns")
        XCTAssertEqual(resolver.allReports, [], "and must not queue a notice for it either")
        XCTAssertEqual(router.pendingRequestID, requestID, "the newer tap must survive, unrouted")
        XCTAssertEqual(
            router.pendingRequestTapSequence,
            newerTapSequence,
            "the newer tap must still be the exact intent standing, not one retired by the older attempt"
        )
    }

    // MARK: - Normal routing is unchanged

    func testAnOpenRequestRoutesHomeRootedToItsDetailAndRetiresTheTap() async throws {
        let router = HelperNotificationRouter()
        let store = makeStore()
        router.handleUserActedOnNotification(userInfo: [
            "type": "new-request",
            "requestId": requestID
        ])
        HelperNotificationRoutingURLProtocol.enqueue(.response(data: detailResponse(status: "open")))

        let resolvedPath = await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)

        let path = try XCTUnwrap(resolvedPath)
        XCTAssertEqual(path.count, 1, "Home is the root; the tapped destination is the only route")
        XCTAssertNil(router.pendingRequestID, "an applied tap must be retired")
    }

    /// Exactly-once: once a tap has actually been applied, a further attempt
    /// must not replay it.
    func testAnAppliedTapIsNotReplayedByALaterAttempt() async throws {
        let router = HelperNotificationRouter()
        let store = makeStore()
        router.handleUserActedOnNotification(userInfo: [
            "type": "new-request",
            "requestId": requestID
        ])
        HelperNotificationRoutingURLProtocol.enqueue(.response(data: detailResponse(status: "open")))
        _ = await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)

        let replay = await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)

        XCTAssertNil(replay, "a second attempt must find nothing to apply")
    }

    func testNothingPendingProducesNoDestination() async {
        let router = HelperNotificationRouter()
        let store = makeStore()

        let resolvedPath = await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)

        XCTAssertNil(resolvedPath)
    }

    /// A backend-confirmed non-open request still recovers to Active Requests
    /// with its accepted notice — the cancellation fix must not have turned
    /// every non-`available` outcome into "leave navigation alone".
    func testAnUnavailableRequestStillRecoversToActiveRequestsWithItsNotice() async throws {
        let router = HelperNotificationRouter()
        let store = makeStore()
        router.handleUserActedOnNotification(userInfo: [
            "type": "new-request",
            "requestId": requestID
        ])
        HelperNotificationRoutingURLProtocol.enqueue(.response(data: detailResponse(status: "claimed")))
        // W4-H1: continuation truth confirms this helper holds no reservation.
        HelperNotificationRoutingURLProtocol.enqueue(.response(data: Data(#"{"reservation":null}"#.utf8)))

        let resolvedPath = await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)

        XCTAssertEqual(resolvedPath, [])
        let notice = try XCTUnwrap(store.claimUnavailableNotice)
        XCTAssertEqual(notice.requestID, requestID)
        XCTAssertEqual(notice.reason, .noLongerAvailable)
        XCTAssertNil(router.pendingRequestID)
    }

    /// Inconclusive truth still recovers with the distinct "try again"
    /// notice, and — unlike a cancelled attempt — is a real outcome, so it
    /// retires the tap rather than retrying forever.
    func testATemporarilyUnavailableResultRecoversAndRetiresTheTap() async throws {
        let router = HelperNotificationRouter()
        let store = makeStore()
        router.handleUserActedOnNotification(userInfo: [
            "type": "new-request",
            "requestId": requestID
        ])
        HelperNotificationRoutingURLProtocol.enqueue(.failure(.networkConnectionLost))

        let resolvedPath = await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)

        XCTAssertEqual(resolvedPath, [])
        XCTAssertEqual(store.claimUnavailableNotice?.reason, .temporarilyUnavailable)
        XCTAssertNil(router.pendingRequestID)
    }

    // MARK: - Tap-order authority is preserved

    /// The accepted fence still holds: an older tap whose resolution comes
    /// back after a newer tap was captured must not touch navigation, and
    /// must not queue a notice.
    func testAnOlderTapSupersededByANewerOneAppliesNothing() async throws {
        let router = HelperNotificationRouter()
        let store = makeStore()
        router.handleUserActedOnNotification(userInfo: [
            "type": "new-request",
            "requestId": requestID
        ])
        // A later requester-fulfillment tap advances the shared counter
        // without taking the helper slot, which is what makes the older
        // helper tap's frozen claim lose the fence while it is still pending.
        router.handleUserActedOnNotification(userInfo: [
            "type": "requester-order-placed", "requestId": "64c0000000000000000000a1"
        ])
        HelperNotificationRoutingURLProtocol.enqueue(.response(data: detailResponse(status: "open")))

        let resolvedPath = await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)

        XCTAssertNil(resolvedPath, "a superseded tap must not overwrite newer navigation intent")
        XCTAssertNil(store.claimUnavailableNotice)
        XCTAssertNil(router.pendingRequestID, "a superseded tap is retired, not left to fire later")
    }

    // MARK: - Requester-fulfillment routing remains separate

    /// The helper driver never consumes a requester-fulfillment tap; its
    /// own route carries the exact request id to R3's placed-order screen.
    func testRequesterFulfillmentTapArmsOnlyItsPlacedOrderIntent() async {
        let router = HelperNotificationRouter()
        let store = makeStore()

        router.handleUserActedOnNotification(userInfo: [
            "type": "requester-order-placed",
            "requestId": "64c0000000000000000000a1"
        ])

        XCTAssertNil(router.pendingRequestID)
        XCTAssertEqual(router.routingGeneration, 0)
        XCTAssertEqual(router.pendingRequesterFulfillmentIntent?.requestID, "64c0000000000000000000a1")
        XCTAssertEqual(router.requesterFulfillmentRoutingGeneration, 1)

        let resolvedPath = await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)

        XCTAssertNil(resolvedPath, "the helper driver must never consume a requester intent")
        XCTAssertEqual(router.pendingRequesterFulfillmentIntent?.requestID, "64c0000000000000000000a1")
    }

    /// A helper tap captured after a requester tap makes the older requester
    /// intent stale; retiring it cannot affect the helper route.
    func testLaterHelperTapSupersedesRequesterPlacedOrderIntent() async throws {
        let router = HelperNotificationRouter()
        let store = makeStore()
        router.handleUserActedOnNotification(userInfo: [
            "type": "requester-order-placed",
            "requestId": "64c0000000000000000000a1"
        ])
        let requesterIntent = try XCTUnwrap(router.pendingRequesterFulfillmentIntent)
        router.handleUserActedOnNotification(userInfo: [
            "type": "new-request",
            "requestId": requestID
        ])
        HelperNotificationRoutingURLProtocol.enqueue(.response(data: detailResponse(status: "open")))

        _ = await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)

        XCTAssertNil(router.pendingRequestID)
        XCTAssertFalse(TapAuthorityFence.isStillAuthoritative(
            capturedSequence: requesterIntent.tapSequence,
            currentSequence: router.latestTapSequence
        ))
        router.markRequesterFulfillmentIntentHandled(tapSequence: requesterIntent.tapSequence)
        XCTAssertNil(router.pendingRequesterFulfillmentIntent)
    }

    // MARK: - Helpers

    /// The request a controlled `.available` resolution carries, matching the
    /// id the taps in these cases name.
    private func makeRequest() -> FoodRequest {
        FoodRequest(
            id: requestID,
            diningSpot: DiningSpot(name: "Crave NYU", address: nil),
            foodDescription: "Rice bowl",
            pickupWindowText: "ASAP",
            mealSwipes: 2,
            windowStart: nil,
            windowEnd: nil,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(5 * 60 * 60),
            status: .open
        )
    }

    private func makeStore() -> RequestStore {
        RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            // W3-I1: a verified participant, so the gate is not what these
            // cases are proving.
            participantAuthorityProvider: { "64c0000000000000000000a1.1.credential" },
            participantAuthorityRejected: {}
        )
    }

    private func makeService() -> RequestService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HelperNotificationRoutingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return RequestService(client: client)
    }

    private func detailResponse(status: String) -> Data {
        Data("""
        {
          "request": {
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
        }
        """.utf8)
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
