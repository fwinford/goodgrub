import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

/// W4-MSG1 CP3 (F4): hosted, in-process accessibility and layout proof for the
/// dormant chat components, using the real accessibility tree SwiftUI exposes
/// and the real sheet detent heights.
///
/// Scope honesty: this is simulator-hosted `accessibilityActivate()` and frame
/// inspection. It is NOT VoiceOver on a physical device, which stays a separate
/// manual check.
@MainActor
final class MessagingAccessibilityHostedTests: XCTestCase {
    private let width: CGFloat = 390
    private let minimumTarget = ConversationLayout.minimumTarget

    // MARK: Harness

    private func mount<V: View>(_ view: V, size: DynamicTypeSize, height: CGFloat = 844) throws -> UIWindow {
        try enableMessagingAccessibilityTree()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.rootViewController = UIHostingController(rootView: view.dynamicTypeSize(size))
        window.makeKeyAndVisible()
        settle(window)
        return window
    }

    private func settle(_ window: UIWindow) {
        for _ in 0..<8 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.layoutIfNeeded()
        }
    }

    private static func identifier(of element: NSObject) -> String? {
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue() as? String
    }

    private func walk(_ root: NSObject, _ visitor: (NSObject) -> Void) {
        var seen = Set<ObjectIdentifier>()
        func visit(_ element: NSObject) {
            guard seen.insert(ObjectIdentifier(element)).inserted else { return }
            visitor(element)
            if let elements = element.accessibilityElements {
                for child in elements { if let child = child as? NSObject { visit(child) } }
            }
            let count = element.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let child = element.accessibilityElement(at: index) as? NSObject { visit(child) }
                }
            }
            if let view = element as? UIView { for subview in view.subviews { visit(subview) } }
        }
        visit(root)
    }

    private func find(_ window: UIWindow, _ predicate: (NSObject) -> Bool) -> NSObject? {
        var match: NSObject?
        walk(window) { if match == nil, predicate($0) { match = $0 } }
        return match
    }

    private func collect(_ window: UIWindow, _ predicate: (NSObject) -> Bool) -> [NSObject] {
        var matches: [NSObject] = []
        walk(window) { if predicate($0) { matches.append($0) } }
        return matches
    }

    private func find(_ window: UIWindow, id: String) -> NSObject? {
        find(window) { Self.identifier(of: $0) == id }
    }

    /// Prefers an exact label, then a button-trait element, then a combined label containing the text.
    private func find(_ window: UIWindow, label: String) -> NSObject? {
        find(window) { $0.accessibilityLabel == label && $0.accessibilityTraits.contains(.button) }
            ?? find(window) { $0.accessibilityLabel == label }
            ?? find(window) { ($0.accessibilityLabel ?? "").contains(label) }
    }

    private func require(_ element: NSObject?, _ what: String, in window: UIWindow, file: StaticString = #filePath, line: UInt = #line) throws -> NSObject {
        if let element { return element }
        var lines: [String] = []
        walk(window) { if $0.accessibilityLabel != nil || Self.identifier(of: $0) != nil { lines.append("\(type(of: $0)) label=\($0.accessibilityLabel ?? "-") id=\(Self.identifier(of: $0) ?? "-")") } }
        XCTFail("missing \(what). tree:\n\(lines.joined(separator: "\n"))", file: file, line: line)
        throw XCTSkip("missing \(what)")
    }

    private func scrollViews(in window: UIWindow) -> [UIScrollView] {
        var result: [UIScrollView] = []
        walk(window) { if let s = $0 as? UIScrollView { result.append(s) } }
        return result
    }

    /// The element is reachable if it is on screen, or a scroll view can bring it on screen.
    private func assertReachable(_ element: NSObject, in window: UIWindow, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let bounds = window.bounds
        func visible() -> Bool {
            let f = element.accessibilityFrame
            return f.minY >= bounds.minY - 0.5 && f.maxY <= bounds.maxY + 0.5 && f.minX >= -0.5 && f.maxX <= bounds.maxX + 0.5
        }
        if visible() { return }
        for scroll in scrollViews(in: window) where scroll.contentSize.height > scroll.bounds.height + 1 {
            scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom), animated: false)
            settle(window)
            if visible() { return }
        }
        XCTFail("\(name) unreachable: frame \(element.accessibilityFrame) in \(bounds)", file: file, line: line)
    }

    private func assertTarget(_ element: NSObject, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let f = element.accessibilityFrame
        XCTAssertGreaterThanOrEqual(f.height + 0.5, minimumTarget, "\(name) height \(f.height)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(f.width + 0.5, minimumTarget, "\(name) width \(f.width)", file: file, line: line)
    }

    // MARK: Failed-message sheet at the real detents

    /// Heights of the presented sheet: `.medium` is half of an 844 pt screen; `.large` is full.
    private let detents: [(String, CGFloat)] = [("medium", 422), ("large", 790)]
    private let sizes: [DynamicTypeSize] = [.large, .accessibility3, .accessibility5]

    func testRetryableSheetKeepsBothActionsReachableWithRealTargetsAtEveryDetentAndSize() throws {
        for (detent, height) in detents {
            for size in sizes {
                let window = try mount(FailedMessageSheet(failure: .unconfirmed, onTryAgain: {}, onCancel: {}), size: size, height: height)
                let name = "\(detent)/\(size)"
                let retry = try require(find(window, id: "chat.tryAgain"), "Try again \(name)", in: window)
                let cancel = try require(find(window, id: "chat.cancelFailed"), "Cancel \(name)", in: window)
                assertReachable(retry, in: window, "Try again \(name)")
                assertReachable(cancel, in: window, "Cancel \(name)")
                assertTarget(retry, "Try again \(name)")
                assertTarget(cancel, "Cancel \(name)")
                XCTAssertEqual(retry.accessibilityLabel, "Try again")
                XCTAssertEqual(cancel.accessibilityLabel, "Cancel")
                XCTAssertNotNil(find(window, label: "Message not sent"), name)
                window.isHidden = true
            }
        }
    }

    func testDefinitiveRefusalSheetShowsOnlyCancelAtEveryDetentAndSize() throws {
        for (detent, height) in detents {
            for size in sizes {
                let window = try mount(FailedMessageSheet(failure: .refused(.textNotAllowed), onTryAgain: {}, onCancel: {}), size: size, height: height)
                let name = "\(detent)/\(size)"
                XCTAssertNil(find(window, id: "chat.tryAgain"), "no retry of refused content (\(name))")
                let cancel = try require(find(window, id: "chat.cancelFailed"), "Cancel \(name)", in: window)
                assertReachable(cancel, in: window, "Cancel \(name)")
                assertTarget(cancel, "Cancel \(name)")
                window.isHidden = true
            }
        }
    }

    func testSheetActionsInvokeTheirClosuresThroughAccessibilityActivation() throws {
        var retries = 0, cancels = 0
        let window = try mount(FailedMessageSheet(failure: .notDelivered, onTryAgain: { retries += 1 }, onCancel: { cancels += 1 }), size: .accessibility3, height: 422)
        XCTAssertTrue(try require(find(window, id: "chat.tryAgain"), "retry", in: window).accessibilityActivate())
        XCTAssertTrue(try require(find(window, id: "chat.cancelFailed"), "cancel", in: window).accessibilityActivate())
        XCTAssertEqual(retries, 1)
        XCTAssertEqual(cancels, 1)
    }

    // MARK: Leaf components

    func testBannerRetryIsReachableTargetSizedAndActivates() throws {
        for size in sizes {
            var taps = 0
            let window = try mount(ConversationStatusBanner(text: ConversationCopy.offlineBanner, actionTitle: ConversationCopy.retry, action: { taps += 1 }), size: size, height: 300)
            let retry = try require(find(window, label: "Retry"), "Retry \(size)", in: window)
            assertReachable(retry, in: window, "Retry \(size)")
            assertTarget(retry, "Retry \(size)")
            XCTAssertTrue(retry.accessibilityActivate())
            XCTAssertEqual(taps, 1, "\(size)")
            window.isHidden = true
        }
    }

    func testEntryRowsActivateTheHostClosureOnceAndAreTargetSized() throws {
        var helper = 0, requester = 0
        let window = try mount(VStack { ChatWithHelperRow(action: { helper += 1 }); ChatWithRequesterRow(action: { requester += 1 }) }, size: .accessibility5)
        let h = try require(find(window, label: ChatWithHelperRow.title), "helper row", in: window)
        let r = try require(find(window, label: ChatWithRequesterRow.title), "requester row", in: window)
        assertTarget(h, "helper row"); assertTarget(r, "requester row")
        XCTAssertTrue(h.accessibilityActivate())
        XCTAssertEqual(helper, 1)
        XCTAssertEqual(requester, 0)
        XCTAssertTrue(r.accessibilityActivate())
        XCTAssertEqual(requester, 1)
    }

    func testComposerSendButtonIsTargetSizedLabelledAndDisabledWhenEmpty() throws {
        for size in sizes {
            let window = try mount(ConversationComposer(text: .constant(""), canSend: false, onSend: {}), size: size, height: 300)
            let send = try require(find(window, id: "chat.send"), "send \(size)", in: window)
            XCTAssertEqual(send.accessibilityLabel, ConversationCopy.sendLabel)
            assertTarget(send, "send \(size)")
            XCTAssertTrue(send.accessibilityTraits.contains(.notEnabled), "disabled when it cannot send (\(size))")
            window.isHidden = true
        }
    }

    // MARK: Screen states

    private func screen(_ h: CoordinatorHarness) -> ConversationScreen {
        ConversationScreen(coordinator: h.coordinator)
    }

    private func local(_ h: CoordinatorHarness) -> [LocalOutgoingMessage] {
        h.coordinator.items.compactMap { if case .local(let l) = $0 { return l } else { return nil } }
    }

    func testEveryAdvertisedChatStateRendersItsOwnContent() async throws {
        // loading (idle)
        var h = CoordinatorHarness.make(withSocket: false)
        var w = try mount(screen(h), size: .accessibility5)
        XCTAssertNotNil(find(w, label: ConversationCopy.loading), "loading")
        w.isHidden = true

        // empty
        await h.boot()
        w = try mount(screen(h), size: .accessibility5)
        XCTAssertNotNil(find(w, label: ConversationCopy.emptyLine), "empty")
        XCTAssertNotNil(find(w, id: "chat.composer"))
        w.isHidden = true

        // transcript
        let http = ScriptedHTTP(); http.readReturning([MsgFixture.message(1, sender: .other, text: "hello"), MsgFixture.message(2, sender: .own, text: "hi")])
        h = CoordinatorHarness.make(http: http, withSocket: false)
        await h.boot()
        w = try mount(screen(h), size: .large)
        XCTAssertNotNil(find(w) { ($0.accessibilityLabel ?? "").hasPrefix("Other person, ") && ($0.accessibilityLabel ?? "").hasSuffix(": hello") }, "incoming bubble")
        XCTAssertNotNil(find(w) { ($0.accessibilityLabel ?? "").hasPrefix("You, ") && ($0.accessibilityLabel ?? "").hasSuffix(": hi") }, "outgoing bubble")
        w.isHidden = true

        // open failed + Retry
        let openHTTP = ScriptedHTTP(); openHTTP.enqueueOpen { .unknown }
        h = CoordinatorHarness.make(http: openHTTP, withSocket: false)
        h.coordinator.start()
        await eventually("open failed") { h.coordinator.phase == .openFailed }
        w = try mount(screen(h), size: .accessibility5)
        XCTAssertNotNil(find(w, label: ConversationCopy.openFailed), "open failed")
        let retry = try require(find(w, label: ConversationCopy.retry), "open-failed Retry", in: w)
        assertTarget(retry, "open-failed Retry")
        XCTAssertTrue(retry.accessibilityActivate())
        await eventually("reopened") { openHTTP.opens == 2 }
        w.isHidden = true

        // offline banner + Retry
        let offHTTP = ScriptedHTTP(); offHTTP.enqueueRead { _ in .unknown }
        h = CoordinatorHarness.make(http: offHTTP, withSocket: false)
        h.coordinator.start()
        await eventually("offline") { h.coordinator.isOffline }
        w = try mount(screen(h), size: .accessibility5)
        XCTAssertNotNil(find(w, label: ConversationCopy.offlineBanner), "offline")
        let bannerRetry = try require(find(w, label: ConversationCopy.retry), "banner Retry", in: w)
        assertTarget(bannerRetry, "banner Retry")
        let reads = offHTTP.reads.count
        XCTAssertTrue(bannerRetry.accessibilityActivate())
        await eventually("retry read") { offHTTP.reads.count > reads }
        w.isHidden = true

        // reconnecting
        h = CoordinatorHarness.make()
        await h.boot()
        h.socket.last!.fail()
        await eventually("disconnected") { h.coordinator.connectionStatus == .disconnected }
        w = try mount(screen(h), size: .accessibility5)
        XCTAssertNotNil(find(w, label: ConversationCopy.reconnecting), "reconnecting")
        w.isHidden = true

        // unavailable, ended and authority required
        h = CoordinatorHarness.make(withSocket: false); await h.boot(); h.coordinator.dismiss()
        w = try mount(screen(h), size: .accessibility5)
        XCTAssertNotNil(find(w, label: ConversationCopy.unavailableTitle), "unavailable/ended")
        w.isHidden = true
        h = CoordinatorHarness.make(withSocket: false, authority: MsgAuthorityBox(nil))
        h.coordinator.start()
        w = try mount(screen(h), size: .accessibility5)
        XCTAssertNotNil(find(w, label: ConversationCopy.authorityRequiredLine), "authority required")
        w.isHidden = true
    }

    func testFailedIndicatorRetriesInlineAndOnlyRefusalsOpenTheSheet() async throws {
        for (refusal, label) in [(false, "Not sent. Tap to retry"), (true, "Not sent. Tap for details")] {
            let http = ScriptedHTTP()
            if refusal { http.enqueueSend { _ in .refused(.invalidMessage) } }
            else { http.enqueueSend { _ in .unknown }; http.enqueueReconcile { _ in .success(nil) } }
            let h = CoordinatorHarness.make(http: http, withSocket: false)
            await h.boot()
            h.coordinator.draft = "payload"
            h.coordinator.sendDraft()
            await eventually("failed") { if case .failed = self.local(h).first?.state { return true } else { return false } }
            let w = try mount(screen(h), size: .accessibility5)
            let warning = try require(find(w, id: "chat.failedWarning"), "failed warning", in: w)
            XCTAssertEqual(warning.accessibilityLabel, label)
            assertTarget(warning, "failed warning")
            XCTAssertTrue(warning.accessibilityActivate())
            if refusal {
                XCTAssertEqual(h.coordinator.failedSheetTarget, MsgFixture.identity(1))
            } else {
                XCTAssertNil(h.coordinator.failedSheetTarget, "recoverable failure never opens a sheet")
                await eventually("retry resent") { http.sends.count == 2 }
            }
            w.isHidden = true
        }
    }

    func testCapacityNoticeAppearsAtTheLimitAndSendIsDisabled() async throws {
        let http = ScriptedHTTP()
        var config = ConversationConfiguration(); config.maxOutstandingLocal = 1
        let h = CoordinatorHarness.make(http: http, withSocket: false, configuration: config)
        await h.boot()
        http.enqueueSend { _ in .unknown }; http.enqueueReconcile { _ in .success(nil) }
        h.coordinator.draft = "one"; h.coordinator.sendDraft()
        await eventually("failed") { self.local(h).first?.state == .failed(.notDelivered) }
        h.coordinator.draft = "two"
        let w = try mount(screen(h), size: .accessibility5)
        XCTAssertNotNil(find(w, label: ConversationCopy.capacityNotice))
        let send = try require(find(w, id: "chat.send"), "send", in: w)
        XCTAssertTrue(send.accessibilityTraits.contains(.notEnabled))
    }

    func testScreenHasNoSecondaryHeadingAndOnlyTheFailedOwnBubbleShowsInlineRetry() async throws {
        let http = ScriptedHTTP()
        http.readReturning([MsgFixture.message(1, sender: .other, text: "hello"), MsgFixture.message(2, sender: .own, text: "fine")])
        http.enqueueSend { _ in .unknown }; http.enqueueReconcile { _ in .success(nil) }
        let h = CoordinatorHarness.make(http: http, withSocket: false)
        await h.boot()
        h.coordinator.draft = "unsent"
        h.coordinator.sendDraft()
        await eventually("failed") { self.local(h).first?.state == .failed(.notDelivered) }
        for size in [DynamicTypeSize.large, .accessibility5] {
            let w = try mount(screen(h), size: size)
            XCTAssertNil(find(w, label: "Order chat"), "no secondary heading (\(size))")
            XCTAssertNil(find(w) { ($0.accessibilityLabel ?? "") == "Venue" })
            let indicators = collect(w) { Self.identifier(of: $0) == "chat.failedWarning" }
            XCTAssertEqual(indicators.count, 1, "only the failed message carries the indicator (\(size))")
            let retry = try require(indicators.first, "retry indicator", in: w)
            XCTAssertEqual(retry.accessibilityLabel, "Not sent. Tap to retry")
            assertTarget(retry, "retry indicator \(size)")
            XCTAssertNotNil(find(w, label: "You, Message not sent: unsent"))
            XCTAssertNotNil(find(w) { ($0.accessibilityLabel ?? "").hasPrefix("Other person, ") })
            w.isHidden = true
        }
        XCTAssertNil(h.coordinator.failedSheetTarget)
    }

    func testRemoveMessageActionExistsOnlyOnTheFailedBubbleAndRemovesOnlyIt() async throws {
        let http = ScriptedHTTP()
        http.readReturning([MsgFixture.message(1, sender: .other, text: "hello"), MsgFixture.message(2, sender: .own, text: "fine")])
        http.enqueueSend { _ in .unknown }; http.enqueueReconcile { _ in .success(nil) }
        let h = CoordinatorHarness.make(http: http, withSocket: false)
        await h.boot()
        h.coordinator.draft = "unsent"
        h.coordinator.sendDraft()
        await eventually("failed") { self.local(h).first?.state == .failed(.notDelivered) }
        let w = try mount(screen(h), size: .large)
        let withRemove = collect(w) { ($0.accessibilityCustomActions ?? []).contains { $0.name == ConversationCopy.removeMessage } }
        XCTAssertEqual(withRemove.count, 1, "only the failed bubble exposes Remove message")
        let failed = try require(withRemove.first, "failed bubble", in: w)
        XCTAssertEqual(failed.accessibilityLabel, "You, Message not sent: unsent")
        let action = try XCTUnwrap(failed.accessibilityCustomActions?.first { $0.name == ConversationCopy.removeMessage })
        XCTAssertTrue(action.actionHandler?(action) ?? false)
        XCTAssertTrue(self.local(h).isEmpty, "unsent message removed")
        settle(w)
        XCTAssertNotNil(find(w) { ($0.accessibilityLabel ?? "").hasSuffix(": hello") })
        XCTAssertNotNil(find(w) { ($0.accessibilityLabel ?? "").hasSuffix(": fine") })
        XCTAssertEqual(http.sends.count, 1, "removal does not send")
        w.isHidden = true
    }

    func testUnconfirmedBubbleShowsUnknownDeliveryAndOffersNoRemove() async throws {
        let http = ScriptedHTTP()
        http.enqueueSend { _ in .unknown }; http.enqueueReconcile { _ in .unknown }
        let h = CoordinatorHarness.make(http: http, withSocket: false)
        await h.boot()
        h.coordinator.draft = "maybe sent"
        h.coordinator.sendDraft()
        await eventually("unconfirmed") { self.local(h).first?.state == .failed(.unconfirmed) }
        let w = try mount(screen(h), size: .large)
        let retry = try require(find(w, id: "chat.failedWarning"), "indicator", in: w)
        XCTAssertEqual(retry.accessibilityLabel, "Delivery unconfirmed. Tap to retry")
        XCTAssertNotNil(find(w, label: "You, Delivery unconfirmed: maybe sent"))
        XCTAssertNil(find(w, label: "You, Message not sent: maybe sent"))
        let withRemove = collect(w) { ($0.accessibilityCustomActions ?? []).contains { $0.name == ConversationCopy.removeMessage } }
        XCTAssertTrue(withRemove.isEmpty, "no Remove for unknown delivery")
        w.isHidden = true
    }

    func testInlineRetryActivationResendsTheSameMessageAndRemovesTheIndicator() async throws {
        let http = ScriptedHTTP()
        http.enqueueSend { _ in .unknown }; http.enqueueReconcile { _ in .success(nil) }
        let h = CoordinatorHarness.make(http: http, withSocket: false)
        await h.boot()
        h.coordinator.draft = "retry me"
        h.coordinator.sendDraft()
        await eventually("failed") { self.local(h).first?.state == .failed(.notDelivered) }
        http.enqueueSend { call in .success(MsgFixture.message(2, sender: .own, text: call.text, identity: 1)) }
        let w = try mount(screen(h), size: .large)
        let retry = try require(find(w, id: "chat.failedWarning"), "retry", in: w)
        XCTAssertTrue(retry.accessibilityActivate())
        await eventually("resent") { http.sends.count == 2 && self.local(h).isEmpty }
        XCTAssertEqual(http.sends[0], http.sends[1])
        settle(w)
        XCTAssertNil(find(w, id: "chat.failedWarning"))
        XCTAssertNotNil(find(w, label: "retry me") ?? find(w) { ($0.accessibilityLabel ?? "").hasSuffix(": retry me") })
        w.isHidden = true
    }
}
