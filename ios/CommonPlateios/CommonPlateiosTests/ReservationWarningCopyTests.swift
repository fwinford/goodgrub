import UserNotifications
import XCTest
@testable import CommonPlateios

/// W4-N1 (Faith): the five-minute warning is warm and states remaining time; it
/// promises no action the notification itself does not perform.
final class ReservationWarningCopyTests: XCTestCase {
    private final class RecordingCenter: ReservationWarningNotificationCentering, @unchecked Sendable {
        private let lock = NSLock()
        private var added: [UNNotificationRequest] = []
        var requests: [UNNotificationRequest] { lock.withLock { added } }

        func add(_ request: UNNotificationRequest, completionHandler: @escaping @Sendable (Error?) -> Void) {
            lock.withLock { added.append(request) }
            completionHandler(nil)
        }
        func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
        func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}
        func getPendingNotificationRequests(completionHandler: @escaping @Sendable ([UNNotificationRequest]) -> Void) {
            completionHandler([])
        }
        func getDeliveredNotificationRequests(completionHandler: @escaping @Sendable ([UNNotificationRequest]) -> Void) {
            completionHandler([])
        }
    }

    func testWarningNotificationCarriesTitleAndContextBody() {
        let center = RecordingCenter()
        let scheduler = UNUserNotificationCenterReservationWarningScheduler(notificationCenter: center)

        scheduler.scheduleWarning(requestID: "copy-request", fireAt: Date().addingTimeInterval(120))

        let predicate = NSPredicate { _, _ in !center.requests.isEmpty }
        wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 5)
        let content = center.requests[0].content
        XCTAssertEqual(content.title, "A little help goes a long way")
        XCTAssertEqual(content.body, "You have 5 minutes left to finish helping. Head back to GoodGrub to wrap things up.")
        for promise in ["add", "extend", "more minutes", "Grubhub", "order was placed", "helping completed"] {
            XCTAssertFalse(content.body.localizedCaseInsensitiveContains(promise), "body must not promise \(promise)")
        }
        // Time Sensitive needs an entitlement the app does not have (IOS1
        // handoff); the warning keeps the default interruption level.
        XCTAssertEqual(content.interruptionLevel, .active)
        XCTAssertTrue(content.categoryIdentifier.isEmpty, "no notification action can mutate the reservation")
        XCTAssertFalse(content.body.contains("copy-request"), "no request details on the lock screen")
    }
}
