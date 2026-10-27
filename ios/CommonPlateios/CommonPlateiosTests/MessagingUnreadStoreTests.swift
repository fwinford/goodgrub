import Foundation
import XCTest
@testable import CommonPlateios

/// W4-MSG1 CP7-B: the in-memory unread projection, its stale-response fencing
/// and its invalidation. Scripted transport only; no live backend evidence.
@MainActor
final class MessagingUnreadStoreTests: XCTestCase {
    private nonisolated static let reqA = "64c0000000000000000000a1"
    private nonisolated static let reqB = "64c0000000000000000000a2"
    private nonisolated static let convA = "64c0000000000000000000c1"
    private nonisolated static let convB = "64c0000000000000000000c2"
    private var reqA: String { Self.reqA }
    private var reqB: String { Self.reqB }
    private var convA: String { Self.convA }
    private var convB: String { Self.convB }

    private nonisolated func summary(_ entries: [(String, String, Int)]) -> MessagingUnreadSummaryDTO {
        MessagingUnreadSummaryDTO(
            unreadCount: entries.reduce(0) { $0 + $1.2 },
            conversations: entries.map { ConversationUnreadEntryDTO(requestId: $0.0, conversationId: $0.1, unreadCount: $0.2) }
        )
    }

    private func make(_ http: ScriptedHTTP = ScriptedHTTP(), authority: MsgAuthorityBox? = nil) -> (MessagingUnreadStore, ScriptedHTTP, MsgAuthorityBox) {
        let authority = authority ?? MsgAuthorityBox()
        return (MessagingUnreadStore(http: http, authorityProvider: { authority.value }), http, authority)
    }

    private func fetch(_ store: MessagingUnreadStore, _ http: ScriptedHTTP, calls: Int) async {
        store.refresh()
        await eventually("unread call \(calls)") { http.unreadCalls.count >= calls }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    func testNothingFetchedIsUnknownNeverZero() {
        let (store, _, _) = make()
        XCTAssertEqual(store.state(forRequest: reqA), .unknown)
        XCTAssertNil(store.state(forRequest: reqA).displayableCount)
    }

    func testSuccessfulSummaryGivesExactCountAndCurrentZeroForAbsentRequest() async {
        let (store, http, _) = make()
        http.enqueueUnread { _ in .success(self.summary([(Self.reqA, Self.convA, 3)])) }
        await fetch(store, http, calls: 1)
        XCTAssertEqual(store.state(forRequest: reqA), .known(count: 3, isStale: false))
        XCTAssertEqual(store.state(forRequest: reqB), .known(count: 0, isStale: false))
    }

    func testMultipleConversationsForOneRequestIsUnknownNotChosen() async {
        let (store, http, _) = make()
        http.enqueueUnread { _ in .success(self.summary([(Self.reqA, Self.convA, 3), (Self.reqA, Self.convB, 5)])) }
        await fetch(store, http, calls: 1)
        XCTAssertEqual(store.state(forRequest: reqA), .unknown)
    }

    func testFailureRetainsLastKnownCountAsStaleAndNeverFabricatesZero() async {
        let (store, http, _) = make()
        http.enqueueUnread { _ in .success(self.summary([(Self.reqA, Self.convA, 4)])) }
        await fetch(store, http, calls: 1)
        for outcome in [ConversationHTTPOutcome<MessagingUnreadSummaryDTO>.unknown, .unavailable, .refused(.invalidMessage)] {
            http.enqueueUnread { _ in outcome }
            store.refresh()
            await eventually("failed fetch") { http.unreadCalls.count >= 2 }
            try? await Task.sleep(nanoseconds: 20_000_000)
            XCTAssertEqual(store.state(forRequest: reqA), .known(count: 4, isStale: true))
            XCTAssertNotNil(store.state(forRequest: reqA).displayableCount)
            // Absence is not zero on a stale snapshot.
            XCTAssertEqual(store.state(forRequest: reqB), .unknown)
            http.enqueueUnread { _ in .success(self.summary([(Self.reqA, Self.convA, 4)])) }
            await fetch(store, http, calls: http.unreadCalls.count + 1)
            XCTAssertEqual(store.state(forRequest: reqA), .known(count: 4, isStale: false))
        }
    }

    func testFailureBeforeAnySnapshotStaysUnknown() async {
        let (store, http, _) = make()
        http.enqueueUnread { _ in .unavailable }
        await fetch(store, http, calls: 1)
        XCTAssertEqual(store.state(forRequest: reqA), .unknown)
    }

    func testOutOfOrderResponsesNewerFetchWins() async {
        let (store, http, _) = make()
        let slow = Gate()
        http.enqueueUnread { _ in await slow.wait(); return .success(self.summary([(Self.reqA, Self.convA, 1)])) }
        http.enqueueUnread { _ in .success(self.summary([(Self.reqA, Self.convA, 9)])) }
        store.refresh()
        await eventually("first started") { http.unreadCalls.count == 1 }
        store.invalidate(requestId: reqB)          // distinct clock so a second fetch starts
        store.refresh()
        await eventually("second done") { store.state(forRequest: Self.reqA) == .known(count: 9, isStale: false) }
        slow.open()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.state(forRequest: reqA), .known(count: 9, isStale: false), "older response must not overwrite")
    }

    func testResponseStartedBeforeInvalidationCannotRepopulateThatRequest() async {
        let (store, http, _) = make()
        let gate = Gate()
        http.enqueueUnread { _ in await gate.wait(); return .success(self.summary([(Self.reqA, Self.convA, 5)])) }
        store.refresh()
        await eventually("started") { http.unreadCalls.count == 1 }
        store.invalidate(requestId: reqA)
        gate.open()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.state(forRequest: reqA), .unknown)
    }

    func testInvalidationIsUnknownNotZeroUntilFreshFetch() async {
        let (store, http, _) = make()
        http.enqueueUnread { _ in .success(self.summary([(Self.reqA, Self.convA, 2)])) }
        await fetch(store, http, calls: 1)
        store.conversationClosed(requestId: reqA)
        XCTAssertEqual(store.state(forRequest: reqA), .unknown)
        http.enqueueUnread { _ in .success(self.summary([])) }
        await fetch(store, http, calls: 2)
        XCTAssertEqual(store.state(forRequest: reqA), .known(count: 0, isStale: false))
    }

    func testClearAllDropsEverythingAndDiscardsInFlightResponse() async {
        let (store, http, _) = make()
        let gate = Gate()
        http.enqueueUnread { _ in await gate.wait(); return .success(self.summary([(Self.reqA, Self.convA, 5)])) }
        store.refresh()
        await eventually("started") { http.unreadCalls.count == 1 }
        store.clearAll()
        gate.open()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.state(forRequest: reqA), .unknown)
    }

    func testAuthorityRejectionClearsRetainedCounts() async {
        let (store, http, _) = make()
        http.enqueueUnread { _ in .success(self.summary([(Self.reqA, Self.convA, 2)])) }
        await fetch(store, http, calls: 1)
        http.enqueueUnread { _ in .identityInvalid }
        store.invalidate(requestId: reqB)
        await fetch(store, http, calls: 2)
        XCTAssertEqual(store.state(forRequest: reqA), .unknown)
        http.enqueueUnread { _ in .success(self.summary([(Self.reqA, Self.convA, 2)])) }
        http.enqueueUnread { _ in .authorityRequired }
        await fetch(store, http, calls: 3)
        store.invalidate(requestId: reqB)
        await fetch(store, http, calls: 4)
        XCTAssertEqual(store.state(forRequest: reqA), .unknown)
    }

    func testSignOutAndReplacementIdentityNeverSeeThePreviousHelpersCounts() async {
        let (store, http, authority) = make()
        http.enqueueUnread { _ in .success(self.summary([(Self.reqA, Self.convA, 6)])) }
        await fetch(store, http, calls: 1)
        authority.value = MsgFixture.otherAuthority
        XCTAssertEqual(store.state(forRequest: reqA), .unknown, "different participant sees nothing")
        store.authorityMayHaveChanged()
        authority.value = MsgFixture.authority
        XCTAssertEqual(store.state(forRequest: reqA), .unknown, "returning does not resurrect cleared data")
        authority.value = nil
        store.refresh()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(http.unreadCalls.count, 1, "no credential, no request")
        XCTAssertEqual(store.state(forRequest: reqA), .unknown)
    }

    func testObservedIdentitySwitchAndBackWithoutAnyHostHookDoesNotResurrectCounts() async {
        let (store, http, authority) = make()
        http.enqueueUnread { _ in .success(self.summary([(Self.reqA, Self.convA, 6)])) }
        await fetch(store, http, calls: 1)
        XCTAssertEqual(store.state(forRequest: reqA), .known(count: 6, isStale: false))
        authority.value = MsgFixture.otherAuthority
        XCTAssertEqual(store.state(forRequest: reqA), .unknown)      // observed as the other participant
        authority.value = MsgFixture.authority
        XCTAssertEqual(store.state(forRequest: reqA), .unknown, "sticky until a fresh authoritative fetch")
        http.enqueueUnread { _ in .success(self.summary([(Self.reqA, Self.convA, 6)])) }
        await fetch(store, http, calls: 2)
        XCTAssertEqual(store.state(forRequest: reqA), .known(count: 6, isStale: false))
    }

    func testResponseForPreviousIdentityCannotRepopulateAfterSwitch() async {
        let (store, http, authority) = make()
        let gate = Gate()
        http.enqueueUnread { _ in await gate.wait(); return .success(self.summary([(Self.reqA, Self.convA, 8)])) }
        store.refresh()
        await eventually("started") { http.unreadCalls.count == 1 }
        authority.value = MsgFixture.otherAuthority
        store.authorityMayHaveChanged()
        gate.open()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.state(forRequest: reqA), .unknown)
    }

    func testRefreshSendsOnlyTheCredentialAsAuthorityNeverPollsAndDedupesInFlight() async {
        let (store, http, _) = make()
        let gate = Gate()
        http.enqueueUnread { _ in await gate.wait(); return .success(MessagingUnreadSummaryDTO(unreadCount: 0, conversations: [])) }
        store.refresh()
        await eventually("started") { http.unreadCalls.count == 1 }
        store.refresh()
        store.refresh()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(http.unreadCalls, [MsgFixture.authority], "identical in-flight fetch is not repeated")
        gate.open()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(http.unreadCalls.count, 1, "no timer-driven refresh")
    }

    func testLookupIsReadOnlyAndDisplayCapAndLabels() {
        XCTAssertNil(ConversationUnreadPresentation.badgeText(for: nil))
        XCTAssertNil(ConversationUnreadPresentation.badgeText(for: 0))
        XCTAssertEqual(ConversationUnreadPresentation.badgeText(for: 1), "1")
        XCTAssertEqual(ConversationUnreadPresentation.badgeText(for: 99), "99")
        XCTAssertEqual(ConversationUnreadPresentation.badgeText(for: 100), "99+")
        XCTAssertEqual(ConversationUnreadPresentation.badgeText(for: 5_000), "99+")
        XCTAssertEqual(ConversationUnreadPresentation.accessibilityLabel(for: 1), "1 unread message")
        XCTAssertEqual(ConversationUnreadPresentation.accessibilityLabel(for: 7), "7 unread messages")
        XCTAssertEqual(ConversationUnreadPresentation.accessibilityLabel(for: 250), "More than 99 unread messages")
        XCTAssertNil(ConversationUnreadPresentation.accessibilityLabel(for: nil))
        XCTAssertNil(RequestUnreadState.unknown.displayableCount)
        XCTAssertNil(RequestUnreadState.known(count: 0, isStale: false).displayableCount, "zero hides the capsule")
        XCTAssertEqual(RequestUnreadState.known(count: 2, isStale: true).displayableCount, 2)
    }
}
