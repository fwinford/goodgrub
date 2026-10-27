import Foundation
import XCTest
@testable import CommonPlateios

/// W4-MSG1 CP7-B: ack/unread wire strictness, HTTP classification and the
/// coordinator's opening-versus-displayed acknowledgement. Scripted only.
@MainActor
final class MessagingReadAcknowledgementTests: XCTestCase {
    private let dec = JSONDecoder()

    // MARK: Wire

    func testAckDTOIsStrict() {
        let ok = #"{"conversationId":"\#(MsgFixture.conversationId)","acknowledgedCount":2}"#
        XCTAssertEqual(try? dec.decode(ConversationReadAckDTO.self, from: Data(ok.utf8)).acknowledgedCount, 2)
        for bad in [
            #"{"conversationId":"\#(MsgFixture.conversationId)"}"#,
            #"{"conversationId":"\#(MsgFixture.conversationId)","acknowledgedCount":-1}"#,
            #"{"conversationId":"\#(MsgFixture.conversationId)","acknowledgedCount":101}"#,
            #"{"conversationId":"\#(MsgFixture.conversationId)","acknowledgedCount":1.5}"#,
            #"{"conversationId":"\#(MsgFixture.conversationId)","acknowledgedCount":1,"extra":1}"#,
            #"{"conversationId":"nope","acknowledgedCount":1}"#,
        ] {
            XCTAssertThrowsError(try dec.decode(ConversationReadAckDTO.self, from: Data(bad.utf8)), bad)
        }
    }

    func testUnreadSummaryDTOIsStrict() {
        let e = #"{"requestId":"\#(MsgFixture.requestId)","conversationId":"\#(MsgFixture.conversationId)","unreadCount":3}"#
        XCTAssertNoThrow(try dec.decode(MessagingUnreadSummaryDTO.self, from: Data(#"{"unreadCount":3,"conversations":[\#(e)]}"#.utf8)))
        XCTAssertNoThrow(try dec.decode(MessagingUnreadSummaryDTO.self, from: Data(#"{"unreadCount":0,"conversations":[]}"#.utf8)))
        for bad in [
            #"{"unreadCount":4,"conversations":[\#(e)]}"#,                 // sum mismatch
            #"{"unreadCount":6,"conversations":[\#(e),\#(e)]}"#,           // duplicate conversation
            #"{"unreadCount":0,"conversations":[{"requestId":"\#(MsgFixture.requestId)","conversationId":"\#(MsgFixture.conversationId)","unreadCount":0}]}"#,
            #"{"unreadCount":3,"conversations":[\#(e)],"extra":true}"#,
            #"{"unreadCount":3}"#,
            #"{"conversations":[]}"#,
            #"{"unreadCount":3,"conversations":[{"requestId":"\#(MsgFixture.requestId)","conversationId":"\#(MsgFixture.conversationId)","unreadCount":3,"x":1}]}"#,
        ] {
            XCTAssertThrowsError(try dec.decode(MessagingUnreadSummaryDTO.self, from: Data(bad.utf8)), bad)
        }
    }

    // MARK: HTTP client

    private func client() -> ConversationHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MsgHTTPStub.self]
        return ConversationHTTPClient(client: APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        ))
    }

    func testAcknowledgeRequestShapeAndResponseBinding() async throws {
        defer { MsgHTTPStub.reset() }
        MsgHTTPStub.reset(.init(body: #"{"conversationId":"\#(MsgFixture.conversationId)","acknowledgedCount":2}"#))
        let outcome = await client().acknowledge(authority: MsgFixture.authority, requestId: MsgFixture.requestId, conversationId: MsgFixture.conversationId, displayedSequences: [4, 5])
        XCTAssertEqual(outcome, .success(ConversationReadAckDTO(conversationId: MsgFixture.conversationId, acknowledgedCount: 2)))
        let request = try XCTUnwrap(MsgHTTPStub.captured.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/request/\(MsgFixture.requestId)/conversation/\(MsgFixture.conversationId)/read")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-commonplate-participant"), MsgFixture.authority)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: MsgHTTPStub.capturedBodies[0]) as? [String: [Int]])
        XCTAssertEqual(body, ["displayedSequences": [4, 5]])
    }

    func testAcknowledgeRejectsInvalidBatchesWithoutRequestAndMismatchedResponses() async {
        defer { MsgHTTPStub.reset() }
        let c = client()
        for batch in [[], [0], [-1], [1, 1], Array(1...101)] {
            let outcome = await c.acknowledge(authority: MsgFixture.authority, requestId: MsgFixture.requestId, conversationId: MsgFixture.conversationId, displayedSequences: batch)
            XCTAssertNotEqual(outcome, .success(ConversationReadAckDTO(conversationId: MsgFixture.conversationId, acknowledgedCount: 0)))
        }
        XCTAssertTrue(MsgHTTPStub.captured.isEmpty)
        MsgHTTPStub.reset(.init(body: #"{"conversationId":"\#(MsgFixture.otherConversationId)","acknowledgedCount":1}"#))
        let other = await c.acknowledge(authority: MsgFixture.authority, requestId: MsgFixture.requestId, conversationId: MsgFixture.conversationId, displayedSequences: [1])
        XCTAssertEqual(other, .unknown)
        MsgHTTPStub.reset(.init(body: #"{"conversationId":"\#(MsgFixture.conversationId)","acknowledgedCount":3}"#))
        let over = await c.acknowledge(authority: MsgFixture.authority, requestId: MsgFixture.requestId, conversationId: MsgFixture.conversationId, displayedSequences: [1])
        XCTAssertEqual(over, .unknown, "cannot acknowledge more than was submitted")
    }

    func testUnreadSummaryRequestShapeAndTrustBoundary() async throws {
        defer { MsgHTTPStub.reset() }
        MsgHTTPStub.reset(.init(body: #"{"unreadCount":0,"conversations":[]}"#))
        let c = client()
        let ok = await c.unreadSummary(authority: MsgFixture.authority)
        XCTAssertEqual(ok, .success(MessagingUnreadSummaryDTO(unreadCount: 0, conversations: [])))
        let request = try XCTUnwrap(MsgHTTPStub.captured.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/participant/messaging/unread-count")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-commonplate-participant"), MsgFixture.authority)
        MsgHTTPStub.reset(.init(body: #"{"unreadCount":9,"conversations":[]}"#))
        let bad = await c.unreadSummary(authority: MsgFixture.authority)
        XCTAssertEqual(bad, .unknown)
    }

    // MARK: Coordinator

    private func harness(snapshot: Int, history: [ChatMessage], http: ScriptedHTTP = ScriptedHTTP(), unread: MessagingUnreadStore? = nil) async -> CoordinatorHarness {
        http.defaultOpeningSnapshot = snapshot
        http.defaultHistory = { _ in .success(MsgFixture.history(history)) }
        let h = CoordinatorHarness.make(http: http, withSocket: false, unread: unread)
        await h.boot()
        return h
    }

    private func ids(_ messages: [ChatMessage]) -> Set<String> { Set(messages.map(\.clientMessageId)) }

    private func settle() async { try? await Task.sleep(nanoseconds: 40_000_000) }

    func testOpeningItselfSubmitsNoAcknowledgementForExistingMessages() async {
        let existing = [MsgFixture.message(1), MsgFixture.message(2)]
        let h = await harness(snapshot: 2, history: existing)
        h.coordinator.messagesDidDisplay(ids(existing))
        await settle()
        XCTAssertTrue(h.http.acks.isEmpty, "the opening snapshot already read these server-side")
    }

    func testDisplayedNewIncomingMessagesAreAcknowledgedExactlyOnce() async {
        let old = MsgFixture.message(1)
        let new = MsgFixture.message(3)
        let h = await harness(snapshot: 1, history: [old, new])
        h.coordinator.messagesDidDisplay(ids([old, new]))
        await eventually("ack") { h.http.acks.count == 1 }
        XCTAssertEqual(h.http.acks[0].displayedSequences, [3])
        XCTAssertEqual(h.http.acks[0].conversationId, MsgFixture.conversationId)
        XCTAssertEqual(h.http.acks[0].authority, MsgFixture.authority)
        h.coordinator.messagesDidDisplay(ids([old, new]))
        await settle()
        XCTAssertEqual(h.http.acks.count, 1, "valid duplicate display does not resubmit")
    }

    func testFetchedButUndisplayedOwnAndLocalMessagesAreNeverAcknowledged() async {
        let new = MsgFixture.message(3)
        let own = MsgFixture.message(4, sender: .own)
        let h = await harness(snapshot: 1, history: [new, own])
        h.coordinator.messagesDidDisplay([])
        await settle()
        XCTAssertTrue(h.http.acks.isEmpty, "offscreen/prefetched")
        h.coordinator.messagesDidDisplay([own.clientMessageId, "unknown-local-id"])
        await settle()
        XCTAssertTrue(h.http.acks.isEmpty, "own and unknown rows are never acknowledged")
    }

    func testBackgroundedSceneDoesNotAcknowledgeAndReactivationFlushesOnlyDisplayed() async {
        let new = MsgFixture.message(3)
        let h = await harness(snapshot: 1, history: [new])
        h.coordinator.sceneDidEnterBackground()
        h.coordinator.messagesDidDisplay(ids([new]))
        await settle()
        XCTAssertTrue(h.http.acks.isEmpty)
        h.coordinator.sceneDidBecomeActive()
        await eventually("ack after reactivation") { h.http.acks.count == 1 }
        XCTAssertEqual(h.http.acks[0].displayedSequences, [3])
    }

    func testFailedAcknowledgementIsNotConfirmedAndNeverRetriedOnATimer() async {
        let new = MsgFixture.message(3)
        let http = ScriptedHTTP()
        http.enqueueAck { _ in .unknown }
        let h = await harness(snapshot: 1, history: [new], http: http)
        h.coordinator.messagesDidDisplay(ids([new]))
        await eventually("first ack") { http.acks.count == 1 }
        await settle()
        h.scheduler.advance(by: 3600)
        await settle()
        XCTAssertEqual(http.acks.count, 1, "no automatic retry loop")
        // A later genuine display event reconciles.
        h.coordinator.messagesDidDisplay([])
        h.coordinator.messagesDidDisplay(ids([new]))
        await eventually("reconciled") { http.acks.count == 2 }
        XCTAssertEqual(http.acks[1].displayedSequences, [3])
        h.coordinator.messagesDidDisplay(ids([new]))
        await settle()
        XCTAssertEqual(http.acks.count, 2)
    }

    func testBatchesAreCappedAtOneHundredAndSequential() async {
        let msgs = (2...151).map { MsgFixture.message($0) }
        let http = ScriptedHTTP()
        http.enqueueRead { _ in .success(ChatMessagePageDTO(messages: Array(msgs[50...]), nextAfter: 151)) }
        let gate = Gate()
        http.enqueueAck { call in
            await gate.wait()
            return .success(ConversationReadAckDTO(conversationId: call.conversationId, acknowledgedCount: call.displayedSequences.count))
        }
        let h = await harness(snapshot: 1, history: Array(msgs[..<50]), http: http)
        await eventually("all loaded") { h.coordinator.items.count == 150 }
        h.coordinator.messagesDidDisplay(ids(msgs))
        await eventually("first batch") { http.acks.count == 1 }
        XCTAssertEqual(http.acks[0].displayedSequences, Array(2...101))
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(http.acks.count, 1, "one in flight at a time")
        gate.open()
        await eventually("second batch") { http.acks.count == 2 }
        XCTAssertEqual(http.acks[1].displayedSequences, Array(102...151))
    }

    func testAcknowledgementResultFromPreviousConversationIsFencedAfterDismiss() async {
        let new = MsgFixture.message(3)
        let http = ScriptedHTTP()
        let gate = Gate()
        http.enqueueAck { call in
            await gate.wait()
            return .success(ConversationReadAckDTO(conversationId: call.conversationId, acknowledgedCount: 1))
        }
        let unreadHTTP = ScriptedHTTP()
        let unread = MessagingUnreadStore(http: unreadHTTP, authorityProvider: { MsgFixture.authority })
        let h = await harness(snapshot: 1, history: [new], http: http, unread: unread)
        h.coordinator.messagesDidDisplay(ids([new]))
        await eventually("in flight") { http.acks.count == 1 }
        h.coordinator.dismiss()
        gate.open()
        await settle()
        XCTAssertTrue(unreadHTTP.unreadCalls.isEmpty, "a fenced result must not touch the unread projection")
    }

    func testSuccessfulAcknowledgementInvalidatesThenRefreshesUnreadFromServer() async {
        let new = MsgFixture.message(3)
        let unreadHTTP = ScriptedHTTP()
        unreadHTTP.enqueueUnread { _ in .success(MessagingUnreadSummaryDTO(unreadCount: 0, conversations: [])) }
        let unread = MessagingUnreadStore(http: unreadHTTP, authorityProvider: { MsgFixture.authority })
        let h = await harness(snapshot: 1, history: [new], unread: unread)
        XCTAssertEqual(unread.state(forRequest: MsgFixture.requestId), .unknown)
        h.coordinator.messagesDidDisplay(ids([new]))
        await eventually("refresh") { unreadHTTP.unreadCalls.count >= 1 }
        await eventually("authoritative zero") { unread.state(forRequest: MsgFixture.requestId) == .known(count: 0, isStale: false) }
    }

    func testClosureAndAuthorityRevocationClearTheUnreadCache() async {
        let unreadHTTP = ScriptedHTTP()
        unreadHTTP.defaultUnread = { _ in .success(MessagingUnreadSummaryDTO(unreadCount: 2, conversations: [ConversationUnreadEntryDTO(requestId: MsgFixture.requestId, conversationId: MsgFixture.conversationId, unreadCount: 2)])) }
        let unread = MessagingUnreadStore(http: unreadHTTP, authorityProvider: { MsgFixture.authority })
        unread.refresh()
        await eventually("known") { unread.state(forRequest: MsgFixture.requestId) == .known(count: 2, isStale: false) }
        let http = ScriptedHTTP()
        http.enqueueOpen { .unavailable }
        let h = CoordinatorHarness.make(http: http, withSocket: false, unread: unread)
        h.coordinator.start()
        await eventually("closed") { h.coordinator.phase == .unavailable }
        XCTAssertEqual(unread.state(forRequest: MsgFixture.requestId), .unknown)

        unread.refresh()
        await eventually("known again") { unread.state(forRequest: MsgFixture.requestId) == .known(count: 2, isStale: false) }
        let revoked = CoordinatorHarness.make(http: ScriptedHTTP(), withSocket: false, authority: MsgAuthorityBox(nil), unread: unread)
        revoked.coordinator.start()
        await settle()
        XCTAssertEqual(unread.state(forRequest: MsgFixture.requestId), .unknown)
    }

    func testNoSenderVisibleReadReceiptSurfaceExists() {
        let source = try? String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios/Messaging/Views/ConversationScreen.swift"), encoding: .utf8)
        XCTAssertNotNil(source)
        for forbidden in ["\"Seen\"", "\"Read\"", "read receipt", "readAt"] {
            XCTAssertFalse(source?.contains(forbidden) ?? true, forbidden)
        }
    }

    func testVisibleRowGeometryRequiresMajorityOverlap() {
        let viewport = CGRect(x: 0, y: 0, width: 300, height: 400)
        let frames: [String: CGRect] = [
            "full": CGRect(x: 0, y: 100, width: 300, height: 50),
            "half": CGRect(x: 0, y: 375, width: 300, height: 50),       // 25 of 50
            "sliver": CGRect(x: 0, y: 390, width: 300, height: 50),     // 10 of 50
            "above": CGRect(x: 0, y: -200, width: 300, height: 50),
            "tall": CGRect(x: 0, y: -100, width: 300, height: 900),     // covers the viewport
        ]
        let visible = ConversationViewport.visibleIDs(frames: frames, in: viewport)
        XCTAssertTrue(visible.contains("full"))
        XCTAssertTrue(visible.contains("half"))
        XCTAssertTrue(visible.contains("tall"))
        XCTAssertFalse(visible.contains("sliver"))
        XCTAssertFalse(visible.contains("above"))
    }
}
