import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

@MainActor
private final class PathBox: ObservableObject {
    @Published var path: [AppRoute] = []
}

private struct EntryHarness: View {
    @ObservedObject var box: PathBox
    let role: RequestConversationRole
    var body: some View {
        RequestConversationEntryRow(requestID: "64c0000000000000000000a1", role: role, path: $box.path)
    }
}

/// Route shape, entry-row gating, Report disclosure and production dormancy.
@MainActor
final class RequestConversationRoutingTests: XCTestCase {
    private let id = "64c0000000000000000000a1"

    func testIdentityReplacementDropsConversationRouteButKeepsUnrelatedRoutes() {
        let path: [AppRoute] = [.settings, .requestConversation(requestID: id, role: .requester)]
        XCTAssertEqual(AppRoute.afterIdentityReplacement(from: path), [.settings])
    }

    func testRouteCarriesOnlyRequestAndRoleAndIsRequestSpecific() {
        let a = AppRoute.requestConversation(requestID: id, role: .requester)
        XCTAssertNotEqual(a, .requestConversation(requestID: "64c0000000000000000000a2", role: .requester))
        XCTAssertNotEqual(a, .requestConversation(requestID: id, role: .helper))
        XCTAssertFalse(AppRoute.containsHelperDestination(in: [a], requestID: id))
    }

    private func host<V: View>(_ view: V) -> (UIWindow, UIHostingController<V>) {
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return (window, controller)
    }

    private func labels(in view: UIView) -> [String] {
        var found: [String] = []
        func walk(_ element: NSObject) {
            if let label = element.accessibilityLabel { found.append(label) }
            (element.accessibilityElements as? [NSObject])?.forEach(walk)
            if let v = element as? UIView { v.subviews.forEach(walk) }
        }
        walk(view)
        return found
    }

    private func entryLabels(in view: UIView) -> [String] {
        labels(in: view).filter { $0.hasPrefix("Message helper") || $0.hasPrefix("Message requester") }
    }

    func testDormantEnvironmentRendersNoEntryRow() async throws {
        try enableMessagingAccessibilityTree()
        let box = PathBox()
        let (window, controller) = host(EntryHarness(box: box, role: .requester))
        await settle()
        controller.view.layoutIfNeeded()
        XCTAssertTrue(entryLabels(in: controller.view).isEmpty)
        XCTAssertTrue(box.path.isEmpty)
        _ = window
    }

    func testEnabledEnvironmentRendersEntryForEachRole() async throws {
        try enableMessagingAccessibilityTree()
        for role in [RequestConversationRole.requester, .helper] {
            let box = PathBox()
            let composition = RequestMessagingComposition.enabled { _, _, _ in
                fatalError("entry row must not create a coordinator")
            }
            let (window, controller) = host(
                EntryHarness(box: box, role: role).environment(\.requestMessaging, composition)
            )
            await settle()
            controller.view.layoutIfNeeded()
            let expected = role == .requester ? "Message helper" : "Message requester"
            XCTAssertTrue(entryLabels(in: controller.view).contains { $0.hasPrefix(expected) }, "\(role)")
            _ = window
        }
    }

    func testShippingCompositionIsDormant() {
        XCTAssertFalse(RequestMessagingComposition.shipping.isEnabled)
        XCTAssertFalse(RequestMessagingComposition.dormant.isEnabled)
        XCTAssertNil(RequestMessagingComposition.shipping.makeCoordinator)
    }

    func testDisclosureCopyIsBoundedAndDoesNotImplyBroaderAccess() {
        let text = ParticipantReportConversationDisclosure.text
        XCTAssertTrue(text.contains("10 most recent"))
        XCTAssertTrue(text.contains("moderation review"))
        XCTAssertTrue(text.contains("may be attached"))
        XCTAssertTrue(text.contains("evidence is incomplete"))
        XCTAssertTrue(text.contains("Nothing from other conversations"))
        XCTAssertTrue(text.contains("can't choose"))
        XCTAssertFalse(text.lowercased().contains("all conversations"))
    }

    func testReportViewDisclosureIsOffByDefaultAndPrecedesSubmitInSource() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
        let report = try String(
            contentsOf: root.appendingPathComponent("Views/ParticipantReportView.swift"), encoding: .utf8
        )
        XCTAssertTrue(report.contains("var discloseConversationContext = false"))
        let form = try XCTUnwrap(report.range(of: "participant-report-conversation-disclosure"))
        let submit = try XCTUnwrap(report.range(of: "Submit report"))
        XCTAssertLessThan(report.distance(from: report.startIndex, to: form.lowerBound),
                          report.distance(from: report.startIndex, to: submit.lowerBound))
    }

    func testProductionCompositionRootStaysDormant() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let content = try String(
            contentsOf: repo.appendingPathComponent("CommonPlateios/ContentView.swift"), encoding: .utf8
        )
        let app = try String(
            contentsOf: repo.appendingPathComponent("CommonPlateios/CommonPlateiosApp.swift"), encoding: .utf8
        )
        for source in [content, app] {
            XCTAssertFalse(source.contains(".live("))
            XCTAssertFalse(source.contains("RequestMessagingComposition.enabled"))
            XCTAssertFalse(source.contains("\\.requestMessaging,"))
            XCTAssertFalse(source.contains("environment(\\.requestMessaging"))
        }
        let backendRoot = repo.deletingLastPathComponent().deletingLastPathComponent()
        for file in ["app.ts", "models/db.ts"] {
            let url = backendRoot.appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            XCTAssertFalse(text.contains("installMessagingLifecycle"), file)
        }
    }
}
