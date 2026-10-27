//
//  RequesterFulfillmentNotificationPayload.swift
//  CommonPlateios
//
// Parses the requester-fulfillment push payload
// (`src/requesterFulfillmentPushPayload.ts`) out of a delivered notification's
// `userInfo`. A tap carries only the request id and resolves current requester
// authority in the R3 placed-order destination.
import Foundation

struct RequesterFulfillmentNotificationPayload: Equatable {
    let requestID: String
}

enum RequesterFulfillmentNotificationPayloadParser {
    /// Must match `REQUESTER_FULFILLMENT_NOTIFICATION_TYPE` in
    /// `src/requesterFulfillmentPushPayload.ts` exactly.
    static let requesterFulfillmentType = "requester-order-placed"

    /// Returns `nil` unless the payload has the requester-fulfillment type and
    /// a backend ObjectId. The id is routing context, never authority.
    static func parse(
        userInfo: [AnyHashable: Any]
    ) -> RequesterFulfillmentNotificationPayload? {
        guard userInfo["type"] as? String == requesterFulfillmentType,
              let requestID = userInfo["requestId"] as? String,
              requestID.utf8.count == 24,
              requestID.utf8.allSatisfy({
                  (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
              }) else {
            return nil
        }
        return RequesterFulfillmentNotificationPayload(requestID: requestID)
    }
}
