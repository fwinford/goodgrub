//
//  SettingsRequestAlertsToggleTests.swift
//  CommonPlateiosTests
//
// Focused coverage for the W4-H2 FIX Settings Email/Push toggle source of
// truth: the approved Figma `Control / Toggle` is binary (Off/On only, no
// pending/halfway state), and the read side must consume only the W4-N0
// authoritative Email read and the existing accepted Push truth — never
// `AlertSubscriptionStore.phase`, Check Email presentation history, or a
// remembered signup submission. See `SettingsView.isEmailToggleOn` and
// `SettingsView.isPushToggleOn`.
import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

final class SettingsRequestAlertsToggleTests: XCTestCase {
    @MainActor
    func testFoodHelpNYCOpensTheApprovedFinderLandingPage() {
        let resource = SettingsView.foodResources.filter { $0.title == "Food Help NYC" }
        XCTAssertEqual(resource.count, 1)
        XCTAssertEqual(resource.first?.url.absoluteString, "https://finder.nyc.gov/foodhelp/")
    }

    @MainActor
    func testPushLoadingPreservesRenderedRowHeight() {
        func store(isLoading: Bool) -> PushSubscriptionStore {
            let storage = InMemoryPushInstallationStorage()
            if isLoading { storage.recordConfirmedPushEnabled(true) }
            return PushSubscriptionStore(
                service: InstallationPushService(client: APIClient(
                    configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!)
                )),
                installationStorage: storage,
                authorizationCoordinator: StubPushAuthorizationCoordinator(),
                remoteNotificationRegistrar: StubRemoteNotificationRegistrar(),
                settingsOpener: StubPushSettingsOpener()
            )
        }
        let off = store(isLoading: false)
        let loading = store(isLoading: true)
        XCTAssertEqual(off.state, .off)
        XCTAssertEqual(loading.state, .settingUp)
        for size: DynamicTypeSize in [.large, .accessibility3] {
            for home in [false, true] {
                func height(_ store: PushSubscriptionStore) -> CGFloat {
                    let host = UIHostingController(rootView:
                        PushNotificationSection(store: store, isHomePromotion: home)
                            .environment(\.dynamicTypeSize, size)
                    )
                    return host.sizeThatFits(in: CGSize(width: 320, height: 1000)).height
                }
                XCTAssertEqual(height(off), height(loading), accuracy: 0.5,
                               "Loading must not move adjacent rows at \(size), Home: \(home)")
            }
        }
    }

    @MainActor
    func testSettingsPushControlKeepsExplanationsAndRecoveryInsideAlerts() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/PushNotificationSection.swift")
        let start = try XCTUnwrap(source.range(of: "private var settingsToggle: some View {"))
        let alert = try XCTUnwrap(source.range(of: ".alert(Self.deniedTitle", range: start.upperBound..<source.endIndex))
        let row = String(source[start.lowerBound..<alert.lowerBound])
        XCTAssertTrue(row.contains("Toggle(Self.toggleTitle"))
        XCTAssertTrue(row.contains("get: { store.state == .on }"))
        XCTAssertTrue(row.contains(".disabled(store.isBusy)"))
        XCTAssertFalse(row.contains("Button("))
        XCTAssertFalse(row.contains("Text("))
        XCTAssertFalse(row.contains("ProgressView("))
        XCTAssertEqual(PushNotificationSection.toggleTitle, "Push notifications")
        XCTAssertTrue(source.contains("Button(Self.openSettingsButtonTitle) { store.openSystemSettings() }"))
        XCTAssertTrue(source.contains("await store.retryUpdate()"))
        XCTAssertTrue(source.contains("else if enabled && store.state == .denied"))
        XCTAssertTrue(source.contains("if enabled { await store.enable() }"))
        XCTAssertTrue(source.contains("else { await store.disable() }"))
    }

    @MainActor
    func testDeniedFailedAndAmbiguousPushKeepTheSameNativeRowHeight() async {
        func store(
            storage: InMemoryPushInstallationStorage = InMemoryPushInstallationStorage(),
            authorization: StubPushAuthorizationCoordinator = StubPushAuthorizationCoordinator()
        ) -> PushSubscriptionStore {
            PushSubscriptionStore(
                service: InstallationPushService(client: APIClient(
                    configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!)
                )),
                installationStorage: storage,
                authorizationCoordinator: authorization,
                remoteNotificationRegistrar: StubRemoteNotificationRegistrar(),
                settingsOpener: StubPushSettingsOpener(),
                participantAuthorityProvider: { canonicalParticipantAuthorityFixture }
            )
        }
        let off = store()
        let failed = store()
        await failed.enable()
        XCTAssertEqual(failed.state, .failed)
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .denied
        let denied = store(authorization: authorization)
        await denied.enable()
        XCTAssertEqual(denied.state, .denied)
        let ambiguous = store(storage: InMemoryPushInstallationStorage(pendingAmbiguousDesiredEnabled: true))
        XCTAssertEqual(ambiguous.state, .ambiguous(desiredEnabled: true))
        for size: DynamicTypeSize in [.large, .accessibility3] {
            func height(_ store: PushSubscriptionStore) -> CGFloat {
                UIHostingController(rootView: PushNotificationSection(store: store)
                    .environment(\.dynamicTypeSize, size))
                    .sizeThatFits(in: CGSize(width: 320, height: 1000)).height
            }
            XCTAssertEqual(height(off), height(failed), accuracy: 0.5)
            XCTAssertEqual(height(off), height(denied), accuracy: 0.5)
            XCTAssertEqual(height(off), height(ambiguous), accuracy: 0.5)
        }
    }

    // MARK: - Email toggle source (W4-N0 only)

    func testEmailToggleIsOnOnlyWhenN0ReportsActive() {
        XCTAssertTrue(SettingsView.isEmailToggleOn(.active))
    }

    func testEmailToggleIsOffWhenN0ReportsInactive() {
        XCTAssertFalse(SettingsView.isEmailToggleOn(.inactive))
    }

    /// The load-bearing "never fabricate On" guarantee: not-yet-read,
    /// unreadable, and a superseded-identity read all collapse to the same
    /// `.unknown` case, and none of them may render as On.
    func testEmailToggleIsOffWhenN0StateIsUnknown() {
        XCTAssertFalse(SettingsView.isEmailToggleOn(.unknown))
    }

    // MARK: - Push toggle source (existing accepted Push truth only)

    func testPushToggleIsOnOnlyWhenStablyOn() {
        XCTAssertTrue(SettingsView.isPushToggleOn(.on))
    }

    func testPushToggleIsOffForEveryNonStableOnState() {
        XCTAssertFalse(SettingsView.isPushToggleOn(.off))
        XCTAssertFalse(SettingsView.isPushToggleOn(.settingUp))
        XCTAssertFalse(SettingsView.isPushToggleOn(.denied))
        XCTAssertFalse(SettingsView.isPushToggleOn(.failed))
        XCTAssertFalse(SettingsView.isPushToggleOn(.ambiguous(desiredEnabled: true)))
        XCTAssertFalse(SettingsView.isPushToggleOn(.ambiguous(desiredEnabled: false)))
    }

    // MARK: - Email Unknown presentation (Faith's resolution, item 1)

    /// The toggle must never be interactive while N0 truth is Unknown — a
    /// disabled Off-looking switch, not an interactive one, is what keeps
    /// this from reading as a truth claim of confirmed Off.
    func testEmailToggleIsNotInteractiveWhileUnknown() {
        XCTAssertFalse(SettingsView.isEmailToggleInteractive(.unknown))
        XCTAssertTrue(SettingsView.isEmailToggleInteractive(.active))
        XCTAssertTrue(SettingsView.isEmailToggleInteractive(.inactive))
    }

    /// No inline status at all once truth is established either way — the
    /// status exists only to explain away an ambiguous-looking Off toggle.
    func testNoInlineStatusOnceTruthIsEstablished() {
        XCTAssertNil(SettingsView.emailUnknownStatusMessage(state: .active, isRefreshing: false))
        XCTAssertNil(SettingsView.emailUnknownStatusMessage(state: .inactive, isRefreshing: false))
        XCTAssertNil(SettingsView.emailUnknownStatusMessage(state: .inactive, isRefreshing: true))
    }

    func testInlineStatusReadsCheckingWhileARefreshForTheCurrentParticipantIsInFlight() {
        XCTAssertEqual(
            SettingsView.emailUnknownStatusMessage(state: .unknown, isRefreshing: true),
            SettingsView.emailAlertsCheckingStatus
        )
    }

    func testInlineStatusReadsUnavailableWhenUnknownAndNoRefreshIsInFlight() {
        XCTAssertEqual(
            SettingsView.emailUnknownStatusMessage(state: .unknown, isRefreshing: false),
            SettingsView.emailAlertsUnavailableStatus
        )
    }

    // MARK: - Refresh cue: no semantic release threshold (Faith's resolution, item 2)

    // MARK: - Unverified participant presentation (simulator FIX, item 5)

    func testRequestAlertsSectionBranchesOnParticipantVerification() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift")

        XCTAssertTrue(source.contains("if participantIdentityStore.isVerified {"))
        XCTAssertTrue(source.contains("requestAlertsVerificationPrompt"))
        XCTAssertEqual(
            SettingsView.requestAlertsVerificationPromptText,
            "Required to manage request alerts."
        )
        XCTAssertEqual(SettingsView.verifyNYUEmailActionTitle, "Verify NYU email")
    }

    /// HQ decision 7: the unverified row must expose an explicit actionable
    /// button, not passive-only text and not a bare disclosure chevron.
    func testUnverifiedPromptExposesAnExplicitVerifyButton() throws {
        let prompt = try declarationSource(
            startMarker: "private var requestAlertsVerificationPrompt: some View {",
            endMarker: "static let requestAlertsVerificationPromptText",
            in: "ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift"
        )
        XCTAssertTrue(prompt.contains("Button {"))
        XCTAssertTrue(prompt.contains("Text(Self.verifyNYUEmailActionTitle)"))
        XCTAssertTrue(prompt.contains(".commonPlateSecondaryAction()"))
        XCTAssertFalse(prompt.contains("CommonPlateDisclosureIndicator"))
    }

    /// The unverified prompt opens the same focused overlay the toggles
    /// themselves open — no second verification path — and the generic N0
    /// unavailable/checking status can only ever render inside the verified
    /// branch, never for an unverified participant.
    func testUnverifiedPromptOpensTheSameOverlayAndNeverShowsTheGenericN0Status() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift")

        let prompt = try declarationSource(
            startMarker: "private var requestAlertsVerificationPrompt: some View {",
            endMarker: "static let requestAlertsVerificationPromptText",
            in: "ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift"
        )
        XCTAssertTrue(prompt.contains("isPresentingRequestAlerts = true"))
        XCTAssertFalse(prompt.contains(SettingsView.emailAlertsUnavailableStatus))
        XCTAssertFalse(prompt.contains(SettingsView.emailAlertsCheckingStatus))
        XCTAssertFalse(source.contains("RequestAlertsOverlayView("))
        XCTAssertTrue(source.contains("PushNotificationSection(store: pushSubscriptionStore)"))
        XCTAssertTrue(source.contains("ParticipantVerificationView(store: participantIdentityStore)"))
    }

    private func declarationSource(
        startMarker: String,
        endMarker: String,
        in relativePath: String
    ) throws -> String {
        let source = try fileSource(relativePath)
        let start = try XCTUnwrap(source.range(of: startMarker))
        let end = try XCTUnwrap(source.range(of: endMarker, range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private func fileSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - Settings Figma-measured spacing (simulator FIX, item 4)

    func testSettingsMetricsMatchApprovedFigmaMeasurements() {
        XCTAssertEqual(CommonPlateStyle.Metrics.settingsPageInset, 18)
        XCTAssertEqual(CommonPlateStyle.Metrics.settingsRowInset, 16)
    }

    func testSettingsViewUsesTheMeasuredInsetsNotTheGeneralSpacingScale() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift")

        XCTAssertTrue(source.contains("CommonPlateStyle.Metrics.settingsPageInset"))
        // W4-R2 removed the permanent W4-S1 AI Assistance explanatory
        // paragraph (Settings now presents Screenshot Assistance as one
        // named toggle with no permanent explanatory row) — six measured
        // rows remain.
        XCTAssertEqual(
            source.components(separatedBy: "CommonPlateStyle.Metrics.settingsRowInset").count - 1,
            7,
            "expected the measured row inset on: the identity row (the action buttons are full card width), "
                + "the request-alerts rows, the toggle row, the verification prompt row, "
                + "the shared divider, and the About & Help row"
        )
    }

    func testUnavailableAreaPresentationHasNoReleaseThresholdCase() {
        // Compile-time proof: `UnavailableAreaPresentation` has exactly the
        // two cases below. If a release-threshold or success case is
        // reintroduced, this exhaustive switch fails to compile rather than
        // silently passing. Success acknowledgment is not an
        // unavailable-body presentation (W4-H3).
        func exhaustive(_ presentation: HomeExchangeView.UnavailableAreaPresentation) -> String {
            switch presentation {
            case .atRest: return "atRest"
            case .refreshing: return "refreshing"
            }
        }
        XCTAssertEqual(exhaustive(.atRest), "atRest")
    }
}
