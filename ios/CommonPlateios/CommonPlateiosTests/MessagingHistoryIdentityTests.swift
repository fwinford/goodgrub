import Foundation
import XCTest
@testable import CommonPlateios

final class HistoryCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    var cancelled: Bool { lock.withLock { _cancelled } }
    func record() { lock.withLock { _cancelled = true } }
}

@MainActor
final class MessagingHistoryIdentityTests: XCTestCase {
    private func gated(_ older: Bool, outcome: ConversationHTTPOutcome<ChatMessageHistoryDTO>? = nil) async -> (CoordinatorHarness, Gate, HistoryCancellationProbe) {
        let http = ScriptedHTTP()
        http.defaultHistory = { call in .success(MsgFixture.historyPage(total: 51, before: call.before)) }
        let h = CoordinatorHarness.make(http: http, withSocket: false)
        if older {
            h.coordinator.start()
            await eventually("initialized") { h.coordinator.hasLoaded }
        }
        let gate = Gate()
        let probe = HistoryCancellationProbe()
        http.enqueueHistory { call in
            await withTaskCancellationHandler {
                await gate.wait() // Deliberately noncooperative completion after cancellation.
                return outcome ?? .success(MsgFixture.historyPage(total: 51, before: call.before))
            } onCancel: { probe.record() }
        }
        if older { h.coordinator.loadOlderMessages() } else { h.coordinator.start() }
        await eventually("history gated") { http.history.count == (older ? 2 : 1) }
        return (h, gate, probe)
    }

    func testIdentityReplacementAndRemovalCancelAndFenceLatestAndOlder() async {
        for older in [false, true] {
            for replacement in [nil, MsgFixture.otherAuthority] {
                let (h, gate, probe) = await gated(older)
                h.coordinator.draft = "private draft"
                h.authority.value = replacement
                h.coordinator.identityDidChange()
                await eventually("cancellation observed") { probe.cancelled }
                gate.open()
                await settle()
                XCTAssertEqual(h.coordinator.phase, .ended)
                XCTAssertTrue(h.coordinator.items.isEmpty)
                XCTAssertFalse(h.coordinator.hasOlder || h.coordinator.hasLoaded || h.coordinator.isLoadingHistory || h.coordinator.historyFailed)
                XCTAssertEqual(h.coordinator.draft, "")
                XCTAssertTrue(h.socket.connections.isEmpty)
                XCTAssertEqual(h.authority.rejectedCount, 0)
            }
        }
    }

    func testBackgroundCancelsWithoutApplyingLatePageAndForegroundRetriesAppliedBoundary() async {
        for older in [false, true] {
            let (h, gate, probe) = await gated(older)
            let count = h.coordinator.items.count
            h.coordinator.sceneDidEnterBackground()
            await eventually("cancelled") { probe.cancelled }
            gate.open()
            await settle()
            XCTAssertEqual(h.coordinator.items.count, count)
            XCTAssertFalse(h.coordinator.isLoadingHistory)
            h.coordinator.sceneDidBecomeActive()
            if older { h.coordinator.loadOlderMessages() }
            await eventually("fresh history") { h.http.history.count == (older ? 3 : 2) }
            XCTAssertEqual(h.http.history.last?.before, older ? 2 : nil)
            XCTAssertEqual(h.http.opens, 1)
        }
    }

    func testLateObsoleteCompletionCannotClearNewLoadingState() async {
        let (h, oldGate, _) = await gated(true)
        h.coordinator.sceneDidEnterBackground()
        let newGate = Gate()
        h.http.enqueueHistory { call in
            await newGate.wait()
            return .success(MsgFixture.historyPage(total: 51, before: call.before))
        }
        h.coordinator.sceneDidBecomeActive()
        h.coordinator.loadOlderMessages()
        await eventually("new request gated") { h.http.history.count == 3 }
        oldGate.open()
        await settle()
        XCTAssertTrue(h.coordinator.isLoadingHistory)
        XCTAssertEqual(h.coordinator.items.count, 50)
        newGate.open()
        await eventually("new applied") { h.coordinator.items.count == 51 }
    }

    func testDismissCancelsLatestAndOlderAndPreventsAnyContinuation() async {
        for older in [false, true] {
            let (h, gate, probe) = await gated(older)
            h.coordinator.dismiss()
            await eventually("cancelled") { probe.cancelled }
            gate.open()
            await settle()
            h.coordinator.retryHistory()
            h.coordinator.loadOlderMessages()
            h.coordinator.sceneDidBecomeActive()
            XCTAssertEqual(h.coordinator.phase, .ended)
            XCTAssertTrue(h.coordinator.items.isEmpty)
            XCTAssertEqual(h.http.history.count, older ? 2 : 1)
        }
    }

    func testHistoryUnavailableIsTerminalAndPurgesDraftPendingAndFailedMessages() async {
        for older in [false, true] {
            let (h, gate, _) = await gated(older, outcome: .unavailable)
            h.http.enqueueSend { _ in .unknown }
            h.http.enqueueReconcile { _ in .success(nil) }
            h.coordinator.draft = "failed"
            h.coordinator.sendDraft()
            await eventually("failed send") { h.http.reconciles.count == 1 }
            h.coordinator.draft = "draft"
            gate.open()
            await eventually("closed") { h.coordinator.phase == .unavailable }
            XCTAssertTrue(h.coordinator.items.isEmpty)
            XCTAssertEqual(h.coordinator.draft, "")
            XCTAssertEqual(h.coordinator.outstandingLocalCount, 0)
            XCTAssertFalse(h.coordinator.hasLoaded || h.coordinator.hasOlder || h.coordinator.historyFailed || h.coordinator.isLoadingHistory)
            h.coordinator.retryHistory()
            h.coordinator.retryConnection()
            h.coordinator.sceneDidBecomeActive()
            await settle()
            XCTAssertEqual(h.http.opens, 1)
        }
    }

    func testClosureFromSendWhileHistoryIsGatedCannotResurrectRows() async {
        for older in [false, true] {
            let (h, gate, probe) = await gated(older)
            h.http.enqueueSend { _ in .unavailable }
            h.coordinator.draft = "close"
            h.coordinator.sendDraft()
            await eventually("closed") { h.coordinator.phase == .unavailable }
            await eventually("history cancelled") { probe.cancelled }
            gate.open()
            await settle()
            XCTAssertTrue(h.coordinator.items.isEmpty)
            XCTAssertFalse(h.coordinator.hasLoaded || h.coordinator.hasOlder)
        }
    }

    func testStaleAuthorityRejectionCannotRejectReplacementCredential() async {
        for older in [false, true] {
            let (h, gate, _) = await gated(older, outcome: .identityInvalid)
            h.authority.value = MsgFixture.otherAuthority
            gate.open()
            await eventually("ended") { h.coordinator.phase == .ended }
            XCTAssertEqual(h.authority.rejectedCount, 0)
            XCTAssertTrue(h.coordinator.items.isEmpty)
        }
    }

    func testForwardClosureCancelsPendingHistoryAndLateSuccessCannotReopen() async {
        let (h, gate, probe) = await gated(true)
        h.http.enqueueRead { _ in .unavailable }
        h.coordinator.retryConnection()
        await eventually("forward closed") { h.coordinator.phase == .unavailable }
        await eventually("history cancellation") { probe.cancelled }
        gate.open()
        await settle()
        XCTAssertTrue(h.coordinator.items.isEmpty)
        XCTAssertFalse(h.coordinator.hasLoaded || h.coordinator.hasOlder || h.coordinator.isLoadingHistory)
        h.coordinator.sceneDidBecomeActive()
        h.coordinator.retryHistory()
        XCTAssertEqual(h.http.history.count, 2)
    }

    func testHelperReplacementUsesFreshConversationRowsAndCursors() async {
        let (old, gate, _) = await gated(true)
        old.authority.value = MsgFixture.otherAuthority
        old.coordinator.identityDidChange()
        let http = ScriptedHTTP()
        http.defaultConversationId = MsgFixture.otherConversationId
        let replacement = CoordinatorHarness.make(http: http, withSocket: false, authority: MsgAuthorityBox(MsgFixture.otherAuthority))
        replacement.coordinator.start()
        await eventually("replacement ready") { replacement.coordinator.hasLoaded }
        gate.open()
        await settle()
        XCTAssertTrue(old.coordinator.items.isEmpty)
        XCTAssertTrue(replacement.coordinator.items.isEmpty)
        XCTAssertNil(http.history.first?.before)
        XCTAssertEqual(http.history.first?.conversationId, MsgFixture.otherConversationId)
        XCTAssertEqual(http.reads.first?.after, 0)
    }
}
