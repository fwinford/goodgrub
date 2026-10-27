//
//  HomeRefreshHostedScrollTests.swift
//  CommonPlateiosTests
//
// W4-H3 hosted proof. Mounts the real production `HomeExchangeView` inside a
// real `NavigationStack` and `UIWindow` and reads the real `UIScrollView` and
// the accessibility tree SwiftUI actually produces — this repository's only
// available hosted-proof technique (`docs/testing.md`: no UI-test target).
//
// Scope honesty: this proves layout-level facts on the simulator — the band
// adds no scroll range to short content, the ownership handoff follows a real
// scroll offset, and exactly one Settings action is accessibility-exposed.
// It does not prove the physical pull, the native refresh indicator's
// placement, handoff smoothness, VoiceOver behavior, or Reduce Motion; those
// remain physical-device checks.
import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

@MainActor
final class HomeRefreshHostedScrollTests: XCTestCase {
    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - The band adds no scroll range

    /// The persistent `Request a Meal` inset itself already gives short
    /// content `ctaClearance` points of scroll range (the pre-A2 H4 layout
    /// sized content to the full container height, ignoring that inset). That
    /// pre-existing range is unchanged here; this proves the A2 band adds
    /// none on top of it.
    func testBandAddsNoScrollRangeToShortUnavailableHome() async throws {
        let window = try await mountHome(requests: nil)
        let scrollView = try XCTUnwrap(findScrollView(in: window))

        XCTAssertLessThanOrEqual(scrollRange(scrollView), ctaClearance(scrollView, in: window) + 1)
    }

    func testBandAddsNoScrollRangeToShortEmptyHome() async throws {
        let window = try await mountHome(requests: [])
        let scrollView = try XCTUnwrap(findScrollView(in: window))

        XCTAssertLessThanOrEqual(scrollRange(scrollView), ctaClearance(scrollView, in: window) + 1)
    }

    func testTheBandIsActuallyReservedAtTheTop() async throws {
        let window = try await mountHome(requests: [])
        let scrollView = try XCTUnwrap(findScrollView(in: window))

        // Safe area plus a real reserved band (header height + paddings).
        XCTAssertGreaterThan(scrollView.adjustedContentInset.top, window.safeAreaInsets.top + 40)
    }

    func testLongHomeScrolls() async throws {
        let window = try await mountHome(requests: Array(0..<14).map { "r\($0)" })
        let scrollView = try XCTUnwrap(findScrollView(in: window))

        XCTAssertGreaterThan(scrollRange(scrollView), 100)
    }

    // MARK: - Header ownership follows real scroll position

    func testSettingsIsExposedOnceAndStaysStationaryThroughAPull() async throws {
        let window = try await mountHome(requests: Array(0..<14).map { "r\($0)" })
        let scrollView = try XCTUnwrap(findScrollView(in: window))
        let rest = -scrollView.adjustedContentInset.top

        let restFrames = settingsFrames(in: window)
        XCTAssertEqual(restFrames.count, 1, "exactly one Settings exposed at rest")
        let restY = try XCTUnwrap(restFrames.first).minY

        scrollView.setContentOffset(CGPoint(x: 0, y: rest - 90), animated: false)
        settle(window)

        let pulledFrames = settingsFrames(in: window)
        XCTAssertEqual(pulledFrames.count, 1, "exactly one Settings exposed while pulled")
        XCTAssertEqual(try XCTUnwrap(pulledFrames.first).minY, restY, accuracy: 0.5,
                       "CommonPlate's Settings stays put while the content is pulled down")
    }

    func testInScrollHeaderOwnsOrdinaryScrollingAndOwnershipReturnsAtRest() async throws {
        let window = try await mountHome(requests: Array(0..<14).map { "r\($0)" })
        let scrollView = try XCTUnwrap(findScrollView(in: window))
        let rest = -scrollView.adjustedContentInset.top

        let restY = try XCTUnwrap(settingsFrames(in: window).first).minY

        scrollView.setContentOffset(CGPoint(x: 0, y: rest + 40), animated: false)
        settle(window)
        let scrolledFrames = settingsFrames(in: window)
        XCTAssertEqual(scrolledFrames.count, 1, "exactly one Settings exposed while scrolled")
        XCTAssertEqual(try XCTUnwrap(scrolledFrames.first).minY, restY - 40, accuracy: 1,
                       "the in-scroll copy owns ordinary scrolling and moves with the content (not sticky)")

        scrollView.setContentOffset(CGPoint(x: 0, y: rest), animated: false)
        settle(window)
        let backFrames = settingsFrames(in: window)
        XCTAssertEqual(backFrames.count, 1, "exactly one Settings exposed back at rest")
        XCTAssertEqual(try XCTUnwrap(backFrames.first).minY, restY, accuracy: 0.5)
    }

    func testSettingsIsNotExposedAtAnyPositionOnceScrolledFarAway() async throws {
        let window = try await mountHome(requests: Array(0..<14).map { "r\($0)" })
        let scrollView = try XCTUnwrap(findScrollView(in: window))
        let rest = -scrollView.adjustedContentInset.top

        scrollView.setContentOffset(CGPoint(x: 0, y: rest + 300), animated: false)
        settle(window)

        // Whatever the system exposes for the scrolled-away in-scroll copy,
        // the stationary band copy must not be a second exposed Settings.
        XCTAssertLessThanOrEqual(settingsFrames(in: window).count, 1)
    }

    // MARK: - Mounting

    private func mountHome(requests ids: [String]?) async throws -> UIWindow {
        let store = makeRequestStore()
        if let ids {
            RequestFetchingURLProtocol.enqueue(.response(data: listResponse(ids.map(requestObject))))
        } else {
            RequestFetchingURLProtocol.enqueue(.failure(.notConnectedToInternet))
        }
        await store.fetchRequests()

        let root = NavigationStack {
            HomeExchangeView(
                store: store,
                identityStore: makeIdentityStore(),
                alertSubscriptionStore: makeAlertStore(),
                pushSubscriptionStore: makePushStore(),
                unsubscribeStore: makeUnsubscribeStore(),
                isRevealingLandingContinuityCard: false,
                onRequestMeal: {}
            )
            .navigationDestination(for: AppRoute.self) { _ in EmptyView() }
            .toolbar(.hidden, for: .navigationBar)
        }

        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        settle(window)
        return window
    }

    private func settle(_ window: UIWindow) {
        for _ in 0..<12 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            window.layoutIfNeeded()
        }
    }

    private func findScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView, scrollView.bounds.height > 100 {
            return scrollView
        }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) { return found }
        }
        return nil
    }

    /// Total distance the user could scroll between the resting top and the
    /// resting bottom, accounting for the adjusted (safe-area/inset) edges.
    private func scrollRange(_ scrollView: UIScrollView) -> CGFloat {
        let inset = scrollView.adjustedContentInset
        let minOffset = -inset.top
        let maxOffset = scrollView.contentSize.height - scrollView.bounds.height + inset.bottom
        return max(0, maxOffset - minOffset)
    }

    /// Pre-existing bottom clearance the persistent CTA contributes to the
    /// scroll view's bottom inset (the adjusted inset beyond the system safe
    /// area).
    private func ctaClearance(_ scrollView: UIScrollView, in window: UIWindow) -> CGFloat {
        max(0, scrollView.adjustedContentInset.bottom - window.safeAreaInsets.bottom)
    }

    /// Accessibility frames (screen coordinates) of every exposed element
    /// labelled `Settings` in the tree SwiftUI actually produces.
    private func settingsFrames(in window: UIWindow) -> [CGRect] {
        var frames: [CGRect] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ element: NSObject) {
            guard seen.insert(ObjectIdentifier(element)).inserted else { return }
            if element.accessibilityLabel == "Settings", (element as? UIView)?.isHidden != true {
                frames.append(element.accessibilityFrame)
            }
            if let elements = element.accessibilityElements {
                for child in elements { if let child = child as? NSObject { visit(child) } }
            }
            let count = element.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let child = element.accessibilityElement(at: index) as? NSObject { visit(child) }
                }
            }
            if let view = element as? UIView {
                for subview in view.subviews { visit(subview) }
            }
        }
        visit(window)
        return frames
    }

    // MARK: - Stores

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func client() -> APIClient {
        APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session()
        )
    }

    private func makeRequestStore() -> RequestStore {
        RequestStore(
            service: RequestService(client: client()),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { "64c0000000000000000000a1.1.credential" },
            participantAuthorityRejected: {}
        )
    }

    private func makeIdentityStore() -> ParticipantIdentityStore {
        ParticipantIdentityStore(
            service: ParticipantVerificationService(client: client()),
            storage: InMemoryParticipantIdentityStorage()
        )
    }

    private func makeAlertStore() -> AlertSubscriptionStore {
        AlertSubscriptionStore(
            service: AlertSubscriptionService(client: client()),
            presentationStorage: InMemoryAlertSignupPresentationStorage()
        )
    }

    private func makePushStore() -> PushSubscriptionStore {
        PushSubscriptionStore(
            service: InstallationPushService(client: client()),
            installationStorage: InMemoryPushInstallationStorage(),
            authorizationCoordinator: StubPushAuthorizationCoordinator(),
            remoteNotificationRegistrar: StubRemoteNotificationRegistrar(),
            settingsOpener: StubPushSettingsOpener(),
            registrationTimeout: .seconds(5)
        )
    }

    private func makeUnsubscribeStore() -> ParticipantEmailUnsubscribeStore {
        ParticipantEmailUnsubscribeStore(
            service: ParticipantEmailUnsubscribeService(client: client())
        )
    }

    private func listResponse(_ requestObjects: [String]) -> Data {
        Data(#"{"requests":[\#(requestObjects.joined(separator: ","))]}"#.utf8)
    }

    private func requestObject(id: String) -> String {
        """
        {
          "id": "\(id)",
          "vendor": "Crave NYU",
          "food": "Rice bowl",
          "pickupWindowText": "ASAP",
          "mealSwipes": 2,
          "menuPath": "meal-exchange",
          "mealItems": ["Meal 1", "Meal 2"],
          "orderDetails": null,
          "estimatedDiningDollarsCents": null,
          "windowStart": null,
          "windowEnd": null,
          "status": "open",
          "createdAt": "2026-07-20T18:30:00.000Z",
          "expiresAt": "2026-07-20T23:30:00.000Z"
        }
        """
    }
}
