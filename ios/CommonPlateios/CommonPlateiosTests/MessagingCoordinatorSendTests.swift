import Foundation
import XCTest
@testable import CommonPlateios

/// W4-MSG1 CP3: send, ambiguous-result reconciliation and manual Retry.
@MainActor
final class MessagingCoordinatorSendTests: XCTestCase {
    private func sent(_ seq: Int, id: String) -> ChatMessage {
        ChatMessage(clientMessageId: id, sequence: seq, sender: .own, text: "x", createdAt: MsgFixture.epoch.addingTimeInterval(Double(seq)))
    }

    private func booted(_ http: ScriptedHTTP = ScriptedHTTP(), socket: Bool = true) async -> CoordinatorHarness {
        let h = CoordinatorHarness.make(http: http, withSocket: socket)
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

    func testSuccessfulSendUsesClientIdentityClearsDraftAndNeverMovesTheCursor() async {
        let http = ScriptedHTTP()
        let id = MsgFixture.identity(1)
        http.enqueueSend { call in .success(MsgFixture.message(7, sender: .own, text: call.text, identity: 1)) }
        let h = await booted(http)
        send(h, "  hello  ")
        XCTAssertEqual(h.coordinator.draft, "")
        XCTAssertEqual(local(h).first?.state, .sending)
        await eventually("sent") { http.sends.count == 1 && self.local(h).isEmpty }
        XCTAssertEqual(http.sends[0], ScriptedHTTP.SendCall(authority: MsgFixture.authority, conversationId: MsgFixture.conversationId, clientMessageId: id, text: "  hello  "))
        XCTAssertEqual(h.coordinator.items.count, 1)
        h.socket.last!.push(FakeSocketConnection.changedFrame(CoordinatorHarness.ref))
        await eventually("hint read") { http.reads.count == 3 }
        XCTAssertEqual(http.reads.last?.after, 0, "a POST result is not a catch-up cursor")
    }

    func testBlankOrInactiveDraftsAreNotSent() async {
        let h = await booted()
        send(h, "   \n")
        send(h, "")
        XCTAssertTrue(h.http.sends.isEmpty)
        XCTAssertFalse(h.coordinator.canSend)
        let fresh = CoordinatorHarness.make()
        fresh.coordinator.draft = "hi"
        fresh.coordinator.sendDraft()
        XCTAssertTrue(fresh.http.sends.isEmpty)
    }

    func testAmbiguousSendThatCommittedIsResolvedByExactReconciliationWithoutResend() async {
        let http = ScriptedHTTP()
        http.enqueueSend { _ in .unknown }                                   // response lost after commit
        http.enqueueReconcile { call in .success(MsgFixture.message(4, sender: .own, text: "hi", identity: 1)) }
        let h = await booted(http)
        send(h, "hi")
        await eventually("resolved") { self.local(h).isEmpty && h.coordinator.items.count == 1 }
        XCTAssertEqual(http.sends.count, 1)
        XCTAssertEqual(http.reconciles, [ScriptedHTTP.ReconcileCall(conversationId: MsgFixture.conversationId, clientMessageId: MsgFixture.identity(1))])
    }

    func testAmbiguousSendProvenAbsentFailsAsNotDeliveredAndIsNeverResentAutomatically() async {
        let http = ScriptedHTTP()
        http.enqueueSend { _ in .unknown }
        http.enqueueReconcile { _ in .success(nil) }
        let h = await booted(http)
        send(h, "hi")
        await eventually("failed") { self.local(h).first?.state == .failed(.notDelivered) }

        h.socket.last!.fail()                                                // reconnect
        h.scheduler.advance(by: 5)
        h.coordinator.sceneDidEnterBackground()
        h.coordinator.sceneDidBecomeActive()
        h.scheduler.advance(by: 120)
        h.socket.last!.push(FakeSocketConnection.changedFrame(CoordinatorHarness.ref))
        await settle()
        XCTAssertEqual(http.sends.count, 1, "no reconnect, foreground, periodic or hint may resend")
        XCTAssertEqual(local(h).first?.state, .failed(.notDelivered))
    }

    func testUnresolvableReconciliationFailsAsUnconfirmedAndKeepsPayload() async {
        let http = ScriptedHTTP()
        http.enqueueSend { _ in .unknown }
        http.enqueueReconcile { _ in .unknown }
        let h = await booted(http)
        send(h, "keep me")
        await eventually("unconfirmed") { self.local(h).first?.state == .failed(.unconfirmed) }
        XCTAssertEqual(local(h).first?.text, "keep me")
        XCTAssertEqual(h.authority.rejectedCount, 0)
    }

    func testSuccessWithAMismatchedIdentityIsNotTrustedAndIsReconciled() async {
        let http = ScriptedHTTP()
        http.enqueueSend { _ in .success(MsgFixture.message(3, sender: .own, identity: 99)) }
        http.enqueueReconcile { _ in .success(nil) }
        let h = await booted(http)
        send(h, "hi")
        await eventually("failed") { self.local(h).first?.state == .failed(.notDelivered) }
        XCTAssertEqual(h.coordinator.items.count, 1)
    }

    func testManualRetryResendsTheIdenticalConversationUUIDAndPayload() async {
        let http = ScriptedHTTP()
        http.enqueueSend { _ in .unknown }
        http.enqueueReconcile { _ in .success(nil) }
        let h = await booted(http)
        send(h, "  exact\n payload  ")
        await eventually("failed") { self.local(h).first?.state == .failed(.notDelivered) }
        let id = MsgFixture.identity(1)
        h.coordinator.presentFailedSheet(for: id)
        XCTAssertNil(h.coordinator.failedSheetTarget, "a recoverable failure never opens the sheet")
        XCTAssertEqual(local(h).first?.text, "  exact\n payload  ")
        http.enqueueSend { call in .success(MsgFixture.message(2, sender: .own, text: call.text, identity: 1)) }
        h.coordinator.retryFailed(id)
        XCTAssertNil(h.coordinator.failedSheetTarget)
        await eventually("retried") { self.local(h).isEmpty && h.coordinator.items.count == 1 }
        XCTAssertEqual(http.sends.count, 2)
        XCTAssertEqual(http.sends[0], http.sends[1])
    }

    func testRetryIsManualOnlyAndIgnoredWhileSendingOrForUnknownIdentity() async {
        let http = ScriptedHTTP()
        let gate = Gate()
        http.enqueueSend { _ in await gate.wait(); return .unknown }
        let h = await booted(http)
        send(h, "hi")
        await eventually("in flight") { http.sends.count == 1 }
        h.coordinator.retryFailed(MsgFixture.identity(1))
        h.coordinator.retryFailed(MsgFixture.identity(555))
        h.coordinator.presentFailedSheet(for: MsgFixture.identity(1))
        XCTAssertNil(h.coordinator.failedSheetTarget)
        gate.open()
        await settle()
        XCTAssertEqual(http.sends.count, 1)
    }

    func testCancelDiscardsOnlyThatFailedMessage() async {
        let http = ScriptedHTTP()
        http.enqueueSend { _ in .unknown }; http.enqueueReconcile { _ in .success(nil) }
        http.enqueueSend { _ in .unknown }; http.enqueueReconcile { _ in .success(nil) }
        let h = await booted(http)
        send(h, "one")
        await eventually("first failed") { self.local(h).first?.state == .failed(.notDelivered) }
        send(h, "two")
        await eventually("both failed") { self.local(h).count == 2 && self.local(h).allSatisfy { $0.state == .failed(.notDelivered) } }
        h.coordinator.cancelFailed(MsgFixture.identity(1))
        XCTAssertNil(h.coordinator.failedSheetTarget)
        XCTAssertEqual(local(h).map(\.text), ["two"])
        XCTAssertEqual(http.sends.count, 2)
    }

    func testDefinitiveRefusalsFailWithoutReconciliationAndTextRefusalSetsANotice() async {
        let http = ScriptedHTTP()
        http.enqueueSend { _ in .refused(.textNotAllowed) }
        let h = await booted(http)
        send(h, "no")
        await eventually("refused") { self.local(h).first?.state == .failed(.refused(.textNotAllowed)) }
        XCTAssertEqual(h.coordinator.notice, .reviseMessage)
        XCTAssertTrue(http.reconciles.isEmpty)
        XCTAssertEqual(http.sends.count, 1)
    }

    func testDefinitiveRefusalOffersNoRetryAndNeverResendsIdenticalContent() async {
        for refusal in [ConversationRefusal.textNotAllowed, .invalidMessage, .identityConflict] {
            let http = ScriptedHTTP()
            http.enqueueSend { _ in .refused(refusal) }
            let h = await booted(http)
            send(h, "refused")
            await eventually("refused \(refusal)") { self.local(h).first?.state == .failed(.refused(refusal)) }
            let id = MsgFixture.identity(1)
            h.coordinator.presentFailedSheet(for: id)
            h.coordinator.retryFailed(id)
            await settle()
            XCTAssertEqual(http.sends.count, 1, "\(refusal)")
            XCTAssertEqual(local(h).first?.state, .failed(.refused(refusal)))
            h.coordinator.cancelFailed(id)
            XCTAssertTrue(local(h).isEmpty)
        }
    }

    func testTransientAndAmbiguousFailuresStayRetryable() {
        XCTAssertTrue(LocalSendFailure.notDelivered.isRetryable)
        XCTAssertTrue(LocalSendFailure.unconfirmed.isRetryable)
        XCTAssertFalse(LocalSendFailure.refused(.invalidMessage).isRetryable)
    }

    // MARK: Outstanding local message capacity (F1)

    private func failOne(_ h: CoordinatorHarness, _ http: ScriptedHTTP, text: String, count: Int) async {
        http.enqueueSend { _ in .unknown }
        http.enqueueReconcile { _ in .success(nil) }
        send(h, text)
        await eventually("failed \(count)") { self.local(h).count == count && self.local(h).allSatisfy { $0.state == .failed(.notDelivered) } }
    }

    func testOutstandingLocalMessagesAreCappedAndNothingIsDiscarded() async {
        let http = ScriptedHTTP()
        let h = await booted(http)
        let limit = ConversationConfiguration().maxOutstandingLocal
        XCTAssertEqual(limit, 10)
        for i in 1...limit { await failOne(h, http, text: "m\(i)", count: i) }
        XCTAssertTrue(h.coordinator.isAtLocalCapacity)
        h.coordinator.draft = "one too many"
        XCTAssertFalse(h.coordinator.canSend)
        h.coordinator.sendDraft()
        await settle()
        XCTAssertEqual(http.sends.count, limit, "no send above the limit")
        XCTAssertEqual(local(h).map(\.text), (1...limit).map { "m\($0)" }, "no unresolved message is dropped")
        XCTAssertEqual(h.coordinator.draft, "one too many", "the draft is preserved, not consumed")
    }

    func testInFlightAndAmbiguousSendsCountTowardsTheLimit() async {
        let http = ScriptedHTTP()
        var config = ConversationConfiguration(); config.maxOutstandingLocal = 2
        let h = CoordinatorHarness.make(http: http, configuration: config)
        await h.boot()
        let gate = Gate()
        http.enqueueSend { _ in await gate.wait(); return .unknown }     // stays in flight
        http.enqueueSend { _ in .unknown }
        http.enqueueReconcile { _ in .unknown }                          // stays unconfirmed
        send(h, "a")
        send(h, "b")
        await eventually("one unconfirmed") { self.local(h).contains { $0.state == .failed(.unconfirmed) } }
        XCTAssertTrue(h.coordinator.isAtLocalCapacity)
        send(h, "c")
        XCTAssertEqual(http.sends.count, 2)
        gate.open()
    }

    func testCapacityIsFreedByCancelAndBySuccessfulManualRetryAndSendingResumes() async {
        let http = ScriptedHTTP()
        var config = ConversationConfiguration(); config.maxOutstandingLocal = 2
        let h = CoordinatorHarness.make(http: http, configuration: config)
        await h.boot()
        await failOne(h, http, text: "one", count: 1)
        await failOne(h, http, text: "two", count: 2)
        XCTAssertFalse(h.coordinator.canSend || { h.coordinator.draft = "x"; return h.coordinator.canSend }())
        h.coordinator.cancelFailed(MsgFixture.identity(1))
        XCTAssertFalse(h.coordinator.isAtLocalCapacity)
        http.enqueueSend { call in .success(MsgFixture.message(5, sender: .own, text: call.text, identity: 3)) }
        h.coordinator.draft = "three"
        XCTAssertTrue(h.coordinator.canSend)
        h.coordinator.sendDraft()
        await eventually("freed by success") { self.local(h).map(\.text) == ["two"] }
        XCTAssertFalse(h.coordinator.isAtLocalCapacity)
        // retry keeps the same identity and payload, and does not change the count
        http.enqueueSend { call in .success(MsgFixture.message(6, sender: .own, text: call.text, identity: 2)) }
        h.coordinator.retryFailed(MsgFixture.identity(2))
        await eventually("retry resolved") { self.local(h).isEmpty }
        XCTAssertEqual(http.sends.last, ScriptedHTTP.SendCall(authority: MsgFixture.authority, conversationId: MsgFixture.conversationId, clientMessageId: MsgFixture.identity(2), text: "two"))
    }

    func testReconciliationThatFindsTheMessageFreesCapacity() async {
        let http = ScriptedHTTP()
        var config = ConversationConfiguration(); config.maxOutstandingLocal = 1
        let h = CoordinatorHarness.make(http: http, configuration: config)
        await h.boot()
        http.enqueueSend { _ in .unknown }
        http.enqueueReconcile { _ in .success(MsgFixture.message(4, sender: .own, text: "hi", identity: 1)) }
        send(h, "hi")
        await eventually("resolved") { self.local(h).isEmpty && h.coordinator.items.count == 1 }
        XCTAssertFalse(h.coordinator.isAtLocalCapacity)
    }

    func testClosureAndReplacementPurgeAllOutstandingLocalState() async {
        let http = ScriptedHTTP()
        let h = await booted(http)
        for i in 1...3 { await failOne(h, http, text: "secret \(i)", count: i) }
        h.authority.value = MsgFixture.otherAuthority
        h.coordinator.identityDidChange()
        XCTAssertEqual(h.coordinator.outstandingLocalCount, 0)
        XCTAssertTrue(h.coordinator.items.isEmpty)
        XCTAssertFalse(h.coordinator.isAtLocalCapacity)

        let http2 = ScriptedHTTP()
        let g = await booted(http2)
        await failOne(g, http2, text: "secret", count: 1)
        http2.enqueueRead { _ in .unavailable }
        g.socket.last!.push(FakeSocketConnection.changedFrame(CoordinatorHarness.ref))
        await eventually("closed") { g.coordinator.phase == .unavailable }
        XCTAssertEqual(g.coordinator.outstandingLocalCount, 0)
        XCTAssertTrue(g.coordinator.items.isEmpty)
    }

    func testDefinitiveRefusalsAlsoOccupyCapacityUntilCancelled() async {
        let http = ScriptedHTTP()
        var config = ConversationConfiguration(); config.maxOutstandingLocal = 1
        let h = CoordinatorHarness.make(http: http, configuration: config)
        await h.boot()
        http.enqueueSend { _ in .refused(.invalidMessage) }
        send(h, "bad")
        await eventually("refused") { self.local(h).first?.state == .failed(.refused(.invalidMessage)) }
        XCTAssertTrue(h.coordinator.isAtLocalCapacity)
        h.coordinator.cancelFailed(MsgFixture.identity(1))
        XCTAssertFalse(h.coordinator.isAtLocalCapacity)
    }

    func testSendConversationUnavailablePurgesTheWholeConversation() async {
        let http = ScriptedHTTP()
        http.readReturning([MsgFixture.message(1)])
        http.enqueueSend { _ in .unavailable }
        let h = await booted(http)
        send(h, "blocked now")
        await eventually("closed") { h.coordinator.phase == .unavailable }
        XCTAssertTrue(h.coordinator.items.isEmpty)
        XCTAssertEqual(h.coordinator.draft, "")
        XCTAssertNil(h.coordinator.failedSheetTarget)
    }

    func testReconciliationConversationUnavailableAlsoPurges() async {
        let http = ScriptedHTTP()
        http.enqueueSend { _ in .unknown }
        http.enqueueReconcile { _ in .unavailable }
        let h = await booted(http)
        send(h, "hi")
        await eventually("closed") { h.coordinator.phase == .unavailable }
        XCTAssertTrue(h.coordinator.items.isEmpty)
    }

    func testSendAuthorityInvalidRejectsIdentityAndPurgesButServiceUnavailableDoesNot() async {
        let http = ScriptedHTTP()
        http.enqueueSend { _ in .identityInvalid }
        let h = await booted(http)
        send(h, "hi")
        await eventually("rejected") { h.authority.rejectedCount == 1 }
        XCTAssertEqual(h.coordinator.phase, .ended)
        XCTAssertTrue(h.coordinator.items.isEmpty)

        let http2 = ScriptedHTTP()
        http2.enqueueSend { _ in .unknown }                                  // 503 / transport
        http2.enqueueReconcile { _ in .unknown }
        let g = await booted(http2)
        send(g, "hi")
        await eventually("unconfirmed") { self.local(g).first?.state == .failed(.unconfirmed) }
        XCTAssertEqual(g.authority.rejectedCount, 0)
        XCTAssertEqual(g.coordinator.phase, .active)
    }

    func testSendFromAnOldIdentityCannotPostIntoAReplacementCoordinator() async {
        let http = ScriptedHTTP()
        let gate = Gate()
        http.enqueueSend { _ in await gate.wait(); return .success(MsgFixture.message(1, sender: .own, identity: 1)) }
        let old = await booted(http)
        send(old, "old helper message")
        await eventually("in flight") { http.sends.count == 1 }

        let replacement = await booted(ScriptedHTTP())
        old.authority.value = MsgFixture.otherAuthority
        old.coordinator.identityDidChange()
        gate.open()
        await settle()
        XCTAssertTrue(old.coordinator.items.isEmpty)
        XCTAssertTrue(replacement.coordinator.items.isEmpty)
        XCTAssertTrue(http.reconciles.isEmpty, "a fenced send is never reconciled or resent")
        XCTAssertEqual(http.sends.count, 1)
    }

    func testBackgroundDoesNotAbandonAnInFlightSend() async {
        let http = ScriptedHTTP()
        let gate = Gate()
        http.enqueueSend { call in await gate.wait(); return .success(MsgFixture.message(1, sender: .own, text: call.text, identity: 1)) }
        let h = await booted(http)
        send(h, "hi")
        await eventually("in flight") { http.sends.count == 1 }
        h.coordinator.sceneDidEnterBackground()
        gate.open()
        await eventually("sent") { self.local(h).isEmpty && h.coordinator.items.count == 1 }
        XCTAssertEqual(http.sends.count, 1)
    }
}
