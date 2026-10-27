import Foundation
import XCTest
@testable import CommonPlateios

/// W4-MSG1 CP3 (F3): releasing a coordinator cancels or settles everything it
/// owns. The coordinator is observed only through a weak reference.
@MainActor
final class MessagingCoordinatorLifetimeTests: XCTestCase {
    private func m(_ seq: Int) -> ChatMessage { MsgFixture.message(seq) }

    func testReleasingALiveCoordinatorCancelsPeriodicSleepAndSocket() async {
        var h: CoordinatorHarness? = CoordinatorHarness.make()
        await h!.boot()
        let scheduler = h!.scheduler
        let socket = h!.socket.last!
        XCTAssertGreaterThanOrEqual(scheduler.pendingSleeps, 1, "periodic sleep is pending")
        weak var weakCoordinator = h!.coordinator
        h = nil
        await eventually("deallocated") { weakCoordinator == nil }
        await eventually("sleeps cancelled") { scheduler.pendingSleeps == 0 }
        await eventually("socket cancelled") { socket.cancelCount >= 1 }
    }

    func testReleasingDuringAReconnectSleepCancelsItAndNeverReconnects() async {
        var h: CoordinatorHarness? = CoordinatorHarness.make()
        await h!.boot()
        let scheduler = h!.scheduler
        let transport = h!.socket
        h!.socket.last!.fail()
        await eventually("reconnect sleep") { scheduler.sleepRequests.contains { $0 < 30 } }
        weak var weakCoordinator = h!.coordinator
        h = nil
        await eventually("deallocated") { weakCoordinator == nil }
        await eventually("sleeps cancelled") { scheduler.pendingSleeps == 0 }
        scheduler.advance(by: 600)
        await settle()
        XCTAssertEqual(transport.connections.count, 1, "no reconnect after release")
    }

    func testReleasingDuringAGatedFetchDeallocatesImmediatelyAndTheLateResultIsDiscarded() async {
        let http = ScriptedHTTP()
        let gate = Gate()
        http.enqueueRead { call in await gate.wait(); return .success(MsgFixture.page([MsgFixture.message(1)], after: call.after)) }
        var h: CoordinatorHarness? = CoordinatorHarness.make(http: http)
        h!.coordinator.start()
        await eventually("gated read") { http.reads.count == 1 }
        let transport = h!.socket
        weak var weakCoordinator = h!.coordinator
        h = nil
        await eventually("deallocated while the fetch is still suspended") { weakCoordinator == nil }
        gate.open()
        await settle()
        XCTAssertEqual(http.reads.count, 1, "no further pages after release")
        XCTAssertTrue(transport.connections.isEmpty, "the late result must not start a socket")
    }

    func testReleasingDuringAMultiPageCatchUpStopsPaging() async {
        let http = ScriptedHTTP()
        let gate = Gate()
        http.enqueueRead { call in .success(MsgFixture.page([MsgFixture.message(1), MsgFixture.message(2)], after: call.after)) }
        http.enqueueRead { call in await gate.wait(); return .success(MsgFixture.page([MsgFixture.message(3)], after: call.after)) }
        var config = ConversationConfiguration(); config.pageLimit = 2
        var h: CoordinatorHarness? = CoordinatorHarness.make(http: http, configuration: config)
        h!.coordinator.start()
        await eventually("second page gated") { http.reads.count == 2 }
        weak var weakCoordinator = h!.coordinator
        h = nil
        await eventually("deallocated") { weakCoordinator == nil }
        gate.open()
        await settle()
        XCTAssertEqual(http.reads.count, 2)
    }

    func testReleasingDuringOpenCancelsTheOpen() async {
        let http = ScriptedHTTP()
        let gate = Gate()
        http.enqueueOpen { await gate.wait(); return .unknown }
        var h: CoordinatorHarness? = CoordinatorHarness.make(http: http)
        h!.coordinator.start()
        await eventually("open") { http.opens == 1 }
        weak var weakCoordinator = h!.coordinator
        h = nil
        await eventually("deallocated") { weakCoordinator == nil }
        gate.open()
        await settle()
        XCTAssertEqual(http.reads.count, 0)
    }

    func testReleaseDoesNotCancelOrResendAnInFlightSend() async {
        let http = ScriptedHTTP()
        let gate = Gate()
        http.enqueueSend { _ in await gate.wait(); return .success(MsgFixture.message(1, sender: .own, identity: 1)) }
        var h: CoordinatorHarness? = CoordinatorHarness.make(http: http)
        await h!.boot()
        h!.coordinator.draft = "uncertain"
        h!.coordinator.sendDraft()
        await eventually("in flight") { http.sends.count == 1 }
        weak var weakCoordinator = h!.coordinator
        h = nil
        await eventually("deallocated") { weakCoordinator == nil }
        gate.open()
        await settle()
        XCTAssertEqual(http.sends.count, 1, "never resent")
        XCTAssertTrue(http.reconciles.isEmpty, "nothing left to reconcile into")
    }
}
