//
//  CommonPlateFoundationPresentationTests.swift
//  CommonPlateiosTests
//
// Focused W4-F1 source-scope proof for the presentation seams that SwiftUI
// unit tests cannot inspect without a UI-test target: the native-first action
// hierarchy, Home identity presentation, and F1-owned helper vocabulary.
import Foundation
import XCTest
@testable import CommonPlateios

final class CommonPlateFoundationPresentationTests: XCTestCase {
    func testSharedActionStylesKeepTheHierarchyWithModerateRoundedRectangles() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Design/CommonPlateButtonStyles.swift")

        XCTAssertTrue(source.contains("func commonPlatePrimaryAction()"))
        XCTAssertTrue(source.contains("buttonStyle(CommonPlateFilledActionStyle())"))
        XCTAssertTrue(source.contains("func commonPlateSecondaryAction()"))
        XCTAssertTrue(source.contains("commonPlateSecondaryAction(minimumHeight: CommonPlateStyle.Control.minimumHeight)"))
        XCTAssertTrue(source.contains("buttonStyle(CommonPlateSoftActionStyle(minimumHeight: minimumHeight))"))
        XCTAssertTrue(source.contains("func commonPlateTertiaryAction()"))
        XCTAssertTrue(source.contains("func commonPlateDestructiveAction()"))
        XCTAssertTrue(source.contains("buttonStyle(CommonPlateDestructiveButtonStyle())"))
        XCTAssertTrue(source.contains("shape.fill(isEnabled ? CommonPlateStyle.Color.destructiveFill"))
        XCTAssertTrue(source.contains("strokeBorder(isEnabled ? CommonPlateStyle.Color.destructiveBorder"))
        XCTAssertTrue(source.contains("foregroundStyle(isEnabled ? CommonPlateStyle.Color.destructiveText : Color.secondary)"))
        let sharedRoundedRectangle =
            "RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)"
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: sharedRoundedRectangle).count - 1,
            2,
            "Primary and secondary actions must share the F1 rounded-rectangle token."
        )
        XCTAssertFalse(source.contains("Capsule"))
        XCTAssertTrue(source.contains("commonPlateActionLabelLayout()"))
        XCTAssertTrue(source.contains("func commonPlateMajorActionFrame()"))
        XCTAssertTrue(source.contains("frame(maxWidth: CommonPlateStyle.Control.majorActionMaximumWidth)"))
        XCTAssertTrue(source.contains("lineLimit(nil)"))
        XCTAssertTrue(source.contains("fixedSize(horizontal: false, vertical: true)"))
        XCTAssertTrue(source.contains("padding(.horizontal, CommonPlateStyle.Spacing.l)"), "Ordinary actions keep their existing inset.")
        XCTAssertTrue(source.contains("padding(.vertical, CommonPlateStyle.Spacing.m)"))
        XCTAssertTrue(source.contains("maxWidth: .infinity"))
        XCTAssertTrue(source.contains("minimumHeight: CGFloat = CommonPlateStyle.Control.minimumHeight"))
        XCTAssertTrue(source.contains("minHeight: minimumHeight"))
        XCTAssertFalse(source.contains(".frame(width:"))
        XCTAssertFalse(source.contains(".clipped()"))
        XCTAssertFalse(source.contains("lineLimit(1)"))
        XCTAssertFalse(source.contains("minimumScaleFactor"))

        let tokens = try fileSource("ios/CommonPlateios/CommonPlateios/Design/CommonPlateStyle.swift")
        XCTAssertTrue(tokens.contains("enum Radius"))
        XCTAssertTrue(tokens.contains("static let standard: CGFloat"))
        XCTAssertTrue(tokens.contains("static let minimumHeight: CGFloat"))
        XCTAssertTrue(tokens.contains("static let majorActionMinimumHeight: CGFloat = 52"))
        XCTAssertTrue(tokens.contains("static let majorActionMaximumWidth: CGFloat = 292"))

        XCTAssertTrue(source.contains("func commonPlateMajorPrimaryAction()"))
        XCTAssertTrue(source.contains("func commonPlateMajorSecondaryAction()"))
        XCTAssertTrue(source.contains("font(.title3.weight(.semibold))"))
        XCTAssertTrue(source.contains("shadow(color: .black.opacity(isEnabled ? 0.18 : 0), radius: 4, y: 2)"))
        XCTAssertTrue(source.contains("scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.985 : 1)"))
        XCTAssertTrue(source.contains("opacity(configuration.isPressed && isEnabled ? 0.88 : 1)"))
        XCTAssertTrue(source.contains("struct CommonPlateFlatActionButtonStyle: ButtonStyle"))
        XCTAssertTrue(source.contains("opacity(configuration.isPressed ? 0.62 : 1)"))
    }

    /// W4-H2: this presentation relocated from Home to the shared Settings
    /// route (compact identity, left Change Email, right destructive Remove
    /// Email). The masked-identity/destructive-removal invariants this test
    /// previously proved against `ContentView` now apply to `SettingsView`.
    func testSettingsKeepsTheAcceptedMaskedIdentityAndDestructiveRemovalPresentation() throws {
        let section = try declarationSource(
            startMarker: "private var identitySection: some View {",
            endMarker: "@ViewBuilder\n    private func identityActions",
            in: "ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift"
        )

        XCTAssertTrue(section.contains("identity.masked"))
        XCTAssertTrue(section.contains("settings-verified-identity"))
        XCTAssertTrue(section.contains("verifiedIdentityRow(masked: identity.masked)"))
        XCTAssertFalse(section.contains("Text(\"Verified NYU email\")"))
        XCTAssertTrue(section.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertFalse(section.contains("commonPlateGroupedSurface"))

        let identityActions = try declarationSource(
            startMarker: "private func identityActions(axis: Axis) -> some View {",
            endMarker: "private var emailReplacementNoticeContent",
            in: "ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift"
        )
        XCTAssertTrue(identityActions.contains("signOutButton"))
        XCTAssertFalse(identityActions.contains("changeEmailButton"))

        let removeEmail = try declarationSource(
            startMarker: "private var signOutButton: some View {",
            endMarker: "static let verifiedNYUEmailLabel",
            in: "ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift"
        )
        XCTAssertTrue(removeEmail.contains("Button(Self.signOutTitle)"))
        XCTAssertTrue(removeEmail.contains("settings-sign-out"))
        XCTAssertFalse(removeEmail.contains("Remove Email"))
        XCTAssertTrue(removeEmail.contains("commonPlateDestructiveAction()"))
    }

    /// W4-H2 Settings fidelity pass: the approved Figma drops identity out of
    /// a grouped card entirely and strips About & Help's explanatory
    /// subtitles, replacing the oversized warm/yellowish card with a plain
    /// native row surface. Request Alerts keeps its subtitle and its
    /// existing accepted `.alerts` destination unchanged — this pass adds
    /// visual fidelity only, no new Email/Push toggle semantics.
    func testSettingsFidelityDropsIdentityCardStripsAboutHelpSubtitlesAndKeepsRequestAlertsBehavior() throws {
        let identity = try declarationSource(
            startMarker: "private var identitySection: some View {",
            endMarker: "@ViewBuilder\n    private func identityActions",
            in: "ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift"
        )
        XCTAssertFalse(identity.contains("CommonPlateStyle.Color.warmSurface"))

        let aboutHelp = try declarationSource(
            startMarker: "private var aboutAndHelpSection: some View {",
            endMarker: "private func sectionHeading",
            in: "ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift"
        )
        XCTAssertFalse(aboutHelp.contains("CommonPlateStyle.Color.warmSurface"))
        XCTAssertFalse(aboutHelp.contains("How requesting and helping fit together"))
        XCTAssertFalse(aboutHelp.contains("Understand the exchange’s safety boundaries"))
        XCTAssertFalse(aboutHelp.contains("Get help with CommonPlate"))
        XCTAssertTrue(aboutHelp.contains("SettingsRow(title: \"How \\(AppBrand.name) Works\")"))
        XCTAssertTrue(aboutHelp.contains("SettingsRow(title: \"Privacy & Safety\")"))
        XCTAssertTrue(aboutHelp.contains("SettingsRow(title: \"Support\")"))

        let requestAlerts = try declarationSource(
            startMarker: "private var requestAlertsSection: some View {",
            endMarker: "// MARK: - About & Help",
            in: "ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift"
        )
        // Final H2 visual alignment FIX (supersedes both the prior "Request
        // Alerts remains inline in Settings for later management" wording
        // and the intermediate compact "Set up"/"Manage" row): Settings
        // presents Email/Push as the approved Figma `Control / Toggle` rows,
        // not the embedded `AlertSignupView` form and not a `NavigationLink`
        // destination — turning a toggle on opens the existing focused
        // overlay instead.
        XCTAssertFalse(requestAlerts.contains("NavigationLink(value: AppRoute.alerts)"))
        XCTAssertFalse(requestAlerts.contains("subtitle: \"Manage how CommonPlate can alert you\""))
        XCTAssertFalse(requestAlerts.contains("AlertSignupView("))
        XCTAssertTrue(requestAlerts.contains("PushNotificationSection(store: pushSubscriptionStore)"))

        let settings = try fileSource("ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift")
        XCTAssertFalse(settings.contains("RequestAlertsOverlayView("))
    }

    /// W4-H2: Home is now the live exchange board, not a static launcher.
    /// Request a Meal remains persistently available and Settings remains
    /// reachable from the gear — this replaces the old two-zone-composition
    /// proof, which asserted structure H2 explicitly supersedes.
    func testHomeExchangeKeepsRequestAMealPersistentAndSettingsReachable() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        XCTAssertTrue(source.contains("home-request-a-meal"))
        XCTAssertTrue(source.contains("NavigationLink(value: AppRoute.settings)"))
        XCTAssertTrue(source.contains(".safeAreaInset(edge: .bottom)"))
        XCTAssertFalse(source.contains("Find a request"))
        XCTAssertFalse(source.contains("AppRoute.activeRequests"), "Active Requests is retired")
    }

    func testHomeUsesHelperWhenItNamesTheHelpingRole() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/ContentView.swift")
        XCTAssertTrue(source.contains("A helper with extra meal swipes chooses a request to help with."))
        XCTAssertFalse(source.contains("Another student with extra meal swipes chooses a request to help with."))
    }

    /// W4-H2: Home is now the board-first exchange — there is no "Find a
    /// request" launcher step, and identity/Privacy & Safety relocated to
    /// Settings. This proves the new content order instead: the board
    /// heading precedes the persistent Request a Meal action, which remains
    /// reachable via native vertical overflow (`safeAreaInset`, not a fixed
    /// absolute layout).
    func testHomeHasNativeVerticalOverflowWithoutChangingContentOrder() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")
        XCTAssertTrue(source.contains("ScrollView {"))
        XCTAssertTrue(source.contains(".safeAreaInset(edge: .bottom)"))

        let header = try XCTUnwrap(source.range(of: "private var header: some View"))
        let board = try XCTUnwrap(source.range(of: "private func boardSection("))
        let requestMeal = try XCTUnwrap(source.range(of: "private var requestMealButton: some View"))
        XCTAssertLessThan(header.lowerBound, board.lowerBound)
        XCTAssertLessThan(board.lowerBound, requestMeal.lowerBound)
    }

    func testVerificationUsesDirectScrollableHierarchyWithoutGroupedSurfaces() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/ParticipantVerificationView.swift")
        // W4-H2: Home's full-page canvas now lives in `HomeExchangeView`.
        let homeSource = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")
        let header = try declarationSource(
            startMarker: "private var verificationBrandHeader: some View {",
            endMarker: "@ViewBuilder\n    private var emailSection: some View {",
            in: "ios/CommonPlateios/CommonPlateios/Views/ParticipantVerificationView.swift"
        )
        let email = try declarationSource(
            startMarker: "private var emailSection: some View {",
            endMarker: "private func codeSection(address: String, resendAvailableAt: Date) -> some View {",
            in: "ios/CommonPlateios/CommonPlateios/Views/ParticipantVerificationView.swift"
        )
        let code = try declarationSource(
            startMarker: "private func codeSection(address: String, resendAvailableAt: Date) -> some View {",
            endMarker: "    static let codeLifetimeNotice",
            in: "ios/CommonPlateios/CommonPlateios/Views/ParticipantVerificationView.swift"
        )

        XCTAssertTrue(source.contains("ScrollView {"))
        XCTAssertTrue(source.contains(".scrollDismissesKeyboard(.interactively)"))
        let verificationCanvas = try XCTUnwrap(pageCanvasUsage(in: source))
        XCTAssertEqual(verificationCanvas, pageCanvasUsage(in: homeSource))
        XCTAssertFalse(verificationCanvas.contains("warmSurface"))
        XCTAssertFalse(source.contains("Form {"))
        XCTAssertFalse(source.contains("Section {"))
        XCTAssertTrue(source.contains("participant-verification-brand-header"))
        // B1 repaint: two-tone GoodGrub wordmark with the campus qualifier.
        XCTAssertTrue(source.contains("Text(AppBrand.name)"))
        XCTAssertTrue(source.contains("Text(\" at \\(AppBrand.campus)\")"))
        XCTAssertTrue(source.contains("Codes expire after 10 minutes."))
        XCTAssertTrue(source.contains("participant-verification-code-lifetime"))
        XCTAssertFalse(header.contains("Section"))
        XCTAssertFalse(header.contains("commonPlateGroupedSurface"))
        XCTAssertFalse(email.contains("commonPlateGroupedSurface"))
        let dismissalControl = try declarationSource(
            startMarker: "private var closeButton: some View {",
            endMarker: "    /// Verification is an approved",
            in: "ios/CommonPlateios/CommonPlateios/Views/ParticipantVerificationView.swift"
        )
        // B1: the dismissal is the first scroll-content element so VoiceOver
        // reads it before the form, not a toolbar item read after it.
        let entry = try declarationSource(
            startMarker: "private var verificationEntry: some View {",
            endMarker: "    /// Placed first in the scroll content",
            in: "ios/CommonPlateios/CommonPlateios/Views/ParticipantVerificationView.swift"
        )
        let closeIndex = try XCTUnwrap(entry.range(of: "closeButton\n")).lowerBound
        let headerIndex = try XCTUnwrap(entry.range(of: "verificationBrandHeader")).lowerBound
        XCTAssertLessThan(closeIndex, headerIndex)
        XCTAssertFalse(entry.contains("ToolbarItem"))
        // B1: the shared screen close control owns the 44×44 warm circle, 17pt
        // semibold xmark and hairline; this screen supplies label and action.
        XCTAssertTrue(dismissalControl.contains("CommonPlateScreenCloseControl("))
        XCTAssertTrue(dismissalControl.contains("action: cancel"))
        XCTAssertTrue(dismissalControl.contains("\"Close email verification\""))
        let shared = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios/Design/CommonPlateScreenCloseControl.swift"), encoding: .utf8)
        XCTAssertTrue(shared.contains("Image(systemName: \"xmark\")"))
        XCTAssertTrue(shared.contains(".font(.system(size: 17, weight: .semibold))"))
        XCTAssertTrue(shared.contains(".frame(width: 44, height: 44)"))
        XCTAssertTrue(shared.contains(".background(CommonPlateStyle.Color.warmSurface, in: Circle())"))
        XCTAssertFalse(dismissalControl.contains("Button(\"Cancel\")"))
        XCTAssertTrue(source.contains(
            "case .awaitingCode(let address, _, let resendAvailableAt):\n"
                + "                    codeSection(address: address, resendAvailableAt: resendAvailableAt)"
        ))
        XCTAssertFalse(code.contains("Form {"))
        XCTAssertFalse(code.contains("Section {"))
        XCTAssertFalse(code.contains("commonPlateGroupedSurface"))
        XCTAssertFalse(source.contains("commonPlateGroupedSurface"))
    }

    /// The presentation contract is semantic: Home and verification share a
    /// full-page canvas, and it is not the grouped warm-surface treatment.
    /// It intentionally does not pin a particular token name.
    private func pageCanvasUsage(in source: String) -> String? {
        let pattern = #"\.background\(CommonPlateStyle\.Color\.(?!warmSurface)[A-Za-z][A-Za-z0-9]*\.ignoresSafeArea\(\)\)"#
        guard let range = source.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return String(source[range])
    }

    private func declarationSource(
        startMarker: String,
        endMarker: String,
        in relativePath: String = "ios/CommonPlateios/CommonPlateios/ContentView.swift"
    ) throws -> String {
        let source = try fileSource(relativePath)
        let start = try XCTUnwrap(source.range(of: startMarker))
        let end = try XCTUnwrap(source.range(of: endMarker, range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private func fileSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CommonPlateiosTests
            .deletingLastPathComponent() // CommonPlateios
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repository root
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
