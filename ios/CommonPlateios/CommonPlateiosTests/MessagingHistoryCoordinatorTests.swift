import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class MessagingHistoryCoordinatorTests: XCTestCase {
    private func historyHTTP(_ total: Int) -> ScriptedHTTP {
        let http = ScriptedHTTP()
        http.defaultHistory = { call in
            .success(MsgFixture.historyPage(total: total, before: call.before, limit: call.limit))
        }
        return http
    }

    private func ready(_ h: CoordinatorHarness) async {
        h.coordinator.start()
        await eventually("latest initialized and forward caught up") {
            h.coordinator.hasLoaded && !h.http.reads.isEmpty
        }
        await settle()
    }

    func testOpensLatestFiftyThenForwardFromOpeningSnapshotWithoutPrefetch() async {
        let http = historyHTTP(151)
        let h = CoordinatorHarness.make(http: http, withSocket: false)
        await ready(h)
        XCTAssertEqual(h.coordinator.items.map(\.id), (102...151).map { MsgFixture.identity(1000 + $0) })
        XCTAssertEqual(http.history.count, 1)
        XCTAssertNil(http.history[0].before)
        XCTAssertEqual(http.history[0].limit, 50)
        XCTAssertEqual(http.reads.map(\.after), [151])
        XCTAssertTrue(h.coordinator.hasOlder)
    }

    func testEmptyAndShortOpeningConversation() async {
        for count in [0, 1, 5, 49, 50] {
            let http = historyHTTP(count)
            let h = CoordinatorHarness.make(http: http, withSocket: false)
            await ready(h)
            XCTAssertEqual(h.coordinator.items.count, count)
            XCTAssertFalse(h.coordinator.hasOlder)
            for _ in 0..<10 { h.coordinator.loadOlderMessages() }
            await settle()
            XCTAssertEqual(http.history.count, 1)
            XCTAssertEqual(http.reads.first?.after, count)
        }
    }

    func testMultipleOlderPagesStopAtFalseWithNonNullBound() async {
        let http = historyHTTP(151)
        let h = CoordinatorHarness.make(http: http, withSocket: false)
        await ready(h)
        for expected in [100, 150, 151] {
            h.coordinator.loadOlderMessages()
            await eventually("older \(expected)") { h.coordinator.items.count == expected }
        }
        XCTAssertEqual(http.history.map(\.before), [nil, 102, 52, 2])
        XCTAssertFalse(h.coordinator.hasOlder)
        for _ in 0..<10 { h.coordinator.loadOlderMessages() }
        await settle()
        XCTAssertEqual(http.history.count, 4)
        XCTAssertEqual(h.coordinator.items.map(\.id), (1...151).map { MsgFixture.identity(1000 + $0) })
    }

    func testOpeningFailureRetriesLatestWithoutResolvingAgainOrWalkingForward() async {
        let http = historyHTTP(101)
        http.enqueueHistory { _ in .unknown }
        let h = CoordinatorHarness.make(http: http, withSocket: false)
        h.coordinator.start()
        await eventually("opening page failed") { h.coordinator.historyFailed }
        XCTAssertFalse(h.coordinator.hasLoaded)
        XCTAssertTrue(http.reads.isEmpty)
        XCTAssertTrue(h.socket.connections.isEmpty)
        h.coordinator.retryHistory()
        await eventually("retry applied") { h.coordinator.hasLoaded && !http.reads.isEmpty }
        XCTAssertEqual(http.opens, 1)
        XCTAssertEqual(http.history.map(\.before), [nil, nil])
        XCTAssertEqual(http.reads.first?.after, 101)
    }

    func testNoForwardRequestOrSocketCanRaceAheadOfGatedLatest() async {
        let http = historyHTTP(51)
        let gate = Gate()
        http.enqueueHistory { _ in await gate.wait(); return .success(MsgFixture.historyPage(total: 51)) }
        let h = CoordinatorHarness.make(http: http)
        h.coordinator.start()
        await eventually("latest gated") { http.history.count == 1 }
        h.coordinator.retryConnection()
        h.coordinator.sceneDidBecomeActive()
        h.scheduler.advance(by: 300)
        for _ in 0..<10 { h.coordinator.loadOlderMessages() }
        await settle()
        XCTAssertEqual(http.history.count, 1)
        XCTAssertTrue(http.reads.isEmpty)
        XCTAssertFalse(h.coordinator.hasLoaded)
        XCTAssertTrue(h.socket.connections.isEmpty)
        gate.open()
        await eventually("caught up then connected") { h.socket.connections.count == 1 }
        XCTAssertEqual(http.reads.first?.after, 51)
    }

    func testRepeatedTopCallbacksCoalesceAndDoNotDrainHistory() async {
        let http = historyHTTP(151)
        let h = CoordinatorHarness.make(http: http, withSocket: false)
        await ready(h)
        let gate = Gate()
        http.enqueueHistory { call in
            await gate.wait()
            return .success(MsgFixture.historyPage(total: 151, before: call.before))
        }
        for _ in 0..<30 { h.coordinator.loadOlderMessages() }
        await eventually("one older fetch") { http.history.count == 2 }
        XCTAssertTrue(h.coordinator.isLoadingHistory)
        gate.open()
        await eventually("applied") { h.coordinator.items.count == 100 }
        await settle()
        XCTAssertEqual(http.history.count, 2)
    }

    func testOlderFailureAndRetryKeepBoundAndDoNotStallForwardOrResend() async {
        let http = historyHTTP(51)
        let h = CoordinatorHarness.make(http: http, withSocket: false)
        await ready(h)
        h.coordinator.draft = "failed payload"
        h.coordinator.sendDraft()
        await eventually("failed local") { h.coordinator.outstandingLocalCount == 1 && !http.reconciles.isEmpty }
        http.enqueueHistory { _ in .unknown }
        h.coordinator.loadOlderMessages()
        await eventually("failed history") { h.coordinator.historyFailed }
        http.readReturning([MsgFixture.message(52)])
        h.scheduler.advance(by: 30)
        await eventually("forward still works") { h.coordinator.items.contains { $0.id == MsgFixture.identity(1052) } }
        for _ in 0..<10 { h.coordinator.loadOlderMessages() }
        await settle()
        XCTAssertEqual(http.history.count, 2, "failure requires manual Retry")
        h.coordinator.retryHistory()
        await eventually("history recovered") { !h.coordinator.hasOlder }
        XCTAssertEqual(http.history.map(\.before), [nil, 2, 2])
        XCTAssertEqual(http.sends.count, 1)
        XCTAssertEqual(h.coordinator.outstandingLocalCount, 1)
        XCTAssertEqual(http.reads.last?.after, 51)
    }

    func testOlderHeadNeverSkipsNewCommitsInEitherCompletionOrder() async {
        for olderFirst in [false, true] {
            let http = historyHTTP(51)
            let h = CoordinatorHarness.make(http: http)
            await h.boot()
            let olderGate = Gate(), forwardGate = Gate()
            http.enqueueHistory { call in
                await olderGate.wait()
                return .success(MsgFixture.historyPage(total: 101, before: call.before))
            }
            http.enqueueRead { call in
                await forwardGate.wait()
                return .success(MsgFixture.page([MsgFixture.message(52)], after: call.after))
            }
            h.coordinator.loadOlderMessages()
            h.socket.last!.push(FakeSocketConnection.changedFrame(CoordinatorHarness.ref))
            await eventually("both gated") { http.history.count == 2 && http.reads.count == 3 }
            if olderFirst { olderGate.open() } else { forwardGate.open() }
            await settle()
            if olderFirst { forwardGate.open() } else { olderGate.open() }
            await eventually("union applied") { h.coordinator.items.count == 52 }
            XCTAssertEqual(http.reads.last?.after, 51)
            h.socket.last!.push(FakeSocketConnection.changedFrame(CoordinatorHarness.ref))
            await eventually("forward stays contiguous") { http.reads.last?.after == 52 }
            XCTAssertEqual(Set(h.coordinator.items.map(\.id)).count, 52)
        }
    }

    func testSendDuringLatestIsRecoveredExactlyOnceInEitherCompletionOrder() async {
        for latestFirst in [false, true] {
            let http = ScriptedHTTP()
            let latestGate = Gate(), sendGate = Gate()
            let message = MsgFixture.message(1, sender: .own, text: "hello", identity: 1)
            http.enqueueHistory { _ in await latestGate.wait(); return .success(MsgFixture.history([message])) }
            http.enqueueSend { _ in await sendGate.wait(); return .success(message) }
            let h = CoordinatorHarness.make(http: http, withSocket: false)
            h.coordinator.start()
            await eventually("latest pending") { http.history.count == 1 }
            h.coordinator.draft = "hello"
            h.coordinator.sendDraft()
            await eventually("send pending") { http.sends.count == 1 }
            if latestFirst { latestGate.open() } else { sendGate.open() }
            await settle()
            if latestFirst { sendGate.open() } else { latestGate.open() }
            await eventually("single committed row") { h.coordinator.hasLoaded && h.coordinator.outstandingLocalCount == 0 }
            XCTAssertEqual(h.coordinator.items, [.message(message)])
            XCTAssertEqual(http.sends.count, 1)
            XCTAssertEqual(http.reads.first?.after, 1)
        }
    }

    func testPOSTAndExactReconcileOverlapOlderAndForwardWithoutDuplicates() async {
        for historyFirst in [false, true] {
            for exact in [false, true] {
                let http = historyHTTP(51)
                let h = CoordinatorHarness.make(http: http)
                await h.boot()
                let olderGate = Gate(), sendGate = Gate()
                let message = MsgFixture.message(52, sender: .own, text: "hello", identity: 1)
                http.enqueueHistory { call in
                    await olderGate.wait()
                    return .success(MsgFixture.historyPage(total: 52, before: call.before))
                }
                http.enqueueSend { _ in
                    await sendGate.wait()
                    return exact ? .unknown : .success(message)
                }
                http.enqueueReconcile { _ in .success(message) }
                http.readReturning([message])
                h.coordinator.loadOlderMessages()
                h.coordinator.draft = "hello"
                h.coordinator.sendDraft()
                await eventually("both requests") { http.history.count == 2 && http.sends.count == 1 }
                if historyFirst { olderGate.open() } else { sendGate.open() }
                await settle()
                h.socket.last!.push(FakeSocketConnection.changedFrame(CoordinatorHarness.ref))
                await eventually("forward applied") { http.reads.last?.after == 51 && h.coordinator.items.contains(.message(message)) }
                if historyFirst { sendGate.open() } else { olderGate.open() }
                await eventually("complete union") { h.coordinator.items.count == 52 && h.coordinator.outstandingLocalCount == 0 }
                XCTAssertEqual(Set(h.coordinator.items.map(\.id)).count, 52)
                XCTAssertEqual(http.sends.count, 1)
            }
        }
    }

    func testInvalidPageIsVisibleRetryableAndCannotMoveTheOlderBound() async {
        let http = historyHTTP(51)
        let h = CoordinatorHarness.make(http: http, withSocket: false)
        await ready(h)
        http.enqueueHistory { _ in .success(MsgFixture.history([MsgFixture.message(2)], hasOlder: true, head: 51)) }
        h.coordinator.loadOlderMessages()
        await eventually("invalid page rejected") { h.coordinator.historyFailed }
        XCTAssertEqual(h.coordinator.items.count, 50)
        h.coordinator.retryHistory()
        await eventually("retry complete") { h.coordinator.items.count == 51 }
        XCTAssertEqual(http.history.map(\.before), [nil, 2, 2])
    }

    func testForwardFailurePreservesHistoryAndSocketReconnectNeverReseedsIt() async {
        let http = historyHTTP(101)
        let h = CoordinatorHarness.make(http: http)
        await h.boot()
        h.coordinator.loadOlderMessages()
        await eventually("older applied") { h.coordinator.items.count == 100 }
        http.enqueueRead { _ in .unknown }
        h.socket.last!.push(FakeSocketConnection.changedFrame(CoordinatorHarness.ref))
        await eventually("forward failed") { h.coordinator.isOffline }
        XCTAssertEqual(h.coordinator.items.count, 100)
        XCTAssertTrue(h.coordinator.hasOlder)
        h.socket.last!.fail()
        await eventually("reconnect scheduled") { h.scheduler.sleepRequests.contains { $0 < 30 } }
        h.scheduler.advance(by: 2)
        await eventually("reconnected") { h.socket.connections.count == 2 }
        h.socket.last!.push(FakeSocketConnection.subscribedFrame(CoordinatorHarness.ref))
        await eventually("ack catchup") { !h.coordinator.isOffline }
        XCTAssertEqual(http.history.count, 2)
        XCTAssertEqual(http.reads.last?.after, 101)
        h.coordinator.loadOlderMessages()
        await eventually("last older page") { h.coordinator.items.count == 101 }
        XCTAssertEqual(http.history.last?.before, 2)
    }
}
