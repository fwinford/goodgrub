//
//  RequestRemovedPresentation.swift
//  CommonPlateios
//
// W4-U1.2 CP5: the neutral requester notice shown when the requester's own
// request was removed by moderation. The backend signals it only to the
// requester: on the own-request detail read as the decoded `REQUEST_REMOVED`
// code, and on the own-request list as the boolean `removedNotice` (Home). No
// other answer (including an ordinary `REQUEST_NOT_FOUND`) is ever read as
// removal.
//
// The copy names no reporter, reason or rule, and does not imply the requester
// did anything wrong.
import Foundation

enum RequestRemovedPresentation {
    /// Matches `OWNER_REQUEST_REMOVED_CODE` in `src/requestOwnerReadRoute.ts`.
    static let errorCode = "REQUEST_REMOVED"
    static let message =
        "This request is no longer available. Contact support if you need assistance."
    static let supportActionTitle = "Contact support"

    /// True only for the decoded removal code on a read.
    static func isRemoval(_ error: Error) -> Bool {
        guard case RequestServiceError.serverError(let code, _) = error else { return false }
        return code == errorCode
    }
}
