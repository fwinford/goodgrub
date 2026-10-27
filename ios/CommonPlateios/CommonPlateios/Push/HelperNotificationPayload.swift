//
//  HelperNotificationPayload.swift
//  CommonPlateios
//
// Parses the helper new-request push payload (`src/helperPushPayload.ts`)
// out of a delivered notification's `userInfo`. Pure and side-effect free so
// it can be unit tested without a real `UNNotification`, which has no public
// initializer.
import Foundation

/// The one payload shape the backend currently sends
/// (`HELPER_NEW_REQUEST_NOTIFICATION_TYPE` in `src/helperPushPayload.ts`).
struct HelperNewRequestNotificationPayload: Equatable {
    let requestID: String
    /// W4-R5: the request's content revision when the notification was sent
    /// (`contentRevision` in `src/helperPushPayload.ts`), or `nil` when the
    /// payload carried none (an older notification, or a request with no
    /// revision). Opaque; compared, never interpreted.
    var contentRevision: Int? = nil
}

enum HelperNotificationPayloadParser {
    /// Must match `HELPER_NEW_REQUEST_NOTIFICATION_TYPE` in
    /// `src/helperPushPayload.ts` exactly.
    static let helperNewRequestType = "new-request"

    /// Returns `nil` for anything that is not a well-formed helper
    /// new-request payload — an unrelated notification type, a missing or
    /// empty `requestId`, or a payload of the wrong shape entirely — so a
    /// malformed or unrelated notification never routes as one.
    static func parse(userInfo: [AnyHashable: Any]) -> HelperNewRequestNotificationPayload? {
        guard let type = userInfo["type"] as? String, type == helperNewRequestType else {
            return nil
        }
        guard let requestID = userInfo["requestId"] as? String, !requestID.isEmpty else {
            return nil
        }
        // Present only as a positive integer; anything else is "none", never a
        // guessed revision.
        let revision = (userInfo["contentRevision"] as? Int).flatMap { $0 >= 1 ? $0 : nil }
        return HelperNewRequestNotificationPayload(requestID: requestID, contentRevision: revision)
    }
}
