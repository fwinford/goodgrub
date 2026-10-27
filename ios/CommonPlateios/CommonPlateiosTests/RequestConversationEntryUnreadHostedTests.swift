import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

private final class EntryBox: ObservableObject {
    @Published var path: [AppRoute] = []
}

private struct EntryHarness: View {
    @ObservedObject var box: EntryBox
    let composition: RequestMessagingComposition
    var suppressed = false

    var body: some View {
        VStack {
            RequestConversationEntryRow(requestID: MsgFixture.requestId, role: .requester, isSuppressed: suppressed, path: $box.path)
        }
        .padding()
        .environment(\.requestMessaging, composition)
        .environment(\.scenePhase, .active)
    }
}

/// W4-MSG1 CP7-B: the trailing unread capsule on the MSG1-owned entry row.
/// Simulator-hosted, scripted transport. Not a live backend or device check.
@MainActor
final class RequestConversationEntryUnreadHostedTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() {
        windows.forEach { $0.isHidden = true }
        windows.removeAll()
        super.tearDown()
    }

    private func composition(count: Int?, http: ScriptedHTTP = ScriptedHTTP()) -> (RequestMessagingComposition, MessagingUnreadStore) {
        if let count {
            http.defaultUnread = { _ in
                .success(MessagingUnreadSummaryDTO(
                    unreadCount: count,
                    conversations: count == 0 ? [] : [ConversationUnreadEntryDTO(requestId: MsgFixture.requestId, conversationId: MsgFixture.conversationId, unreadCount: count)]
                ))
            }
        } else {
            http.defaultUnread = { _ in .unknown }
        }
        let store = MessagingUnreadStore(http: http, authorityProvider: { MsgFixture.authority })
        let c = RequestMessagingComposition.enabled(unread: store) { id, _, rejected in
            ConversationCoordinator(
                requestId: id, http: ScriptedHTTP(), socketTransport: nil,
                authorityProvider: { MsgFixture.authority }, participantAuthorityRejected: rejected,
                scheduler: ManualScheduler()
            )
        }
        return (c, store)
    }

    private func mount(_ composition: RequestMessagingComposition, suppressed: Bool = false, size: DynamicTypeSize = .large) throws -> UIWindow {
        try enableMessagingAccessibilityTree()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: EntryHarness(box: EntryBox(), composition: composition, suppressed: suppressed).dynamicTypeSize(size))
        window.makeKeyAndVisible()
        windows.append(window)
        window.layoutIfNeeded()
        return window
    }

    private func labels(_ root: NSObject) -> [String] {
        var out: [String] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ e: NSObject) {
            guard seen.insert(ObjectIdentifier(e)).inserted else { return }
            if let l = e.accessibilityLabel { out.append(l) }
            (e.accessibilityElements as? [NSObject])?.forEach(visit)
            let n = e.accessibilityElementCount()
            if n != NSNotFound, n > 0 { for i in 0..<n { if let c = e.accessibilityElement(at: i) as? NSObject { visit(c) } } }
            (e as? UIView)?.subviews.forEach(visit)
        }
        visit(root)
        return out
    }

    private func frame(of prefix: String, in root: NSObject) -> CGRect? {
        var found: CGRect?
        var seen = Set<ObjectIdentifier>()
        func visit(_ e: NSObject) {
            guard found == nil, seen.insert(ObjectIdentifier(e)).inserted else { return }
            if (e.accessibilityLabel ?? "").hasPrefix(prefix) { found = e.accessibilityFrame; return }
            (e.accessibilityElements as? [NSObject])?.forEach(visit)
            let n = e.accessibilityElementCount()
            if n != NSNotFound, n > 0 { for i in 0..<n { if let c = e.accessibilityElement(at: i) as? NSObject { visit(c) } } }
            (e as? UIView)?.subviews.forEach(visit)
        }
        visit(root)
        return found
    }

    private func pump(_ window: UIWindow, until: () -> Bool) async {
        let deadline = Date().addingTimeInterval(4)
        while !until(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 40_000_000)
            window.layoutIfNeeded()
        }
    }

    private func entryLabel(_ window: UIWindow) -> String? {
        labels(window).first { $0.hasPrefix("Message helper") }
    }

    func testKnownCountsRenderInTheAccessibleLabel() async throws {
        for (count, expected) in [(1, "1 unread message"), (7, "7 unread messages"), (99, "99 unread messages"), (100, "More than 99 unread messages"), (5000, "More than 99 unread messages")] {
            let (c, _) = composition(count: count)
            let window = try mount(c)
            await pump(window) { self.entryLabel(window)?.contains("unread") == true }
            XCTAssertEqual(entryLabel(window), "Message helper, \(expected)")
            windows.removeLast().isHidden = true
        }
    }

    func testZeroUnknownAndFailedHideTheCapsuleAndKeepTheChatAction() async throws {
        for count in [0, nil] as [Int?] {
            let http = ScriptedHTTP()
            let (c, _) = composition(count: count, http: http)
            let window = try mount(c)
            await pump(window) { !http.unreadCalls.isEmpty }
            try? await Task.sleep(nanoseconds: 100_000_000)
            window.layoutIfNeeded()
            XCTAssertEqual(entryLabel(window), "Message helper", "count \(String(describing: count))")
            windows.removeLast().isHidden = true
        }
    }

    func testDormantAndSuppressedEntriesRenderNothingAndFetchNothing() async throws {
        let dormant = try mount(.dormant)
        XCTAssertNil(entryLabel(dormant))
        let http = ScriptedHTTP()
        let (c, _) = composition(count: 3, http: http)
        let suppressed = try mount(c, suppressed: true)
        try? await Task.sleep(nanoseconds: 150_000_000)
        suppressed.layoutIfNeeded()
        XCTAssertNil(entryLabel(suppressed))
        XCTAssertTrue(http.unreadCalls.isEmpty, "a suppressed relationship triggers no unread fetch")
    }

    func testLargestAccessibilitySizeKeepsTheCountAndTheChatActionFittingTheWidth() async throws {
        let (c, _) = composition(count: 250)
        let window = try mount(c, size: .accessibility5)
        await pump(window) { self.entryLabel(window)?.contains("unread") == true }
        XCTAssertEqual(entryLabel(window), "Message helper, More than 99 unread messages")
        let frame = try XCTUnwrap(frame(of: "Message helper", in: window))
        XCTAssertGreaterThanOrEqual(frame.minX, -0.5)
        XCTAssertLessThanOrEqual(frame.maxX, window.bounds.width + 0.5, "row is not clipped horizontally")
        XCTAssertGreaterThanOrEqual(frame.height, ConversationLayout.minimumTarget)
    }
}
