//
//  UI1Checkpoint1CorrectionsTests.swift
//  CommonPlateiosTests
//
// Hosted production-view captures with stubbed transport. Store calls arrange
// states; these tests do not exercise button taps or a physical walkthrough.
import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

@MainActor
final class UI1Checkpoint1CorrectionsTests: XCTestCase {
    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    @MainActor
    final class Host {
        let window: UIWindow
        let controller: UIHostingController<AnyView>

        init(_ root: some View) throws {
            let scene = try XCTUnwrap(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            )
            window = UIWindow(windowScene: scene)
            controller = UIHostingController(rootView: AnyView(root))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            settle()
        }

        func settle(_ seconds: TimeInterval = 0.6) {
            let end = Date().addingTimeInterval(seconds)
            repeat {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                window.layoutIfNeeded()
            } while Date() < end
        }

        func scroll(toFraction fraction: CGFloat) throws {
            let scrollView = try XCTUnwrap(firstScrollView(in: controller.view))
            let travel = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            scrollView.setContentOffset(CGPoint(x: 0, y: travel * fraction), animated: false)
            settle(0.5)
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }

        func enterEmail(_ value: String) throws {
            let field = try XCTUnwrap(emailTextField(in: controller.view))
            field.text = value
            field.sendActions(for: .editingChanged)
            settle(0.3)
        }

        private func firstScrollView(in view: UIView) -> UIScrollView? {
            if let scrollView = view as? UIScrollView { return scrollView }
            for subview in view.subviews {
                if let scrollView = firstScrollView(in: subview) { return scrollView }
            }
            return nil
        }

        private func emailTextField(in view: UIView) -> UITextField? {
            if let field = view as? UITextField,
               field.accessibilityIdentifier == "participant-verification-email"
                || field.placeholder == ParticipantVerificationView.emailPlaceholder {
                return field
            }
            for subview in view.subviews {
                if let field = emailTextField(in: subview) { return field }
            }
            return nil
        }

        func screenshot(named name: String, appearance: String) throws {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
            let image = renderer.image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            let captureName = "hosted-stubbed-\(name)-\(appearance)"
            attachment.name = captureName
            attachment.lifetime = .keepAlways
            XCTContext.runActivity(named: captureName) { activity in
                activity.add(attachment)
            }
        }

        func captureBothAppearances(named name: String) throws {
            window.overrideUserInterfaceStyle = .light
            settle(0.3)
            try screenshot(named: name, appearance: "light")
            window.overrideUserInterfaceStyle = .dark
            settle(0.3)
            try screenshot(named: name, appearance: "dark")
        }
    }

    private func makeIdentityStore(stored: ParticipantIdentityRecord? = nil) -> ParticipantIdentityStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return ParticipantIdentityStore(
            service: ParticipantVerificationService(client: client),
            storage: InMemoryParticipantIdentityStorage(stored: stored)
        )
    }

    private func challengeResponse() -> Data {
        Data(#"""
        {"verification":{
          "expiresAt": "2026-07-28T16:10:00.000Z",
          "resendAvailableAt": "2026-07-28T16:01:00.000Z"
        }}
        """#.utf8)
    }

    private func errorResponse(code: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"detail","fields":null}}"#.utf8)
    }

    // MARK: - Welcome hero, chevron-only scroll cue, and story-card reveal

    func testCorrectedWelcomeHero() throws {
        let host = try Host(OnboardingWelcomeView(onContinue: {}))
        defer { host.close() }
        try host.captureBothAppearances(named: "02-onboarding-welcome-hero-corrected")
        try host.scroll(toFraction: 0.35)
        try host.captureBothAppearances(named: "03-onboarding-story-cards-first-reveal-corrected")
        try host.scroll(toFraction: 1)
        try host.captureBothAppearances(named: "04-onboarding-story-cards-later-reveal-corrected")
    }

    func testNonNYUEmailShowsInlineFeedbackOnEditableEntry() async throws {
        let store = makeIdentityStore()
        store.beginVerificationIfNeeded()
        await store.requestCode(for: "test@e.com")

        XCTAssertEqual(store.verificationError?.message, "Enter a valid NYU email address.")
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
        XCTAssertEqual(store.flow?.stage, .enteringEmail)

        let host = try Host(ParticipantVerificationView(store: store, isRootGate: true))
        defer { host.close() }
        try host.enterEmail("test@e.com")
        try host.captureBothAppearances(named: "06-verification-non-nyu-inline-validation-corrected")
    }

    // MARK: - C: shortened code-entry supporting text

    func testCorrectedVerificationAwaitingCode() async throws {
        let store = makeIdentityStore()
        store.beginVerificationIfNeeded()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
        await store.requestCode(for: "student@nyu.edu")
        let host = try Host(ParticipantVerificationView(store: store, isRootGate: true))
        defer { host.close() }
        try host.captureBothAppearances(named: "05-verification-awaiting-code-corrected")
    }

    // MARK: - D: a flow's FIRST requestCode call hitting resendTooSoon now
    // stays on email entry with an honest "try again in a moment" error,
    // instead of jumping to a code-entry screen for a code this flow never
    // confirmed sending.

    func testCorrectedFreshFlowResendTooSoonStaysOnEmailEntry() async throws {
        let store = makeIdentityStore()
        store.beginVerificationIfNeeded()
        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 429, data: errorResponse(code: "VERIFICATION_RESEND_TOO_SOON"))
        )
        await store.requestCode(for: "student@nyu.edu")
        XCTAssertEqual(store.flow?.stage, .enteringEmail, "D: must not enter code entry on a flow's first attempt")
        let host = try Host(ParticipantVerificationView(store: store, isRootGate: true))
        defer { host.close() }
        try host.captureBothAppearances(named: "18-verification-fresh-resend-too-soon-stays-on-email-corrected")
    }

    // MARK: - E: revoked/stale saved identity no longer shows a notice; the
    // ordinary email-entry experience is presented.

    func testCorrectedIdentityRevokedShowsOrdinaryEntryNoNotice() throws {
        let storedRecord = ParticipantIdentityRecord(
            principal: "student@nyu.edu",
            authority: "64c0000000000000000000a1.1." + String(repeating: "A", count: 42),
            verifiedAt: Date()
        )
        let store = makeIdentityStore(stored: storedRecord)
        store.discardRejectedIdentity()
        store.beginVerificationIfNeeded()
        XCTAssertTrue(store.wasIdentityRevoked, "setup: the store-level signal still fires (E only removes the UI notice)")
        let host = try Host(ParticipantVerificationView(store: store, isRootGate: true))
        defer { host.close() }
        try host.captureBothAppearances(named: "16-verification-rejected-identity-ordinary-entry")
    }
}
