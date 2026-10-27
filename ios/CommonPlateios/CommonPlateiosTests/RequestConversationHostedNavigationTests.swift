import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

@MainActor
private final class NavBox: ObservableObject {
    @Published var path: [AppRoute] = []
}

private let requestA = "64c0000000000000000000a1"
private let requestB = "64c0000000000000000000a2"

/// Per-request scripted conversations: each request id gets its own transport
/// double, conversation id and distinct transcript text.
@MainActor
private final class ConversationRig {
    var https: [String: ScriptedHTTP] = [:]
    let verifier = StubVerifier()
    var lastSession: RequestConversationSession?
    let authority = MsgAuthorityBox()

    func script(_ requestID: String, text: String, conversationId: String) {
        let http = ScriptedHTTP()
        http.defaultConversationId = conversationId
        http.defaultHistory = { _ in .success(MsgFixture.history([MsgFixture.message(1, text: text)])) }
        https[requestID] = http
    }

    var composition: RequestMessagingComposition {
        .enabled { [self] id, _, rejected in
            ConversationCoordinator(
                requestId: id,
                http: https[id] ?? ScriptedHTTP(),
                socketTransport: nil,
                authorityProvider: { self.authority.value },
                participantAuthorityRejected: rejected,
                scheduler: ManualScheduler()
            )
        }
    }
}

private struct NavigationHarness: View {
    @ObservedObject var box: NavBox
    let rig: ConversationRig
    let store: RequestStore
    let identityStore: ParticipantIdentityStore
    let role: RequestConversationRole

    var body: some View {
        NavigationStack(path: $box.path) {
            VStack {
                RequestConversationEntryRow(requestID: requestA, role: role, path: $box.path)
                Text("HOME-SCREEN")
            }
            .navigationDestination(for: AppRoute.self) { route in
                if case .requestConversation(let id, let role) = route {
                    RequestConversationHostView(
                        requestID: id,
                        role: role,
                        composition: rig.composition,
                        store: store,
                        identityStore: identityStore,
                        verifier: rig.verifier,
                        path: $box.path,
                        onSessionCreated: { rig.lastSession = $0 }
                    )
                }
            }
        }
        .environment(\.requestMessaging, rig.composition)
        .environment(\.scenePhase, .active)
    }
}

/// Mounts the host directly (no NavigationStack) so the visible closed state
/// after a Block can be observed rather than popped away.
private struct DirectHostHarness: View {
    @ObservedObject var box: NavBox
    let rig: ConversationRig
    let store: RequestStore
    let identityStore: ParticipantIdentityStore
    let role: RequestConversationRole

    var body: some View {
        NavigationStack {
            RequestConversationHostView(
                requestID: requestA,
                role: role,
                composition: rig.composition,
                store: store,
                identityStore: identityStore,
                verifier: rig.verifier,
                path: $box.path,
                onSessionCreated: { rig.lastSession = $0 }
            )
        }
        .environment(\.scenePhase, .active)
    }
}

/// Simulator-hosted SwiftUI navigation proof with scripted HTTP and a scripted
/// URLProtocol. Not live-backend evidence (routes are unmounted) and not a
/// physical-device or keyboard check.
@MainActor
final class RequestConversationHostedNavigationTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func setUp() {
        super.setUp()
        ParticipantBlockURLProtocol.reset()
    }

    override func tearDown() {
        windows.forEach { $0.isHidden = true }
        windows.removeAll()
        ParticipantBlockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: Harness

    private func makeClient() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ParticipantBlockURLProtocol.self]
        return APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
    }

    private func makeStore(_ authority: MsgAuthorityBox) -> RequestStore {
        RequestStore(
            service: RequestService(client: makeClient()),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { authority.value },
            participantAuthorityRejected: {}
        )
    }

    private func makeIdentityStore() -> ParticipantIdentityStore {
        ParticipantIdentityStore(
            service: ParticipantVerificationService(client: makeClient()),
            storage: InMemoryParticipantIdentityStorage()
        )
    }

    private func mount<V: View>(_ view: V) throws -> UIWindow {
        try enableMessagingAccessibilityTree()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        windows.append(window)
        window.layoutIfNeeded()
        return window
    }

    private func pump(_ window: UIWindow, _ seconds: TimeInterval = 0.4) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(nanoseconds: 30_000_000)
            window.layoutIfNeeded()
        }
    }

    private func labels(_ root: NSObject) -> [String] {
        var out: [String] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ element: NSObject) {
            guard seen.insert(ObjectIdentifier(element)).inserted else { return }
            if let label = element.accessibilityLabel { out.append(label) }
            (element.accessibilityElements as? [NSObject])?.forEach(visit)
            let count = element.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for i in 0..<count { if let c = element.accessibilityElement(at: i) as? NSObject { visit(c) } }
            }
            (element as? UIView)?.subviews.forEach(visit)
        }
        visit(root)
        return out
    }

    private func element(_ window: UIWindow, containing text: String) -> NSObject? {
        var found: NSObject?
        var seen = Set<ObjectIdentifier>()
        func visit(_ e: NSObject) {
            guard found == nil, seen.insert(ObjectIdentifier(e)).inserted else { return }
            if (e.accessibilityLabel ?? "").contains(text) { found = e; return }
            (e.accessibilityElements as? [NSObject])?.forEach(visit)
            let count = e.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for i in 0..<count { if let c = e.accessibilityElement(at: i) as? NSObject { visit(c) } }
            }
            (e as? UIView)?.subviews.forEach(visit)
        }
        visit(window)
        return found
    }

    private func waitForLabel(_ window: UIWindow, _ text: String, present: Bool = true, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while (element(window, containing: text) != nil) != present, Date() < deadline { await pump(window, 0.1) }
        XCTAssertEqual(element(window, containing: text) != nil, present, text, file: file, line: line)
    }

    private func blockJSON(released: Bool = false) -> Data {
        Data("""
        { "block": { "id": "block-1", "blockedRole": "requester", "diningLocation": "Palladium",
          "interactionAt": "2026-07-20T18:30:00.000Z", "createdAt": "2026-07-20T18:31:00.000Z" },
          "reservationReleased": \(released) }
        """.utf8)
    }

    // MARK: 1 + 2. Entry opens the request-bound conversation

    func testRequesterAndHelperEntryOpenTheirRequestBoundConversation() async throws {
        for role in [RequestConversationRole.requester, .helper] {
            let rig = ConversationRig()
            rig.script(requestA, text: "ONLY-REQUEST-A", conversationId: MsgFixture.conversationId)
            rig.script(requestB, text: "ONLY-REQUEST-B", conversationId: MsgFixture.otherConversationId)
            let box = NavBox()
            let window = try mount(NavigationHarness(
                box: box, rig: rig, store: makeStore(rig.authority),
                identityStore: makeIdentityStore(), role: role
            ))
            XCTAssertNotNil(element(window, containing: "HOME-SCREEN"))
            let entry = try XCTUnwrap(element(window, containing: role == .requester ? "Message helper" : "Message requester"))
            XCTAssertTrue(entry.accessibilityActivate())
            await waitForLabel(window, "ONLY-REQUEST-A")
            XCTAssertEqual(box.path, [.requestConversation(requestID: requestA, role: role)])
            XCTAssertEqual(rig.https[requestA]?.opens, 1)
            XCTAssertEqual(rig.https[requestB]?.opens, 0)
            XCTAssertNil(element(window, containing: "ONLY-REQUEST-B"))
        }
    }

    // MARK: 4. Switching requests keeps nothing

    func testSwitchingRequestsNeverCarriesTheOtherConversationOrItsActions() async throws {
        let rig = ConversationRig()
        rig.script(requestA, text: "ONLY-REQUEST-A", conversationId: MsgFixture.conversationId)
        rig.script(requestB, text: "ONLY-REQUEST-B", conversationId: MsgFixture.otherConversationId)
        rig.verifier.actions = ConversationActionAvailability(report: true, block: .viewedRequest)
        let store = makeStore(rig.authority)
        let box = NavBox()
        let window = try mount(NavigationHarness(
            box: box, rig: rig, store: store, identityStore: makeIdentityStore(), role: .requester
        ))
        box.path = [.requestConversation(requestID: requestA, role: .requester)]
        await waitForLabel(window, "ONLY-REQUEST-A")

        box.path = []
        await waitForLabel(window, "ONLY-REQUEST-A", present: false)
        box.path = [.requestConversation(requestID: requestB, role: .requester)]
        await waitForLabel(window, "ONLY-REQUEST-B")
        XCTAssertNil(element(window, containing: "ONLY-REQUEST-A"))
        XCTAssertEqual(rig.https[requestB]?.opens, 1)
        XCTAssertEqual(rig.https[requestA]?.opens, 1, "A is not reopened by visiting B")
    }

    // MARK: 3. Report and Block bind to this request's counterpart

    func testReportAndBlockTargetOnlyThisRequestAndSendNoParticipantIdentity() async throws {
        let rig = ConversationRig()
        rig.script(requestA, text: "A", conversationId: MsgFixture.conversationId)
        let store = makeStore(rig.authority)
        let session = SessionRig.makeWith(requestID: requestA, role: .requester, verifier: rig.verifier)
        rig.verifier.actions = ConversationActionAvailability(report: true, block: .viewedRequest)
        session.begin(isForeground: true)
        await eventually("actions") { session.actions.block != nil }
        let box = NavBox()
        box.path = [.requestConversation(requestID: requestA, role: .requester)]
        let binding = Binding(get: { box.path }, set: { box.path = $0 })
        let actions = RequestConversationActions(requestID: requestA, session: session, store: store, path: binding)

        actions.report()
        let popup = try XCTUnwrap(store.reportPopup)
        XCTAssertEqual(popup.requestID, requestA)
        XCTAssertFalse(popup.offersBlockAfter, "Block is already in the chat menu; no second consumer of the shared flag")
        XCTAssertFalse(popup.returnsHome)
        store.dismissReportPopup()

        ParticipantBlockURLProtocol.enqueue(.response(data: blockJSON()))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
        XCTAssertEqual(actions.beginBlock(), .viewedRequest)
        await actions.blockViewedRequest()

        let sent = try XCTUnwrap(ParticipantBlockURLProtocol.capturedRequests.first { $0.path.hasSuffix("/block") })
        XCTAssertEqual(sent.path, "/api/request/\(requestA)/block")
        XCTAssertEqual(sent.bodyObject?.count, 0, "no participant identifier is ever sent")
        XCTAssertEqual(box.path, [])
    }

    // MARK: 5 + 6. Successful Block closes the visible conversation; Unblock does not resurrect it

    func testSuccessfulBlockClosesTheVisibleConversationAndUnblockNeverReopensIt() async throws {
        let rig = ConversationRig()
        rig.script(requestA, text: "SECRET-TRANSCRIPT", conversationId: MsgFixture.conversationId)
        rig.verifier.actions = ConversationActionAvailability(report: true, block: .viewedRequest)
        let store = makeStore(rig.authority)
        let box = NavBox()
        box.path = [.requestConversation(requestID: requestA, role: .requester)]
        let window = try mount(DirectHostHarness(
            box: box, rig: rig, store: store, identityStore: makeIdentityStore(), role: .requester
        ))
        await waitForLabel(window, "SECRET-TRANSCRIPT")
        let http = try XCTUnwrap(rig.https[requestA])
        XCTAssertEqual(http.opens, 1)

        ParticipantBlockURLProtocol.enqueue(.response(data: blockJSON()))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
        let session = try XCTUnwrap(rig.lastSession)
        let actions = RequestConversationActions(
            requestID: requestA, session: session, store: store,
            path: Binding(get: { box.path }, set: { box.path = $0 })
        )
        XCTAssertEqual(actions.beginBlock(), .viewedRequest)
        await actions.blockViewedRequest()

        await waitForLabel(window, "SECRET-TRANSCRIPT", present: false)
        await waitForLabel(window, ConversationCopy.unavailableTitle)
        XCTAssertEqual(session.state, .closed)
        XCTAssertTrue(session.coordinator.items.isEmpty)
        XCTAssertEqual(session.coordinator.draft, "")
        XCTAssertEqual(session.actions, .none)

        let readsBeforeUnblock = http.reads.count
        // Unblock: the pair may interact again, but this conversation never returns.
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"removed": true}"#.utf8)))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
        await store.unblockStudent(id: "block-1")
        rig.verifier.denied = false
        rig.verifier.result = .eligible
        session.sceneDidBecomeActive()
        session.retryVerification()
        session.relationshipStateChanged()
        await pump(window, 0.6)
        XCTAssertEqual(session.state, .closed)
        XCTAssertNil(element(window, containing: "SECRET-TRANSCRIPT"))
        XCTAssertEqual(http.opens, 1, "no new open after Unblock")
        XCTAssertEqual(http.reads.count, readsBeforeUnblock, "no reads after Unblock")
        XCTAssertEqual(session.actions, .none)
    }

    // MARK: Failed Block keeps an authorized conversation

    func testFailedBlockShowsNoSuccessAndKeepsTheAuthorizedConversation() async throws {
        let rig = ConversationRig()
        rig.script(requestA, text: "STILL-HERE", conversationId: MsgFixture.conversationId)
        rig.verifier.actions = ConversationActionAvailability(report: true, block: .viewedRequest)
        let store = makeStore(rig.authority)
        let box = NavBox()
        box.path = [.requestConversation(requestID: requestA, role: .requester)]
        let window = try mount(DirectHostHarness(
            box: box, rig: rig, store: store, identityStore: makeIdentityStore(), role: .requester
        ))
        await waitForLabel(window, "STILL-HERE")
        let session = try XCTUnwrap(rig.lastSession)
        ParticipantBlockURLProtocol.enqueue(.failure(.timedOut))
        await settle()
        let callsBefore = rig.verifier.verifyCalls
        let actions = RequestConversationActions(
            requestID: requestA, session: session, store: store,
            path: Binding(get: { box.path }, set: { box.path = $0 })
        )
        _ = actions.beginBlock()
        await actions.blockViewedRequest()
        XCTAssertNotNil(store.blockError)
        XCTAssertEqual(session.state, .open)
        XCTAssertEqual(box.path, [.requestConversation(requestID: requestA, role: .requester)])
        await waitForLabel(window, "STILL-HERE")
        await eventually("re-verification after the failed Block") { rig.verifier.verifyCalls > callsBefore }
        XCTAssertTrue(store.currentBlockedStudents.isEmpty)
    }

    // MARK: Helper holding a real reservation: existing U1.3 Yes / No behavior

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func claimJSON(requestID: String) -> Data {
        Data("""
        { "request": { "id": "\(requestID)", "vendor": "Palladium", "food": "Rice bowl",
            "pickupWindowText": "ASAP", "mealSwipes": 2, "menuPath": "meal-exchange", "mealItems": [],
            "orderDetails": null, "estimatedDiningDollarsCents": null, "windowStart": null, "windowEnd": null,
            "status": "claimed", "createdAt": "2026-07-20T18:30:00.000Z",
            "expiresAt": "\(iso(Date().addingTimeInterval(5 * 3600)))" },
          "claim": { "claimToken": "claim-token",
            "claimExpiresAt": "\(iso(Date().addingTimeInterval(15 * 60)))" } }
        """.utf8)
    }

    /// A real held reservation: the claim is placed through the store's own
    /// claim endpoint, so `activeClaim` and `canBlockHelpedRequester` are the
    /// application's, not simulated. The real verifier derives the actions.
    private func heldHelper(
        _ authority: MsgAuthorityBox
    ) async throws -> (RequestStore, RequestConversationSession, StoreConversationEntryVerifier) {
        let store = makeStore(authority)
        ParticipantBlockURLProtocol.enqueue(.response(data: claimJSON(requestID: requestA)))
        try await store.claim(requestID: requestA)
        XCTAssertEqual(store.activeClaim?.requestID, requestA)
        XCTAssertTrue(store.canBlockHelpedRequester)
        let verifier = StoreConversationEntryVerifier(store: store)
        let http = ScriptedHTTP()
        http.defaultHistory = { _ in .success(MsgFixture.history([MsgFixture.message(1, text: "HELD-A")])) }
        let coordinator = ConversationCoordinator(
            requestId: requestA, http: http, socketTransport: nil,
            authorityProvider: { authority.value },
            participantAuthorityRejected: {}, scheduler: ManualScheduler()
        )
        let session = RequestConversationSession(
            requestID: requestA, role: .helper, coordinator: coordinator, verifier: verifier
        )
        // The entry verification re-reads the helper's continuations; let it
        // consume its own scripted response before any Block is scripted.
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
        let before = ParticipantBlockURLProtocol.capturedRequests.count
        session.begin(isForeground: true)
        await eventually("entry verification read") { ParticipantBlockURLProtocol.capturedRequests.count > before }
        await settle()
        await eventually("held helper actions") { session.actions.block == .helpingReservation }
        XCTAssertTrue(session.actions.report, "live reservation permits Report")
        return (store, session, verifier)
    }

    func testHeldHelperBlockYesKeepsTheReservationClosesChatAndReturnsToHelping() async throws {
        let (store, session, _) = try await heldHelper(MsgAuthorityBox())
        let before = try XCTUnwrap(store.activeClaim)
        let helping = AppRoute.fulfillment(fixtureRequest())
        let box = NavBox()
        box.path = [.settings, helping, .requestConversation(requestID: requestA, role: .helper)]
        let actions = RequestConversationActions(
            requestID: requestA, session: session, store: store,
            path: Binding(get: { box.path }, set: { box.path = $0 })
        )
        XCTAssertEqual(actions.beginBlock(), .helpingReservation)
        ParticipantBlockURLProtocol.enqueue(.response(data: blockJSON(released: false)))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
        await actions.blockHelpingReservation(externalOrderPlaced: true)

        let sent = try XCTUnwrap(ParticipantBlockURLProtocol.capturedRequests.first { $0.path.hasSuffix("/block") })
        XCTAssertEqual(sent.path, "/api/request/\(requestA)/block")
        XCTAssertEqual(sent.bodyObject as? [String: Bool], ["externalOrderPlaced": true])
        XCTAssertFalse(ParticipantBlockURLProtocol.capturedRequests.contains { $0.path.contains("release") })
        // Reservation unchanged: same request, same deadline.
        XCTAssertEqual(store.activeClaim?.requestID, before.requestID)
        XCTAssertEqual(store.activeClaim?.claimExpiresAt, before.claimExpiresAt)
        // Chat closed and purged; Helping stays, chat and what preceded Helping are gone.
        XCTAssertEqual(session.state, .closed)
        XCTAssertTrue(session.coordinator.items.isEmpty)
        XCTAssertEqual(session.actions, .none)
        XCTAssertEqual(box.path, [helping])
        XCTAssertFalse(store.currentBlockedStudents.isEmpty)
    }

    func testHeldHelperBlockNoReleasesTheReservationClosesChatAndGoesHome() async throws {
        let (store, session, _) = try await heldHelper(MsgAuthorityBox())
        let box = NavBox()
        box.path = [.settings, .fulfillment(fixtureRequest()), .requestConversation(requestID: requestA, role: .helper)]
        let actions = RequestConversationActions(
            requestID: requestA, session: session, store: store,
            path: Binding(get: { box.path }, set: { box.path = $0 })
        )
        XCTAssertEqual(actions.beginBlock(), .helpingReservation)
        ParticipantBlockURLProtocol.enqueue(.response(data: blockJSON(released: true)))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
        await actions.blockHelpingReservation(externalOrderPlaced: false)

        let sent = try XCTUnwrap(ParticipantBlockURLProtocol.capturedRequests.first { $0.path.hasSuffix("/block") })
        XCTAssertEqual(sent.path, "/api/request/\(requestA)/block")
        XCTAssertEqual(sent.bodyObject as? [String: Bool], ["externalOrderPlaced": false])
        XCTAssertNil(store.activeClaim, "reservation ends only on the backend's confirmed release")
        XCTAssertEqual(session.state, .closed)
        XCTAssertTrue(session.coordinator.items.isEmpty)
        XCTAssertEqual(session.actions, .none)
        XCTAssertEqual(box.path, [], "Home, not Active Requests")
    }

    func testHeldHelperBlockFailureKeepsReservationAndChat() async throws {
        let (store, session, _) = try await heldHelper(MsgAuthorityBox())
        let box = NavBox()
        box.path = [.fulfillment(fixtureRequest()), .requestConversation(requestID: requestA, role: .helper)]
        let actions = RequestConversationActions(
            requestID: requestA, session: session, store: store,
            path: Binding(get: { box.path }, set: { box.path = $0 })
        )
        ParticipantBlockURLProtocol.enqueue(.failure(.timedOut))
        await actions.blockHelpingReservation(externalOrderPlaced: true)
        XCTAssertNotNil(store.blockError)
        XCTAssertNotNil(store.activeClaim)
        XCTAssertEqual(session.state, .open)
        XCTAssertEqual(box.path.count, 2)
        XCTAssertEqual(session.actions.block, .helpingReservation, "still offered; server stays definitive")
    }

    // MARK: 7. Revoked server authorization retires and clears

    func testServerRevocationClearsTheVisibleConversation() async throws {
        let rig = ConversationRig()
        rig.script(requestA, text: "REVOKE-ME", conversationId: MsgFixture.conversationId)
        let store = makeStore(rig.authority)
        let box = NavBox()
        box.path = [.requestConversation(requestID: requestA, role: .helper)]
        let window = try mount(DirectHostHarness(
            box: box, rig: rig, store: store, identityStore: makeIdentityStore(), role: .helper
        ))
        await waitForLabel(window, "REVOKE-ME")
        let session = try XCTUnwrap(rig.lastSession)
        let http = try XCTUnwrap(rig.https[requestA])
        http.defaultRead = { _ in .unavailable }
        http.defaultHistory = { _ in .unavailable }
        session.sceneDidEnterBackground()
        session.sceneDidBecomeActive()

        await waitForLabel(window, "REVOKE-ME", present: false)
        await waitForLabel(window, ConversationCopy.unavailableTitle)
        XCTAssertTrue(session.coordinator.items.isEmpty)
        XCTAssertEqual(session.coordinator.phase, .unavailable)
    }

    // MARK: Store-backed action availability mirrors the existing screens

    func testStoreVerifierOffersNothingWithoutAKnownRelationshipStage() {
        let authority = MsgAuthorityBox()
        let store = makeStore(authority)
        let verifier = StoreConversationEntryVerifier(store: store)
        XCTAssertEqual(verifier.availableActions(requestID: requestA, role: .requester), .none)
        XCTAssertEqual(verifier.availableActions(requestID: requestA, role: .helper), .none)
        authority.value = nil
        XCTAssertEqual(verifier.availableActions(requestID: requestA, role: .requester), .none)
    }

    // MARK: Helpers

    private func fixtureRequest() -> FoodRequest {
        FoodRequest(
            id: "64c0000000000000000000f1",
            diningSpot: DiningSpot(name: "Palladium", address: nil),
            foodDescription: "Rice bowl", pickupWindowText: "ASAP", mealSwipes: 1,
            windowStart: nil, windowEnd: nil,
            createdAt: Date(timeIntervalSince1970: 0), expiresAt: Date(timeIntervalSince1970: 3_600),
            status: .open
        )
    }
}

extension SessionRig {
    static func makeWith(requestID: String, role: RequestConversationRole, verifier: StubVerifier) -> RequestConversationSession {
        let http = ScriptedHTTP()
        http.defaultHistory = { _ in .success(MsgFixture.history([MsgFixture.message(1)])) }
        let coordinator = ConversationCoordinator(
            requestId: requestID, http: http, socketTransport: nil,
            authorityProvider: { MsgFixture.authority },
            participantAuthorityRejected: {}, scheduler: ManualScheduler()
        )
        return RequestConversationSession(
            requestID: requestID, role: role, coordinator: coordinator, verifier: verifier
        )
    }
}
