//
//  ReservationWarningRouteDriver.swift
//  CommonPlateios
//
// One reservation-warning notification tap turned into one navigation
// outcome (W3-H1), mirroring `HelperNotificationRouteDriver` — including the
// terminated-launch fix: a captured tap is retired only once its navigation
// outcome has actually been produced, so an attempt SwiftUI cancels before
// that (the cold-launch case) leaves the intent for the next attempt to find.
//
// The one real difference from the helper driver: there is no `requestId` to
// resolve against `GET /api/request/:id`, because "is this request still
// open" is not the question. The question is "do I still hold this exact
// reservation", which is `continueActiveReservationIfNeeded()`'s job — the
// same read `ContentView`'s own launch-time `.task` already performs, called
// again here so this driver is self-contained and correct even if that
// separate call has not finished yet.
import Foundation

/// What the driver needs from `RequestStore`: its current in-memory active
/// claim, the same continuation read `RequestStore` already exposes, and the
/// existing "gone" recovery notice every other notification-resolution
/// outcome in this app already uses.
@MainActor
protocol ReservationWarningResolving: AnyObject {
    var activeClaim: ActiveClaimPresentation? { get }
    func continueActiveReservationIfNeeded() async throws -> ActiveReservationContinuationOutcome
    func reportRequestUnavailableFromNotification(requestID: String)
    func reportRequestTemporarilyUnavailableFromNotification(requestID: String)
}

extension RequestStore: ReservationWarningResolving {}

@MainActor
enum ReservationWarningRouteDriver {
    /// Resolves the router's pending reservation-warning tap, if there is
    /// one, and returns the navigation path it should produce — or `nil` to
    /// leave navigation untouched, for the same three reasons
    /// `HelperNotificationRouteDriver.routeIfNeeded` documents: nothing
    /// pending, an attempt cancelled before or after resolving, or a later
    /// tap of either kind having superseded this one.
    static func routeIfNeeded(
        router: HelperNotificationRouter,
        resolver: some ReservationWarningResolving
    ) async -> [AppRoute]? {
        guard let intent = router.pendingReservationWarningIntent else {
            return nil
        }

        // Already resolved in-process (the common case: the app was merely
        // backgrounded, not terminated, so `activeClaim` never left memory)
        // — nothing to await. Otherwise, resolve current backend truth the
        // same way a cold launch's continuation does.
        let outcome: ActiveReservationContinuationOutcome
        if let activeClaim = resolver.activeClaim {
            outcome = .active(activeClaim)
        } else {
            do {
                outcome = try await resolver.continueActiveReservationIfNeeded()
            } catch is CancellationError {
                return nil
            } catch {
                outcome = .unknown
            }
        }

        guard !Task.isCancelled else {
            return nil
        }

        // The exclusive claim — see `HelperNotificationRouteDriver` for why
        // identity, not just the tap-sequence fence, has to be re-checked
        // here before any effect runs.
        guard router.pendingReservationWarningIntent == intent else {
            return nil
        }

        guard TapAuthorityFence.isStillAuthoritative(
            capturedSequence: intent.tapSequence,
            currentSequence: router.latestTapSequence
        ) else {
            router.markReservationWarningIntentHandled(tapSequence: intent.tapSequence)
            return nil
        }

        switch outcome {
        case .active(let activeClaim):
            router.markReservationWarningIntentHandled(tapSequence: intent.tapSequence)
            guard activeClaim.requestID == intent.requestID else {
                // The payload names the reservation whose warning fired. If
                // backend truth now names another reservation, the old warning
                // is stale; it cannot borrow the newer reservation's route.
                // Reuse the established ended-request recovery and copy.
                resolver.reportRequestUnavailableFromNotification(requestID: intent.requestID)
                return []
            }
            return [.fulfillment(activeClaim.request)]
        case .none:
            // The reservation ended (expired, released, or fulfilled through
            // some other path) between the notification firing and the tap.
            // Continuation established that absence authoritatively and also
            // retired the participant's stale reservation-warning namespace.
            router.markReservationWarningIntentHandled(tapSequence: intent.tapSequence)
            resolver.reportRequestUnavailableFromNotification(requestID: intent.requestID)
            return []
        case .unknown:
            // Transport/server/decode failure proves neither absence nor an
            // active reservation. Apply the existing bounded recovery notice,
            // never the "gone" notice, and leave warning state untouched.
            router.markReservationWarningIntentHandled(tapSequence: intent.tapSequence)
            resolver.reportRequestTemporarilyUnavailableFromNotification(requestID: intent.requestID)
            return []
        }
    }
}
