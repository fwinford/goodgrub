import Foundation
import XCTest
@testable import CommonPlateios

/// Private stub so these tests do not depend on other suites' URLProtocol state.
final class MsgHTTPStub: URLProtocol {
    struct Reply { var status: Int = 200; var body: String = "{}"; var error: URLError.Code? }
    nonisolated(unsafe) static var reply = Reply()
    nonisolated(unsafe) static var captured: [URLRequest] = []
    nonisolated(unsafe) static var capturedBodies: [Data] = []
    private static let lock = NSLock()

    static func reset(_ reply: Reply = Reply()) {
        lock.withLock { self.reply = reply; captured = []; capturedBodies = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(buffer, maxLength: 4096)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        } else if let b = request.httpBody { body = b }
        let reply: Reply = Self.lock.withLock {
            Self.captured.append(request)
            Self.capturedBodies.append(body)
            return Self.reply
        }
        if let code = reply.error {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// W4-MSG1 CP3: request shape and error classification of the HTTP client.
final class MessagingHTTPClientTests: XCTestCase {
    private var client: ConversationHTTPClient!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MsgHTTPStub.self]
        let session = URLSession(configuration: configuration)
        client = ConversationHTTPClient(client: APIClient(configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!), session: session))
        MsgHTTPStub.reset()
    }

    override func tearDown() {
        MsgHTTPStub.reset()
        super.tearDown()
    }

    private func error(_ status: Int, _ code: String) -> MsgHTTPStub.Reply {
        .init(status: status, body: #"{"error":{"code":"\#(code)","message":"m"}}"#)
    }

    private let messageJSON = #"{"clientMessageId":"00000000-0000-4000-8000-000000000001","sequence":1,"sender":"own","text":"hi","createdAt":"2026-10-20T12:00:00.000Z"}"#

    func testOpenRequestShapeAndCredentialHeaderOnly() async throws {
        MsgHTTPStub.reset(.init(body: #"{"conversationId":"\#(MsgFixture.conversationId)","openingSnapshotSequence":7}"#))
        let outcome = await client.open(authority: MsgFixture.authority, requestId: MsgFixture.requestId)
        XCTAssertEqual(outcome, .success(ConversationOpenDTO(conversationId: MsgFixture.conversationId, openingSnapshotSequence: 7)))
        let request = try XCTUnwrap(MsgHTTPStub.captured.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/request/\(MsgFixture.requestId)/conversation")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-commonplate-participant"), MsgFixture.authority)
        XCTAssertFalse(request.url!.absoluteString.contains(MsgFixture.authority))
    }

    func testReadPageUsesCursorAndLimitQuery() async throws {
        MsgHTTPStub.reset(.init(body: #"{"messages":[\#(messageJSON)],"nextAfter":1}"#))
        let outcome = await client.readPage(authority: MsgFixture.authority, requestId: MsgFixture.requestId, conversationId: MsgFixture.conversationId, after: 4, limit: 100)
        guard case .success(let page) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(page.nextAfter, 1)
        let url = try XCTUnwrap(MsgHTTPStub.captured.first?.url)
        XCTAssertEqual(url.path, "/api/request/\(MsgFixture.requestId)/conversation/\(MsgFixture.conversationId)/messages")
        XCTAssertEqual(url.query, "after=4&limit=100")
    }

    func testSendPostsExactlyIdentityAndTextWithTimeout() async throws {
        MsgHTTPStub.reset(.init(status: 201, body: #"{"message":\#(messageJSON)}"#))
        let outcome = await client.send(authority: MsgFixture.authority, requestId: MsgFixture.requestId, conversationId: MsgFixture.conversationId, clientMessageId: MsgFixture.identity(1), text: "  hi  ")
        guard case .success(let message) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(message.sequence, 1)
        let request = try XCTUnwrap(MsgHTTPStub.captured.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, ConversationHTTPClient.sendTimeout)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: MsgHTTPStub.capturedBodies[0]) as? [String: String])
        XCTAssertEqual(body, ["clientMessageId": MsgFixture.identity(1), "text": "  hi  "])
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-commonplate-participant"), MsgFixture.authority)
    }

    func testReconcileIsAReadOnlyGetByIdentityAndDecodesAbsence() async throws {
        MsgHTTPStub.reset(.init(body: #"{"message":null}"#))
        let outcome = await client.reconcile(authority: MsgFixture.authority, requestId: MsgFixture.requestId, conversationId: MsgFixture.conversationId, clientMessageId: MsgFixture.identity(1))
        guard case .success(let message) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertNil(message)
        let request = try XCTUnwrap(MsgHTTPStub.captured.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertTrue(request.url!.path.hasSuffix("/messages/\(MsgFixture.identity(1))"))
        XCTAssertTrue(MsgHTTPStub.capturedBodies[0].isEmpty)
    }

    func testOnlyConversationUnavailableMeansClosed() async {
        MsgHTTPStub.reset(error(404, "CONVERSATION_UNAVAILABLE"))
        let a = await client.readPage(authority: MsgFixture.authority, requestId: MsgFixture.requestId, conversationId: MsgFixture.conversationId, after: 0, limit: 100)
        XCTAssertEqual(a, .unavailable)
        MsgHTTPStub.reset(error(404, "SOMETHING_ELSE"))
        let b = await client.readPage(authority: MsgFixture.authority, requestId: MsgFixture.requestId, conversationId: MsgFixture.conversationId, after: 0, limit: 100)
        XCTAssertEqual(b, .unknown)
    }

    func testOnlyAuthorityInvalidMeansInvalidCredential() async {
        MsgHTTPStub.reset(error(401, "PARTICIPANT_AUTHORITY_INVALID"))
        let a = await client.open(authority: MsgFixture.authority, requestId: MsgFixture.requestId)
        XCTAssertEqual(a, .identityInvalid)
        MsgHTTPStub.reset(error(401, "PARTICIPANT_VERIFICATION_REQUIRED"))
        let b = await client.open(authority: MsgFixture.authority, requestId: MsgFixture.requestId)
        XCTAssertEqual(b, .authorityRequired)
    }

    func testSendRefusalsAreDefinitive() async {
        for (status, code, expected) in [
            (400, "MESSAGE_TEXT_NOT_ALLOWED", ConversationRefusal.textNotAllowed),
            (400, "INVALID_MESSAGE", .invalidMessage),
            (409, "MESSAGE_IDENTITY_CONFLICT", .identityConflict),
        ] {
            MsgHTTPStub.reset(error(status, code))
            let outcome = await client.send(authority: MsgFixture.authority, requestId: MsgFixture.requestId, conversationId: MsgFixture.conversationId, clientMessageId: MsgFixture.identity(1), text: "x")
            XCTAssertEqual(outcome, .refused(expected), code)
        }
    }

    func testServiceUnavailableTransportAndMalformedBodiesAreUnknownNeverRevocation() async {
        let replies: [MsgHTTPStub.Reply] = [
            error(503, "MESSAGING_UNAVAILABLE"),
            .init(status: 500, body: "boom"),
            .init(status: 200, body: "not json"),
            .init(status: 200, body: #"{"messages":[],"nextAfter":0,"extra":1}"#),
            .init(error: .timedOut),
            .init(error: .notConnectedToInternet),
            .init(error: .networkConnectionLost),
        ]
        for reply in replies {
            MsgHTTPStub.reset(reply)
            let outcome = await client.readPage(authority: MsgFixture.authority, requestId: MsgFixture.requestId, conversationId: MsgFixture.conversationId, after: 0, limit: 100)
            XCTAssertEqual(outcome, .unknown, "\(reply)")
        }
    }

    func testMissingCredentialSendsNothing() async {
        let outcome = await client.open(authority: "", requestId: MsgFixture.requestId)
        XCTAssertEqual(outcome, .authorityRequired)
        XCTAssertTrue(MsgHTTPStub.captured.isEmpty)
    }

    func testMalformedIdentifiersNeverReachTheNetwork() async {
        let a = await client.readPage(authority: MsgFixture.authority, requestId: "../x", conversationId: MsgFixture.conversationId, after: 0, limit: 100)
        let b = await client.readPage(authority: MsgFixture.authority, requestId: MsgFixture.requestId, conversationId: MsgFixture.conversationId, after: -1, limit: 100)
        XCTAssertEqual(a, .unknown)
        XCTAssertEqual(b, .unknown)
        XCTAssertTrue(MsgHTTPStub.captured.isEmpty)
    }
}
