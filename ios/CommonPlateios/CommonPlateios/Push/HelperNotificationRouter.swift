//
//  HelperNotificationRouter.swift
//  CommonPlateios
//
// The `UNUserNotificationCenterDelegate` for helper new-request push (Week 3
// Day 6 tap-routing slice). Two responsibilities only:
//
// 1. Foreground presentation: helper/requester pushes keep their visible
//    system banner/sound. A valid reservation warning is suppressed only
//    while an actually active CommonPlate scene owns its in-app surface;
//    inactive scenes remain eligible for local presentation.
// 2. Capturing a tap (from background, or a cold launch) as one pending
//    `requestId` that `HelperNotificationRouteDriver` applies exactly once
//    when the app is ready to navigate. Held in memory only: this object is
//    created in `PushAppDelegate.init`, before
//    `application(_:willFinishLaunchingWithOptions:)` runs, so a launch-time
//    tap is captured before `ContentView` exists — no persistence beyond the
//    process's own lifetime is needed. Crucially it also survives *routing
//    attempts that did not finish*: it is retired only once a navigation
//    outcome has actually been applied, so a cold launch's first, cancelled
//    attempt cannot silently discard the tap. See
//    `markHelperIntentHandled(tapSequence:)`.
//
// This delegate never fabricates request availability from the payload —
// `requestId` is routing context only. Resolving whether the request is
// still open is `RequestStore.resolveHelperNotificationRequest(id:)`'s job.
//
// Also captures the requester-fulfillment tap intent
// (`RequesterFulfillmentNotificationPayload`). W4-N1 Increment B: a tap now
// resolves to the requester's exact placed order
// (`AppRoute.placedOrder(requestID:)`) instead of always opening Home with a
// generic one-time notice — `PlacedOrderDetailView` itself re-resolves
// current ownership/pickup truth and handles the not-open/not-found/
// unauthorized/unreachable cases, so this router's job is unchanged in
// kind: capture the tap, protect it across a cancelled cold-launch attempt,
// and let a later tap of any kind supersede it. It is kept as its own
// published pair (`pendingRequesterFulfillmentIntent`,
// `requesterFulfillmentRoutingGeneration`) for the same reason the
// reservation-warning intent is kept separate from the helper intent: three
// independently-triggered navigation intents, each retired only once its
// own outcome is actually applied.
//
// Each tap is a distinct navigation intent. The one shared sequence means a
// later tap of any kind supersedes an older unresolved intent.
//
// Independent review (Week 3 Day 6 Slice 6E) found a correctness defect, and
// a narrow independent re-review found the first fix still assigned tap
// authority too late: reading `latestTapSequence` from inside a consumer's
// `.task` closure — even "synchronously, before any `await`" — is not safe,
// because SwiftUI's own task-scheduling gap between "a tap advanced the
// counter" and "the closure actually starts running" is exactly where a
// further tap can advance the counter again. A closure that reads the
// counter at that point can misattribute a *later* tap's value to an
// *earlier* one it is still processing.
//
// The corrected rule, now applied uniformly to all three intent kinds: a
// tap's authority is decided the instant the router itself receives it,
// never later. Every valid tap claims the next value from the one shared
// `latestTapSequence` inside `handleUserActedOnNotification`, and that value
// is stored *with* the intent it belongs to. Consuming an intent later hands
// back that original, frozen value; nothing derives it from whatever the
// counter happens to read at consumption time. A pending intent of any kind
// is stale once *any* later tap of *any* kind has been captured.
//
// `TapAuthorityFence` is the one pure comparison every kind reduces to.
import Combine
import Foundation
import UserNotifications

/// Whether a value captured from the monotonic tap-authority counter at
/// intent-capture time is still current, given that counter's value read
/// again immediately before a navigation mutation. Pure and independently
/// testable apart from `ContentView`/SwiftUI or `HelperNotificationRouter`:
/// the one comparison Slice 6E's tap-ordering requirement reduces to, reused
/// for the helper, reservation-warning, and requester-fulfillment fences
/// alike, all against the one shared `latestTapSequence`. Equality means
/// "nothing that should supersede this intent has been captured since";
/// inequality means this intent is stale and must not mutate navigation.
enum TapAuthorityFence {
    static func isStillAuthoritative(capturedSequence: Int, currentSequence: Int) -> Bool {
        capturedSequence == currentSequence
    }
}

/// A captured tap's intent: the routing `requestId`, and this specific tap's
/// own claim on `latestTapSequence`, frozen the instant
/// `handleUserActedOnNotification` captures it. Shared by the helper,
/// reservation-warning, and requester-fulfillment intents alike.
///
/// Read without being cleared (`pendingHelperIntent`,
/// `pendingReservationWarningIntent`, `pendingRequesterFulfillmentIntent`),
/// and cleared only once the routing it describes has actually been applied
/// (`markHelperIntentHandled(tapSequence:)` and its two siblings). See those
/// methods for why reading and clearing must not be the same step.
struct HelperNotificationIntent: Equatable {
    let requestID: String
    let tapSequence: Int
    /// W4-R5: the content revision the tapped notification carried, if any.
    /// Unused by the reservation-warning and requester-fulfillment intents.
    var contentRevision: Int? = nil
}

@MainActor
final class HelperNotificationRouter: NSObject, ObservableObject {
    /// The one captured, not-yet-applied helper tap. `private(set)`, not
    /// `private`: reading it is safe and non-destructive by construction, and
    /// only `handleUserActedOnNotification` and `markHelperIntentHandled` may
    /// write it.
    @Published private(set) var pendingHelperIntent: HelperNotificationIntent?

    /// Advances only when a *new* tap intent is captured, never when one is
    /// retired. `ContentView` keys its resolution `.task(id:)` on this value
    /// instead of on `pendingRequestID` directly: retiring the intent clears
    /// it (see below), and if that clear were the same value driving the
    /// task's identity, the task would rewrite its own id mid-flight and
    /// SwiftUI would cancel its own in-flight backend resolution. Keeping
    /// "a new intent arrived" and "the pending intent was retired" as two
    /// separate published facts is what keeps retirement from being able to
    /// self-cancel the work it started.
    @Published private(set) var routingGeneration = 0

    /// The one captured, not-yet-applied reservation-warning tap (W3-H1).
    /// Reuses `HelperNotificationIntent`'s exact shape — a routing
    /// `requestId` plus a frozen `latestTapSequence` claim — because the
    /// routing need is identical: resolve current backend truth, then land
    /// on the one destination that answer implies. Kept as its own field
    /// rather than folded into `pendingHelperIntent`: the two intents route
    /// to different resolution logic (`resolveHelperNotificationRequest`'s
    /// "is this request still open" versus "do I still hold this exact
    /// reservation") and must retire independently.
    @Published private(set) var pendingReservationWarningIntent: HelperNotificationIntent?

    /// Same self-cancellation reasoning as `routingGeneration`, for the
    /// reservation-warning intent.
    @Published private(set) var reservationWarningRoutingGeneration = 0

    /// The one captured, not-yet-applied requester-fulfillment tap.
    @Published private(set) var pendingRequesterFulfillmentIntent: HelperNotificationIntent?
    /// Advances only when a new requester-fulfillment tap is captured.
    @Published private(set) var requesterFulfillmentRoutingGeneration = 0
    @Published private(set) var pendingPickupConfirmedIntent: HelperNotificationIntent?
    @Published private(set) var pickupConfirmedRoutingGeneration = 0
    private var presentedHelperPickupRequestID: String?

    func updateHelperPickupNoticePresentation(requestID: String?) {
        presentedHelperPickupRequestID = requestID
    }

    /// Every valid navigation tap claims the next value. Each route checks
    /// its captured value before applying a navigation outcome.
    @Published private(set) var latestTapSequence = 0
    private let deletionNotificationFence: ParticipantDeletionNotificationFence

    init(
        deletionNotificationFence: ParticipantDeletionNotificationFence =
            ParticipantDeletionNotificationFence(defaults: .standard)
    ) {
        self.deletionNotificationFence = deletionNotificationFence
        super.init()
    }

    func fenceForCompletedDeletion() {
        latestTapSequence += 1
        pendingHelperIntent = nil
        pendingReservationWarningIntent = nil
        pendingRequesterFulfillmentIntent = nil
        pendingPickupConfirmedIntent = nil
        routingGeneration += 1
        reservationWarningRoutingGeneration += 1
        requesterFulfillmentRoutingGeneration += 1
        pickupConfirmedRoutingGeneration += 1
        presentedHelperPickupRequestID = nil
    }

    /// Actual active-scene ownership supplied by `ContentView`. Defaulting to
    /// false is fail-open for local presentation during launch: until a real
    /// active scene says it owns the in-app warning, the delegate must not
    /// suppress the system surface merely because the process is alive.
    private var isApplicationSceneActive = false

    /// Non-nil exactly while a captured helper tap is waiting to be routed.
    /// Reading never clears: the intent is retired only by
    /// `markHelperIntentHandled(tapSequence:)`, once routing has actually
    /// been applied.
    var pendingRequestID: String? { pendingHelperIntent?.requestID }
    /// The pending helper tap's own frozen claim on `latestTapSequence` —
    /// see the type header for why this must never be read from
    /// `latestTapSequence` directly at routing time instead.
    var pendingRequestTapSequence: Int? { pendingHelperIntent?.tapSequence }

    /// Keeps the notification delegate on the same visibility truth as
    /// `RequestStore`: only `.active` owns in-app warning presentation;
    /// `.inactive` and `.background` do not.
    func updateApplicationSceneActivity(isActive: Bool) {
        isApplicationSceneActive = isActive
    }

    /// Main-actor decision used by the delegate callback and directly by its
    /// tests, so the exercised seam includes the router's current scene truth
    /// rather than only a caller-supplied Boolean.
    func foregroundPresentationOptions(
        userInfo: [AnyHashable: Any]
    ) -> UNNotificationPresentationOptions {
        if isApplicationSceneActive,
           let requestID = HelperPickupConfirmedNotificationPayloadParser.requestID(userInfo: userInfo),
           presentedHelperPickupRequestID == requestID {
            return []
        }
        return foregroundPresentationOptions(
            isReservationWarning:
                ReservationWarningNotificationPayloadParser.parse(userInfo: userInfo) != nil
        )
    }

    private func foregroundPresentationOptions(
        isReservationWarning: Bool
    ) -> UNNotificationPresentationOptions {
        guard isReservationWarning else {
            return [.banner, .list, .sound]
        }
        return isApplicationSceneActive ? [] : [.banner, .list, .sound]
    }

    /// The testable entry point: extracts the payload and records the
    /// pending route. Called by the `UNUserNotificationCenterDelegate` bridge
    /// below, and directly by tests, since `UNNotificationResponse` has no
    /// public initializer to construct one against.
    func handleUserActedOnNotification(userInfo: [AnyHashable: Any], deliveredAt: Date = .now) {
        guard !deletionNotificationFence.rejects(deliveredAt: deliveredAt) else { return }
        if let payload = HelperNotificationPayloadParser.parse(userInfo: userInfo) {
            latestTapSequence += 1
            pendingHelperIntent = HelperNotificationIntent(
                requestID: payload.requestID,
                tapSequence: latestTapSequence,
                contentRevision: payload.contentRevision
            )
            routingGeneration += 1
            return
        }
        if let payload = ReservationWarningNotificationPayloadParser.parse(userInfo: userInfo) {
            // Returning to an already-held reservation is a navigation intent
            // and supersedes any older pending tap.
            latestTapSequence += 1
            pendingReservationWarningIntent = HelperNotificationIntent(requestID: payload.requestID, tapSequence: latestTapSequence)
            reservationWarningRoutingGeneration += 1
            return
        }
        if let payload = RequesterFulfillmentNotificationPayloadParser.parse(userInfo: userInfo) {
            latestTapSequence += 1
            pendingRequesterFulfillmentIntent = HelperNotificationIntent(
                requestID: payload.requestID,
                tapSequence: latestTapSequence
            )
            requesterFulfillmentRoutingGeneration += 1
            return
        }
        if let requestID = HelperPickupConfirmedNotificationPayloadParser.requestID(userInfo: userInfo) {
            latestTapSequence += 1
            pendingPickupConfirmedIntent = HelperNotificationIntent(
                requestID: requestID, tapSequence: latestTapSequence
            )
            pickupConfirmedRoutingGeneration += 1
        }
    }

    /// Retires the pending helper intent, but only if the intent still
    /// standing is the very one identified by `tapSequence`. Deliberately
    /// leaves `routingGeneration` untouched — see its doc comment.
    ///
    /// This is the terminated-launch correction. Reading and clearing used to
    /// be one step (`consumePendingRequestID()`), performed *before* the
    /// awaited `GET /api/request/:id` that decides where the tap goes. That
    /// made the intent unrecoverable the moment the resolution did not finish:
    /// a launch-time routing attempt that SwiftUI cancels — which is exactly
    /// what a cold launch does while the scene and the `@StateObject`
    /// hierarchy are still being established — swallowed its own
    /// `CancellationError`, left `path` untouched, and had already destroyed
    /// the only record of the tap, so the relaunched attempt found nothing and
    /// the app simply stayed on Home. Background taps were unaffected because
    /// that view hierarchy already existed and the attempt was never
    /// cancelled.
    ///
    /// So the intent now survives an attempt that did not reach a navigation
    /// outcome, and only an attempt that actually applied one retires it. The
    /// `tapSequence` check is what keeps that from being a way to clobber a
    /// newer tap: a late attempt for an older tap finds the slot already
    /// holding a different intent and clears nothing. Retiring is idempotent,
    /// so a second attempt for the same tap cannot reopen an already-applied
    /// route.
    func markHelperIntentHandled(tapSequence: Int) {
        guard pendingHelperIntent?.tapSequence == tapSequence else {
            return
        }
        pendingHelperIntent = nil
    }

    /// The reservation-warning equivalent of `markHelperIntentHandled(tapSequence:)`;
    /// same reasoning and the same terminated-launch safety property applies.
    func markReservationWarningIntentHandled(tapSequence: Int) {
        guard pendingReservationWarningIntent?.tapSequence == tapSequence else {
            return
        }
        pendingReservationWarningIntent = nil
    }

    /// Retires the requester-fulfillment intent only after its destination
    /// has been applied. A stale attempt cannot clear a newer tap.
    func markRequesterFulfillmentIntentHandled(tapSequence: Int) {
        guard pendingRequesterFulfillmentIntent?.tapSequence == tapSequence else {
            return
        }
        pendingRequesterFulfillmentIntent = nil
    }

    func consumePickupConfirmedRoute() -> [AppRoute]? {
        guard let intent = pendingPickupConfirmedIntent else { return nil }
        pendingPickupConfirmedIntent = nil
        guard intent.tapSequence == latestTapSequence else { return nil }
        return []
    }
}

extension HelperNotificationRouter: UNUserNotificationCenterDelegate {
    /// Foreground presentation is payload-aware only for the W3-H1 local
    /// warning; this does not globally suppress existing push presentation.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        Task { @MainActor in
            completionHandler(
                self.foregroundPresentationOptions(
                    userInfo: userInfo
                )
            )
        }
    }

    /// A tap from background or terminated state. `completionHandler()` is
    /// called immediately — routing itself is asynchronous app state, not
    /// something the system needs to wait on.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let notification = response.notification
        let userInfo = notification.request.content.userInfo
        let deliveredAt = notification.date
        Task { @MainActor in
            self.handleUserActedOnNotification(userInfo: userInfo, deliveredAt: deliveredAt)
        }
        completionHandler()
    }
}
