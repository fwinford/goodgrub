import Foundation
import XCTest
@testable import CommonPlateios

final class MessagingHistoryTranscriptTests: XCTestCase {
    func testFiniteTraversalIncludesEveryIdentityAcrossVolumeBoundaries() {
        for count in [0, 1, 5, 49, 50, 51, 100, 101, 151, 450] {
            var transcript = ConversationTranscript()
            XCTAssertTrue(transcript.applyHistory(MsgFixture.historyPage(total: count), before: nil))
            while transcript.hasOlder {
                let bound = transcript.nextBefore
                XCTAssertTrue(transcript.applyHistory(MsgFixture.historyPage(total: count, before: bound), before: bound))
            }
            XCTAssertEqual(transcript.messages.map(\.sequence), count == 0 ? [] : Array(1...count), "\(count)")
            XCTAssertEqual(Set(transcript.messages.map(\.id)).count, count)
            XCTAssertEqual(transcript.cursor, count)
        }
    }

    func testOlderHeadCannotPoisonForwardCursorAndForwardCannotMoveHistoryBoundary() {
        var transcript = ConversationTranscript()
        XCTAssertTrue(transcript.applyHistory(MsgFixture.historyPage(total: 101), before: nil))
        XCTAssertEqual(transcript.nextBefore, 52)
        XCTAssertTrue(transcript.applyHistory(MsgFixture.historyPage(total: 151, before: 52), before: 52))
        XCTAssertEqual(transcript.cursor, 101)
        XCTAssertEqual(transcript.nextBefore, 2)
        XCTAssertTrue(transcript.applyPage(MsgFixture.page([MsgFixture.message(102)], after: 101), requestedAfter: 101))
        XCTAssertEqual(transcript.cursor, 102)
        XCTAssertEqual(transcript.nextBefore, 2)
        XCTAssertTrue(transcript.hasOlder)
    }

    func testEmptyOpeningThenForwardArrivalHasNoEarlierHistory() {
        var transcript = ConversationTranscript()
        XCTAssertTrue(transcript.applyHistory(MsgFixture.history([]), before: nil))
        XCTAssertTrue(transcript.applyPage(MsgFixture.page([MsgFixture.message(8)], after: 0), requestedAfter: 0))
        XCTAssertFalse(transcript.hasOlder)
        XCTAssertNil(transcript.nextBefore)
        XCTAssertFalse(transcript.applyHistory(MsgFixture.history([MsgFixture.message(1)]), before: 8))
    }

    func testIdenticalPOSTAndForwardOverlapsAreIdempotentAcrossLatestAndOlderPages() {
        var transcript = ConversationTranscript()
        transcript.applySent(MsgFixture.message(51))
        transcript.applySent(MsgFixture.message(1))
        XCTAssertTrue(transcript.applyHistory(MsgFixture.historyPage(total: 51), before: nil))
        XCTAssertTrue(transcript.applyHistory(MsgFixture.historyPage(total: 51, before: 2), before: 2))
        for _ in 0..<10 { XCTAssertTrue(transcript.applySent(MsgFixture.message(51))) }
        XCTAssertEqual(transcript.messages.count, 51)
        XCTAssertEqual(transcript.messages.map(\.sequence), Array(1...51))
    }

    func testMalformedConflictingStaleAndNoProgressPagesAreAtomic() {
        var transcript = ConversationTranscript()
        XCTAssertTrue(transcript.applyHistory(MsgFixture.historyPage(total: 51), before: nil))
        let before = transcript
        for page in [
            MsgFixture.history([MsgFixture.message(2)], hasOlder: true, head: 51),
            MsgFixture.history([], hasOlder: true, head: 51),
            MsgFixture.history([MsgFixture.message(1, identity: 1002)], head: 51),
            MsgFixture.history([MsgFixture.message(1), MsgFixture.message(0)], head: 51)
        ] {
            XCTAssertFalse(transcript.applyHistory(page, before: 2))
            XCTAssertEqual(transcript, before)
        }
        XCTAssertFalse(transcript.applyHistory(MsgFixture.historyPage(total: 51, before: 2), before: 3))
        XCTAssertEqual(transcript, before)
        XCTAssertTrue(transcript.applyHistory(MsgFixture.historyPage(total: 51, before: 2), before: 2))
        let finished = transcript
        XCTAssertFalse(transcript.applyHistory(MsgFixture.historyPage(total: 51, before: 2), before: 2))
        XCTAssertEqual(transcript, finished)
    }

    func testPayloadSequenceAndIdentityConflictsAreNotSilentlyDropped() {
        var transcript = ConversationTranscript()
        transcript.applySent(MsgFixture.message(7))
        let before = transcript
        for message in [
            MsgFixture.message(7, text: "different"),
            MsgFixture.message(7, identity: 999),
            MsgFixture.message(8, identity: 1007),
            MsgFixture.message(7, sender: .own)
        ] {
            XCTAssertFalse(transcript.applySent(message))
            XCTAssertFalse(transcript.applyPage(MsgFixture.page([message], after: 0), requestedAfter: 0))
            XCTAssertEqual(transcript, before)
        }
    }

    func testSequenceNotTimestampOrdersRowsAndFailedLocalsSurviveHistory() {
        var transcript = ConversationTranscript()
        let local = LocalOutgoingMessage(
            clientMessageId: MsgFixture.identity(1), conversationId: MsgFixture.conversationId,
            text: "keep", createdAt: MsgFixture.epoch, state: .failed(.unconfirmed)
        )
        transcript.addLocal(local)
        let messages = (1...3).map { sequence in
            ChatMessage(clientMessageId: MsgFixture.identity(1000 + sequence), sequence: sequence,
                        sender: .other, text: "message", createdAt: MsgFixture.epoch.addingTimeInterval(Double(-sequence)))
        }
        XCTAssertTrue(transcript.applyHistory(MsgFixture.history(messages), before: nil))
        XCTAssertEqual(transcript.messages.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(transcript.locals, [local])
        XCTAssertFalse(transcript.applySent(MsgFixture.message(4, sender: .own, text: "wrong", identity: 1)))
        XCTAssertEqual(transcript.locals, [local])
    }
}
