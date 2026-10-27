//
//  PushAppDelegate.swift
//  CommonPlateios
//
// The narrowest `UIApplicationDelegate` bridge SwiftUI's app lifecycle needs
// for APNs device-token callbacks and notification delivery — SwiftUI has no
// equivalent hook for either. This owns exactly two things, both shared with
// `ContentView`: the `UIKitRemoteNotificationRegistrar` whose continuation the
// two callbacks below resume, and the `HelperNotificationRouter` wired as
// `UNUserNotificationCenter`'s delegate so a foreground delivery and a tap
// are captured from the moment the app is willing to finish launching. It
// adds no other app-delegate responsibility: no background-mode processing,
// and no notification-tap decision-making of its own — that lives in the
// router.
import UIKit
import UserNotifications

final class PushAppDelegate: NSObject, UIApplicationDelegate {
    /// Shared with `ContentView`, which passes it into `PushSubscriptionStore`.
    /// Must be the same instance the callbacks below resume, or a token or
    /// error delivered here would have no pending caller to reach.
    let remoteNotificationRegistrar = UIKitRemoteNotificationRegistrar()

    /// Shared with `ContentView`, which reads a captured tap from it. Must be
    /// assigned as `UNUserNotificationCenter`'s delegate before this method
    /// returns, so a notification that launched the app is delivered to this
    /// instance rather than dropped.
    let notificationRouter = HelperNotificationRouter()

    /// `willFinishLaunchingWithOptions`, not `didFinishLaunchingWithOptions`:
    /// a notification tap that cold-launches the terminated app can hand
    /// `UNUserNotificationCenter` its delegate-callback before `did` runs, and
    /// a delegate assigned too late misses that callback and drops the tap —
    /// the reproduced terminated-launch routing failure. `will` is the
    /// earliest point `UIApplicationDelegate` offers, so the assignment moves
    /// here instead.
    func application(
        _ application: UIApplication,
        willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = notificationRouter
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        remoteNotificationRegistrar.received(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        remoteNotificationRegistrar.failed(error: error)
    }
}
