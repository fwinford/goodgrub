//
//  AppRoute.swift
//  CommonPlateios
//

import Foundation

/// Every destination in the app's single navigation stack, addressed by value.
///
/// The stack is app state, not a chain of `dismiss()` calls. That is the whole
/// point of this type: a claimant screen sits *above* the request detail that
/// opened it, and a `DismissAction` read on the detail cannot reliably remove
/// both levels from underneath the screen calling it. Expressing the stack as an
/// array lets the helper flow rewrite the path in one update: a confirmed claim
/// replaces its pre-claim detail with Helping (W4-H1), and a finished flow
/// leaves to Home after confirmed placement or to Active Requests after a
/// non-success end, so no stale detail survives to be reached with Back.
enum AppRoute: Hashable {
    case requestFood
    case alerts
    /// W4-O1 How CommonPlate Works reference hub and its two detail screens.
    /// Typed routes keep the Settings row on the same native push as Privacy
    /// & Safety, and let `Return to Home` clear the path.
    case howCommonPlateWorks
    case howRequestingWorks
    case howHelpingWorks
    case privacySafety
    /// W4-H2's one shared secondary utility route, reached from Home's gear.
    /// Owns compact identity presentation, the Request Alerts management row
    /// (`.alerts`), and About & Help destination rows.
    case settings
    /// W4-H2 About & Help destination row. Minimal placeholder content —
    /// final trust/support content belongs to T1.
    case support
    /// W4-U1.3's minimal blocked-student management list, reached from
    /// Settings → Privacy & Safety. Carries no value: it is rendered from
    /// `RequestStore`'s own backend-confirmed list.
    case blockedStudents
    /// The public request screen. Carries the request by value because the
    /// backend removes a placed request from the list, so an ID that had to be
    /// looked up again would resolve to nothing at exactly the moment it matters.
    case requestDetail(FoodRequest)
    /// W4-R5: the requester's own request, carried by value for the same reason
    /// `requestDetail` is. The screen re-reads current owner truth on appearance
    /// and never trusts this snapshot as authority.
    case ownerRequest(OwnerRequest)
    /// W4-R3: an exact requester-private placed-order destination. Only the ID
    /// is carried; the screen resolves current ownership and pickup state again.
    case placedOrder(requestID: String)
    /// W4-R5: Edit Request for one of the requester's own requests, reusing the
    /// Request a Meal form prefilled from the confirmed saved fields.
    case editRequest(OwnerRequest)
    /// The claimant-only reservation screen (Helping). Replaces the detail
    /// screen once a claim confirms, and is the held request's one destination
    /// from every other entry; the route itself carries no claimant-private
    /// value, only the public request.
    case fulfillment(FoodRequest)
    /// W4-H4's `See all N` destination: the complete authoritative
    /// currently-open owned-request set, carried by value for the same reason
    /// `requestDetail` is — a request can leave the board between the tap and
    /// the destination rendering. Not history, not V2 My Requests, not
    /// request management: an ordinary subordinate expansion of the same Home
    /// ownership preview.
    case ownRequests([FoodRequest])
    /// W4-R3: `See all` for the helper's `Continue helping` set. Carries no
    /// value: it renders the store's live set so a retired continuation leaves
    /// in place rather than lingering from a stale snapshot.
    case helperContinuations
    /// W4-R3: the helper's own `Waiting for pickup` continuation for one placed
    /// request. Carries only the ID and resolves the store's helper-owned
    /// placement; it never goes through the public request-availability path.
    case helperWaiting(requestID: String)
    /// W4-MSG1 CP6: the private conversation of one request. Carries only the
    /// request id and caller role: no helper, reservation, token or transcript.
    case requestConversation(requestID: String, role: RequestConversationRole)
}

extension AppRoute {
    /// The path after a helper flow ends without a success — Home, the empty
    /// path. W4-R5 retired the Active Requests screen this used to land on, so
    /// every non-success end (a lost claim, an expired reservation, a
    /// confirmed-unavailable request) returns to Home, where the one-time
    /// notice is delivered. Nothing is left on the stack to be reached with Back.
    static func returningHome(from path: [AppRoute]) -> [AppRoute] {
        _ = path
        return []
    }

    /// W4-H1: the one destination after authoritatively confirmed helper
    /// completion — Home, the empty path — regardless of whether the helper
    /// entered from Home, Active Requests, or a helper notification. Applied
    /// once by the automatic success presentation after its readable dwell.
    static func afterHelperSuccess(from path: [AppRoute]) -> [AppRoute] {
        _ = path
        return []
    }

    /// W4-U1.3: the one destination after a confirmed Block that makes the
    /// request unreachable (normal Block, or active `No, not yet` with the
    /// reservation released) — Home, the empty path; not Active Requests.
    /// True while any request chat is open above the current screen.
    static func hasOpenConversation(in path: [AppRoute]) -> Bool {
        path.contains { if case .requestConversation = $0 { return true } else { return false } }
    }

    static func afterParticipantBlock(from path: [AppRoute]) -> [AppRoute] {
        _ = path
        return []
    }

    /// W4-U1.3: the path after a confirmed active-reservation Block with
    /// `Yes, already placed`. The helper stays on Helping (restricted), but the
    /// Block transition must not leave legacy Active Requests as its Back
    /// destination, so everything beneath the Helping route is dropped and Back
    /// resolves to Home. Only used by the Block-Yes success seam; a path with
    /// no Helping route is returned unchanged.
    static func afterParticipantBlockKeepingHelping(from path: [AppRoute]) -> [AppRoute] {
        guard let index = path.lastIndex(where: {
            if case .fulfillment = $0 { return true }
            return false
        }) else {
            return path
        }
        return Array(path[index...])
    }

    /// W4-H1 active-reservation navigation: the path once `activeClaim` is
    /// this helper's confirmed reservation. Request Detail is pre-claim only,
    /// so no destination for the held request — its now-stale detail, or an
    /// earlier Helping copy — stays in the stack. The path is cut at the first
    /// such destination and Helping takes its place, which leaves whatever was
    /// beneath the detail (normally Home) as Back's destination. A path that
    /// never contained the request simply gains Helping on top.
    static func enteringHeldRequest(
        _ activeClaim: ActiveClaimPresentation,
        from path: [AppRoute]
    ) -> [AppRoute] {
        let base: [AppRoute]
        if let index = path.firstIndex(where: {
            containsHelperDestination(in: [$0], requestID: activeClaim.requestID)
        }) {
            base = Array(path[..<index])
        } else {
            base = path
        }
        return base + [.fulfillment(activeClaim.request)]
    }

    /// W4-R5 `R5-IR-1`: the path after a successful Change Email replaced the
    /// current participant with a different one. Destinations that carry a
    /// request *by value* (`requestDetail`, `ownRequests`) hold a snapshot that
    /// was served to, and filtered for, the previous participant, so they are
    /// dropped rather than left reachable with Back. `fulfillment` is kept: it
    /// is the helper's own reservation continuation, which keeps the principal
    /// binding of the claim that created it and is not request-list data.
    /// Everything else (Settings, Alerts, reference screens) carries no request.
    static func afterIdentityReplacement(from path: [AppRoute]) -> [AppRoute] {
        path.filter { route in
            switch route {
            case .requestDetail, .ownRequests, .ownerRequest, .placedOrder, .editRequest,
                 .helperWaiting, .requestConversation:
                return false
            default:
                return true
            }
        }
    }

    /// Pushes `route` unless it is already on top. Entering the claimant flow is
    /// driven by confirmed store state, and that state can republish while the
    /// screen it opens is already showing; without this a single claim could
    /// stack two identical destinations.
    static func appending(_ route: AppRoute, to path: [AppRoute]) -> [AppRoute] {
        guard path.last != route else {
            return path
        }
        return path + [route]
    }

    /// Whether the stack still contains a request-detail or claimant destination
    /// for `requestID`.
    static func containsHelperDestination(
        in path: [AppRoute],
        requestID: String
    ) -> Bool {
        path.contains { route in
            switch route {
            case .requestDetail(let request), .fulfillment(let request):
                return request.id == requestID
            case .requestFood, .alerts, .howCommonPlateWorks,
                 .howRequestingWorks, .howHelpingWorks, .privacySafety,
                 .settings, .support, .ownRequests, .blockedStudents,
                 .ownerRequest, .placedOrder, .editRequest, .helperContinuations,
                 .helperWaiting, .requestConversation:
                return false
            }
        }
    }

    /// The path a helper new-request notification tap replaces the current
    /// one with, once `RequestStore.resolveHelperNotificationRequest(id:)`
    /// has answered from backend truth. A tap is a fresh navigation intent —
    /// whatever the helper was doing before is discarded, matching "opens
    /// CommonPlate and routes toward the specific request". Home is always the
    /// base (W4-R5 retired Active Requests), so Back and any later completed-flow
    /// truncation land somewhere real.
    ///
    /// Every outcome that is not a destination (unavailable, withdrawn,
    /// expired, not yet available, unknown) lands on Home itself, where the
    /// one-time notice the driver queued is presented.
    static func afterNotificationResolution(
        _ resolution: HelperNotificationResolution
    ) -> [AppRoute] {
        switch resolution {
        case .available(let request), .availableUpdated(let request):
            return [.requestDetail(request)]
        // W4-H1: the tapped request is this helper's confirmed reservation.
        // Helping is its one destination, with no Request Detail.
        case .heldByCurrentHelper(let request):
            return [.fulfillment(request)]
        case .unavailable, .withdrawn, .expired, .notYetAvailable, .temporarilyUnavailable:
            return []
        }
    }

    /// W4-N1 Increment B: requester-fulfillment taps carry only the request
    /// id and enter R3's destination, which resolves current backend truth.
    static func afterRequesterFulfillmentNotification(
        requestID: String
    ) -> [AppRoute] {
        [.placedOrder(requestID: requestID)]
    }
}
