//
//  PushAuthorizationCoordinator.swift
//  CommonPlateios
//
// The narrow, testable boundary around `UNUserNotificationCenter` that
// `PushSubscriptionStore` uses. Nothing outside this file touches
// `UNUserNotificationCenter` directly, so the store's permission logic can be
// exercised without ever showing Apple's real system prompt.
import UserNotifications

protocol PushAuthorizationCoordinator {
    /// The current authorization status, read fresh every call. Never
    /// prompts.
    func currentAuthorizationStatus() async -> UNAuthorizationStatus

    /// Requests alert/sound/badge authorization. Callers must call this only
    /// after an explicit `Enable notifications` action, and only when the
    /// current status is `.notDetermined` — this type does not enforce that
    /// itself, because doing so would hide from a test whether the caller
    /// actually respected it.
    func requestAuthorization() async throws -> Bool
}

/// The accepted product surface requests only alert, sound, and badge —
/// never provisional authorization, per the Week 3 Day 6 contract.
struct UNUserNotificationCenterAuthorizationCoordinator: PushAuthorizationCoordinator {
    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }
}
