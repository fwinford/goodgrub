import Foundation
import XCTest
@testable import CommonPlateios

/// Inline "Not sent · Tap to retry": recoverable failures stay in the
/// transcript and retry the same logical message, with no sheet.
@MainActor
final class MessagingInlineRetryTests: XCTestCase {
    private func booted(_ http: ScriptedHTTP) async -> CoordinatorHarness {
        let h = CoordinatorHarness.make(http: http, withSocket: false)
        await h.boot()
        return h
    }

    private func send(_ h: CoordinatorHarness, _ text: String) {
        h.coordinator.draft = text
        h.coordinator.sendDraft()
    }

    private func local(_ h: CoordinatorHarness) -> [LocalOutgoingMessage] {
        h.coordinator.items.compactMap { if case .local(let l) = $0 { return l } else { return nil } }
    }

    private func failFirst(_ http: ScriptedHTTP) {
        http.enqueueSend { _ in .unknown }
        http.enqueueReconcile { _ in .success(nil) }
    }

    func testRecoverableFailureStaysVisibleInPlaceWithItsTextAndOpensNoSheet() async {
        let http = ScriptedHTTP()
        http.readReturning([MsgFixture.message(1, sender: .other, text: "hello")])
        failFirst(http)
        let h = await booted(http)
        send(h, "  keep\nme  ")
        await eventually("failed") { self.local(h).first?.state == .failed(.notDelivered) }
        XCTAssertEqual(h.coordinator.items.count, 2)
        XCTAssertEqual(local(h).first?.text, "  keep\nme  ")
        h.coordinator.presentFailedSheet(for: MsgFixture.identity(1))
        XCTAssertNil(h.coordinator.failedSheetTarget)
        XCTAssertNil(h.coordinator.failedSheetMessage)
    }

    func testRetryTargetsTheSameLogicalMessageAndClearsTheFailureOnSuccess() async {
        let http = ScriptedHTTP()
        failFirst(http)
        let h = await booted(http)
        send(h, "again")
        await eventually("failed") { self.local(h).first?.state == .failed(.notDelivered) }
        http.enqueueSend { call in .success(MsgFixture.message(2, sender: .own, text: call.text, identity: 1)) }
        h.coordinator.retryFailed(MsgFixture.identity(1))
        XCTAssertEqual(local(h).first?.state, .sending)
        await eventually("delivered") { self.local(h).isEmpty && h.coordinator.items.count == 1 }
        XCTAssertEqual(http.sends.count, 2)
        XCTAssertEqual(http.sends[0], http.sends[1], "same conversation, client id and payload")
    }

    func testRepeatedRetryTapsSendOnceWhileTheRetryIsInFlight() async {
        let http = ScriptedHTTP()
        failFirst(http)
        let h = await booted(http)
        send(h, "once")
        await eventually("failed") { self.local(h).first?.state == .failed(.notDelivered) }
        let gate = Gate()
        http.enqueueSend { call in await gate.wait(); return .success(MsgFixture.message(2, sender: .own, text: call.text, identity: 1)) }
        for _ in 0..<5 { h.coordinator.retryFailed(MsgFixture.identity(1)) }
        await eventually("one retry") { http.sends.count == 2 }
        gate.open()
        await eventually("delivered") { self.local(h).isEmpty }
        XCTAssertEqual(http.sends.count, 2)
        XCTAssertEqual(h.coordinator.items.count, 1)
    }

    func testRepeatedFailureReturnsToTheRecoverableState() async {
        let http = ScriptedHTTP()
        failFirst(http)
        failFirst(http)
        let h = await booted(http)
        send(h, "flaky")
        await eventually("failed") { self.local(h).first?.state == .failed(.notDelivered) }
        h.coordinator.retryFailed(MsgFixture.identity(1))
        await eventually("failed again") { http.sends.count == 2 && self.local(h).first?.state == .failed(.notDelivered) }
        XCTAssertEqual(local(h).count, 1)
        XCTAssertTrue(LocalSendFailure.notDelivered.isRetryable)
    }

    func testOnlyTheFailedMessageIsAffectedByRetryAndRemove() async {
        let http = ScriptedHTTP()
        http.readReturning([MsgFixture.message(1, sender: .other, text: "hello")])
        failFirst(http)
        let h = await booted(http)
        send(h, "bad")
        await eventually("failed") { self.local(h).first?.state == .failed(.notDelivered) }
        h.coordinator.cancelFailed(MsgFixture.identity(1))
        XCTAssertTrue(local(h).isEmpty)
        XCTAssertEqual(h.coordinator.items.count, 1, "the received message is untouched")
    }

    func testUnconfirmedMessageCannotBeRemovedAndStaysUntilReconciled() async {
        let http = ScriptedHTTP()
        http.enqueueSend { _ in .unknown }; http.enqueueReconcile { _ in .unknown }
        let h = await booted(http)
        send(h, "maybe")
        await eventually("unconfirmed") { self.local(h).first?.state == .failed(.unconfirmed) }
        XCTAssertFalse(LocalSendFailure.unconfirmed.isDefinitelyUnsent)
        XCTAssertTrue(LocalSendFailure.notDelivered.isDefinitelyUnsent)
        XCTAssertTrue(LocalSendFailure.refused(.invalidMessage).isDefinitelyUnsent)
        h.coordinator.cancelFailed(MsgFixture.identity(1))
        XCTAssertEqual(local(h).map(\.text), ["maybe"], "unknown delivery is never discarded")
        http.enqueueSend { call in .success(MsgFixture.message(2, sender: .own, text: call.text, identity: 1)) }
        h.coordinator.retryFailed(MsgFixture.identity(1))
        await eventually("reconciled") { self.local(h).isEmpty && http.sends.count == 2 }
        XCTAssertEqual(http.sends[0], http.sends[1], "same logical message")
        h.coordinator.cancelFailed(MsgFixture.identity(1))
        XCTAssertEqual(h.coordinator.items.count, 1, "a confirmed message is untouched")
    }

    func testReconciliationProvingNonDeliveryMakesRemoveAvailable() async {
        let http = ScriptedHTTP()
        http.enqueueSend { _ in .unknown }; http.enqueueReconcile { _ in .unknown }
        http.enqueueSend { _ in .unknown }; http.enqueueReconcile { _ in .success(nil) }
        let h = await booted(http)
        send(h, "x")
        await eventually("unconfirmed") { self.local(h).first?.state == .failed(.unconfirmed) }
        h.coordinator.retryFailed(MsgFixture.identity(1))
        await eventually("proved") { self.local(h).first?.state == .failed(.notDelivered) }
        h.coordinator.cancelFailed(MsgFixture.identity(1))
        XCTAssertTrue(local(h).isEmpty)
    }

    func testDefinitiveRefusalIsNotRetryableAndStillUsesTheSheet() async {
        let http = ScriptedHTTP()
        http.enqueueSend { _ in .refused(.invalidMessage) }
        let h = await booted(http)
        send(h, "refused")
        await eventually("refused") { self.local(h).first?.state == .failed(.refused(.invalidMessage)) }
        h.coordinator.retryFailed(MsgFixture.identity(1))
        await settle()
        XCTAssertEqual(http.sends.count, 1)
        h.coordinator.presentFailedSheet(for: MsgFixture.identity(1))
        XCTAssertEqual(h.coordinator.failedSheetTarget, MsgFixture.identity(1))
    }

    func testAuthorizationDenialOnRetryClosesTheConversationInsteadOfRetrying() async {
        let http = ScriptedHTTP()
        failFirst(http)
        let h = await booted(http)
        send(h, "blocked later")
        await eventually("failed") { self.local(h).first?.state == .failed(.notDelivered) }
        http.enqueueSend { _ in .unavailable }
        h.coordinator.retryFailed(MsgFixture.identity(1))
        await eventually("closed") { h.coordinator.phase == .unavailable }
        XCTAssertTrue(h.coordinator.items.isEmpty)
        h.coordinator.retryFailed(MsgFixture.identity(1))
        await settle()
        XCTAssertEqual(http.sends.count, 2, "a closed conversation never sends again")
    }

    func testFailureCopyIsConciseAndHeaderCopyIsGone() {
        XCTAssertEqual("\(ConversationCopy.notSent) · \(ConversationCopy.tapToRetry)", "Not sent · Tap to retry")
        XCTAssertEqual(ConversationCopy.title, "Chat")
    }
}
