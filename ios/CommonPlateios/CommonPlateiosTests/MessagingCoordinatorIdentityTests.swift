import Foundation
import XCTest
@testable import CommonPlateios

/// W4-MSG1 CP3: identity fencing, helper replacement, authoritative closure and
/// stale asynchronous result suppression.
@MainActor
final class MessagingCoordinatorIdentityTests: XCTestCase {
    private func m(_ seq: Int) -> ChatMessage { MsgFixture.message(seq) }

    func testCredentialReplacementEndsAndPurgesWithoutSignallingRevocation() async {
        let http = ScriptedHTTP()
        http.readReturning([m(1)])
        let h = CoordinatorHarness.make(http: http)
        await h.boot()
        let socket = h.socket.last!
        h.coordinator.draft = "unsent draft"
        h.authority.value = MsgFixture.otherAuthority
        h.coordinator.identityDidChange()
        XCTAssertEqual(h.coordinator.phase, .ended)
        XCTAssertTrue(h.coordinator.items.isEmpty)
        XCTAssertEqual(h.coordinator.draft, "")
        XCTAssertGreaterThanOrEqual(socket.cancelCount, 1)
        XCTAssertEqual(h.authority.rejectedCount, 0)
        XCTAssertEqual(h.scheduler.pendingSleeps, 0)
    }

    func testCredentialRemovalEndsAtTheNextEntryPointEvenWithoutAHostCall() async {
        let h = CoordinatorHarness.make()
        await h.boot()
        h.authority.value = nil
        h.coordinator.sceneDidBecomeActive()
        XCTAssertEqual(h.coordinator.phase, .ended)
        XCTAssertTrue(h.coordinator.items.isEmpty)
    }

    func testStaleHTTPResponseAfterIdentityChangeCannotPopulateOrContinue() async {
        let http = ScriptedHTTP()
        let gate = Gate()
        http.enqueueRead { call in await gate.wait(); return .success(MsgFixture.page([MsgFixture.message(1)], after: call.after)) }
        let h = CoordinatorHarness.make(http: http)
        h.coordinator.start()
        await eventually("gated read") { http.reads.count == 1 }
        h.authority.value = MsgFixture.otherAuthority
        h.coordinator.identityDidChange()
        gate.open()
        await settle()
        XCTAssertTrue(h.coordinator.items.isEmpty)
        XCTAssertEqual(h.coordinator.phase, .ended)
        XCTAssertTrue(h.socket.connections.isEmpty, "stale catch-up must not start a socket")
        XCTAssertEqual(http.reads.count, 1)
    }

    func testStaleSocketHintsAfterIdentityChangeAreDropped() async {
        let http = ScriptedHTTP()
        let h = CoordinatorHarness.make(http: http)
        await h.boot()
        let old = h.socket.last!
        let base = http.reads.count
        h.authority.value = MsgFixture.otherAuthority
        h.coordinator.identityDidChange()
        old.push(FakeSocketConnection.changedFrame(CoordinatorHarness.ref))
        await settle()
        XCTAssertEqual(http.reads.count, base)
        XCTAssertEqual(h.socket.connections.count, 1)
    }

    func testReplacementHelperGetsAFreshConversationAndNeverSeesTheOldTranscript() async {
        let http = ScriptedHTTP()
        http.readReturning([m(1), m(2)])
        let old = CoordinatorHarness.make(http: http)
        await old.boot()
        XCTAssertEqual(old.coordinator.items.count, 2)

        let newHTTP = ScriptedHTTP()
        newHTTP.defaultConversationId = MsgFixture.otherConversationId
        let replacement = CoordinatorHarness.make(http: newHTTP, authority: MsgAuthorityBox(MsgFixture.otherAuthority))
        old.authority.value = MsgFixture.otherAuthority
        old.coordinator.identityDidChange()
        await replacement.boot()

        XCTAssertTrue(replacement.coordinator.items.isEmpty)
        XCTAssertTrue(old.coordinator.items.isEmpty)
        XCTAssertEqual(newHTTP.reads.first?.conversationId, MsgFixture.otherConversationId)
        XCTAssertEqual(newHTTP.reads.first?.authority, MsgFixture.otherAuthority)
        XCTAssertEqual(newHTTP.reads.first?.after, 0, "a new conversation starts from cursor 0")
    }

    // MARK: Authoritative closure

    func testConversationUnavailableOnReadClosesPurgesAndStopsAllWork() async {
        let http = ScriptedHTTP()
        http.readReturning([m(1)])
        let h = CoordinatorHarness.make(http: http)
        await h.boot()
        XCTAssertEqual(h.coordinator.items.count, 1)
        let socket = h.socket.last!
        http.enqueueRead { _ in .unavailable }
        socket.push(FakeSocketConnection.changedFrame(CoordinatorHarness.ref))
        await eventually("closed") { h.coordinator.phase == .unavailable }
        XCTAssertTrue(h.coordinator.items.isEmpty)
        XCTAssertGreaterThanOrEqual(socket.cancelCount, 1)
        XCTAssertEqual(h.scheduler.pendingSleeps, 0)
        XCTAssertEqual(h.authority.rejectedCount, 0)
    }

    func testClosedConversationNeverResurrects() async {
        let http = ScriptedHTTP()
        let h = CoordinatorHarness.make(http: http)
        await h.boot()
        http.enqueueRead { _ in .unavailable }
        h.socket.last!.push(FakeSocketConnection.changedFrame(CoordinatorHarness.ref))
        await eventually("closed") { h.coordinator.phase == .unavailable }
        let reads = http.reads.count, opens = http.opens, sockets = h.socket.connections.count
        http.readReturning([m(9)])                      // even if the server later "recovers" (unblock)
        h.coordinator.sceneDidBecomeActive()
        h.coordinator.retryConnection()
        h.coordinator.start()
        h.scheduler.advance(by: 600)
        h.coordinator.draft = "hello"
        h.coordinator.sendDraft()
        await settle()
        XCTAssertEqual(h.coordinator.phase, .unavailable)
        XCTAssertEqual(http.reads.count, reads)
        XCTAssertEqual(http.opens, opens)
        XCTAssertEqual(h.socket.connections.count, sockets)
        XCTAssertTrue(http.sends.isEmpty)
        XCTAssertTrue(h.coordinator.items.isEmpty)
    }

    func testLateResultFromAFetchStartedBeforeClosureCannotRestoreTheTranscript() async {
        let http = ScriptedHTTP()
        let h = CoordinatorHarness.make(http: http)
        await h.boot()
        let gate = Gate()
        http.enqueueRead { call in await gate.wait(); return .success(MsgFixture.page([MsgFixture.message(1)], after: call.after)) }
        h.socket.last!.push(FakeSocketConnection.changedFrame(CoordinatorHarness.ref))
        await eventually("gated") { http.reads.count == 3 }
        h.coordinator.dismiss()
        gate.open()
        await settle()
        XCTAssertTrue(h.coordinator.items.isEmpty)
        XCTAssertEqual(h.coordinator.phase, .ended)
    }

    func testOpenUnavailableIsClosureAndOpenUnknownIsRetryable() async {
        let http = ScriptedHTTP()
        http.enqueueOpen { .unavailable }
        let a = CoordinatorHarness.make(http: http)
        a.coordinator.start()
        await eventually("closed") { a.coordinator.phase == .unavailable }

        let http2 = ScriptedHTTP()
        http2.enqueueOpen { .unknown }
        let b = CoordinatorHarness.make(http: http2, withSocket: false)
        b.coordinator.start()
        await eventually("failed") { b.coordinator.phase == .openFailed }
        XCTAssertEqual(b.authority.rejectedCount, 0)
        b.coordinator.retryConnection()
        await eventually("active") { b.coordinator.phase == .active }
        XCTAssertEqual(http2.opens, 2)
    }

    func testMissingCredentialSendsNothingAndIsTerminal() async {
        let h = CoordinatorHarness.make(authority: MsgAuthorityBox(nil))
        h.coordinator.start()
        await settle()
        XCTAssertEqual(h.coordinator.phase, .authorityRequired)
        XCTAssertEqual(h.http.opens, 0)
        XCTAssertTrue(h.socket.connections.isEmpty)
    }

    // MARK: Error classification at the coordinator

    func testOnlyAuthorityInvalidReachesTheRejectionClosureAndOnlyForTheSameCredential() async {
        let http = ScriptedHTTP()
        let h = CoordinatorHarness.make(http: http)
        await h.boot()
        http.enqueueRead { _ in .identityInvalid }
        h.socket.last!.push(FakeSocketConnection.changedFrame(CoordinatorHarness.ref))
        await eventually("rejected") { h.authority.rejectedCount == 1 }
        XCTAssertEqual(h.coordinator.phase, .ended)
        XCTAssertTrue(h.coordinator.items.isEmpty)

        // The credential was already replaced when the stale rejection arrives: not forwarded.
        let http2 = ScriptedHTTP()
        let gate = Gate()
        http2.enqueueRead { _ in await gate.wait(); return .identityInvalid }
        let g = CoordinatorHarness.make(http: http2)
        g.coordinator.start()
        await eventually("gated") { http2.reads.count == 1 }
        g.authority.value = MsgFixture.otherAuthority
        gate.open()
        await settle()
        XCTAssertEqual(g.authority.rejectedCount, 0)
        XCTAssertEqual(g.coordinator.phase, .ended)
    }

    func testServiceUnavailableTransportAndOrdinarySocketErrorsPreserveIdentityAndTranscript() async {
        let http = ScriptedHTTP()
        http.readReturning([m(1)])
        let h = CoordinatorHarness.make(http: http)
        await h.boot()
        http.enqueueRead { _ in .unknown }
        h.socket.last!.push(FakeSocketConnection.changedFrame(CoordinatorHarness.ref))
        await eventually("offline") { h.coordinator.isOffline }
        h.socket.last!.fail(URLError(.timedOut))
        await settle()
        XCTAssertEqual(h.authority.rejectedCount, 0)
        XCTAssertEqual(h.coordinator.phase, .active)
        XCTAssertEqual(h.coordinator.items.count, 1, "transient failures never purge")
    }

    func testDismissPurgesCancelsAndIgnoresLateWork() async {
        let h = CoordinatorHarness.make()
        await h.boot()
        let socket = h.socket.last!
        h.coordinator.dismiss()
        h.coordinator.dismiss()
        XCTAssertEqual(h.coordinator.phase, .ended)
        XCTAssertGreaterThanOrEqual(socket.cancelCount, 1)
        XCTAssertEqual(h.scheduler.pendingSleeps, 0)
        let base = h.http.reads.count
        socket.push(FakeSocketConnection.changedFrame(CoordinatorHarness.ref))
        h.coordinator.sceneDidBecomeActive()
        await settle()
        XCTAssertEqual(h.http.reads.count, base)
    }
}
