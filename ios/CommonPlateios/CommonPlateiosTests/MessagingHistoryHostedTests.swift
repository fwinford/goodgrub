import Foundation
import SwiftUI
import UIKit
import Combine
import XCTest
@testable import CommonPlateios

@MainActor
private final class HistoryTextSize: ObservableObject {
    @Published var value: DynamicTypeSize = .large
}

@MainActor
private final class HistoryInteractionControls: ObservableObject {
    @Published var finished = false
    var release: () -> Void = {}
    var incoming: () -> Void = {}
    var close: () -> Void = {}
}

private struct HistoryHostedScreen: View {
    let coordinator: ConversationCoordinator
    @ObservedObject var textSize: HistoryTextSize
    var controls: HistoryInteractionControls?
    var body: some View {
        VStack(spacing: 0) {
            if let controls {
                Text("CP5 TEST ONLY - fictional conversation").font(.caption)
                HStack {
                    Button("Release page") { controls.release() }
                    Button("Incoming") { controls.incoming() }
                    Button("Close") { controls.close() }
                    Button("Finish") { controls.finished = true }
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
            ConversationScreen(coordinator: coordinator)
                .dynamicTypeSize(textSize.value)
        }
    }
}

/// Real UIWindow + ConversationScreen geometry. These are simulator-hosted
/// interactions, not physical-device VoiceOver or a manual walkthrough.
@MainActor
final class MessagingHistoryHostedTests: XCTestCase {
    private func message(_ sequence: Int) -> ChatMessage {
        ChatMessage(
            clientMessageId: MsgFixture.identity(1000 + sequence), sequence: sequence,
            sender: sequence.isMultiple(of: 2) ? .own : .other,
            text: sequence.isMultiple(of: 7)
                ? String(repeating: "A tall message that wraps naturally. ", count: 12)
                : "Message \(sequence)",
            createdAt: MsgFixture.epoch.addingTimeInterval(Double(sequence * 1801))
        )
    }

    private func history(_ before: Int? = nil) -> ChatMessageHistoryDTO {
        let end = (before ?? 152) - 1
        let start = max(1, end - 49)
        return MsgFixture.history((start...end).map(message), hasOlder: start > 1, head: 151)
    }

    private func flush(_ window: UIWindow, file: StaticString = #filePath, line: UInt = #line) async {
        let end = Date().addingTimeInterval(8)
        var last: [CGFloat] = []
        var stableFrames = 0
        repeat {
            window.layoutIfNeeded()
            let markers = views(window).compactMap { $0 as? ConversationRowMarker.Marker }
            let scrolls = views(window).compactMap { $0 as? UIScrollView }
            let geometry = scrolls.flatMap { [$0.contentOffset.y, $0.contentSize.height, $0.bounds.height] }
            if !markers.isEmpty && markers.allSatisfy({ $0.viewport?.isSettling == false })
                && scrolls.allSatisfy({ !$0.isDragging && !$0.isDecelerating }) && geometry == last {
                stableFrames += 1
                if stableFrames == 4 { return }
            } else {
                stableFrames = 0
            }
            last = geometry
            try? await Task.sleep(for: .milliseconds(16))
        } while Date() < end
        XCTFail("Hosted layout did not settle", file: file, line: line)
    }

    private func mount(_ h: CoordinatorHarness, size: DynamicTypeSize, textSize: HistoryTextSize? = nil,
                       controls: HistoryInteractionControls? = nil) async throws -> UIWindow {
        try enableMessagingAccessibilityTree()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let textSize = textSize ?? HistoryTextSize()
        textSize.value = size
        window.rootViewController = UIHostingController(rootView: HistoryHostedScreen(coordinator: h.coordinator, textSize: textSize, controls: controls))
        window.makeKeyAndVisible()
        await flush(window)
        return window
    }

    private func views(_ root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap(views)
    }

    private func scroll(_ window: UIWindow) throws -> UIScrollView {
        try XCTUnwrap(views(window).compactMap { $0 as? UIScrollView }
            .first { $0.contentSize.height > $0.bounds.height && !($0 is UITextView) })
    }

    private func row(_ sequence: Int, _ window: UIWindow, file: StaticString = #filePath, line: UInt = #line) throws -> UIView {
        let markers = views(window).filter { $0.accessibilityIdentifier?.hasPrefix("chat.row.") == true }
        let scroll = try scroll(window)
        return try XCTUnwrap(markers.first { $0.accessibilityIdentifier == "chat.row.\(MsgFixture.identity(1000 + sequence))" },
                             "row \(sequence); offset=\(scroll.contentOffset.y), viewport=\(scroll.bounds.height), materialized=\(markers.map { "\($0.accessibilityIdentifier ?? "") y=\(y($0, scroll)) h=\($0.bounds.height)" })",
                             file: file, line: line)
    }

    private func y(_ row: UIView, _ scroll: UIScrollView) -> CGFloat {
        row.convert(row.bounds, to: scroll).minY - scroll.bounds.minY
    }

    private func bottomGap(_ scroll: UIScrollView) -> CGFloat {
        max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            - scroll.contentOffset.y
    }

    private func accessElements(_ root: NSObject) -> [NSObject] {
        var result: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            if let elements = object.accessibilityElements {
                for case let child as NSObject in elements { visit(child) }
            }
            let count = object.accessibilityElementCount()
            if count != NSNotFound && count > 0 {
                for i in 0..<count {
                    if let child = object.accessibilityElement(at: i) as? NSObject { visit(child) }
                }
            }
            if let view = object as? UIView { for child in view.subviews { visit(child) } }
        }
        visit(root)
        return result
    }

    private func accessibilityID(_ element: NSObject) -> String? {
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue() as? String
    }

    private func reachTop(_ window: UIWindow, http: ScriptedHTTP) async throws {
        let scroll = try scroll(window)
        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
        await flush(window)
        let count = http.history.count
        let offset = scroll.contentOffset.y
        let boundary = try XCTUnwrap(accessElements(window).first { accessibilityID($0) == "chat.loadOlder" },
                                     "loading boundary at offset \(offset)")
        XCTAssertTrue(boundary.accessibilityActivate())
        await eventually("top loading boundary") { http.history.count == count + 1 }
    }

    private func partiallyReveal(_ sequence: Int, _ window: UIWindow) async throws -> CGFloat {
        let scroll = try scroll(window)
        let id = "chat.row.\(MsgFixture.identity(1000 + sequence))"
        // Walk the actual lazy viewport rather than assuming a distant row exists.
        for _ in 0..<80 {
            if views(window).contains(where: { $0.accessibilityIdentifier == id }) { break }
            scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentOffset.y + scroll.bounds.height / 2), animated: false)
            await flush(window)
        }
        for _ in 0..<3 {
            let bubble = try row(sequence, window)
            scroll.setContentOffset(CGPoint(x: 0, y: bubble.convert(bubble.bounds, to: scroll).minY + 24), animated: false)
            await flush(window)
        }
        let bubble = try row(sequence, window)
        let position = y(bubble, scroll)
        XCTAssertEqual(position, -24, accuracy: 2)
        XCTAssertGreaterThan(position + bubble.bounds.height, 0)
        return position
    }

    private func boot() async -> CoordinatorHarness {
        let http = ScriptedHTTP()
        // Capturing a value-only fixture avoids retaining the hosted test case.
        let messages = (1...151).map(message)
        http.defaultHistory = { call in
            let eligible = messages.filter { $0.sequence < (call.before ?? 152) }
            return .success(MsgFixture.history(Array(eligible.suffix(50)), hasOlder: eligible.count > 50, head: 151))
        }
        let h = CoordinatorHarness.make(http: http, withSocket: false)
        h.coordinator.start()
        await eventually("latest") { h.coordinator.hasLoaded && !http.reads.isEmpty }
        return h
    }

    func testLatestOpensAtBottomAndPinnedAppendFollowsAtStandardAndAccessibilitySizes() async throws {
        for size in [DynamicTypeSize.large, .accessibility3] {
                let h = await boot()
                let window = try await mount(h, size: size)
                defer { h.coordinator.dismiss(); window.isHidden = true }
                let scroll = try scroll(window)
                XCTAssertLessThanOrEqual(abs(bottomGap(scroll)), 2, "\(size)")
                let next = message(152)
                h.http.readReturning([next])
                h.coordinator.retryConnection()
                await eventually("append") { h.coordinator.items.count == 51 }
                await flush(window)
                XCTAssertLessThanOrEqual(abs(bottomGap(scroll)), 2, "pinned append \(size)")
        }
    }

    func testSimulatorInteractionHost() async throws {
        continueAfterFailure = false
        let h = await boot()
        let controls = HistoryInteractionControls()
        let window = try await mount(h, size: .large, controls: controls)
        defer { h.coordinator.dismiss(); window.isHidden = true }
        XCTAssertEqual(h.coordinator.items.count, 50)
        XCTAssertEqual(h.http.history.map(\.before), [nil])
        guard let mode = ProcessInfo.processInfo.environment["CP5_INTERACTION_MODE"] else { return }
        if mode == "manual" {
            try await manualInteraction(h, window: window, controls: controls)
        } else {
            XCTAssertEqual(mode, "drag")
            try await dragInteraction(h, window: window)
        }
    }

    private var interactionFile: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cp5-interaction.json")
    }

    private func signal(_ stage: String, requests: Int) throws {
        let data = try JSONSerialization.data(withJSONObject: ["stage": stage, "requests": requests])
        try data.write(to: interactionFile, options: .atomic)
    }

    private func dragInteraction(_ h: CoordinatorHarness, window: UIWindow) async throws {
        let scroll = try scroll(window)
        for (index, bound, anchorSequence) in [(1, 102, 105), (2, 52, 56), (3, 2, 7)] {
            let gate = Gate()
            defer { gate.open() }
            let page = history(bound)
            h.http.enqueueHistory { _ in await gate.wait(); return .success(page) }
            try signal("drag-\(index)", requests: h.http.history.count)
            await eventually("real drag starts page \(index)", timeout: 90) { h.http.history.count == index + 1 }
            try signal("settle-\(index)", requests: h.http.history.count)
            await flush(window)
            XCTAssertEqual(h.http.history.last?.before, bound)
            XCTAssertEqual(h.http.history.count, index + 1)
            let before = try await partiallyReveal(anchorSequence, window)
            if index == 1 {
                h.http.readReturning([message(152)])
                h.coordinator.retryConnection()
                await eventually("incoming while history gated") { h.coordinator.items.count == 51 }
                await flush(window)
                XCTAssertLessThanOrEqual(abs(y(try row(anchorSequence, window), scroll) - before), 2)
            }
            gate.open()
            await eventually("drag page applied") { !h.coordinator.isLoadingHistory }
            await flush(window)
            let drift = abs(y(try row(anchorSequence, window), scroll) - before)
            print("CP5 REAL DRAG page=\(index) bound=\(bound) drift=\(drift) reduce=\(UIAccessibility.isReduceMotionEnabled)")
            XCTAssertLessThanOrEqual(drift, 2)
            XCTAssertEqual(h.http.history.count, index + 1, "one request per boundary reach")
            let sequences = h.coordinator.items.compactMap { item -> Int? in
                if case .message(let message) = item { return message.sequence }
                return nil
            }
            let first = try XCTUnwrap(page.messages.first)
            XCTAssertEqual(sequences, Array(first.sequence...152))
        }
        XCTAssertFalse(h.coordinator.hasOlder)
        let ack = interactionFile.deletingLastPathComponent().appendingPathComponent("cp5-drag-end")
        if FileManager.default.fileExists(atPath: ack.path) { try FileManager.default.removeItem(at: ack) }
        try signal("end-of-history", requests: h.http.history.count)
        await eventually("additional end-of-history gestures", timeout: 30) {
            FileManager.default.fileExists(atPath: ack.path)
        }
        await flush(window)
        XCTAssertEqual(h.http.history.count, 4)
        for replacement in [false, true] {
            let next = await boot()
            let nextWindow = try await mount(next, size: .large)
            defer { next.coordinator.dismiss(); nextWindow.isHidden = true }
            let gate = Gate()
            defer { gate.open() }
            let page = history(102)
            next.http.enqueueHistory { _ in await gate.wait(); return .success(page) }
            try signal(replacement ? "drag-identity" : "drag-closure", requests: 1)
            await eventually("real drag before terminal change", timeout: 90) { next.http.history.count == 2 }
            try signal("terminal-settle", requests: 2)
            await flush(nextWindow)
            if replacement {
                next.authority.value = nil
                next.coordinator.identityDidChange()
                await eventually("authority removed") { next.coordinator.phase == .ended }
            } else {
                next.http.enqueueRead { _ in .unavailable }
                next.coordinator.retryConnection()
                await eventually("closed") { next.coordinator.phase == .unavailable }
            }
            gate.open()
            await settle()
            XCTAssertTrue(next.coordinator.items.isEmpty)
            XCTAssertFalse(next.coordinator.hasOlder)
            XCTAssertFalse(next.coordinator.isLoadingHistory)
        }
        try signal("complete", requests: 4)
    }

    private func manualInteraction(_ h: CoordinatorHarness, window: UIWindow,
                                   controls: HistoryInteractionControls) async throws {
        let gates = [Gate(), Gate(), Gate()]
        defer { gates.forEach { $0.open() } }
        for (gate, bound) in zip(gates, [102, 52, 2]) {
            let page = history(bound)
            h.http.enqueueHistory { _ in await gate.wait(); return .success(page) }
        }
        var released = 0
        controls.release = {
            guard released < gates.count else { return }
            gates[released].open()
            released += 1
        }
        controls.incoming = {
            h.http.readReturning([self.message(152)])
            h.coordinator.retryConnection()
        }
        controls.close = {
            h.http.enqueueRead { _ in .unavailable }
            h.coordinator.retryConnection()
        }
        try signal("manual-ready", requests: 1)
        await eventually("manual Finish button", timeout: 1800) { controls.finished }
        try signal("manual-finished", requests: h.http.history.count)
    }

    func testPrependKeepsPartiallyVisibleTallBubbleWithinTwoPointsAcrossConsecutivePages() async throws {
        for size in [DynamicTypeSize.large, .accessibility3] {
            let h = await boot()
            let window = try await mount(h, size: size)
            defer { h.coordinator.dismiss(); window.isHidden = true }
            let scroll = try scroll(window)
            for (pageIndex, bound, sequence) in [(1, 102, 105), (2, 52, 56)] {
                let gate = Gate()
                let page = history(bound)
                h.http.enqueueHistory { _ in await gate.wait(); return .success(page) }
                try await reachTop(window, http: h.http)
                await flush(window)
                let before = try await partiallyReveal(sequence, window)
                gate.open()
                await eventually("older page \(pageIndex)") { h.coordinator.items.count == 50 + pageIndex * 50 }
                await flush(window)
                let after = y(try row(sequence, window), scroll)
                print("CP5 anchor size=\(size) reduce=\(UIAccessibility.isReduceMotionEnabled) page=\(pageIndex) sequence=\(sequence) before=\(before) after=\(after) drift=\(abs(after - before))")
                XCTAssertLessThanOrEqual(abs(after - before), 2)
            }
            XCTAssertEqual(h.http.history.count, 3, "layout never drains history")
        }
    }

    func testReadingPositionAtApplicationWinsOverRequestStartAndConcurrentAppend() async throws {
        let h = await boot()
        let window = try await mount(h, size: .large)
        defer { h.coordinator.dismiss(); window.isHidden = true }
        let scroll = try scroll(window)
        scroll.setContentOffset(.zero, animated: false)
        await flush(window)
        let gate = Gate()
        let page = history(102)
        h.http.enqueueHistory { _ in await gate.wait(); return .success(page) }
        try await reachTop(window, http: h.http)
        await flush(window)
        let before = try await partiallyReveal(105, window)
        h.http.readReturning([message(152)])
        h.coordinator.retryConnection()
        await eventually("append during history") { h.coordinator.items.count == 51 }
        await flush(window)
        XCTAssertLessThanOrEqual(abs(y(try row(105, window), scroll) - before), 2)
        gate.open()
        await eventually("history arrived") { h.coordinator.items.count == 101 }
        await flush(window)
        let drift = abs(y(try row(105, window), scroll) - before)
        print("CP5 moved-during-fetch/concurrent-append drift=\(drift)")
        XCTAssertLessThanOrEqual(drift, 2)
        XCTAssertGreaterThan(bottomGap(scroll), 100)
    }

    func testTopFailureRetryIsAccessibleTargetSizedAndDoesNotJumpToBottom() async throws {
        for size in [DynamicTypeSize.large, .accessibility3] {
            let h = await boot()
            let window = try await mount(h, size: size)
            defer { h.coordinator.dismiss(); window.isHidden = true }
            let scroll = try scroll(window)
            scroll.setContentOffset(.zero, animated: false)
            await flush(window)
            h.http.enqueueHistory { _ in .unknown }
            try await reachTop(window, http: h.http)
            await eventually("history failure") { h.coordinator.historyFailed }
            await flush(window)
            let retry = try XCTUnwrap(accessElements(window).first { accessibilityID($0) == "chat.historyRetry" })
            XCTAssertEqual(retry.accessibilityLabel, ConversationCopy.retryOlder)
            XCTAssertGreaterThanOrEqual(retry.accessibilityFrame.height + 0.000001, 44)
            XCTAssertGreaterThanOrEqual(retry.accessibilityFrame.width + 0.000001, 44)
            let anchor = try row(102, window)
            let before = y(anchor, scroll)
            XCTAssertTrue(retry.accessibilityActivate())
            await eventually("retry applied") { h.coordinator.items.count == 100 }
            await flush(window)
            XCTAssertLessThanOrEqual(abs(y(try row(102, window), scroll) - before), 2)
            XCTAssertGreaterThan(bottomGap(scroll), 100)
            XCTAssertEqual(h.http.history.map(\.before), [nil, 102, 102])
            XCTAssertTrue(h.http.sends.isEmpty)
        }
    }

    func testChangingDynamicTypeKeepsTheReadingBubbleAtItsViewportPosition() async throws {
        let h = await boot()
        let textSize = HistoryTextSize()
        let window = try await mount(h, size: .large, textSize: textSize)
        defer { h.coordinator.dismiss(); window.isHidden = true }
        let scroll = try scroll(window)
        scroll.setContentOffset(.zero, animated: false)
        await flush(window)
        let before = try await partiallyReveal(105, window)
        textSize.value = .accessibility3
        await flush(window)
        let drift = abs(y(try row(105, window), scroll) - before)
        print("CP5 live Dynamic Type change drift=\(drift)")
        XCTAssertLessThanOrEqual(drift, 2)
    }

    func testPendingAndFailedLocalResolutionDuringPrependKeepsReadingPosition() async throws {
        let h = await boot()
        let window = try await mount(h, size: .large)
        defer { h.coordinator.dismiss(); window.isHidden = true }
        let scroll = try scroll(window)
        h.coordinator.draft = "local payload"
        h.coordinator.sendDraft()
        await eventually("failed local retained") { h.http.reconciles.count == 1 }
        await flush(window)
        scroll.setContentOffset(.zero, animated: false)
        await flush(window)
        let gate = Gate()
        let page = history(102)
        h.http.enqueueHistory { _ in await gate.wait(); return .success(page) }
        try await reachTop(window, http: h.http)
        await flush(window)
        let before = try await partiallyReveal(105, window)
        let message = MsgFixture.message(152, sender: .own, text: "local payload", identity: 1)
        h.http.enqueueSend { _ in .success(message) }
        h.coordinator.retryFailed(MsgFixture.identity(1))
        await eventually("manual Retry resolved") { h.coordinator.outstandingLocalCount == 0 }
        gate.open()
        await eventually("older applied") { h.coordinator.items.count == 101 }
        await flush(window)
        XCTAssertLessThanOrEqual(abs(y(try row(105, window), scroll) - before), 2)
        XCTAssertEqual(h.http.sends.count, 2, "only the explicit Retry resends")
        XCTAssertEqual(h.http.sends.first, h.http.sends.last)
    }

    /// The simulator's hardware-keyboard configuration never shows the software
    /// keyboard in this app-hosted target, so this applies the same bottom safe
    /// area inset the keyboard produces, in animated frame steps. It proves the
    /// viewport-resize response, not the system keyboard itself.
    private func setKeyboardInset(_ target: CGFloat, _ window: UIWindow) async {
        let host = window.rootViewController!
        let start = host.additionalSafeAreaInsets.bottom
        for step in 1...15 {
            host.additionalSafeAreaInsets.bottom = start + (target - start) * CGFloat(step) / 15
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(16))
        }
        await flush(window)
    }

    func testViewportShrinkLikeKeyboardDoesNotMoveAReaderOfOlderMessages() async throws {
        let h = await boot()
        let window = try await mount(h, size: .large)
        defer { h.coordinator.dismiss(); window.isHidden = true }
        let scroll = try scroll(window)
        scroll.setContentOffset(.zero, animated: false)
        await flush(window)
        let before = try await partiallyReveal(105, window)
        let offset = scroll.contentOffset.y
        await setKeyboardInset(336, window)
        let shown = y(try row(105, window), scroll)
        print("CP5 KB reader-show: drift=\(abs(shown - before)) offsetDelta=\(scroll.contentOffset.y - offset) gap=\(bottomGap(scroll))")
        XCTAssertLessThanOrEqual(abs(shown - before), 2)
        XCTAssertGreaterThan(bottomGap(scroll), 100)
        await setKeyboardInset(0, window)
        let hidden = y(try row(105, window), scroll)
        print("CP5 KB reader-hide: drift=\(abs(hidden - before)) gap=\(bottomGap(scroll))")
        XCTAssertLessThanOrEqual(abs(hidden - before), 2)
        XCTAssertGreaterThan(bottomGap(scroll), 100)
    }
}
