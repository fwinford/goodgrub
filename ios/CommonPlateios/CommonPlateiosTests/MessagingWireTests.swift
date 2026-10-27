import Foundation
import XCTest
@testable import CommonPlateios

/// W4-MSG1 CP3: strict CP1 DTO decoding, CP2 frame decoding, and the socket
/// configuration (header-only credential, scheme mapping, single subscribe).
final class MessagingWireTests: XCTestCase {
    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private let id1 = MsgFixture.identity(1)

    private func messageJSON(
        id: String? = nil, seq: String = "1", sender: String = "own", text: String = "hi",
        created: String = "2026-10-20T12:00:00Z", extra: String = ""
    ) -> String {
        #"{"clientMessageId":"\#(id ?? id1)","sequence":\#(seq),"sender":"\#(sender)","text":"\#(text)","createdAt":"\#(created)"\#(extra)}"#
    }

    // MARK: Conversation / messages

    func testOpenDecodesExactlyIdentifierAndOpeningSnapshot() throws {
        let id = "64c0000000000000000000c1"
        for snapshot in [0, 1, MessagingWire.maxSequence] {
            let ok = try decoder().decode(ConversationOpenDTO.self, from: Data(#"{"conversationId":"\#(id)","openingSnapshotSequence":\#(snapshot)}"#.utf8))
            XCTAssertEqual(ok.conversationId, id)
            XCTAssertEqual(ok.openingSnapshotSequence, snapshot)
        }
        for bad in [
            #"{"conversationId":"\#(id)"}"#,
            #"{"openingSnapshotSequence":1}"#,
            #"{}"#,
            #"{"conversationId":"nothex","openingSnapshotSequence":1}"#,
            #"{"conversationId":7,"openingSnapshotSequence":1}"#,
            #"{"conversationId":"\#(id)","openingSnapshotSequence":1,"helperId":"x"}"#,
            #"{"conversationId":"\#(id)","openingSnapshotSequence":-1}"#,
            #"{"conversationId":"\#(id)","openingSnapshotSequence":9007199254740992}"#,
            #"{"conversationId":"\#(id)","openingSnapshotSequence":99999999999999999999}"#,
            #"{"conversationId":"\#(id)","openingSnapshotSequence":1.5}"#,
            #"{"conversationId":"\#(id)","openingSnapshotSequence":"1"}"#,
            #"{"conversationId":"\#(id)","openingSnapshotSequence":null}"#,
            #"{"conversationId":"\#(id)","openingSnapshotSequence":true}"#,
        ] {
            XCTAssertThrowsError(try decoder().decode(ConversationOpenDTO.self, from: Data(bad.utf8)), bad)
        }
    }

    func testMessageDecodesStrictShape() throws {
        let m = try decoder().decode(ChatMessage.self, from: Data(messageJSON().utf8))
        XCTAssertEqual(m.sequence, 1)
        XCTAssertEqual(m.sender, .own)
        XCTAssertEqual(m.text, "hi")
        XCTAssertEqual(m.clientMessageId, id1)
    }

    func testMessageRejectsUnexpectedKeysBadIdentityBadSequenceAndEmptyText() {
        let cases = [
            messageJSON(extra: #","senderParticipantId":"x""#),
            messageJSON(id: "NOT-A-UUID"),
            messageJSON(id: "AAAAAAAA-0000-4000-8000-000000000001"),
            messageJSON(id: "00000000-0000-1000-8000-000000000001"),
            messageJSON(seq: "0"),
            messageJSON(seq: "1.5"),
            messageJSON(sender: "helper"),
            messageJSON(text: ""),
            messageJSON(created: "yesterday"),
        ]
        for json in cases {
            XCTAssertThrowsError(try decoder().decode(ChatMessage.self, from: Data(json.utf8)), json)
        }
    }

    func testPageAndEnvelopeAndReconciliationDecoding() throws {
        let page = try decoder().decode(ChatMessagePageDTO.self, from: Data(#"{"messages":[\#(messageJSON())],"nextAfter":1}"#.utf8))
        XCTAssertEqual(page.messages.count, 1)
        XCTAssertEqual(page.nextAfter, 1)
        XCTAssertThrowsError(try decoder().decode(ChatMessagePageDTO.self, from: Data(#"{"messages":[],"nextAfter":-1}"#.utf8)))
        XCTAssertThrowsError(try decoder().decode(ChatMessagePageDTO.self, from: Data(#"{"messages":[],"nextAfter":0,"x":1}"#.utf8)))

        let tooMany = (1...101).map { messageJSON(id: MsgFixture.identity($0), seq: "\($0)") }.joined(separator: ",")
        XCTAssertThrowsError(try decoder().decode(ChatMessagePageDTO.self, from: Data(#"{"messages":[\#(tooMany)],"nextAfter":101}"#.utf8)))

        let env = try decoder().decode(ChatMessageEnvelopeDTO.self, from: Data(#"{"message":\#(messageJSON())}"#.utf8))
        XCTAssertEqual(env.message.sequence, 1)
        XCTAssertThrowsError(try decoder().decode(ChatMessageEnvelopeDTO.self, from: Data(#"{"message":null}"#.utf8)))

        let present = try decoder().decode(ChatMessageReconciliationDTO.self, from: Data(#"{"message":\#(messageJSON())}"#.utf8))
        XCTAssertNotNil(present.message)
        let absent = try decoder().decode(ChatMessageReconciliationDTO.self, from: Data(#"{"message":null}"#.utf8))
        XCTAssertNil(absent.message)
        XCTAssertThrowsError(try decoder().decode(ChatMessageReconciliationDTO.self, from: Data(#"{}"#.utf8)))
    }

    /// CP1 validates JavaScript string length, i.e. UTF-16 code units.
    func testTextLengthIsMeasuredInUTF16UnitsLikeCP1() {
        func ok(_ s: String) -> Bool { MessagingWire.isSendableText(s) }
        func rep(_ s: String, _ n: Int) -> String { String(repeating: s, count: n) }
        XCTAssertTrue(ok("  hello  "))
        XCTAssertFalse(ok(""))
        XCTAssertFalse(ok("   \n\t"))
        // ASCII: 1 unit each
        XCTAssertTrue(ok(rep("a", 2000)))
        XCTAssertFalse(ok(rep("a", 2001)))
        // Emoji: 1 grapheme = 2 units; 1,000 fit, 1,001 do not (CP1 rejects 2,002 units)
        XCTAssertEqual(rep("😀", 1001).utf16.count, 2002)
        XCTAssertTrue(ok(rep("😀", 1000)))
        XCTAssertFalse(ok(rep("😀", 1001)))
        // Combining sequence: 1 grapheme = 2 units
        XCTAssertEqual(rep("e\u{301}", 1000).count, 1000)
        XCTAssertTrue(ok(rep("e\u{301}", 1000)))
        XCTAssertFalse(ok(rep("e\u{301}", 1001)))
        // Family emoji: 1 grapheme, 8 units
        XCTAssertEqual("👨‍👩‍👧".utf16.count, 8)
        XCTAssertTrue(ok(rep("👨‍👩‍👧", 250)))
        XCTAssertFalse(ok(rep("👨‍👩‍👧", 251)))
        // BMP CJK: 1 unit, 3 bytes
        XCTAssertTrue(ok(rep("字", 2000)))
        XCTAssertFalse(ok(rep("字", 2001)))
        // Mixed
        XCTAssertTrue(ok(rep("😀", 999) + "ab"))
        XCTAssertFalse(ok(rep("😀", 999) + "abc"))
        XCTAssertTrue(ok("字" + rep("😀", 999) + "a"))
        XCTAssertFalse(ok("字" + rep("😀", 999) + "ab"))
    }

    // MARK: Socket frames

    private let ref = MsgFixture.identity(9001)

    func testValidSubscribedAndChangedFramesDecode() {
        XCTAssertEqual(ConversationSocketFrame.decode(.text(FakeSocketConnection.subscribedFrame(ref))), .subscribed(reference: ref))
        XCTAssertEqual(ConversationSocketFrame.decode(.text(FakeSocketConnection.changedFrame(ref))), .changed(reference: ref))
    }

    func testUnknownExtraMalformedBinaryAndOversizedFramesAreRejected() {
        let bad: [ConversationSocketInbound] = [
            .text(#"{"type":"message","subscription":"\#(ref)"}"#),
            .text(#"{"type":"changed","subscription":"\#(ref)","text":"leak"}"#),
            .text(#"{"type":"changed"}"#),
            .text(#"{"type":"changed","subscription":"not-a-uuid"}"#),
            .text(#"{"type":"changed","subscription":7}"#),
            .text("not json"),
            .text("[]"),
            .text(""),
            .binary(Data(FakeSocketConnection.changedFrame(ref).utf8)),
            .text(FakeSocketConnection.changedFrame(ref) + String(repeating: " ", count: 1100)),
        ]
        for frame in bad { XCTAssertNil(ConversationSocketFrame.decode(frame), "\(frame)") }
    }

    func testSubscribeFrameCarriesOnlyTypeAndIdentifiers() throws {
        let text = ConversationSubscribeFrame.encode(requestId: MsgFixture.requestId, conversationId: MsgFixture.conversationId)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        XCTAssertEqual(Set(object.keys), ["type", "requestId", "conversationId"])
        XCTAssertEqual(object["type"], "subscribe")
        XCTAssertFalse(text.contains(MsgFixture.authority))
    }

    // MARK: Transport configuration

    func testSocketURLMapsSchemesAndDropsEverythingButThePath() throws {
        XCTAssertEqual(URLSessionConversationSocketTransport.socketURL(for: URL(string: "http://127.0.0.1:3000")!)?.absoluteString, "ws://127.0.0.1:3000/api/messaging/socket")
        XCTAssertEqual(URLSessionConversationSocketTransport.socketURL(for: URL(string: "https://commonplate.test/base?x=1#f")!)?.absoluteString, "wss://commonplate.test/api/messaging/socket")
        XCTAssertNil(URLSessionConversationSocketTransport.socketURL(for: URL(string: "ftp://commonplate.test")!))
    }

    func testCredentialIsOnlyInTheHeader() throws {
        let request = try XCTUnwrap(URLSessionConversationSocketTransport.makeRequest(baseURL: URL(string: "https://commonplate.test")!, authority: MsgFixture.authority))
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-commonplate-participant"), MsgFixture.authority)
        XCTAssertFalse(request.url!.absoluteString.contains(MsgFixture.authority))
        XCTAssertNil(request.url!.query)
        XCTAssertNil(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"))
        XCTAssertEqual(request.allHTTPHeaderFields?.count, 1)
        XCTAssertNil(URLSessionConversationSocketTransport.makeRequest(baseURL: URL(string: "https://commonplate.test")!, authority: ""))
    }

    func testRealAdapterBuildsOneTaskWithTheHeaderAndDisposesIt() throws {
        let transport = URLSessionConversationSocketTransport(baseURL: URL(string: "http://127.0.0.1:9")!, autoResume: false)
        let connection = try XCTUnwrap(transport.connect(authority: MsgFixture.authority) as? URLSessionConversationSocketConnection)
        XCTAssertEqual(connection.task.originalRequest?.value(forHTTPHeaderField: "x-commonplate-participant"), MsgFixture.authority)
        XCTAssertEqual(connection.task.originalRequest?.url?.scheme, "ws")
        XCTAssertEqual(connection.task.maximumMessageSize, 1024)
        XCTAssertEqual(connection.task.state, .suspended)
        connection.cancel()
        connection.cancel()
        XCTAssertNotEqual(connection.task.state, .running)
    }

    func testUnformableConnectionFailsWithoutNetworkAndHasNoLeakedTask() async {
        let transport = URLSessionConversationSocketTransport(baseURL: URL(string: "ftp://x")!)
        let connection = transport.connect(authority: MsgFixture.authority)
        do { _ = try await connection.receive(); XCTFail("expected failure") } catch {
            XCTAssertEqual(error as? ConversationSocketFailure, .failed)
        }
    }
}
