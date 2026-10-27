import Foundation
import XCTest
@testable import CommonPlateios

final class MessagingHistoryHTTPClientTests: XCTestCase {
    private var client: ConversationHTTPClient!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MsgHTTPStub.self]
        client = ConversationHTTPClient(client: APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        ))
        MsgHTTPStub.reset()
    }

    override func tearDown() {
        MsgHTTPStub.reset()
        super.tearDown()
    }

    private func read(_ before: Int? = nil, limit: Int = 50, authority: String = MsgFixture.authority) async -> ConversationHTTPOutcome<ChatMessageHistoryDTO> {
        await client.readHistory(
            authority: authority, requestId: MsgFixture.requestId,
            conversationId: MsgFixture.conversationId, before: before, limit: limit
        )
    }

    func testLatestAndOlderQueriesUseOnlyBackwardFieldsAndHeaderAuthority() async throws {
        let bounds: [Int?] = [nil, 51]
        for before in bounds {
            MsgHTTPStub.reset(.init(body: #"{"messages":[],"hasOlder":false,"nextBefore":null,"newestSequence":0}"#))
            let result = await read(before)
            XCTAssertEqual(result, .success(MsgFixture.history([])))
            let request = try XCTUnwrap(MsgHTTPStub.captured.first)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.query, "direction=backward&limit=50" + (before.map { "&before=\($0)" } ?? ""))
            XCTAssertEqual(request.value(forHTTPHeaderField: ConversationHTTPClient.participantAuthorityHeader), MsgFixture.authority)
            XCTAssertFalse(request.url!.absoluteString.contains(MsgFixture.authority))
            XCTAssertTrue(MsgHTTPStub.capturedBodies[0].isEmpty)
        }
    }

    func testHistoryErrorsPreserveAuthorityClassification() async {
        let cases: [(Int, String, ConversationHTTPOutcome<ChatMessageHistoryDTO>)] = [
            (404, "CONVERSATION_UNAVAILABLE", .unavailable),
            (401, "PARTICIPANT_AUTHORITY_INVALID", .identityInvalid),
            (401, "PARTICIPANT_VERIFICATION_REQUIRED", .authorityRequired),
            (503, "MESSAGING_UNAVAILABLE", .unknown),
            (404, "OTHER", .unknown)
        ]
        for (status, code, expected) in cases {
            MsgHTTPStub.reset(.init(status: status, body: #"{"error":{"code":"\#(code)","message":"m"}}"#))
            let result = await read()
            XCTAssertEqual(result, expected)
        }
    }

    func testMalformedOrRequestContradictoryHistoryIsUnknown() async {
        let replies: [MsgHTTPStub.Reply] = [
            .init(body: "invalid"), .init(error: .timedOut),
            .init(body: #"{"messages":[],"hasOlder":true,"nextBefore":null,"newestSequence":0}"#),
            .init(body: #"{"messages":[],"hasOlder":false,"nextBefore":null,"newestSequence":3}"#),
            .init(body: #"{"messages":[],"hasOlder":false,"nextBefore":null,"newestSequence":0,"nextAfter":0}"#)
        ]
        for reply in replies {
            MsgHTTPStub.reset(reply)
            let result = await read()
            XCTAssertEqual(result, .unknown)
        }
    }

    func testInvalidBoundsOrAbsentAuthorityNeverReachNetwork() async {
        for before in [0, -1, MessagingWire.maxSequence + 1] {
            let result = await read(before)
            XCTAssertEqual(result, .unknown)
        }
        for limit in [0, 101] {
            let result = await read(limit: limit)
            XCTAssertEqual(result, .unknown)
        }
        let absent = await read(authority: "")
        XCTAssertEqual(absent, .authorityRequired)
        XCTAssertTrue(MsgHTTPStub.captured.isEmpty)
    }
}
