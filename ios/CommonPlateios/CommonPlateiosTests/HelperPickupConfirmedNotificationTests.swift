import UserNotifications
import XCTest
@testable import CommonPlateios

@MainActor
final class HelperPickupConfirmedNotificationTests: XCTestCase {
    private func payload(_ id: String = "request-a") -> [AnyHashable: Any] {
        ["type": "helper-pickup-confirmed", "requestId": id]
    }

    func testTapOpensHomeExactlyOnceAndSupersedesOlderNavigation() {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: [
            "type": "new-request", "requestId": "old"
        ])
        let oldSequence = router.latestTapSequence
        router.handleUserActedOnNotification(userInfo: payload())
        XCTAssertGreaterThan(router.latestTapSequence, oldSequence)
        XCTAssertEqual(router.consumePickupConfirmedRoute(), [])
        XCTAssertNil(router.consumePickupConfirmedRoute())
    }

    func testNewerTapSupersedesPickupHomeIntent() {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: payload())
        router.handleUserActedOnNotification(userInfo: [
            "type": "new-request", "requestId": "newer"
        ])
        XCTAssertNil(router.consumePickupConfirmedRoute())
        XCTAssertNotNil(router.pendingHelperIntent)
    }

    func testSuppressesOnlySameRequestWhileItsLocalAcknowledgementIsPresentedInActiveScene() {
        let router = HelperNotificationRouter()
        let native: UNNotificationPresentationOptions = [.banner, .list, .sound]
        XCTAssertEqual(router.foregroundPresentationOptions(userInfo: payload()), native)
        router.updateApplicationSceneActivity(isActive: true)
        XCTAssertEqual(router.foregroundPresentationOptions(userInfo: payload()), native)
        router.updateHelperPickupNoticePresentation(requestID: "request-a")
        XCTAssertEqual(router.foregroundPresentationOptions(userInfo: payload()), [])
        XCTAssertEqual(router.foregroundPresentationOptions(userInfo: payload("different")), native)
        XCTAssertEqual(router.foregroundPresentationOptions(userInfo: [
            "type": "requester-order-placed", "requestId": "request-a"
        ]), native)
        router.updateApplicationSceneActivity(isActive: false)
        XCTAssertEqual(router.foregroundPresentationOptions(userInfo: payload()), native)
        router.updateApplicationSceneActivity(isActive: true)
        router.updateHelperPickupNoticePresentation(requestID: nil)
        XCTAssertEqual(router.foregroundPresentationOptions(userInfo: payload()), native)
    }

    func testMalformedPickupPayloadDoesNotClaimNavigation() {
        let router = HelperNotificationRouter()
        for payload: [AnyHashable: Any] in [
            ["type": "helper-pickup-confirmed"],
            ["type": "helper-pickup-confirmed", "requestId": ""],
            ["type": "helper-pickup-confirmed", "requestId": 42]
        ] {
            router.handleUserActedOnNotification(userInfo: payload)
        }
        XCTAssertEqual(router.latestTapSequence, 0)
        XCTAssertNil(router.consumePickupConfirmedRoute())
    }

    func testProductionHomeReportsActualNoticeVisibility() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("CommonPlateios")
        let home = try String(contentsOf: root.appendingPathComponent("Views/HomeExchangeView.swift"), encoding: .utf8)
        XCTAssertTrue(home.contains("Pickup confirmed. Thanks for helping!"))
        XCTAssertTrue(home.contains("onHelperPickupNoticePresentation(store.helperPickupNoticeRequestID)"))
        XCTAssertTrue(home.contains("onHelperPickupNoticePresentation(nil)"))
        let content = try String(contentsOf: root.appendingPathComponent("ContentView.swift"), encoding: .utf8)
        XCTAssertTrue(content.contains("notificationRouter.updateHelperPickupNoticePresentation(requestID: $0)"))
    }
}
