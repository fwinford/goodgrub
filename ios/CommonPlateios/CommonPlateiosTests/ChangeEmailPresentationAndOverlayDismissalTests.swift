//
//  ChangeEmailPresentationAndOverlayDismissalTests.swift
//  CommonPlateiosTests
//
// W4-H2-FIX review triage, findings 6 and 7. Neither has a UI-test harness
// this target can drive interactively (both are SwiftUI presentation/
// environment-dismissal behavior), so these are source-text assertions,
// matching this target's existing `fileSource` precedent
// (`HomeExchangeStatePresentationTests.swift`, `OnboardingPresentationTests.swift`).
import Foundation
import XCTest
@testable import CommonPlateios

final class ChangeEmailPresentationAndOverlayDismissalTests: XCTestCase {
    func testSettingsExposesSignOutWithoutChangeEmailEntry() throws {
        let settingsSource = try fileSource("ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift")
        XCTAssertFalse(settingsSource.contains("settings-change-email"))
        XCTAssertFalse(settingsSource.contains("changeEmailButton"))
        XCTAssertFalse(settingsSource.contains("\"Change Email\""))
        XCTAssertTrue(settingsSource.contains("settings-sign-out"))
        XCTAssertTrue(settingsSource.contains("participantIdentityStore.removeIdentity(ifSafe:"))
    }

    /// Settings must reconcile the N0 Email toggle for whichever identity is
    /// current after Change Email succeeds while Settings stays mounted —
    /// the initial `.task` only ever runs once, for whatever identity was
    /// current when Settings first appeared.
    func testSettingsReconcilesPushStateWhenIdentityChanges() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift")

        XCTAssertTrue(source.contains(".onChange(of: participantIdentityStore.identity) { _, _ in"))
        XCTAssertTrue(source.contains("Task { await pushSubscriptionStore.refreshAuthorizationStatus() }"))
    }

    // MARK: - Finding 7: Request Alerts overlay Done dismissal

    /// `RequestAlertsOverlayView` is a plain `ZStack` layer, never a
    /// `.sheet`/`.navigationDestination` of its own (Section 12: "never a
    /// navigation push through Settings"). `AlertSignupView`'s Done button
    /// falls back to `@Environment(\.dismiss)` whenever no `onDone` is
    /// passed, which would bubble to whatever ambient presentation actually
    /// owns this screen — Settings' own navigation push, when reached from
    /// there — and pop that instead of closing only this overlay. `onDone`
    /// must be wired to this overlay's own `dismiss()`.
    func testRequestAlertsOverlayPassesItsOwnDismissAsAlertSignupViewsOnDone() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestAlertsOverlayView.swift")

        guard let channelSetupRange = source.range(of: "private var channelSetup: some View {") else {
            return XCTFail("expected channelSetup to be defined")
        }
        let channelSetupBody = source[channelSetupRange.lowerBound...]
        XCTAssertTrue(channelSetupBody.contains("onDone: dismiss"))
    }

    private func fileSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
