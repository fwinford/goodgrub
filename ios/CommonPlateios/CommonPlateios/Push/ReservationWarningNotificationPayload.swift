//
//  ReservationWarningNotificationPayload.swift
//  CommonPlateios
//
// Parses the W3-H1 five-minute reservation-warning local notification's
// `userInfo`. Unlike `HelperNotificationPayload.swift` and
// `RequesterFulfillmentNotificationPayload.swift`, this payload is never sent
// by APNs — `ReservationWarningScheduling` constructs it entirely on-device
// when a claim/extension is granted — but it is parsed back out the same way
// so `HelperNotificationRouter` can route a tap on it through the identical,
// already-proven tap-sequence-fenced pattern.
import Foundation

/// The one payload shape a scheduled reservation-warning notification carries.
struct ReservationWarningNotificationPayload: Equatable {
    let requestID: String
}

enum ReservationWarningNotificationPayloadParser {
    /// On-device vocabulary only; nothing on the backend needs to agree with
    /// this string, but it is kept distinct from
    /// `HelperNotificationPayloadParser.helperNewRequestType` and
    /// `RequesterFulfillmentNotificationPayloadParser.requesterFulfillmentType`
    /// so the three notification kinds can never be confused for one another.
    nonisolated static let reservationWarningType = "reservation-warning"

    /// Returns `nil` for anything that is not a well-formed reservation-warning
    /// payload, so an unrelated or malformed notification never routes as one.
    nonisolated static func parse(userInfo: [AnyHashable: Any]) -> ReservationWarningNotificationPayload? {
        guard let type = userInfo["type"] as? String, type == reservationWarningType else {
            return nil
        }
        guard let requestID = userInfo["requestId"] as? String, !requestID.isEmpty else {
            return nil
        }
        return ReservationWarningNotificationPayload(requestID: requestID)
    }
}
