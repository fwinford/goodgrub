//
//  HelperRequestPresentation.swift
//  CommonPlateios
//
// Shared helper-request presentation rules that lived on the retired Active
// Requests screen (W4-R5 retired that screen and its route; Home is the one
// root). Nothing here decides state or touches a store: it is the pure list
// filtering, the reservation deadline wording, and the claim-unavailable copy,
// kept in one place so Home, Request Detail and Helping read the same words.
import Foundation

enum HelperRequestPresentation {
    static func availableRequests(
        _ requests: [FoodRequest],
        activeClaimRequestID: String?
    ) -> [FoodRequest] {
        guard let activeClaimRequestID else {
            return requests
        }
        return requests.filter { $0.id != activeClaimRequestID }
    }

    static let activeReservationTitle = "You’re helping with a request"

    /// The authoritative backend deadline, shown without a countdown.
    static func reservedUntilText(_ claimExpiresAt: Date) -> String {
        "Reserved until \(claimExpiresAt.formatted(date: .omitted, time: .shortened))"
    }

    /// Which notice the alert should be showing. An alert already on screen is
    /// never swapped out from under the helper: newer notices wait in the store
    /// queue until the presented one is acknowledged by ID, at which point this
    /// returns the next queue head instead of nil.
    static func noticeToPresent(
        presented: ClaimUnavailableNotice?,
        storeNotice: ClaimUnavailableNotice?,
        isViewVisible: Bool = true
    ) -> ClaimUnavailableNotice? {
        guard isViewVisible else {
            return presented
        }
        return presented ?? storeNotice
    }

    /// Locked copy for the race conflict; a calm shared sentence for every
    /// other confirmed-unavailable outcome. The store already refreshed the
    /// list from backend truth before this is shown.
    static func claimUnavailableTitle(for reason: ClaimUnavailableReason?) -> String {
        switch reason {
        case .alreadyClaimed:
            return RequestDetailView.alreadyClaimedNotice
        case .claimExpired:
            return "Your reservation expired."
        case .fulfillmentClaimExpired:
            return "Your reservation ran out"
        case .reservationNoLongerValid:
            return "This meal is no longer reserved for you."
        case .fulfillmentAlreadyPlaced:
            return "This order is already recorded in CommonPlate."
        case .fulfillmentRequestNotFound:
            return "We couldn’t find this request."
        case .noLongerAvailable, nil:
            return RequestDetailView.noLongerAvailableNotice
        case .notYetAvailable:
            // The same sentence a claim before the start produces, so a helper
            // who arrives by notification tap and one who presses Claim are
            // told the same true thing.
            return RequestDetailView.notYetAvailableNotice
        case .temporarilyUnavailable:
            return RequestDetailView.temporarilyUnavailableNotice
        // W4-R5: verified terminal tap targets. Concise and truthful: the
        // backend said exactly this, and nothing about why or by whom.
        case .withdrawn:
            return "This request was withdrawn."
        case .expired:
            return "This request expired."
        }
    }

    /// An expired reservation is the one case that needs a second sentence: the
    /// helper must not place a real order against a request they no longer hold.
    static func claimUnavailableDetail(for reason: ClaimUnavailableReason?) -> String? {
        switch reason {
        case .claimExpired:
            return "Please don’t place an order for that request. Someone else may already be helping."
        case .fulfillmentClaimExpired:
            return "If you already completed the Grubhub order, don’t place it again. CommonPlate may not have saved the details, so the student may not have been emailed. If you had not ordered yet, do not start now."
        case .reservationNoLongerValid:
            return "Someone else may have recorded it. Don’t place another Grubhub order."
        case .fulfillmentAlreadyPlaced:
            // Reached both by a race on a first submission and — since the
            // one-use manual repeat exists — by the repeat that the backend
            // answers with REQUEST_ALREADY_PLACED. In that second case the
            // original response was never readable, so its notification result
            // is unknown here. Placement is the only thing this verdict proves;
            // claiming the student was told would overstate it, and a helper
            // who knows the email may not have gone out can reach them another
            // way. Same register as the emailStatusUnknown confirmation.
            return "Don’t place another Grubhub order. We couldn’t confirm whether the student’s email was sent, so they may not know the order is ready."
        case .fulfillmentRequestNotFound:
            return "It may already have been recorded or removed. Don’t place another Grubhub order."
        // `.notYetAvailable` needs no second sentence either: nothing was
        // ordered, nothing was lost, and the first sentence already says the
        // only thing there is to do about it.
        case .alreadyClaimed, .noLongerAvailable, .notYetAvailable,
             .temporarilyUnavailable, .withdrawn, .expired, nil:
            return nil
        }
    }

    /// How a claim-unavailable notice is presented on Home (W4-R5).
    ///
    /// The reservation-safety reasons keep their alert: their second sentence
    /// stops a helper from placing a second real order and must be read and
    /// acknowledged. Every other reason is a calm, one-time Home banner (the
    /// approved Figma notice pattern), which the student dismisses.
    enum HomeNoticeStyle: Equatable {
        case alert
        case banner
    }

    static func homeNoticeStyle(for reason: ClaimUnavailableReason?) -> HomeNoticeStyle {
        switch reason {
        case .claimExpired, .fulfillmentClaimExpired, .reservationNoLongerValid,
             .fulfillmentAlreadyPlaced, .fulfillmentRequestNotFound, .alreadyClaimed:
            return .alert
        case .noLongerAvailable, .notYetAvailable, .temporarilyUnavailable,
             .withdrawn, .expired, nil:
            return .banner
        }
    }

    /// The banner's two lines. A temporarily-unavailable answer uses the
    /// approved Figma wording; the others reuse their existing title with no
    /// second line.
    static func bannerText(for reason: ClaimUnavailableReason?) -> (title: String, detail: String?) {
        switch reason {
        case .temporarilyUnavailable:
            return ("Couldn’t open this request", "Please try again.")
        default:
            return (claimUnavailableTitle(for: reason), nil)
        }
    }
}
