//
//  HelperNotificationRouteDriver.swift
//  CommonPlateios
//
// One helper new-request tap turned into one navigation outcome, kept out of
// `ContentView` so the terminated-launch ordering this exists to fix can be
// driven by an ordinary test instead of only by a physical device.
//
// The rule this type enforces: a captured tap is retired only once its
// navigation outcome has actually been produced. An attempt that never gets
// that far — the cold-launch case, where SwiftUI cancels the root view's
// `.task` while the scene and store hierarchy are still being established —
// leaves the intent exactly as it found it, so the next attempt (the rebuilt
// view's own `.task`, or the scene becoming active) still has a tap to route.
// No delay is involved: nothing here waits for readiness, it simply refuses to
// destroy routing intent it has not yet honoured.
//
// Availability itself is still never inferred from the payload. `requestId` is
// routing context; only `resolveHelperNotificationRequest(id:)`'s answer from
// `GET /api/request/:id` decides the destination.
import Foundation

/// What the driver needs from `RequestStore` — current backend truth for one
/// request id, whether a not-open request is this helper's held reservation
/// (W4-H1), and the three recovery notices the accepted contract attaches
/// to the non-open outcomes. Narrow on purpose: it keeps the driver free of
/// the rest of the request lifecycle, and lets tests drive it with a real
/// `RequestStore` over a stubbed transport rather than a hand-written double
/// that could drift from the store's actual classification rules.
@MainActor
protocol HelperNotificationResolving: AnyObject {
    func resolveHelperNotificationRequest(id: String) async throws -> HelperNotificationResolution
    /// W4-H1: consulted only after the request resolved `.unavailable`.
    func resolveHeldRequestForNotification(requestID: String) async throws -> HeldRequestNotificationTruth
    func reportRequestUnavailableFromNotification(requestID: String)
    func reportRequestNotYetAvailableFromNotification(requestID: String)
    func reportRequestTemporarilyUnavailableFromNotification(requestID: String)
    /// W4-R5: the same resolution with the revision the notification carried,
    /// and the two verified-terminal notices. Defaults keep every existing
    /// conformer on its accepted behavior.
    func resolveHelperNotificationRequest(
        id: String,
        notifiedRevision: Int?
    ) async throws -> HelperNotificationResolution
    func reportRequestWithdrawnFromNotification(requestID: String)
    func reportRequestExpiredFromNotification(requestID: String)
    func reportRequestUpdatedSinceNotification(requestID: String)
}

extension HelperNotificationResolving {
    func resolveHelperNotificationRequest(
        id: String,
        notifiedRevision: Int?
    ) async throws -> HelperNotificationResolution {
        try await resolveHelperNotificationRequest(id: id)
    }

    func reportRequestWithdrawnFromNotification(requestID: String) {
        reportRequestUnavailableFromNotification(requestID: requestID)
    }

    func reportRequestExpiredFromNotification(requestID: String) {
        reportRequestUnavailableFromNotification(requestID: requestID)
    }

    func reportRequestUpdatedSinceNotification(requestID: String) {}
}

extension RequestStore: HelperNotificationResolving {}

@MainActor
enum HelperNotificationRouteDriver {
    /// Resolves the router's pending helper tap, if there is one, and returns
    /// the navigation path it should produce — or `nil` to leave navigation
    /// untouched.
    ///
    /// `nil` means one of three things, and none of them may fabricate a
    /// destination:
    ///
    /// - nothing is pending;
    /// - the resolution was cancelled, or this attempt was cancelled after it
    ///   came back. The intent stays pending for the next attempt — this is
    ///   the terminated-launch fix;
    /// - a later tap of either kind has superseded this one, so applying it
    ///   would overwrite newer navigation intent. Tap order is authoritative,
    ///   and the superseded intent is retired rather than left to fire later;
    /// - another attempt for this same tap already applied it, so this one
    ///   lost the exclusive claim below and must stay silent.
    ///
    /// Overlapping attempts for one tap are expected — `ContentView` starts
    /// routing from both the root `.task(id:)` and scene activation, and
    /// either can already be in flight when the other begins. Exactly one of
    /// them may produce effects, and that is settled by the exclusive claim
    /// below, not by hoping the effects are idempotent (they are not: a
    /// second late winner would requeue a recovery notice and rewrite `path`
    /// over navigation the user may have moved on from).
    static func routeIfNeeded(
        router: HelperNotificationRouter,
        resolver: some HelperNotificationResolving
    ) async -> [AppRoute]? {
        guard let intent = router.pendingHelperIntent else {
            return nil
        }

        // The only error this can throw is cancellation: every other failure
        // is already classified into `.unavailable` or `.temporarilyUnavailable`
        // by the store. So `nil` here means "this attempt never learned
        // anything", which must leave the tap intact rather than drop it.
        guard var resolution = try? await resolver.resolveHelperNotificationRequest(
            id: intent.requestID,
            notifiedRevision: intent.contentRevision
        ) else {
            return nil
        }

        // W4-H1 held-request tap (narrow change to `docs/system-contract.md`
        // section 8.3). A not-open request may be the reservation this helper
        // holds; only confirmed continuation truth may route it to Helping.
        // Confirmed absence, or a different reservation, keeps `.unavailable`;
        // truth that cannot be established uses the temporarily-unavailable
        // recovery rather than claiming the request is gone. Still before the
        // exclusive claim below, and cancellation leaves the tap pending.
        if resolution == .unavailable {
            guard let held = try? await resolver.resolveHeldRequestForNotification(requestID: intent.requestID) else {
                return nil
            }
            switch held {
            case .held(let request):
                resolution = .heldByCurrentHelper(request)
            case .notHeld:
                break
            case .unknown:
                resolution = .temporarilyUnavailable
            }
        }

        // Cancelled after the answer came back: this attempt is not going to
        // be the one that applies it (its caller is going away), so it must
        // not retire the intent either. Checked explicitly because an `await`
        // that has already returned a value will not throw on its own.
        guard !Task.isCancelled else {
            return nil
        }

        // The exclusive claim. Everything from here to the end runs without a
        // suspension point on the main actor, so this check and the
        // retirement that follows it are one indivisible step: the attempt
        // that finds the exact intent it started with still standing is the
        // only one that can retire it, and every other attempt for that same
        // tap arrives here to find the slot already empty (or holding a
        // different tap) and produces nothing at all.
        //
        // Identity, not the tap sequence, is what has to be re-checked. The
        // sequence fence below answers "has a newer tap superseded this one",
        // which stays true for a losing attempt precisely because retirement
        // deliberately does not advance any counter — so the fence alone
        // cannot tell a second attempt that the first one already applied
        // this very intent.
        guard router.pendingHelperIntent == intent else {
            return nil
        }

        guard TapAuthorityFence.isStillAuthoritative(
            capturedSequence: intent.tapSequence,
            currentSequence: router.latestTapSequence
        ) else {
            router.markHelperIntentHandled(tapSequence: intent.tapSequence)
            return nil
        }

        // Claimed before the effects, so a concurrent attempt that is about
        // to reach the check above cannot still be holding a live claim on
        // this intent while these effects run.
        router.markHelperIntentHandled(tapSequence: intent.tapSequence)

        switch resolution {
        case .available, .heldByCurrentHelper:
            break
        case .availableUpdated:
            resolver.reportRequestUpdatedSinceNotification(requestID: intent.requestID)
        case .withdrawn:
            resolver.reportRequestWithdrawnFromNotification(requestID: intent.requestID)
        case .expired:
            resolver.reportRequestExpiredFromNotification(requestID: intent.requestID)
        case .unavailable:
            resolver.reportRequestUnavailableFromNotification(requestID: intent.requestID)
        case .notYetAvailable:
            resolver.reportRequestNotYetAvailableFromNotification(requestID: intent.requestID)
        case .temporarilyUnavailable:
            resolver.reportRequestTemporarilyUnavailableFromNotification(requestID: intent.requestID)
        }

        return AppRoute.afterNotificationResolution(resolution)
    }
}
