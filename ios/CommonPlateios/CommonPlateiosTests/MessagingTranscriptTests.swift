import Foundation
import XCTest
@testable import CommonPlateios

/// W4-MSG1 CP3: paging, deduplication and cursor rules of the pure reducer.
final class MessagingTranscriptTests: XCTestCase {
    private func m(_ seq: Int, _ sender: ChatMessageSender = .other, id: Int? = nil) -> ChatMessage {
        MsgFixture.message(seq, sender: sender, identity: id)
    }

    func testPageAppliesAndAdvancesTheCursorOnlyAfterApplication() {
        var t = ConversationTranscript()
        XCTAssertEqual(t.cursor, 0)
        XCTAssertTrue(t.applyPage(MsgFixture.page([m(1), m(2)], after: 0), requestedAfter: 0))
        XCTAssertEqual(t.cursor, 2)
        XCTAssertEqual(t.messages.map(\.sequence), [1, 2])
    }

    func testMalformedPagesAreRejectedWholeAndChangeNothing() {
        var t = ConversationTranscript()
        t.applyPage(MsgFixture.page([m(1)], after: 0), requestedAfter: 0)
        let before = t
        // out of order
        XCTAssertFalse(t.applyPage(ChatMessagePageDTO(messages: [m(3), m(2)], nextAfter: 2), requestedAfter: 1))
        // at/before the requested cursor
        XCTAssertFalse(t.applyPage(ChatMessagePageDTO(messages: [m(1, id: 5)], nextAfter: 1), requestedAfter: 1))
        // nextAfter disagrees with contents
        XCTAssertFalse(t.applyPage(ChatMessagePageDTO(messages: [m(2)], nextAfter: 9), requestedAfter: 1))
        // stale request cursor (a page that raced another)
        XCTAssertFalse(t.applyPage(MsgFixture.page([m(2)], after: 0), requestedAfter: 0))
        // cursor moving backwards
        XCTAssertFalse(t.applyPage(ChatMessagePageDTO(messages: [], nextAfter: 0), requestedAfter: 1))
        XCTAssertEqual(t, before)
    }

    func testEmptyPageKeepsTheCursor() {
        var t = ConversationTranscript()
        t.applyPage(MsgFixture.page([m(1)], after: 0), requestedAfter: 0)
        XCTAssertTrue(t.applyPage(MsgFixture.page([], after: 1), requestedAfter: 1))
        XCTAssertEqual(t.cursor, 1)
    }

    func testSentResultInsertsButNeverAdvancesTheCursorAndLaterPageDedupes() {
        var t = ConversationTranscript()
        t.addLocal(LocalOutgoingMessage(clientMessageId: MsgFixture.identity(50), conversationId: MsgFixture.conversationId, text: "message 7", createdAt: MsgFixture.epoch, state: .sending))
        t.applySent(m(7, .own, id: 50))
        XCTAssertEqual(t.cursor, 0)
        XCTAssertTrue(t.locals.isEmpty)
        XCTAssertEqual(t.messages.map(\.sequence), [7])
        // Earlier messages arrive later and sort before it; the replay of 7 is deduped.
        XCTAssertTrue(t.applyPage(MsgFixture.page([m(1), m(2), m(7, .own, id: 50)], after: 0), requestedAfter: 0))
        XCTAssertEqual(t.messages.map(\.sequence), [1, 2, 7])
        XCTAssertEqual(t.cursor, 7)
    }

    func testDedupeBySequenceAndByClientMessageIdentity() {
        var t = ConversationTranscript()
        t.applySent(m(1, id: 10))
        t.applySent(m(1, id: 11))      // same sequence, different identity
        t.applySent(m(2, id: 10))      // same identity, different sequence
        XCTAssertEqual(t.messages.count, 1)
    }

    func testAPageContainingAFailedLocalIdentityResolvesIt() {
        var t = ConversationTranscript()
        let id = MsgFixture.identity(60)
        t.addLocal(LocalOutgoingMessage(clientMessageId: id, conversationId: MsgFixture.conversationId, text: "message 1", createdAt: MsgFixture.epoch, state: .failed(.unconfirmed)))
        t.applyPage(MsgFixture.page([m(1, .own, id: 60)], after: 0), requestedAfter: 0)
        XCTAssertNil(t.local(id))
        XCTAssertEqual(t.items.count, 1)
    }

    func testLocalItemsFollowAuthoritativeMessagesInCreationOrder() {
        var t = ConversationTranscript()
        t.addLocal(LocalOutgoingMessage(clientMessageId: MsgFixture.identity(70), conversationId: MsgFixture.conversationId, text: "a", createdAt: MsgFixture.epoch, state: .sending))
        t.addLocal(LocalOutgoingMessage(clientMessageId: MsgFixture.identity(71), conversationId: MsgFixture.conversationId, text: "b", createdAt: MsgFixture.epoch, state: .sending))
        t.applyPage(MsgFixture.page([m(1)], after: 0), requestedAfter: 0)
        XCTAssertEqual(t.items.map(\.id), [MsgFixture.identity(1001), MsgFixture.identity(70), MsgFixture.identity(71)])
    }
}
