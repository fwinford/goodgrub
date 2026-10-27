import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class MessagingHistoryMemoryTests: XCTestCase {
    func testRetainsEveryRequestedUniqueMessageBeyondEstimateWithoutPrefetchOrEviction() async {
        let http = ScriptedHTTP()
        http.defaultHistory = { call in .success(MsgFixture.historyPage(total: 251, before: call.before)) }
        let h = CoordinatorHarness.make(http: http, withSocket: false)
        h.coordinator.start()
        await eventually("opening page only") { h.coordinator.hasLoaded }
        await settle()
        XCTAssertEqual(http.history.count, 1)
        XCTAssertEqual(h.coordinator.items.count, 50)
        for expected in [100, 150, 200, 250, 251] {
            h.coordinator.loadOlderMessages()
            await eventually("retained \(expected)") { h.coordinator.items.count == expected }
        }
        for _ in 0..<20 {
            h.coordinator.loadOlderMessages()
            h.coordinator.retryConnection()
        }
        await settle()
        XCTAssertEqual(h.coordinator.items.count, 251)
        XCTAssertEqual(http.history.count, 6)
        XCTAssertEqual(Set(h.coordinator.items.map(\.id)).count, 251)
    }

    func testAllTenUnresolvedPayloadsAndDraftSurviveHistoryAndForward() async {
        let http = ScriptedHTTP()
        http.defaultHistory = { call in .success(MsgFixture.historyPage(total: 101, before: call.before)) }
        let h = CoordinatorHarness.make(http: http, withSocket: false)
        h.coordinator.start()
        await eventually("latest") { h.coordinator.hasLoaded }
        for i in 1...10 {
            h.coordinator.draft = "payload \(i)"
            h.coordinator.sendDraft()
        }
        await eventually("all sends attempted") { http.sends.count == 10 && http.reconciles.count == 10 }
        h.coordinator.draft = "preserved draft"
        h.coordinator.loadOlderMessages()
        await eventually("older") { h.coordinator.items.count == 110 }
        http.readReturning([MsgFixture.message(102)])
        h.coordinator.retryConnection()
        await eventually("forward") { h.coordinator.items.count == 111 }
        XCTAssertEqual(h.coordinator.outstandingLocalCount, 10)
        XCTAssertEqual(h.coordinator.draft, "preserved draft")
        XCTAssertFalse(h.coordinator.canSend)
        XCTAssertEqual(http.sends.count, 10)
        let locals = h.coordinator.items.compactMap { if case .local(let local) = $0 { return local } else { return nil } }
        XCTAssertEqual(locals.map(\.text), (1...10).map { "payload \($0)" })
    }

    func testReleaseDuringLatestOrOlderDeallocatesAndCancelsNoncooperativeRequest() async {
        for older in [false, true] {
            let http = ScriptedHTTP()
            http.defaultHistory = { call in .success(MsgFixture.historyPage(total: 51, before: call.before)) }
            var h: CoordinatorHarness? = CoordinatorHarness.make(http: http, withSocket: false)
            if older {
                h!.coordinator.start()
                await eventually("latest") { h!.coordinator.hasLoaded }
            }
            let gate = Gate(), probe = HistoryCancellationProbe()
            http.enqueueHistory { call in
                await withTaskCancellationHandler {
                    await gate.wait()
                    return .success(MsgFixture.historyPage(total: 51, before: call.before))
                } onCancel: { probe.record() }
            }
            if older { h!.coordinator.loadOlderMessages() } else { h!.coordinator.start() }
            await eventually("gated") { http.history.count == (older ? 2 : 1) }
            weak var coordinator = h!.coordinator
            h = nil
            await eventually("deallocated") { coordinator == nil }
            await eventually("cancelled") { probe.cancelled }
            gate.open()
            await settle()
            XCTAssertEqual(http.history.count, older ? 2 : 1)
        }
    }
}
