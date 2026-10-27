//
//  HelpingDiscoveryAccessibilityActivationHostedTests.swift
//  CommonPlateiosTests
//
// W4-O1 F2 proof. Mounts the real production `HomeExchangeView` in a real
// `NavigationStack` and `UIWindow`, finds the highlighted `Needs help`
// card's accessibility element in the tree SwiftUI actually produces, and
// calls `accessibilityActivate()` on it — the call VoiceOver makes for a
// double-tap on the focused element. It proves the Home-card-open report
// fires through that path, and that the card still navigates.
//
// Scope honesty: this is an in-process accessibility activation, not a
// running VoiceOver screen reader. Real VoiceOver on a device remains a
// separate manual check.
import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

@MainActor
final class HelpingDiscoveryAccessibilityActivationHostedTests: XCTestCase {
    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    private final class Recorder: ObservableObject {
        var reportedCardIDs: [String] = []
        @Published var path = NavigationPath()
    }

    private struct Root: View {
        @ObservedObject var recorder: Recorder
        let store: RequestStore
        let discoverySelectedRequestID: String?
        let makeStores: () -> (ParticipantIdentityStore, AlertSubscriptionStore, PushSubscriptionStore, ParticipantEmailUnsubscribeStore)

        var body: some View {
            let stores = makeStores()
            NavigationStack(path: $recorder.path) {
                HomeExchangeView(
                    store: store,
                    identityStore: stores.0,
                    alertSubscriptionStore: stores.1,
                    pushSubscriptionStore: stores.2,
                    unsubscribeStore: stores.3,
                    isRevealingLandingContinuityCard: false,
                    onRequestMeal: {},
                    discoverySelectedRequestID: discoverySelectedRequestID,
                    onOpenEligibleRequestCard: { recorder.reportedCardIDs.append($0) },
                    // Mirrors ContentView's wiring: the marker, then the push.
                    onActivateEligibleRequestCard: { request in
                        recorder.reportedCardIDs.append(request.id)
                        recorder.path.append(AppRoute.requestDetail(request))
                    }
                )
                .navigationDestination(for: AppRoute.self) { _ in EmptyView() }
                .toolbar(.hidden, for: .navigationBar)
            }
        }
    }

    func testAccessibilityActivationOfTheHighlightedCardReportsTheHomeCardOpen() async throws {
        let recorder = Recorder()
        let window = try await mountHome(discoverySelectedRequestID: "r0", recorder: recorder)

        let card = try XCTUnwrap(accessibilityElement(identifier: "home-request-card-r0", in: window))
        let activated = card.accessibilityActivate()
        XCTAssertTrue(activated, "the card must handle accessibility activation (\(describe(card)))")
        settle(window)

        XCTAssertEqual(recorder.reportedCardIDs, ["r0"],
                       "accessibility activation must report the Home-card-open event exactly once")
        XCTAssertEqual(recorder.path.count, 1,
                       "the same activation must open the request detail exactly once")
    }

    func testActivationReportsNothingWhenNoDiscoveryTreatmentIsActive() async throws {
        let recorder = Recorder()
        let window = try await mountHome(discoverySelectedRequestID: nil, recorder: recorder)

        let card = try XCTUnwrap(accessibilityElement(identifier: "home-request-card-r0", in: window))
        XCTAssertTrue(card.accessibilityActivate())
        settle(window)

        XCTAssertTrue(recorder.reportedCardIDs.isEmpty)
        XCTAssertEqual(recorder.path.count, 1, "ordinary cards still navigate")
    }

    // MARK: - Mounting

    private func mountHome(discoverySelectedRequestID: String?, recorder: Recorder) async throws -> UIWindow {
        let store = makeRequestStore()
        RequestFetchingURLProtocol.enqueue(.response(data: listResponse(["r0", "r1"].map(requestObject))))
        await store.fetchRequests()

        let identity = makeIdentityStore()
        let alerts = makeAlertStore()
        let push = makePushStore()
        let unsubscribe = makeUnsubscribeStore()
        let root = Root(
            recorder: recorder,
            store: store,
            discoverySelectedRequestID: discoverySelectedRequestID,
            makeStores: { (identity, alerts, push, unsubscribe) }
        )

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

    private func describe(_ element: NSObject) -> String {
        "\(type(of: element)) label=\(element.accessibilityLabel ?? "-") traits=\(element.accessibilityTraits.rawValue)"
    }

    private static func identifier(of element: NSObject) -> String? {
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue() as? String
    }

    /// The exposed accessibility element carrying `identifier`, found by
    /// walking the same tree the settings-frame hosted test walks.
    private func accessibilityElement(identifier: String, in window: UIWindow) -> NSObject? {
        var seen = Set<ObjectIdentifier>()
        var match: NSObject?
        func visit(_ element: NSObject) {
            guard match == nil, seen.insert(ObjectIdentifier(element)).inserted else { return }
            if Self.identifier(of: element) == identifier {
                match = element
                return
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
        if match == nil { XCTFail("tree dump: \(dump(window))") }
        return match
    }

    private func dump(_ window: UIWindow) -> String {
        var lines: [String] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ element: NSObject, _ depth: Int) {
            guard seen.insert(ObjectIdentifier(element)).inserted else { return }
            if element.accessibilityLabel != nil || Self.identifier(of: element) != nil {
                lines.append("\(depth) \(type(of: element)) label=\(element.accessibilityLabel ?? "-") id=\(Self.identifier(of: element) ?? "-")")
            }
            if let elements = element.accessibilityElements {
                for child in elements { if let child = child as? NSObject { visit(child, depth + 1) } }
            }
            let count = element.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let child = element.accessibilityElement(at: index) as? NSObject { visit(child, depth + 1) }
                }
            }
            if let view = element as? UIView { for subview in view.subviews { visit(subview, depth + 1) } }
        }
        visit(window, 0)
        return lines.joined(separator: "\n")
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
