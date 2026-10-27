//
//  ScreenshotExternalRequestSeamTests.swift
//  CommonPlateiosTests
//
// W4-S3: the external-transfer boundary proved at the real transport. An
// unauthorized, retired, cancelled, stale, replayed, or authority-less attempt
// results in ZERO requests handed to `URLSession`; a valid authorized attempt
// results in exactly ONE.
//
// These cases run the REAL path: the store, the shared runtime, the shipped
// `RequesterOpenAIExternalProvider`, `ScreenshotProposalService`, `APIClient`, and
// a real `URLSession` whose transport is a recording `URLProtocol`. The proof is
// the transport's submitted-request count plus the store's resulting state.
//
// W4-S3 consent-authority revision: the offer decision and (when authorized)
// the transfer both happen inside the one `analyzeScreenshot` call now — there
// is no separate per-attempt permission popup/tap to drive first.
import Foundation
import XCTest
@testable import CommonPlateios

/// A transport that records each request it is actually handed.
final class SeamURLProtocol: URLProtocol {
    enum Behavior {
        case respond(status: Int, body: String)
        /// Accepts the request and never answers until it is cancelled.
        case hang
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var behavior: Behavior = .hang
    private nonisolated(unsafe) static var submitted = 0

    static func install(_ behavior: Behavior) {
        lock.lock()
        self.behavior = behavior
        submitted = 0
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        submitted = 0
        lock.unlock()
    }

    static var submittedRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return submitted
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.submitted += 1
        let behavior = Self.behavior
        Self.lock.unlock()

        guard case .respond(let status, let body) = behavior,
              let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
              ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Runs a closure, in the store's own task, after the shared runtime's gates
/// passed and before the shipped provider begins — the window in which CommonPlate
/// can still cancel before the request is submitted — then delegates to the real
/// production provider.
@MainActor
final class InterceptingProductionProvider: ScreenshotExternalProvider {
    typealias Workflow = RequesterOrderWorkflow

    let wrapped: RequesterOpenAIExternalProvider
    let beforeDelegating: @MainActor () -> Void

    var identity: ScreenshotProviderIdentity { wrapped.identity }
    var inputMode: ScreenshotInputMode { wrapped.inputMode }

    init(wrapped: RequesterOpenAIExternalProvider, beforeDelegating: @escaping @MainActor () -> Void) {
        self.wrapped = wrapped
        self.beforeDelegating = beforeDelegating
    }

    func analyze(
        _ input: ScreenshotProviderInput<RequesterOrderWorkflow>,
        authority: String
    ) async throws -> ScreenshotProviderResult<ScreenshotProposalOutcome> {
        beforeDelegating()
        return try await wrapped.analyze(input, authority: authority)
    }
}

@MainActor
final class ScreenshotExternalRequestSeamTests: XCTestCase {
    private let successBody = #"{"eligible":true,"proposal":{"mealItems":["External Item"]}}"#

    override func tearDown() {
        SeamURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Fixtures over the real stack

    private func makeClient(_ behavior: SeamURLProtocol.Behavior) -> APIClient {
        SeamURLProtocol.install(behavior)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SeamURLProtocol.self]
        return APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
    }

    private func makeStack(
        _ behavior: SeamURLProtocol.Behavior,
        intercept: ((ScreenshotProposalStore) -> (@MainActor () -> Void))? = nil
    ) -> (store: ScreenshotProposalStore, service: ScreenshotProposalService) {
        let service = ScreenshotProposalService(availability: .enabledForTesting(), client: makeClient(behavior))
        var storeRef: ScreenshotProposalStore?
        let real = RequesterOpenAIExternalProvider(service: service)
        let provider: any ScreenshotExternalProvider<RequesterOrderWorkflow> = intercept.map { make in
            InterceptingProductionProvider(wrapped: real, beforeDelegating: { make(storeRef!)() })
        } ?? real
        let runtime = makeRequesterTestRuntime(local: nil, external: provider)
        let store = ScreenshotProposalStore(
            availability: .enabledForTesting(),
            service: service,
            preferences: InMemoryScreenshotProposalPreferencesStorage(),
            runtime: runtime
        )
        storeRef = store
        return (store, service)
    }

    // MARK: - Accepted submission

    func testAnAuthorizedTransferSubmitsExactlyOneRequestAndAppliesItsResult() async {
        let (store, _) = makeStack(.respond(status: 200, body: successBody))
        let token = beginAttempt(store)

        let resolved = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        XCTAssertEqual(resolved?.proposal.mealItems?.first?.name, "External Item")
        XCTAssertEqual(SeamURLProtocol.submittedRequestCount, 1)
        XCTAssertFalse(store.isApplying)
        XCTAssertNil(store.notice)
    }

    func testAnAttemptedRequestThatFailsInTransportKeepsItsNormalFailureNotice() async {
        let (store, _) = makeStack(.respond(status: 500, body: "{}"))
        let token = beginAttempt(store)

        let resolved = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        XCTAssertNil(resolved)
        XCTAssertEqual(store.notice, .unavailable)
        XCTAssertEqual(SeamURLProtocol.submittedRequestCount, 1, "the request was submitted once and never retried")
    }

    // MARK: - Cancelled or retired before the submission seam

    private func assertNoRequestWasSubmitted(
        _ store: ScreenshotProposalStore,
        outcome: ScreenshotProposalOutcome?,
        noticeBefore: ScreenshotProposalNotice?,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(outcome, message, file: file, line: line)
        XCTAssertEqual(SeamURLProtocol.submittedRequestCount, 0, "\(message): URLSession was never handed a request", file: file, line: line)
        XCTAssertEqual(store.notice, noticeBefore, "\(message): no requester-visible mutation", file: file, line: line)
        XCTAssertFalse(store.isApplying, message, file: file, line: line)
    }

    func testACancellationAfterTheRuntimesGatesButBeforeSubmissionSubmitsNoRequest() async {
        // The runtime's own gates pass; the request's task is then cancelled before
        // the service's and client's cancellation checks run.
        let (store, _) = makeStack(.respond(status: 200, body: successBody)) { _ in
            { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let token = beginAttempt(store)
        let noticeBefore = store.notice

        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        assertNoRequestWasSubmitted(store, outcome: outcome, noticeBefore: noticeBefore, "task cancelled before submission")
    }

    func testARetirementAfterTheRuntimesGatesButBeforeSubmissionSubmitsNoRequest() async {
        let (store, _) = makeStack(.respond(status: 200, body: successBody)) { store in
            { store.invalidateCurrentSelection() }
        }
        let token = beginAttempt(store)
        let noticeBefore = store.notice

        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        assertNoRequestWasSubmitted(store, outcome: outcome, noticeBefore: noticeBefore, "selection retired before submission")
        XCTAssertFalse(store.isCurrent(token))
    }

    func testARetirementBeforeTheCallSubmitsNoRequest() async {
        let (store, _) = makeStack(.respond(status: 200, body: successBody))
        let token = beginAttempt(store)
        let noticeBefore = store.notice

        store.invalidateCurrentSelection()
        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        assertNoRequestWasSubmitted(store, outcome: outcome, noticeBefore: noticeBefore, "retired before the call")
    }

    /// A concurrent retirement queued before the call, landing at whichever
    /// internal suspension point the scheduler reaches first.
    func testConcurrentRetirementDuringTheAttemptSubmitsNoRequest() async {
        let (store, _) = makeStack(.respond(status: 200, body: successBody))
        let token = beginAttempt(store)
        let noticeBefore = store.notice

        let retire = Task { store.invalidateCurrentSelection() }
        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)
        await retire.value

        assertNoRequestWasSubmitted(store, outcome: outcome, noticeBefore: noticeBefore, "concurrent retirement")
    }

    func testAuthorityLostAtTheBoundarySubmitsNoRequest() async {
        let (store, _) = makeStack(.respond(status: 200, body: successBody))
        let token = beginAttempt(store)
        let authority = BoundaryScriptedAuthority(["an-authority", nil])

        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { authority.read() }, token: token)

        XCTAssertNil(outcome)
        XCTAssertEqual(SeamURLProtocol.submittedRequestCount, 0)
        XCTAssertEqual(store.notice, .unavailable, "the accepted authority-loss treatment, unchanged")
    }

    func testAGenuineFailureBeforeSubmissionKeepsItsNoticeAndSubmitsNoRequest() async {
        // A real failure (not a cancellation) that happens before the request is
        // submitted: the requester still sees the ordinary notice.
        let service = ScreenshotProposalService(availability: .enabledForTesting(), client: makeClient(.respond(status: 200, body: successBody)))
        let failing = FailingBeforeSubmissionProvider(wrapped: RequesterOpenAIExternalProvider(service: service))
        let store = ScreenshotProposalStore(
            availability: .enabledForTesting(),
            service: service,
            preferences: InMemoryScreenshotProposalPreferencesStorage(),
            runtime: makeRequesterTestRuntime(local: nil, external: failing)
        )
        let token = beginAttempt(store)

        let outcome = await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token)

        XCTAssertNil(outcome)
        XCTAssertEqual(store.notice, .unavailable, "a genuine failure keeps its requester notice")
        XCTAssertEqual(SeamURLProtocol.submittedRequestCount, 0)
    }

    // MARK: - Cancelled after submission began

    func testACancellationAfterSubmissionBeganPresentsNothingAndMutatesNoRequesterState() async {
        let (store, _) = makeStack(.hang)
        let token = beginAttempt(store)
        let noticeBefore = store.notice

        let attempt = Task { await store.analyzeScreenshot(images: [ScreenshotTestEvidence.input()], participantAuthority: { "an-authority" }, token: token) }
        await waitUntil("the request reached the transport") { SeamURLProtocol.submittedRequestCount == 1 }
        store.invalidateCurrentSelection()
        let outcome = await attempt.value

        XCTAssertNil(outcome, "a retired attempt's result is never usable")
        XCTAssertEqual(SeamURLProtocol.submittedRequestCount, 1, "exactly the one request that had begun; never retried")
        XCTAssertEqual(store.notice, noticeBefore, "no requester-visible mutation from the cancelled request")
        XCTAssertFalse(store.isApplying)
    }

    // MARK: - The client and service seam

    private struct UnencodableBody: Encodable {
        func encode(to encoder: Encoder) throws { throw URLError(.cannotParseResponse) }
    }

    func testTheClientSubmitsNothingForACancelledCallerOrAnUnencodableBody() async {
        let client = makeClient(.respond(status: 200, body: "{\"value\":1}"))
        struct Reply: Decodable { let value: Int }

        let cancelled = Task { () -> Error? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                let _: Reply = try await client.send(path: "/x", method: .post, body: ["a": "b"])
                return nil
            } catch { return error }
        }
        let cancelledError = await cancelled.value
        XCTAssertTrue(cancelledError is CancellationError)

        do {
            let _: Reply = try await client.send(path: "/x", method: .post, body: UnencodableBody())
            XCTFail("an unencodable body must fail")
        } catch {}

        XCTAssertEqual(SeamURLProtocol.submittedRequestCount, 0)
    }

    func testTheServiceSubmitsNothingForACancelledCallerAndOneRequestOtherwise() async throws {
        let client = makeClient(.respond(status: 200, body: successBody))
        let service = ScreenshotProposalService(availability: .enabledForTesting(), client: client)
        let image = ScreenshotProposalImage(data: Data([1]), mimeType: "image/jpeg", localEvidenceText: "t")

        let cancelled = Task { () -> Error? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await service.requestProposal(images: [image], authority: "a")
                return nil
            } catch { return error }
        }
        let cancelledError = await cancelled.value
        XCTAssertTrue(cancelledError is CancellationError)
        XCTAssertEqual(SeamURLProtocol.submittedRequestCount, 0)

        _ = try await service.requestProposal(images: [image], authority: "a")
        XCTAssertEqual(SeamURLProtocol.submittedRequestCount, 1)
    }

    func testOrdinaryAPICallsAreUnaffected() async throws {
        let client = makeClient(.respond(status: 200, body: "{\"value\":7}"))
        struct Reply: Decodable { let value: Int }

        let withBody: Reply = try await client.send(path: "/x", method: .post, body: ["a": "b"])
        let withoutBody: Reply = try await client.send(path: "/x", method: .get)

        XCTAssertEqual(withBody.value, 7)
        XCTAssertEqual(withoutBody.value, 7)
        XCTAssertEqual(SeamURLProtocol.submittedRequestCount, 2)
    }
}

/// Fails before delegating: a genuine pre-submission failure (not a cancellation).
@MainActor
final class FailingBeforeSubmissionProvider: ScreenshotExternalProvider {
    typealias Workflow = RequesterOrderWorkflow

    let wrapped: RequesterOpenAIExternalProvider
    var identity: ScreenshotProviderIdentity { wrapped.identity }
    var inputMode: ScreenshotInputMode { wrapped.inputMode }

    init(wrapped: RequesterOpenAIExternalProvider) {
        self.wrapped = wrapped
    }

    func analyze(
        _ input: ScreenshotProviderInput<RequesterOrderWorkflow>,
        authority: String
    ) async throws -> ScreenshotProviderResult<ScreenshotProposalOutcome> {
        throw ScreenshotProposalServiceError.unavailable(underlying: URLError(.badURL))
    }
}
