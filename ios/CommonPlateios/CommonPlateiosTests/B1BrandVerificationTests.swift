import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

/// W4-B1: GoodGrub identity, verification-before-Home, and the
/// unsupported-school entry. Behavior is asserted on the real types where they
/// are testable without a UI host; the root-gate wiring in `ContentView`,
/// which cannot be instantiated here, is asserted from its tracked source and
/// labelled as such.
final class B1BrandVerificationTests: XCTestCase {
    // MARK: - Three-way classification

    func testSupportedAddressesClassifyAsSupported() {
        for address in [
            "taylor@nyu.edu", "taylor@stern.nyu.edu", "TAYLOR@NYU.EDU",
            "  taylor@nyu.edu  ", "\tTaylor@Stern.NYU.EDU\n", "taylor+food@nyu.edu"
        ] {
            XCTAssertEqual(ParticipantEmailClassification.classify(address), .supported, address)
        }
    }

    func testWellFormedOtherSchoolsAndLookalikesAreUnsupportedNotMalformed() {
        for address in [
            "taylor@gmail.com", "taylor@example.edu", "taylor@law.nyu.edu",
            "taylor@fake-nyu.edu", "taylor@nyu.edu.example.com",
            "taylor@notnyu.edu", "taylor@nyu.education", "taylor@columbia.edu"
        ] {
            XCTAssertEqual(ParticipantEmailClassification.classify(address), .unsupportedSchool, address)
        }
    }

    func testMalformedAddressesClassifyAsMalformed() {
        for address in ["", "   ", "taylor", "taylor@", "@nyu.edu", "taylor@@nyu.edu", "taylor @nyu.edu", "nyu.edu"] {
            XCTAssertEqual(ParticipantEmailClassification.classify(address), .malformed, address)
        }
    }

    func testContinueIsActionableForAnyTypedAddressButNotWhileRequesting() {
        XCTAssertTrue(ParticipantVerificationView.canSendCode(email: "taylor@gmail.com", isRequesting: false))
        XCTAssertTrue(ParticipantVerificationView.canSendCode(email: "taylor@nyu.edu", isRequesting: false))
        XCTAssertFalse(ParticipantVerificationView.canSendCode(email: "   ", isRequesting: false))
        XCTAssertFalse(ParticipantVerificationView.canSendCode(email: "taylor@nyu.edu", isRequesting: true))
    }

    // Source-wiring assertion: the action's classification cases have direct
    // behavioral coverage in RequestEmailAllowlistTests.
    func testContinueHandlerSourceRoutesEmailSubmissionActions() throws {
        let source = try appSource("Views/ParticipantVerificationView.swift")
        let handler = try sourceDeclaration(
            in: source,
            startingAt: "private func continueTapped() {",
            endingAt: "/// Shape only."
        )
        let validation = try sourceDeclaration(
            in: handler,
            startingAt: "case .showValidation(let message):",
            endingAt: "case .requestVerification(let address):"
        )
        let request = try XCTUnwrap(handler.range(of: "case .requestVerification(let address):"))
        let requestBranch = String(handler[request.lowerBound...])

        XCTAssertTrue(validation.contains("localEmailError = message"))
        XCTAssertFalse(validation.contains("requestCode"))
        XCTAssertTrue(requestBranch.contains("localEmailError = nil"))
        XCTAssertTrue(requestBranch.contains("store.requestCode(for: address)"))
    }

    // MARK: - Verification entry copy and source styling

    func testVerificationCopyAtRuntimeAndHeaderColorSource() throws {
        XCTAssertEqual(ParticipantVerificationView.brandContext, AppBrand.nameWithCampus)
        XCTAssertEqual(ParticipantVerificationView.title, "Verify your NYU email")
        XCTAssertEqual(ParticipantVerificationView.codeLifetimeNotice, "Codes expire after 10 minutes.")
        XCTAssertEqual(ParticipantVerificationView.emailPlaceholder, "you@nyu.edu")
        XCTAssertEqual(ParticipantVerificationView.continueTitle, "Continue")
        XCTAssertEqual(
            ParticipantEmailClassification.classify("taylor@").validationMessage,
            "Enter a valid email address."
        )

        let source = try appSource("Views/ParticipantVerificationView.swift")
        let header = try sourceDeclaration(
            in: source,
            startingAt: "private var verificationBrandHeader: some View {",
            endingAt: "@ViewBuilder\n    private var emailSection: some View {"
        )
        XCTAssertTrue(header.contains("Text(AppBrand.name).foregroundStyle(.primary)"))
        XCTAssertTrue(header.contains("CommonPlateStyle.Color.campusQualifierCampus"))
        XCTAssertFalse(header.contains("CommonPlateStyle.Color.brandText"))
        XCTAssertFalse(header.contains("CommonPlateStyle.Color.campusQualifierNeutral"))
    }

    func testVerificationViewSourceOmitsPermanentPurposeAndEligibilityNotices() throws {
        let source = try appSource("Views/ParticipantVerificationView.swift")
        XCTAssertFalse(source.contains("purposeNotice"))
        XCTAssertFalse(source.contains("NYUEmailPolicy.requiredMessage"))
        XCTAssertFalse(source.contains("participant-verification-eligibility"))
        // The long replacement-consequence paragraph is superseded by the
        // active-activity gate.
        XCTAssertFalse(source.contains("replacementNotice"))
        XCTAssertFalse(source.contains("participant-replacement-notice"))
        // W4-UI1 Checkpoint 1 (E, Faith 2026-10-23): a revoked/stale saved
        // identity is cleared silently; this screen no longer explains why
        // it is asking again.
        XCTAssertFalse(source.contains("wasIdentityRevoked"))
        XCTAssertFalse(source.contains("revokedNotice"))
        XCTAssertFalse(source.contains("participant-revoked-notice"))
    }

    func testNYUPolicyConstantsAreUnchanged() {
        XCTAssertEqual(NYUEmailPolicy.allowedDomains, ["nyu.edu", "stern.nyu.edu"])
        XCTAssertEqual(
            NYUEmailPolicy.requiredMessage,
            "Enter an NYU email address ending in @nyu.edu or @stern.nyu.edu."
        )
    }

    func testRootGateHasNoDismissalControl() throws {
        let source = try appSource("Views/ParticipantVerificationView.swift")
        XCTAssertTrue(source.contains("if !isRootGate {"))
    }

    func testNotAtNYUIsRootOnlyAndNeverRequestsACodeOrVerifies() throws {
        XCTAssertEqual(ParticipantVerificationView.notAtNYUTitle, "Not at NYU?")
        let source = try appSource("Views/ParticipantVerificationView.swift")
        let start = try XCTUnwrap(source.range(of: "if isRootGate, store.flow?.purpose != .emailReplacement {"))
        let block = String(source[start.lowerBound...].prefix(520))
        XCTAssertTrue(block.contains("openUnsupportedWithoutEmail()"))
        let fn = try XCTUnwrap(source.range(of: "private func openUnsupportedWithoutEmail()"))
        let body = String(source[fn.lowerBound...].prefix(260))
        XCTAssertTrue(body.contains(#"unsupportedAddress = """#))
        for forbidden in ["requestCode", "submitCode", "removeIdentity", "save("] {
            XCTAssertFalse(body.contains(forbidden), forbidden)
        }
    }

    func testSignOutFailsClosedWithoutAuthorityAndUsesFinderURL() throws {
        let source = try appSource("Views/SettingsView.swift")
        XCTAssertTrue(source.contains("participantIdentityStore.currentAuthority() == nil"))
        XCTAssertTrue(source.contains("https://finder.nyc.gov/foodhelp/\""))
        XCTAssertFalse(source.contains("https://finder.nyc.gov/foodhelp/locations"))
        XCTAssertFalse(source.contains("nyc.gov/foodhelp\""))
    }

    func testIHaveAnNYUEmailReturnsToEntryWithNoDraftAndOpensNothing() throws {
        let source = try appSource("Views/ParticipantVerificationView.swift")
        let fn = try XCTUnwrap(source.range(of: "private func returnToEmailEntry()"))
        let body = String(source[fn.lowerBound...].prefix(260))
        for required in ["unsupportedAddress = nil", #"email = """#, "localEmailError = nil"] {
            XCTAssertTrue(body.contains(required), required)
        }
        XCTAssertFalse(body.contains("cancel()"))
        let view = try appSource("Views/UnsupportedSchoolView.swift")
        XCTAssertTrue(view.contains(".commonPlateMajorSecondaryAction()"))
        XCTAssertTrue(view.contains(#"Image("UnsupportedSchoolPlate")"#))
        XCTAssertFalse(view.contains("HelperSuccessMeal"))
        XCTAssertNotNil(UIImage(named: "UnsupportedSchoolPlate"))
    }

    // MARK: - Unsupported-school screen and contact

    func testUnsupportedSchoolCopyIsExact() {
        XCTAssertEqual(UnsupportedSchoolView.heading, "We're not at your school yet")
        XCTAssertEqual(
            UnsupportedSchoolView.body,
            "\(AppBrand.name) is starting at NYU, and we hope to expand to more campuses in the future."
        )
        XCTAssertEqual(UnsupportedSchoolView.contactTitle, "Contact \(AppBrand.name)")
        XCTAssertEqual(UnsupportedSchoolView.haveNYUEmailTitle, "I have an NYU email")
        XCTAssertEqual(UnsupportedSchoolView.wordmark, "\(AppBrand.name)")
        XCTAssertEqual(SupportContact.openFailedTitle, "Couldn't open your email app")
        XCTAssertEqual(
            SupportContact.openFailedBody,
            "You can copy our email address and contact us from another email app."
        )
        XCTAssertEqual(SupportContact.copyActionTitle, "Copy email address")
    }

    func testMailtoCarriesTheFixedSubjectAndNoBody() throws {
        let contact = SupportContact(address: "goodgrubsupport@gmail.com")
        XCTAssertTrue(contact.isConfigured)
        let url = try XCTUnwrap(contact.mailtoURL)
        XCTAssertEqual(url.scheme, "mailto")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "goodgrubsupport@gmail.com")
        XCTAssertEqual(components.queryItems?.count, 1)
        XCTAssertEqual(components.queryItems?.first?.name, "subject")
        XCTAssertEqual(components.queryItems?.first?.value, "Bringing \(AppBrand.name) to my campus")
        XCTAssertNil(components.queryItems?.first { $0.name == "body" })
    }

    func testUnconfiguredOrInvalidDestinationFailsClosed() {
        for value in [nil, "", "   ", "not-an-email", "a@b"] as [String?] {
            let contact = SupportContact(address: value)
            XCTAssertFalse(contact.isConfigured, String(describing: value))
            XCTAssertNil(contact.mailtoURL)
            XCTAssertNil(contact.address)
        }
    }

    func testShippedConfigurationDestinationIsPresent() {
        XCTAssertEqual(SupportContact().address, "goodgrubsupport@gmail.com")
    }

    func testUnsupportedSchoolHasNoCloseAndOffersOnlyTheReturnToEntry() throws {
        let screen = try appSource("Views/UnsupportedSchoolView.swift")
        XCTAssertFalse(screen.contains("CommonPlateScreenCloseControl("),
                       "I have an NYU email is the only way back; no separate X")
        XCTAssertFalse(screen.contains("onClose"))
        let entry = try appSource("Views/ParticipantVerificationView.swift")
        XCTAssertTrue(entry.contains("onHaveNYUEmail: returnToEmailEntry"))
        XCTAssertFalse(entry.contains("closeUnsupported"))
    }

    // MARK: - Welcome

    func testWelcomeButtonSaysContinue() {
        XCTAssertEqual(OnboardingCopy.continueTitle, "Continue")
        XCTAssertEqual(OnboardingCopy.brand, "\(AppBrand.name)")
    }

    // MARK: - Root gate (source inspection of ContentView)

    func testRootRendersGateInsteadOfHomeWhenUnverified() throws {
        let source = try appSource("ContentView.swift")
        XCTAssertTrue(source.contains("verifiedHomeOrGate(brandHasSettled: true)"))
        XCTAssertTrue(source.contains("verifiedHomeOrGate(brandHasSettled: brandHasSettled)"))
        let gate = try XCTUnwrap(source.range(of: "private func verifiedHomeOrGate"))
        let body = String(source[gate.lowerBound...].prefix(700))
        XCTAssertTrue(body.contains("if participantIdentityStore.isVerified"))
        XCTAssertTrue(body.contains("ParticipantVerificationView(store: participantIdentityStore, isRootGate: true)"))
        XCTAssertTrue(body.contains("beginVerificationIfNeeded()"))
    }

    func testProtectedReadsAndRoutingWaitForVerifiedAuthority() throws {
        let source = try appSource("ContentView.swift")
        XCTAssertTrue(source.contains(".task(id: participantIdentityStore.isVerified) {\n            guard participantIdentityStore.isVerified else { return }\n            _ = try? await requestStore.continueActiveReservationIfNeeded()"))
        for fn in [
            "private func routePendingHelperNotification() async {",
            "private func routePendingReservationWarning() async {",
            "private func routePendingRequesterFulfillmentNotification() async {"
        ] {
            let range = try XCTUnwrap(source.range(of: fn), fn)
            let next = String(source[range.upperBound...].prefix(120))
            XCTAssertTrue(next.contains("guard participantIdentityStore.isVerified else { return }"), fn)
        }
        let pickup = try XCTUnwrap(source.range(of: "private func routePendingPickupConfirmedNotification() {"))
        XCTAssertTrue(source[pickup.upperBound...].prefix(240).contains(
            "guard participantIdentityStore.isVerified,\n              let resolvedPath = notificationRouter.consumePickupConfirmedRoute() else { return }"
        ))
    }

    func testLosingIdentityUnwindsThePushedStack() throws {
        let source = try appSource("ContentView.swift")
        XCTAssertTrue(source.contains("} else if previous != nil, current == nil {"))
        let range = try XCTUnwrap(source.range(of: "} else if previous != nil, current == nil {"))
        XCTAssertTrue(String(source[range.upperBound...].prefix(500)).contains("path = []"))
    }

    // MARK: - Brand tokens

    private func sourceDeclaration(
        in source: String,
        startingAt startMarker: String,
        endingAt endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker), startMarker)
        let end = try XCTUnwrap(
            source.range(of: endMarker, range: start.upperBound..<source.endIndex),
            endMarker
        )
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private func hex(_ color: UIColor, dark: Bool) -> String {
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    private func luminance(_ color: UIColor, dark: Bool) -> Double {
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        func lin(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    private func contrast(_ a: UIColor, _ b: UIColor, dark: Bool) -> Double {
        let l1 = luminance(a, dark: dark), l2 = luminance(b, dark: dark)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    func testAccentIsTerracottaInBothAppearances() throws {
        let accent = try XCTUnwrap(UIColor(named: "AccentColor"))
        XCTAssertEqual(hex(accent, dark: false), "AD563D")
        XCTAssertEqual(hex(accent, dark: true), "AD563D")
        let white = UIColor.white
        XCTAssertGreaterThanOrEqual(contrast(white, accent, dark: false), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(white, accent, dark: true), 4.5)
    }

    func testBrandTextMeetsTextContrastOnCanvasAndWarmSurfaceInBothAppearances() throws {
        let brandText = try XCTUnwrap(UIColor(named: "CommonPlateBrandText"))
        let canvas = try XCTUnwrap(UIColor(named: "CommonPlateBaseCanvas"))
        let surface = try XCTUnwrap(UIColor(named: "CommonPlateWarmSurface"))
        for dark in [false, true] {
            XCTAssertGreaterThanOrEqual(contrast(brandText, canvas, dark: dark), 4.5, "canvas dark=\(dark)")
            XCTAssertGreaterThanOrEqual(contrast(brandText, surface, dark: dark), 4.5, "surface dark=\(dark)")
        }
    }

    /// Campus identity keeps NYU purple (a verified-only qualifier); timing,
    /// provenance and illustration are neutral warm grays, not violet.
    func testCampusKeepsPurpleAndOtherRolesAreNeutral() throws {
        let campus = try XCTUnwrap(UIColor(named: "CommonPlateCampusPurple"))
        XCTAssertEqual(hex(campus, dark: false), "5B2A86")
        XCTAssertEqual(hex(campus, dark: true), "9B6FD1")
        for name in ["CommonPlateProvenance", "CommonPlateTiming", "CommonPlateIllustration"] {
            let color = try XCTUnwrap(UIColor(named: name), name)
            for dark in [false, true] {
                let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
                XCTAssertGreaterThanOrEqual(r, g, "\(name) dark=\(dark) is warm, not violet")
                XCTAssertGreaterThanOrEqual(g, b, "\(name) dark=\(dark) is warm, not violet")
            }
        }
    }

    func testHelpingSurfaceIsWarmNeutralNotLavender() {
        for color in [CommonPlateStyle.Color.helpingCardSurface, CommonPlateStyle.Color.helpingCardBorder] {
            for dark in [false, true] {
                let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                UIColor(color).resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
                XCTAssertGreaterThanOrEqual(r, g, "dark=\(dark)")
                XCTAssertGreaterThanOrEqual(g, b, "dark=\(dark)")
            }
        }
    }

    func testNeutralRolesAndBrandTextMeetTextContrastOnEverySurface() throws {
        let surfaces: [(String, UIColor)] = [
            ("canvas", try XCTUnwrap(UIColor(named: "CommonPlateBaseCanvas"))),
            ("requestCard", UIColor(CommonPlateStyle.Color.requestCardSurface)),
            ("helpingCard", UIColor(CommonPlateStyle.Color.helpingCardSurface))
        ]
        for name in ["CommonPlateProvenance", "CommonPlateTiming", "CommonPlateBrandText", "CommonPlateUrgentTiming"] {
            let text = try XCTUnwrap(UIColor(named: name), name)
            for (surfaceName, surface) in surfaces {
                for dark in [false, true] {
                    XCTAssertGreaterThanOrEqual(
                        contrast(text, surface, dark: dark), 4.5,
                        "\(name) on \(surfaceName) dark=\(dark)"
                    )
                }
            }
        }
    }

    /// ASAP keeps an expressive role distinct from ordinary timing; the label
    /// text, not the color, carries the meaning.
    func testUrgentTimingIsADistinctRoleAndOrdinaryTimingStaysNeutral() throws {
        let urgent = UIColor(CommonPlateStyle.Color.timing(isUrgent: true))
        let ordinary = UIColor(CommonPlateStyle.Color.timing(isUrgent: false))
        for dark in [false, true] {
            XCTAssertNotEqual(hex(urgent, dark: dark), hex(ordinary, dark: dark), "dark=\(dark)")
        }
        XCTAssertEqual(ordinary, UIColor(CommonPlateStyle.Color.timing))
        let card = try appSource("Views/RequestCardView.swift")
        XCTAssertTrue(card.contains("request.timing == .asap"))
        XCTAssertTrue(card.contains("if case .helping = kind { return false }"))
    }

    func testSharedRequestCardSurfaceIsWarmNeutralInBothAppearances() {
        for color in [CommonPlateStyle.Color.requestCardSurface, CommonPlateStyle.Color.requestCardBorder] {
            for dark in [false, true] {
                let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                UIColor(color).resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
                XCTAssertGreaterThanOrEqual(r, g, "dark=\(dark)")
                XCTAssertGreaterThanOrEqual(g, b, "dark=\(dark)")
            }
        }
    }

    func testBeingHelpedGoldMeetsTextContrastOnRequestCardsAndCanvas() throws {
        let gold = UIColor(RequestCardView.beingHelpedColor)
        let canvas = try XCTUnwrap(UIColor(named: "CommonPlateBaseCanvas"))
        for dark in [false, true] {
            XCTAssertGreaterThanOrEqual(
                contrast(gold, UIColor(CommonPlateStyle.Color.requestCardSurface), dark: dark), 4.5, "card dark=\(dark)")
            XCTAssertGreaterThanOrEqual(contrast(gold, canvas, dark: dark), 4.5, "canvas dark=\(dark)")
        }
    }

    /// The status palette is not part of the refresh: error, warning, success
    /// and uncertain stay distinct from each other and from urgent timing.
    func testStatusSemanticsStayDistinct() {
        let kinds: [CommonPlateStatusKind] = [.error, .warning, .success, .uncertain]
        for dark in [false, true] {
            let tints = kinds.map { hex(UIColor($0.tint), dark: dark) }
            XCTAssertEqual(Set(tints).count, kinds.count, "dark=\(dark)")
            let urgent = hex(UIColor(CommonPlateStyle.Color.urgentTiming), dark: dark)
            XCTAssertFalse(tints.contains(urgent), "urgent timing must not mimic a status, dark=\(dark)")
        }
    }

    func testEmailFieldHasAnAccessibleLabelAndTitleTracksDynamicType() throws {
        XCTAssertEqual(ParticipantVerificationView.emailFieldLabel, "NYU email address")
        let source = try appSource("Views/ParticipantVerificationView.swift")
        XCTAssertTrue(source.contains(".accessibilityLabel(Self.emailFieldLabel)"))
        XCTAssertTrue(source.contains("commonPlateBrandDisplay(.title2, dynamicTypeSize: dynamicTypeSize)"))
        let small = CommonPlateStyle.BrandDisplay.uiFont(for: .title2, dynamicTypeSize: .large).pointSize
        let large = CommonPlateStyle.BrandDisplay.uiFont(for: .title2, dynamicTypeSize: .accessibility3).pointSize
        XCTAssertGreaterThan(large, small)
    }

    func testBeingHelpedGoldIsUnchangedAndNoYellowTokenExists() throws {
        let card = try appSource("Views/RequestCardView.swift")
        XCTAssertTrue(card.contains("beingHelpedColor"))
        let style = try appSource("Design/CommonPlateStyle.swift")
        XCTAssertFalse(style.lowercased().contains("yellow"))
        XCTAssertFalse(style.lowercased().contains("gold"))
    }

    func testQualifierIsNeutralBeforeVerificationAndCampusAfter() throws {
        XCTAssertEqual(
            CommonPlateStyle.Color.campusQualifier(isVerified: false),
            CommonPlateStyle.Color.campusQualifierNeutral
        )
        let verified = UIColor(CommonPlateStyle.Color.campusQualifier(isVerified: true))
        XCTAssertEqual(hex(verified, dark: false), "5B2A86")
    }

    // MARK: - Source helpers

    /// The product name lives only in `AppBrand`; no source file may
    /// hard-code it, so a rename never needs a per-screen sweep.
    func testProductNameIsDefinedOnlyInAppBrand() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" && url.lastPathComponent != "AppBrand.swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if line.range(of: AppBrand.name, options: .caseInsensitive) != nil && line.contains("\"") {
                    offenders.append("\(url.lastPathComponent): \(trimmed)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, offenders.joined(separator: "\n"))
    }

    private func appSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
