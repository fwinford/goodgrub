import Foundation

enum HelperPickupConfirmedNotificationPayloadParser {
    static let notificationType = "helper-pickup-confirmed"

    static func requestID(userInfo: [AnyHashable: Any]) -> String? {
        guard userInfo["type"] as? String == notificationType,
              let requestID = userInfo["requestId"] as? String,
              !requestID.isEmpty else { return nil }
        return requestID
    }
}
