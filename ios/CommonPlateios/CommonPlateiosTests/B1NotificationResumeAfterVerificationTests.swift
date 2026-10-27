import Foundation
import XCTest
@testable import CommonPlateios

/// W4-B1: a helper notification tap that arrives while the verification gate
/// is showing is kept pending, and resumes (navigation only) once the
/// participant is verified and backend truth allows it.
///
/// These drive the production `HelperNotificationRouteDriver` and
/// `RequestStore` over a stubbed transport. What is not established here:
/// real OS tap delivery, the deployed R5 backend, and a physical device.
final class ResumeRecordingURLProtocol: URLProtocol {
    struct Stub { let statusCode: Int; let data: Data
        static func response(statusCode: Int = 200, data: Data) -> Stub { Stub(statusCode: statusCode, data: data) }
    }
    private static let lock = NSLock()
    private nonisolated(unsafe) static var stubs: [Stub] = []
    private nonisolated(unsafe) static var methods: [String] = []

    static func enqueue(_ stub: Stub) { lock.lock(); stubs.append(stub); lock.unlock() }
    static func reset() { lock.lock(); stubs = []; methods = []; lock.unlock() }
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return methods.count }
    static var recordedMethods: [String] { lock.lock(); defer { lock.unlock() }; return methods }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.methods.append(request.httpMethod ?? "GET")
        let stub = Self.stubs.isEmpty ? nil : Self.stubs.removeFirst()
        Self.lock.unlock()
        guard let stub, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: stub.statusCode, httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class B1NotificationResumeAfterVerificationTests: XCTestCase {
    private let requestID = "resume-request"
    private let authority = "64c0000000000000000000a1.1.credential"

    override func tearDown() {
        ResumeRecordingURLProtocol.reset()
        super.tearDown()
    }

    func testTheGateKeepsTheTapPendingAndRoutingIsSourceGatedOnVerification() throws {
        let source = try contentViewSource()
        let body = try XCTUnwrap(source.range(of: "private func routePendingHelperNotification() async {"))
        XCTAssertTrue(source[body.upperBound...].prefix(120).contains("guard participantIdentityStore.isVerified else { return }"))
        // Resumption is triggered by the verification transition itself.
        XCTAssertTrue(source.contains(".onChange(of: participantIdentityStore.isVerified)"))
    }

    func testWithoutAuthorityTheTapIsUnknownNotUnavailableAndNothingIsRequested() async throws {
        let router = tappedRouter()
        let store = makeStore(authority: { nil })

        let resolution = try await store.resolveHelperNotificationRequest(id: requestID, notifiedRevision: nil)

        XCTAssertEqual(resolution, .temporarilyUnavailable)
        XCTAssertEqual(ResumeRecordingURLProtocol.requestCount, 0, "no read may be sent without authority")
        XCTAssertEqual(router.pendingRequestID, requestID, "resolving does not itself retire the tap")
    }

    func testVerifiedParticipantResumesToTheOriginalRequestDetailExactlyOnce() async throws {
        let router = tappedRouter()
        let store = makeStore(authority: { self.authority })
        ResumeRecordingURLProtocol.enqueue(.response(data: detailResponse(status: "open")))

        let first = await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)
        let second = await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)

        guard case .requestDetail(let request) = try XCTUnwrap(first?.last), first?.count == 1 else {
            return XCTFail("expected only the tapped request's detail, got \(String(describing: first))")
        }
        XCTAssertEqual(request.id, requestID)
        XCTAssertNil(second, "a second attempt must not navigate again")
        XCTAssertNil(router.pendingRequestID)
        XCTAssertEqual(ResumeRecordingURLProtocol.requestCount, 1)
    }

    func testResumeIssuesOnlyAReadNeverAMutation() async throws {
        let router = tappedRouter()
        let store = makeStore(authority: { self.authority })
        ResumeRecordingURLProtocol.enqueue(.response(data: detailResponse(status: "open")))

        _ = await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)

        XCTAssertEqual(ResumeRecordingURLProtocol.recordedMethods, ["GET"])
        XCTAssertNil(store.activeClaim, "navigation resume never claims")
        XCTAssertEqual(ResumeRecordingURLProtocol.recordedMethods.count, 1)
    }

    func testUnavailableDestinationsRouteNowhereAndExposeNothing() async throws {
        for status in ["claimed", "placed"] {
            let router = tappedRouter()
            let store = makeStore(authority: { self.authority })
            ResumeRecordingURLProtocol.enqueue(.response(data: detailResponse(status: status)))

            let path = await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)

            XCTAssertEqual(path, [], status)
            XCTAssertNil(router.pendingRequestID, status)
        }

        let router = tappedRouter()
        let store = makeStore(authority: { self.authority })
        ResumeRecordingURLProtocol.enqueue(.response(
            statusCode: 404,
            data: Data(#"{"error":{"code":"REQUEST_NOT_FOUND","message":"x","fields":null}}"#.utf8)
        ))
        let missing = await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)
        XCTAssertEqual(missing, [], "a stale or unknown id leads nowhere")
    }

    func testAnAuthorityTheBackendRejectsRoutesNowhereAndIsReportedToTheRejectionPath() async throws {
        let router = tappedRouter()
        var rejected = 0
        let store = makeStore(authority: { self.authority }, rejected: { rejected += 1 })
        ResumeRecordingURLProtocol.enqueue(.response(
            statusCode: 401,
            data: Data(#"{"error":{"code":"PARTICIPANT_AUTHORITY_INVALID","message":"x","fields":null}}"#.utf8)
        ))

        let path = await HelperNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)

        XCTAssertEqual(path, [], "no request detail may open for a rejected participant")
        XCTAssertEqual(rejected, 1)
    }

    func testAnAuthorityChangeDuringTheReadDoesNotPresentTheOldParticipantsOwnership() async throws {
        var current = authority
        let router = tappedRouter()
        let store = makeStore(authority: { current })
        ResumeRecordingURLProtocol.enqueue(.response(data: detailResponse(status: "open")))
        current = "64c0000000000000000000b2.1.other"

        let resolution = try await store.resolveHelperNotificationRequest(id: requestID, notifiedRevision: nil)
        _ = router

        guard case .available(let request) = resolution else { return XCTFail("\(resolution)") }
        XCTAssertEqual(request.ownership, .unresolved)
    }

    // MARK: - Helpers

    private func tappedRouter() -> HelperNotificationRouter {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: ["type": "new-request", "requestId": requestID])
        return router
    }

    private func makeStore(authority: @escaping () -> String?, rejected: @escaping () -> Void = {}) -> RequestStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResumeRecordingURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
        return RequestStore(
            service: RequestService(client: client),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: authority,
            participantAuthorityRejected: rejected
        )
    }

    private func detailResponse(status: String) -> Data {
        let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(5 * 60 * 60))
        return Data("""
        {"request":{"id":"\(requestID)","vendor":"Crave NYU","food":"Rice bowl",
        "pickupWindowText":"ASAP","mealSwipes":2,"menuPath":"meal-exchange",
        "mealItems":["Meal 1","Meal 2"],"orderDetails":null,
        "estimatedDiningDollarsCents":null,"windowStart":null,"windowEnd":null,
        "status":"\(status)","createdAt":"2026-07-20T18:30:00.000Z","expiresAt":"\(expires)"}}
        """.utf8)
    }

    private func contentViewSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
        return try String(contentsOf: root.appendingPathComponent("ContentView.swift"), encoding: .utf8)
    }
}
