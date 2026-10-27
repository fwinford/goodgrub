import Foundation
import XCTest
@testable import CommonPlateios

/// W4-MSG1 CP3: HTTP-authoritative catch-up, content-free hints, reconnect,
/// periodic reconciliation and foreground/background lifecycle.
@MainActor
final class MessagingCoordinatorReconciliationTests: XCTestCase {
    private func m(_ seq: Int, _ sender: ChatMessageSender = .other) -> ChatMessage { MsgFixture.message(seq, sender: sender) }
    private func reconnectDelays(_ h: CoordinatorHarness) -> [TimeInterval] { h.scheduler.sleepRequests.filter { $0 != 30 } }

    // MARK: Subscribe / catch-up ordering

    func testHTTPCatchUpRunsBeforeTheSocketConnectsAndSubscribeIsSentOnce() async throws {
        let http = ScriptedHTTP()
        let gate = Gate()
        http.enqueueRead { call in await gate.wait(); return .success(MsgFixture.page([MsgFixture.message(1)], after: call.after)) }
        let h = CoordinatorHarness.make(http: http)
        h.coordinator.start()
        await eventually("first read") { http.reads.count == 1 }
        await settle()
        XCTAssertTrue(h.socket.connections.isEmpty, "socket must not connect before the first HTTP catch-up completes")
        gate.open()
        await eventually("socket") { h.socket.connections.count == 1 }
        let connection = try XCTUnwrap(h.socket.last)
        await eventually("subscribe") { connection.sent.count == 1 }
        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(connection.sent[0].utf8)) as? [String: String])
        XCTAssertEqual(frame, ["type": "subscribe", "requestId": MsgFixture.requestId, "conversationId": MsgFixture.conversationId])
        XCTAssertEqual(connection.authority, MsgFixture.authority)
        await settle()
        XCTAssertEqual(connection.sent.count, 1)
        XCTAssertEqual(h.coordinator.items.count, 1)
    }

    func testSubscribedAckTriggersACatchUpThatClosesTheSubscribeFetchRace() async {
        let http = ScriptedHTTP()
        http.readReturning([])                       // initial catch-up sees nothing
        http.readReturning([m(1)])                   // message committed between fetch and subscribe
        let h = CoordinatorHarness.make(http: http)
        await h.boot()
        XCTAssertEqual(http.reads.map(\.after), [0, 0])
        XCTAssertEqual(h.coordinator.items.map(\.id), [MsgFixture.identity(1001)])
    }

    func testHintsDuringAnOutstandingFetchCoalesceIntoExactlyOneMoreFetch() async {
        let http = ScriptedHTTP()
        let h = CoordinatorHarness.make(http: http)
        await h.boot()
        let base = http.reads.count
        let gate = Gate()
        http.enqueueRead { call in await gate.wait(); return .success(MsgFixture.page([MsgFixture.message(1)], after: call.after)) }
        let socket = h.socket.last!
        socket.push(FakeSocketConnection.changedFrame(CoordinatorHarness.ref))
        await eventually("gated fetch") { http.reads.count == base + 1 }
        for _ in 0..<4 { socket.push(FakeSocketConnection.changedFrame(CoordinatorHarness.ref)) }
        await settle()
        XCTAssertEqual(http.reads.count, base + 1, "no concurrent fetch")
        gate.open()
        await eventually("one dirty rerun") { http.reads.count == base + 2 }
        await settle()
        XCTAssertEqual(http.reads.count, base + 2)
        XCTAssertEqual(http.reads.last?.after, 1)
        XCTAssertEqual(h.coordinator.items.count, 1)
    }

    func testDuplicateAndDelayedHintsNeverDuplicateMessages() async {
        let http = ScriptedHTTP()
        http.readReturning([]); http.readReturning([m(1), m(2)])
        let h = CoordinatorHarness.make(http: http)
        await h.boot()
        for _ in 0..<3 {
            h.socket.last!.push(FakeSocketConnection.changedFrame(CoordinatorHarness.ref))
            await settle()
        }
        XCTAssertEqual(h.coordinator.items.count, 2)
        XCTAssertEqual(http.reads.last?.after, 2)
    }

    func testMissingHintIsRecoveredByPeriodicReconciliation() async {
        let http = ScriptedHTTP()
        let h = CoordinatorHarness.make(http: http)
        await h.boot()
        http.readReturning([m(1)])
        let base = http.reads.count
        h.scheduler.advance(by: 30)
        await eventually("periodic read") { http.reads.count == base + 1 }
        await eventually("applied") { h.coordinator.items.count == 1 }
        // and it keeps recurring
        h.scheduler.advance(by: 30)
        await eventually("second periodic") { http.reads.count == base + 2 }
    }

    func testPeriodicReconciliationWorksWithoutAnySocket() async {
        let http = ScriptedHTTP()
        let h = CoordinatorHarness.make(http: http, withSocket: false)
        await h.boot()
        XCTAssertEqual(h.coordinator.connectionStatus, .idle)
        http.readReturning([m(1)])
        h.scheduler.advance(by: 30)
        await eventually("periodic applied") { h.coordinator.items.count == 1 }
    }

    func testNoHintOrUnrelatedFrameAdvancesTheCursorOrTriggersWork() async {
        let http = ScriptedHTTP()
        http.readReturning([]); http.readReturning([m(5)])
        let h = CoordinatorHarness.make(http: http)
        await h.boot()
        let base = http.reads.count
        let socket = h.socket.last!
        socket.push(FakeSocketConnection.changedFrame(MsgFixture.identity(777)))    // wrong subscription
        socket.push(#"{"type":"message","subscription":"\#(CoordinatorHarness.ref)","text":"leak"}"#)
        socket.push("garbage")
        socket.pushBinary()
        socket.push(FakeSocketConnection.subscribedFrame(MsgFixture.identity(778))) // second ack is ignored
        await settle()
        XCTAssertEqual(http.reads.count, base)
        XCTAssertEqual(h.coordinator.connectionStatus, .live)
        // A hint whose HTTP read fails leaves the cursor where the last applied page put it.
        http.enqueueRead { _ in .unknown }
        socket.push(FakeSocketConnection.changedFrame(CoordinatorHarness.ref))
        await eventually("failed read") { h.coordinator.isOffline }
        http.readReturning([])
        h.scheduler.advance(by: 30)
        await eventually("next") { http.reads.count == base + 2 }
        XCTAssertEqual(http.reads.last?.after, 5)
    }

    func testHTTPFailureShowsOfflineAndManualRetryRecovers() async {
        let http = ScriptedHTTP()
        http.enqueueHistory { _ in .unknown }
        let h = CoordinatorHarness.make(http: http, withSocket: false)
        h.coordinator.start()
        await eventually("offline") { h.coordinator.isOffline }
        XCTAssertFalse(h.coordinator.hasLoaded)
        XCTAssertEqual(h.coordinator.phase, .active)
        http.enqueueHistory { _ in .success(MsgFixture.history([MsgFixture.message(1)])) }
        h.coordinator.retryConnection()
        await eventually("recovered") { h.coordinator.hasLoaded && !h.coordinator.isOffline }
        XCTAssertEqual(h.coordinator.items.count, 1)
    }

    func testPaginationFollowsTheServerCursorAcrossPages() async {
        let http = ScriptedHTTP()
        http.readReturning([m(1), m(2)])
        http.readReturning([m(3)])
        var config = ConversationConfiguration(); config.pageLimit = 2
        let h = CoordinatorHarness.make(http: http, withSocket: false, configuration: config)
        await h.boot()
        XCTAssertEqual(http.reads.map(\.after), [0, 2])
        XCTAssertEqual(http.reads.map(\.limit), [2, 2])
        XCTAssertEqual(h.coordinator.items.count, 3)
    }

    func testLongHistoryIsNeverTruncatedByAPageCap() async {
        let http = ScriptedHTTP()
        let total = 450
        http.defaultRead = { call in
            let upper = min(total, call.after + call.limit)
            let seqs = upper > call.after ? Array((call.after + 1)...upper) : []
            return .success(ChatMessagePageDTO(messages: seqs.map { MsgFixture.message($0) }, nextAfter: seqs.last ?? call.after))
        }
        var config = ConversationConfiguration(); config.pageLimit = 2
        let h = CoordinatorHarness.make(http: http, withSocket: false, configuration: config)
        h.coordinator.start()
        await eventually("all history", timeout: 20) { h.coordinator.items.count == total }
        XCTAssertEqual(http.reads.count, 226, "225 full pages plus the terminating empty page")
        XCTAssertEqual(h.coordinator.items.first?.id, MsgFixture.identity(1001))
    }

    func testMalformedPageIsRejectedWholeAndLeavesTheCursorAlone() async {
        let http = ScriptedHTTP()
        http.enqueueRead { _ in .success(ChatMessagePageDTO(messages: [MsgFixture.message(2), MsgFixture.message(1)], nextAfter: 1)) }
        let h = CoordinatorHarness.make(http: http, withSocket: false)
        h.coordinator.start()
        await eventually("offline") { h.coordinator.isOffline }
        XCTAssertTrue(h.coordinator.items.isEmpty)
        http.readReturning([m(1)])
        h.coordinator.retryConnection()
        await eventually("applied") { h.coordinator.items.count == 1 }
        XCTAssertEqual(http.reads.last?.after, 0)
    }

    // MARK: Reconnect

    func testSocketFailureReconnectsWithExponentialBackoffAndNeverTouchesIdentity() async {
        let h = CoordinatorHarness.make()
        await h.boot()
        var expected: [TimeInterval] = []
        for (i, delay) in [1.0, 2, 4, 8].enumerated() {
            h.socket.last!.fail(ConversationSocketFailure.closed(code: 1006))
            expected.append(delay)
            await eventually("backoff \(i)") { self.reconnectDelays(h) == expected }
            XCTAssertEqual(h.coordinator.connectionStatus, .disconnected)
            h.scheduler.advance(by: delay)
            await eventually("reconnect \(i)") { h.socket.connections.count == i + 2 }
        }
        XCTAssertEqual(h.authority.rejectedCount, 0)
        XCTAssertEqual(h.coordinator.phase, .active)
        XCTAssertEqual(h.http.opens, 1, "reconnect never reopens the conversation")
    }

    func testJitterIsBoundedAndTheDelayCapped() async {
        for (random, first) in [(0.0, 0.8), (1.0, 1.2)] {
            let h = CoordinatorHarness.make(random: { random })
            await h.boot()
            var seen = 0
            for i in 0..<9 {
                h.socket.last!.fail()
                seen += 1
                await eventually("delay \(i)") { self.reconnectDelays(h).count == seen }
                h.scheduler.advance(by: 60)
                await eventually("conn \(i)") { h.socket.connections.count == i + 2 }
            }
            let delays = reconnectDelays(h)
            XCTAssertEqual(delays[0], first, accuracy: 0.0001)
            XCTAssertTrue(delays.allSatisfy { $0 <= 60 && $0 >= 0.8 })
            if random == 1.0 { XCTAssertEqual(delays.last, 60) }
        }
    }

    func testBackoffResetsOnlyAfterAStableConnection() async {
        let h = CoordinatorHarness.make()
        await h.boot()
        for i in 0..<3 {
            h.socket.last!.fail()
            await eventually("fail \(i)") { self.reconnectDelays(h).count == i + 1 }
            h.scheduler.advance(by: 60)
            await eventually("conn \(i)") { h.socket.connections.count == i + 2 }
        }
        XCTAssertEqual(reconnectDelays(h), [1, 2, 4])
        h.socket.last!.push(FakeSocketConnection.subscribedFrame(CoordinatorHarness.ref))
        await eventually("live") { h.coordinator.connectionStatus == .live }
        h.scheduler.advance(by: 31)
        await settle()
        h.socket.last!.fail()
        await eventually("reset delay") { self.reconnectDelays(h).count == 4 }
        XCTAssertEqual(reconnectDelays(h).last, 1)
    }

    func testUpgradeAttemptsAreRateLimited() async {
        var config = ConversationConfiguration(); config.upgradesPerWindow = 2
        let h = CoordinatorHarness.make(configuration: config)
        await h.boot()
        h.socket.last!.fail()
        await eventually("d1") { self.reconnectDelays(h) == [1] }
        h.scheduler.advance(by: 1)
        await eventually("c2") { h.socket.connections.count == 2 }
        h.socket.last!.fail()
        await eventually("d2") { self.reconnectDelays(h) == [1, 2] }
        h.scheduler.advance(by: 2)
        await eventually("deferred") { self.reconnectDelays(h).count == 3 }
        XCTAssertEqual(h.socket.connections.count, 2, "third upgrade inside the window must wait")
        XCTAssertEqual(reconnectDelays(h).last ?? 0, 57, accuracy: 0.001)
        h.scheduler.advance(by: 57)
        await eventually("c3") { h.socket.connections.count == 3 }
    }

    func testPolicyRefusalCloseAsksHTTPAndDoesNotInvalidateIdentityOrClose() async {
        let h = CoordinatorHarness.make()
        await h.boot()
        let base = h.http.reads.count
        h.socket.last!.fail(ConversationSocketFailure.closed(code: 1008))
        await eventually("verification read") { h.http.reads.count == base + 1 }
        XCTAssertEqual(h.coordinator.phase, .active)
        XCTAssertEqual(h.authority.rejectedCount, 0)
        await eventually("reconnect scheduled") { self.reconnectDelays(h).count == 1 }
    }

    func testMalformedSocketFailureAndTimeoutAreOrdinaryDisconnects() async {
        let h = CoordinatorHarness.make()
        await h.boot()
        h.socket.last!.fail(ConversationSocketFailure.malformed)
        await eventually("d") { self.reconnectDelays(h).count == 1 }
        XCTAssertEqual(h.authority.rejectedCount, 0)
        XCTAssertEqual(h.coordinator.phase, .active)
        XCTAssertFalse(h.coordinator.isOffline)
    }

    // MARK: Foreground / background

    func testBackgroundCancelsAllWorkAndForegroundCatchesUpBeforeReconnecting() async {
        let http = ScriptedHTTP()
        let h = CoordinatorHarness.make(http: http)
        await h.boot()
        let first = h.socket.last!
        h.coordinator.sceneDidEnterBackground()
        await eventually("socket cancelled") { first.cancelCount >= 1 }
        XCTAssertEqual(h.scheduler.pendingSleeps, 0)
        XCTAssertEqual(h.coordinator.connectionStatus, .disconnected)
        let base = http.reads.count
        h.scheduler.advance(by: 300)
        first.push(FakeSocketConnection.changedFrame(CoordinatorHarness.ref))
        await settle()
        XCTAssertEqual(http.reads.count, base, "no background polling or hint handling")
        XCTAssertEqual(h.socket.connections.count, 1)

        let gate = Gate()
        http.enqueueRead { call in await gate.wait(); return .success(MsgFixture.page([MsgFixture.message(1)], after: call.after)) }
        h.coordinator.sceneDidBecomeActive()
        await eventually("catch-up first") { http.reads.count == base + 1 }
        await settle()
        XCTAssertEqual(h.socket.connections.count, 1, "socket waits for HTTP")
        gate.open()
        await eventually("reconnected") { h.socket.connections.count == 2 }
        XCTAssertEqual(h.coordinator.items.count, 1)
    }

    func testOpeningWhileBackgroundedDoesNotFetchOrConnectUntilForeground() async {
        let h = CoordinatorHarness.make()
        h.coordinator.start(isForeground: false)
        await eventually("active") { h.coordinator.phase == .active }
        await settle()
        XCTAssertTrue(h.http.reads.isEmpty)
        XCTAssertTrue(h.socket.connections.isEmpty)
        h.coordinator.sceneDidBecomeActive()
        await eventually("connected") { h.socket.connections.count == 1 }
        XCTAssertEqual(h.http.reads.count, 1)
    }

    func testRepeatedForegroundSignalsNeverCreateDuplicateSockets() async {
        let h = CoordinatorHarness.make()
        await h.boot()
        h.coordinator.sceneDidBecomeActive()
        h.coordinator.sceneDidBecomeActive()
        await settle()
        h.coordinator.sceneDidEnterBackground()
        h.coordinator.sceneDidBecomeActive()
        h.coordinator.sceneDidBecomeActive()
        await eventually("second") { h.socket.connections.count == 2 }
        await settle()
        XCTAssertEqual(h.socket.connections.count, 2)
        XCTAssertGreaterThanOrEqual(h.socket.connections[0].cancelCount, 1)
        XCTAssertEqual(h.socket.connections[1].cancelCount, 0)
    }

    func testStaleSocketCallbacksFromAnOldConnectionAreIgnored() async {
        let http = ScriptedHTTP()
        let h = CoordinatorHarness.make(http: http)
        await h.boot()
        let old = h.socket.last!
        h.coordinator.sceneDidEnterBackground()
        h.coordinator.sceneDidBecomeActive()
        await eventually("new") { h.socket.connections.count == 2 }
        await settle()
        let base = http.reads.count
        old.push(FakeSocketConnection.changedFrame(CoordinatorHarness.ref))
        old.fail()
        await settle()
        XCTAssertEqual(http.reads.count, base)
        XCTAssertEqual(h.socket.connections.count, 2)
        XCTAssertEqual(h.coordinator.phase, .active)
    }
}
