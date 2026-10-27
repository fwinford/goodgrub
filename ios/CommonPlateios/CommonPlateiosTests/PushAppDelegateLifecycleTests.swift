//
//  PushAppDelegateLifecycleTests.swift
//  CommonPlateiosTests
//
// Structural coverage for the terminated-launch tap-routing correction: the
// notification-center delegate must be installed from
// `application(_:willFinishLaunchingWithOptions:)`, not
// `didFinishLaunchingWithOptions`, so a tap that cold-launches the app can
// reach `HelperNotificationRouter` before the system delivers its
// delegate callback. This calls the lifecycle method directly rather than
// driving a real `UIApplication` launch, which is not something XCTest can
// do; whether the OS actually calls `will` before delivering that callback
// is physical-device acceptance territory, not something this test proves.
import UIKit
import UserNotifications
import XCTest
@testable import CommonPlateios

@MainActor
final class PushAppDelegateLifecycleTests: XCTestCase {
    func testWillFinishLaunchingInstallsTheSameRouterAsTheNotificationCenterDelegate() {
        let delegate = PushAppDelegate()

        _ = delegate.application(UIApplication.shared, willFinishLaunchingWithOptions: nil)

        XCTAssertTrue(UNUserNotificationCenter.current().delegate === delegate.notificationRouter)
    }
}
