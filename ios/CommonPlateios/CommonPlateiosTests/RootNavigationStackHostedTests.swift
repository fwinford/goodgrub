import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

/// Regression for the fatal
/// `SwiftUI.AnyNavigationPath.Error.comparisonTypeMismatch`: mirrors the
/// root `NavigationStack(path:)` shape `ContentView` builds, where the root
/// swaps between Home and the real verification gate as identity comes and
/// goes while the typed `[AppRoute]` path is rewritten by the same change.
/// The root gate must not introduce a nested `NavigationStack`.
@MainActor
final class RootNavigationStackHostedTests: XCTestCase {
    private final class Navigation: ObservableObject {
        @Published var path: [AppRoute] = []
    }

    private struct Root: View {
        @ObservedObject var identity: ParticipantIdentityStore
        @ObservedObject var navigation: Navigation
        let gate: (ParticipantIdentityStore) -> AnyView

        var body: some View {
            NavigationStack(path: $navigation.path) {
                Group {
                    if identity.isVerified {
                        Text("home")
                    } else {
                        gate(identity)
                    }
                }
                .navigationDestination(for: AppRoute.self) { _ in Text("destination") }
            }
            .onChange(of: identity.identity) { previous, current in
                if previous != nil, current == nil {
                    navigation.path = []
                }
            }
        }
    }

    private func makeIdentity(verified: Bool) -> ParticipantIdentityStore {
        let stored = verified
            ? ParticipantIdentityRecord(
                principal: "taylor@nyu.edu",
                authority: canonicalParticipantAuthorityFixture,
                verifiedAt: Date(timeIntervalSince1970: 1_000)
            )
            : nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
        return ParticipantIdentityStore(
            service: ParticipantVerificationService(client: client),
            storage: InMemoryParticipantIdentityStorage(stored: stored)
        )
    }

    private func mount(_ root: some View) throws -> UIWindow {
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
        for _ in 0..<15 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            window.layoutIfNeeded()
        }
    }

    func testSignOutWithPushedSettingsSwapsToRootGateWithoutCrashing() async throws {
        let identity = makeIdentity(verified: true)
        identity.configureInstallationAssociation { _ in }
        let navigation = Navigation()
        let window = try mount(Root(
            identity: identity,
            navigation: navigation,
            gate: { AnyView(ParticipantVerificationView(store: $0, isRootGate: true)) }
        ))

        navigation.path = [.settings]
        settle(window)
        await identity.removeIdentity()
        settle(window)

        XCTAssertTrue(navigation.path.isEmpty)
        XCTAssertFalse(identity.isVerified)
        window.isHidden = true
    }

    func testFirstVerificationFromRootGateRevealsHome() async throws {
        let identity = makeIdentity(verified: false)
        let navigation = Navigation()
        let window = try mount(Root(
            identity: identity,
            navigation: navigation,
            gate: { AnyView(ParticipantVerificationView(store: $0, isRootGate: true)) }
        ))
        identity.beginVerificationIfNeeded()
        settle(window)
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: Data(#"{"verification":{"expiresAt":"2026-07-28T16:10:00.000Z","resendAvailableAt":"2026-07-28T16:01:00.000Z"}}"#.utf8)))
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: Data(#"{"participant":{"email":"taylor@nyu.edu"},"authority":"\#(canonicalParticipantAuthorityFixture)"}"#.utf8)))
        await identity.requestCode(for: "taylor@nyu.edu")
        settle(window)
        let verified = await identity.submitCode("424242")
        settle(window)

        XCTAssertTrue(verified)
        window.isHidden = true
        RequestFetchingURLProtocol.reset()
    }

    func testRejectedIdentityWithPushedRequestFoodSwapsToRootGateWithoutCrashing() throws {
        let identity = makeIdentity(verified: true)
        let navigation = Navigation()
        let window = try mount(Root(
            identity: identity,
            navigation: navigation,
            gate: { AnyView(ParticipantVerificationView(store: $0, isRootGate: true)) }
        ))

        navigation.path = [.requestFood]
        settle(window)
        identity.discardRejectedIdentity()
        settle(window)

        XCTAssertTrue(navigation.path.isEmpty)
        window.isHidden = true
    }

    func testRootGateDoesNotDeclareNestedNavigationStack() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("CommonPlateios/Views/ParticipantVerificationView.swift"),
            encoding: .utf8
        )
        let entryStart = try XCTUnwrap(source.range(of: "private var verificationEntry: some View {"))
        let contentStart = try XCTUnwrap(source.range(of: "private var verificationContent: some View {"))
        let entry = String(source[entryStart.upperBound..<contentStart.lowerBound])

        XCTAssertTrue(entry.contains("if isRootGate {"))
        let rootBranch = try XCTUnwrap(entry.components(separatedBy: "} else {").first)
        XCTAssertFalse(rootBranch.contains("NavigationStack"))
        XCTAssertTrue(entry.contains("NavigationStack"), "Sheet presentations keep their own stack.")
    }
}
