import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

#if DEBUG
private final class CountingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { requests += 1; return false }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

/// Development-only preview (W4-MSG1 CP6 UI preview). Simulator-hosted and
/// in-memory only: none of this is evidence of live backend, WebSocket,
/// moderation or physical-device behavior.
@MainActor
final class MessagingPreviewTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 1_800_000_000)
    private var windows: [UIWindow] = []

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(CountingURLProtocol.self)
        CountingURLProtocol.requests = 0
    }

    override func tearDown() {
        URLProtocol.unregisterClass(CountingURLProtocol.self)
        windows.forEach { $0.isHidden = true }
        windows.removeAll()
        super.tearDown()
    }

    // MARK: Helpers

    private func repoURL(_ relative: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<2 { url.deleteLastPathComponent() }
        return url.appendingPathComponent(relative)
    }

    private func previewSources() throws -> [(name: String, text: String)] {
        let dir = repoURL("CommonPlateios/Messaging/Preview")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(names.isEmpty)
        return try names.sorted().map { ($0, try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)) }
    }

    private func makeCoordinator(
        _ scenario: MessagingPreviewScenario,
        _ role: RequestConversationRole,
        composition: RequestMessagingComposition? = nil
    ) -> ConversationCoordinator {
        let composition = composition ?? MessagingPreviewComposition.make(anchor: { self.anchor })
        return composition.makeCoordinator!(
            MessagingPreviewFixtures.requestID(scenario, role),
            { MessagingPreviewComposition.fictionalAuthority },
            {}
        )
    }

    private func eventually(_ message: String = "", _ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out. \(message)")
    }

    private func texts(_ coordinator: ConversationCoordinator) -> [String] {
        coordinator.items.map {
            switch $0 {
            case .message(let message): message.text
            case .local(let local): local.text
            }
        }
    }

    // MARK: 1. Openable in an authorized development configuration

    func testPreviewLaunchRequiresExplicitEnvironmentOptIn() {
        XCTAssertFalse(MessagingPreviewLaunch.isRequested(environment: [:]))
        XCTAssertFalse(MessagingPreviewLaunch.isRequested(environment: [MessagingPreviewLaunch.environmentKey: "0"]))
        XCTAssertFalse(MessagingPreviewLaunch.isRequested(environment: [MessagingPreviewLaunch.environmentKey: "true"]))
        XCTAssertTrue(MessagingPreviewLaunch.isRequested(environment: [MessagingPreviewLaunch.environmentKey: "1"]))
    }

    func testStartDirectiveParsesOnlyKnownScenarioAndRole() {
        let key = MessagingPreviewLaunch.startKey
        XCTAssertNil(MessagingPreviewLaunch.start(environment: [:]))
        XCTAssertNil(MessagingPreviewLaunch.start(environment: [key: "long"]))
        XCTAssertNil(MessagingPreviewLaunch.start(environment: [key: "bogus:helper"]))
        XCTAssertNil(MessagingPreviewLaunch.start(environment: [key: "long:admin"]))
        let parsed = MessagingPreviewLaunch.start(environment: [key: "long:helper"])
        XCTAssertEqual(parsed?.0, .long)
        XCTAssertEqual(parsed?.1, .helper)
    }

    func testPreviewSchemeOptsInAndNormalSchemeDoesNot() throws {
        let schemes = repoURL("CommonPlateios.xcodeproj/xcshareddata/xcschemes")
        let preview = try String(
            contentsOf: schemes.appendingPathComponent("CommonPlateios Messaging Preview.xcscheme"), encoding: .utf8
        )
        let normal = try String(
            contentsOf: schemes.appendingPathComponent("CommonPlateios.xcscheme"), encoding: .utf8
        )
        XCTAssertTrue(preview.contains(MessagingPreviewLaunch.environmentKey))
        XCTAssertFalse(normal.contains(MessagingPreviewLaunch.environmentKey))
    }

    func testPreviewRootAndConversationHostRenderOpenable() async throws {
        let box = PreviewPathBox()
        let composition = MessagingPreviewComposition.make(anchor: { self.anchor })
        let requestID = MessagingPreviewFixtures.requestID(.reserved, .requester)
        for view in [
            AnyView(MessagingPreviewRootView()),
            AnyView(PreviewHostHarness(box: box, composition: composition, requestID: requestID, role: .requester)),
        ] {
            let controller = UIHostingController(rootView: view)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            windows.append(window)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
        }
        XCTAssertEqual(CountingURLProtocol.requests, 0)
    }

    // MARK: 2. Absent from Release

    func testEveryPreviewSourceIsWhollyInsideDebugConditional() throws {
        for (name, text) in try previewSources() {
            let code = text.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") }
            XCTAssertEqual(code.first, "#if DEBUG", name)
            XCTAssertEqual(code.last, "#endif", name)
            XCTAssertEqual(code.filter { $0.hasPrefix("#if") }.count, 1, "\(name) must have one conditional")
            XCTAssertFalse(code.contains { $0.hasPrefix("#else") || $0.hasPrefix("#elseif") }, name)
        }
    }

    func testAppEntryReferencesPreviewOnlyInsideDebugBranch() throws {
        let app = try String(contentsOf: repoURL("CommonPlateios/CommonPlateiosApp.swift"), encoding: .utf8)
        var depth = 0
        var inDebugBranch = false
        for line in app.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "#if DEBUG" { inDebugBranch = true; depth += 1; continue }
            if trimmed == "#else" || trimmed == "#endif" { inDebugBranch = false; if trimmed == "#endif" { depth -= 1 }; continue }
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
            if trimmed.contains("MessagingPreview") {
                XCTAssertTrue(inDebugBranch, "Preview referenced outside #if DEBUG: \(trimmed)")
            }
        }
        XCTAssertEqual(depth, 0)
    }

    func testOnlyTheDebugBuildConfigurationDefinesTheDebugCondition() throws {
        let project = try String(
            contentsOf: repoURL("CommonPlateios.xcodeproj/project.pbxproj"), encoding: .utf8
        )
        let blocks = project.components(separatedBy: "isa = XCBuildConfiguration;").dropFirst()
        var conditioned = 0
        for block in blocks {
            let body = String(block)
            if body.contains("SWIFT_ACTIVE_COMPILATION_CONDITIONS") {
                conditioned += 1
                XCTAssertTrue(body.contains("name = Debug;"))
            }
            if body.contains("name = Release;") {
                XCTAssertFalse(body.contains("SWIFT_ACTIVE_COMPILATION_CONDITIONS"))
            }
        }
        XCTAssertEqual(conditioned, 1)
    }

    // MARK: 3. Production dormancy

    func testShippingCompositionStaysDormantAndPreviewDoesNotChangeIt() {
        XCTAssertFalse(RequestMessagingComposition.shipping.isEnabled)
        XCTAssertNil(RequestMessagingComposition.shipping.makeCoordinator)
        XCTAssertFalse(EnvironmentValues().requestMessaging.isEnabled)
        _ = MessagingPreviewComposition.make()
        _ = UIHostingController(rootView: MessagingPreviewRootView())
        XCTAssertFalse(RequestMessagingComposition.shipping.isEnabled)
        XCTAssertFalse(EnvironmentValues().requestMessaging.isEnabled)
        XCTAssertTrue(MessagingPreviewComposition.make().isEnabled)
    }

    // MARK: 4. Perspective binding

    func testFixturesFlipSenderByRoleAndKeepTextAndOrder() {
        for scenario in MessagingPreviewScenario.allCases {
            let requester = MessagingPreviewFixtures.messages(for: scenario, role: .requester, anchor: anchor)
            let helper = MessagingPreviewFixtures.messages(for: scenario, role: .helper, anchor: anchor)
            XCTAssertEqual(requester.map(\.text), helper.map(\.text))
            XCTAssertEqual(requester.map(\.sequence), Array(1...max(1, requester.count)).prefix(requester.count).map { $0 })
            for (r, h) in zip(requester, helper) {
                XCTAssertNotEqual(r.sender, h.sender)
            }
        }
        let requester = MessagingPreviewFixtures.messages(for: .reserved, role: .requester, anchor: anchor)
        XCTAssertEqual(requester.first?.sender, .other)
        XCTAssertEqual(requester[1].text, "Amazing, thank you!")
        XCTAssertEqual(requester[1].sender, .own)
    }

    func testRequestIdentifiersRoundTripAndUnknownIdentifiersResolveToNothing() {
        for scenario in MessagingPreviewScenario.allCases {
            for role in [RequestConversationRole.requester, .helper] {
                let id = MessagingPreviewFixtures.requestID(scenario, role)
                XCTAssertTrue(MessagingWire.isObjectID(id))
                let resolved = MessagingPreviewFixtures.resolve(requestID: id)
                XCTAssertEqual(resolved?.0, scenario)
                XCTAssertEqual(resolved?.1, role)
            }
        }
        XCTAssertNil(MessagingPreviewFixtures.resolve(requestID: "64c0000000000000000000a1"))
    }

    func testPreviewVerifierOffersActionsOnlyForTheMatchingFictionalRole() {
        let verifier = PreviewConversationVerifier()
        let requesterID = MessagingPreviewFixtures.requestID(.reserved, .requester)
        XCTAssertEqual(verifier.availableActions(requestID: requesterID, role: .requester).block, .viewedRequest)
        XCTAssertEqual(verifier.availableActions(requestID: requesterID, role: .helper), .none)
        XCTAssertEqual(verifier.availableActions(requestID: "64c0000000000000000000a1", role: .requester), .none)
        XCTAssertEqual(
            verifier.availableActions(requestID: MessagingPreviewFixtures.requestID(.reserved, .helper), role: .helper).block,
            .helpingReservation
        )
    }

    func testRealCoordinatorShowsRoleBoundOwnershipThroughPreviewDouble() async {
        let requester = makeCoordinator(.reserved, .requester)
        let helper = makeCoordinator(.reserved, .helper)
        requester.start()
        helper.start()
        await eventually { requester.hasLoaded && helper.hasLoaded }
        func senders(_ c: ConversationCoordinator) -> [ChatMessageSender] {
            c.items.compactMap { if case .message(let m) = $0 { m.sender } else { nil } }
        }
        XCTAssertEqual(senders(requester).first, .other)
        XCTAssertEqual(senders(helper).first, .own)
        XCTAssertEqual(senders(requester).map { $0 == .own }, senders(helper).map { $0 != .own })
    }

    // MARK: 5. No production transport

    func testSimulatedSendAppendsLocallyWithoutAnyURLSessionRequest() async {
        let coordinator = makeCoordinator(.reserved, .requester)
        coordinator.start()
        await eventually { coordinator.hasLoaded }
        let before = coordinator.items.count
        coordinator.draft = "Multi\nline reply from the requester"
        XCTAssertTrue(coordinator.canSend)
        coordinator.sendDraft()
        await eventually("send settles") {
            coordinator.items.count == before + 1 && texts(coordinator).last == "Multi\nline reply from the requester"
                && { if case .message = coordinator.items.last { true } else { false } }()
        }
        XCTAssertEqual(coordinator.draft, "")
        XCTAssertEqual(CountingURLProtocol.requests, 0)
    }

    func testPreviewSourcesNeverReferenceLiveNetworkStoreOrModerationSeams() throws {
        let forbidden = [
            "APIClient", "URLSession", "URLRequest", "ConversationHTTPClient",
            "URLSessionConversationSocketTransport", "RequestStore", "RequestService",
            "blockParticipant", "blockRequesterOfViewedRequest", "blockHelpedRequester",
            "submitParticipantReport", "presentReportPopup", "ParticipantReportView",
            "UserDefaults", "Keychain", "FileManager", "APIConfiguration",
            "ParticipantIdentityStore", "PushSubscription", "UNUserNotificationCenter",
        ]
        for (name, text) in try previewSources() {
            for token in forbidden {
                XCTAssertFalse(text.contains(token), "\(name) references \(token)")
            }
        }
    }

    func testPreviewComposeHasNoSocketTransport() throws {
        let source = try previewSources().first { $0.name == "MessagingPreviewComposition.swift" }!.text
        XCTAssertTrue(source.contains("socketTransport: nil"))
    }

    // MARK: 6. Report / Block are local

    func testBlockClosesTheConversationLocallyAndForever() async {
        let session = RequestConversationSession(
            requestID: MessagingPreviewFixtures.requestID(.reserved, .helper),
            role: .helper,
            coordinator: makeCoordinator(.reserved, .helper),
            verifier: PreviewConversationVerifier()
        )
        session.begin(isForeground: true)
        await eventually { session.coordinator.hasLoaded }
        XCTAssertTrue(session.actions.report)
        XCTAssertEqual(session.actions.block, .helpingReservation)
        session.blockSucceeded()
        XCTAssertEqual(session.state, .closed)
        XCTAssertEqual(session.coordinator.phase, .ended)
        XCTAssertTrue(session.coordinator.items.isEmpty)
        XCTAssertEqual(session.actions, .none)
        session.sceneDidBecomeActive()
        session.retryVerification()
        XCTAssertEqual(session.state, .closed)
        XCTAssertEqual(CountingURLProtocol.requests, 0)
    }

    // MARK: 7. Fixture isolation

    func testEntriesAreIsolatedFromOneAnotherWithFreshStateEachTime() async {
        let composition = MessagingPreviewComposition.make(anchor: { self.anchor })
        let first = makeCoordinator(.reserved, .requester, composition: composition)
        first.start()
        await eventually { first.hasLoaded }
        first.draft = "unsent draft"
        first.sendDraft()
        first.draft = "second draft"
        await eventually { first.items.count == 6 }

        let second = makeCoordinator(.reserved, .requester, composition: composition)
        second.start()
        await eventually { second.hasLoaded }
        XCTAssertEqual(second.items.count, 5)
        XCTAssertEqual(second.draft, "")
        XCTAssertFalse(texts(second).contains("unsent draft"))

        let empty = makeCoordinator(.empty, .helper, composition: composition)
        empty.start()
        await eventually { empty.hasLoaded }
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertEqual(empty.draft, "")
    }

    func testScenarioBehaviours() async {
        let closed = makeCoordinator(.closed, .requester)
        closed.start()
        await eventually { closed.phase == .unavailable }

        let loading = makeCoordinator(.loading, .requester)
        loading.start()
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(loading.isLoadingInitialMessages)
        loading.dismiss()

        let long = makeCoordinator(.long, .requester)
        long.start()
        await eventually { long.hasLoaded }
        XCTAssertTrue(long.hasOlder)
        XCTAssertGreaterThan(long.items.count, 20)

        let failing = makeCoordinator(.sendFailure, .helper)
        failing.start()
        await eventually { failing.hasLoaded }
        failing.draft = "Will fail once"
        failing.sendDraft()
        await eventually("failure surfaces") {
            if case .local(let local) = failing.items.last, case .failed = local.state { return true }
            return false
        }
        guard case .local(let local) = failing.items.last else { return XCTFail("expected a failed local message") }
        failing.retryFailed(local.clientMessageId)
        await eventually("retry succeeds") {
            if case .message = failing.items.last { return true }
            return false
        }
        XCTAssertEqual(CountingURLProtocol.requests, 0)
    }

    func testUnknownPreviewRequestFailsClosed() async {
        let composition = MessagingPreviewComposition.make()
        let coordinator = composition.makeCoordinator!("64c0000000000000000000a1", { MessagingPreviewComposition.fictionalAuthority }, {})
        coordinator.start()
        await eventually { coordinator.phase == .unavailable }
        XCTAssertTrue(coordinator.items.isEmpty)
    }

    // MARK: 8. Real navigation unchanged

    func testRealEntryRowStaysSuppressedWithoutCompositionAndRoutesThroughAppRoute() {
        let id = MessagingPreviewFixtures.requestID(.reserved, .requester)
        let route = AppRoute.requestConversation(requestID: id, role: .requester)
        XCTAssertEqual(AppRoute.appending(route, to: []), [route])
        XCTAssertEqual(AppRoute.appending(route, to: [route]), [route])
        XCTAssertTrue(AppRoute.hasOpenConversation(in: [route]))
        XCTAssertFalse(RequestMessagingComposition.shipping.isEnabled)
    }
}

@MainActor
private final class PreviewPathBox: ObservableObject {
    @Published var path: [AppRoute] = []
}

private struct PreviewHostHarness: View {
    @ObservedObject var box: PreviewPathBox
    let composition: RequestMessagingComposition
    let requestID: String
    let role: RequestConversationRole

    var body: some View {
        NavigationStack {
            MessagingPreviewConversationHost(
                requestID: requestID, role: role, composition: composition, path: $box.path
            )
        }
    }
}
#endif
