//
//  AlertSignupTests.swift
//  CommonPlateiosTests
//
// Focused coverage for Week 3 Day 5 Slice 5A: the NYU allowlist, the one-POST
// signup path through the existing APIClient, and the distinct presentation
// states. Deliberately its own file rather than another section of
// ClaimFlowTests: alert signup shares no domain with the claim flow.
import Foundation
import XCTest
@testable import CommonPlateios

/// Local transport double. The signup tests need the request body and the
/// exact number of POSTs, and they must not depend on another test file's
/// stubbing internals.
final class AlertSignupURLProtocol: URLProtocol {
    struct CapturedRequest {
        let path: String
        let method: String
        let body: Data?
    }

    struct Stub {
        let statusCode: Int
        let data: Data
        let errorCode: URLError.Code?
        let delay: TimeInterval

        static func response(
            statusCode: Int = 200,
            data: Data,
            delay: TimeInterval = 0
        ) -> Stub {
            Stub(statusCode: statusCode, data: data, errorCode: nil, delay: delay)
        }

        static func failure(_ errorCode: URLError.Code, delay: TimeInterval = 0) -> Stub {
            Stub(statusCode: 0, data: Data(), errorCode: errorCode, delay: delay)
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var stubs: [Stub] = []
    private nonisolated(unsafe) static var captured: [CapturedRequest] = []

    static func enqueue(_ stub: Stub) {
        lock.lock()
        stubs.append(stub)
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        stubs.removeAll()
        captured.removeAll()
        lock.unlock()
    }

    static var capturedRequests: [CapturedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    private static func dequeue() -> Stub? {
        lock.lock()
        defer { lock.unlock() }
        guard !stubs.isEmpty else { return nil }
        return stubs.removeFirst()
    }

    /// `URLProtocol` receives the body as a stream once the request has been
    /// handed to the loading system, so `httpBody` alone captures nothing.
    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1_024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.captured.append(
            CapturedRequest(
                path: request.url?.path ?? "",
                method: request.httpMethod ?? "",
                body: Self.readBody(from: request)
            )
        )
        Self.lock.unlock()

        guard let stub = Self.dequeue() else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        let completeRequest = {
            if let errorCode = stub.errorCode {
                self.client?.urlProtocol(self, didFailWithError: URLError(errorCode))
                return
            }
            guard let url = self.request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: stub.statusCode,
                      httpVersion: nil,
                      headerFields: ["Content-Type": "application/json"]
                  ) else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: stub.data)
            self.client?.urlProtocolDidFinishLoading(self)
        }

        if stub.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay, execute: completeRequest)
        } else {
            completeRequest()
        }
    }

    override func stopLoading() {}
}

@MainActor
final class AlertSignupTests: XCTestCase {
    override func tearDown() {
        AlertSignupURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Exact-domain allowlist

    func testAcceptedExactDomainsAreAllowed() {
        for email in [
            "student@nyu.edu",
            "student@stern.nyu.edu",
            "ada+alerts@nyu.edu",
            "student+alerts@stern.nyu.edu"
        ] {
            XCTAssertTrue(
                AlertSignupEmailValidator.isAllowedNYUEmail(email),
                "\(email) should be allowed"
            )
        }
    }

    func testNonNYULookalikeAndUnlistedSubdomainAddressesAreRejected() {
        for email in [
            "student@example.com",
            "student@law.nyu.edu",
            "student@nyu.edu.fake",
            "student@fake-nyu.edu",
            "student@nyu.edu.example.com",
            "student@notnyu.edu",
            "student@nyu.education",
            "student@edu",
            "nyu.edu",
            "student@",
            "@nyu.edu",
            "faith @nyu.edu",
            "student@@nyu.edu",
            ""
        ] {
            XCTAssertFalse(
                AlertSignupEmailValidator.isAllowedNYUEmail(email),
                "\(email) should be rejected"
            )
        }
    }

    func testWhitespaceAndUppercaseAreNormalizedBeforeTheDomainComparison() {
        for email in [
            "  student@nyu.edu  ",
            "STUDENT@NYU.EDU",
            "\tStudent@Stern.NYU.edu\n",
            " Student+Alerts@STERN.nyu.EDU "
        ] {
            XCTAssertTrue(
                AlertSignupEmailValidator.isAllowedNYUEmail(email),
                "\(email) should be allowed after normalization"
            )
        }

        XCTAssertEqual(AlertSignupEmailValidator.normalize("  STUDENT@NYU.EDU "), "student@nyu.edu")
        XCTAssertEqual(AlertSignupEmailValidator.domain(of: " Student@Stern.NYU.edu "), "stern.nyu.edu")
    }

    func testDomainIsNotMatchedBySuffixOrSubstring() {
        // The two addresses a `hasSuffix("nyu.edu")` check would wrongly accept.
        XCTAssertFalse(AlertSignupEmailValidator.isAllowedNYUEmail("student@evil-nyu.edu"))
        XCTAssertEqual(AlertSignupEmailValidator.domain(of: "student@nyu.edu.evil.test"), "nyu.edu.evil.test")
        XCTAssertFalse(AlertSignupEmailValidator.isAllowedNYUEmail("student@nyu.edu.evil.test"))
    }

    // MARK: - Submission

    func testValidSubmissionSendsExactlyOneNormalizedSignupRequest() async throws {
        let store = makeStore()
        AlertSignupURLProtocol.enqueue(.response(statusCode: 202, data: acceptedBody))

        await store.submit(email: "  Student@NYU.EDU  ")

        let requests = AlertSignupURLProtocol.capturedRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.path, "/api/subscribe")
        XCTAssertEqual(requests.first?.method, "POST")

        let body = try XCTUnwrap(requests.first?.body)
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: String]
        XCTAssertEqual(decoded, ["email": "student@nyu.edu"])
        XCTAssertEqual(store.phase, .checkEmail)
    }

    func testLocallyRejectedAddressSendsNoRequestAndShowsTheFieldError() async {
        let store = makeStore()

        await store.submit(email: "student@example.com")

        XCTAssertTrue(AlertSignupURLProtocol.capturedRequests.isEmpty)
        XCTAssertEqual(store.phase, .editing)
        XCTAssertEqual(store.fieldError, .invalidNYUEmail)
        XCTAssertNil(store.failure)
    }

    func testRepeatedSubmissionWhileLoadingSendsOnlyOneRequest() async {
        let store = makeStore()
        AlertSignupURLProtocol.enqueue(.response(statusCode: 202, data: acceptedBody, delay: 0.2))

        let first = Task { await store.submit(email: "student@nyu.edu") }
        await waitUntil { store.isSubmitting }

        // Every one of these is a real repeated tap on Continue.
        await store.submit(email: "student@nyu.edu")
        await store.submit(email: "student@nyu.edu")
        XCTAssertEqual(store.phase, .submitting)

        await first.value

        XCTAssertEqual(AlertSignupURLProtocol.capturedRequests.count, 1)
        XCTAssertEqual(store.phase, .checkEmail)
    }

    func testSubmissionIsDisabledWhileSubmittingAndAfterAcceptance() {
        XCTAssertTrue(AlertSignupView.isSubmissionEnabled(email: "student@nyu.edu", phase: .editing))
        XCTAssertFalse(AlertSignupView.isSubmissionEnabled(email: "student@nyu.edu", phase: .submitting))
        XCTAssertFalse(AlertSignupView.isSubmissionEnabled(email: "student@nyu.edu", phase: .checkEmail))
        XCTAssertFalse(AlertSignupView.isSubmissionEnabled(email: "   ", phase: .editing))
        // A malformed but non-empty entry still submits, so its own field can
        // explain the refusal instead of the button silently doing nothing.
        XCTAssertTrue(AlertSignupView.isSubmissionEnabled(email: "student@example.com", phase: .editing))
    }

    func testAcceptedSignupDoesNotSendASecondRequest() async {
        let store = makeStore()
        AlertSignupURLProtocol.enqueue(.response(statusCode: 202, data: acceptedBody))

        await store.submit(email: "student@nyu.edu")
        await store.submit(email: "student@nyu.edu")

        XCTAssertEqual(AlertSignupURLProtocol.capturedRequests.count, 1)
        XCTAssertEqual(store.phase, .checkEmail)
    }

    // MARK: - Generic accepted state

    func testGenericAcceptedResponseMapsToTheCheckEmailState() async {
        let store = makeStore()
        AlertSignupURLProtocol.enqueue(.response(statusCode: 202, data: acceptedBody))

        await store.submit(email: "student@nyu.edu")

        XCTAssertEqual(store.phase, .checkEmail)
        XCTAssertNil(store.fieldError)
        XCTAssertNil(store.failure)
    }

    func testUseADifferentEmailClearsTheFieldAndSendsNothing() async {
        let store = makeStore()
        AlertSignupURLProtocol.enqueue(.response(statusCode: 202, data: acceptedBody))
        await store.submit(email: "student@nyu.edu")
        XCTAssertEqual(store.email, "student@nyu.edu")

        store.useDifferentEmail()

        // The whole point of the action is to type a different address, so the
        // previous one must not be sitting in the field waiting to be
        // resubmitted.
        XCTAssertTrue(
            store.email.isEmpty,
            "The field must be empty after choosing to use a different email"
        )
        XCTAssertEqual(store.phase, .editing)
        // Presentation only: nothing was sent, so the previous address was not
        // unsubscribed, cancelled, or otherwise altered on the backend.
        XCTAssertEqual(AlertSignupURLProtocol.capturedRequests.count, 1)
    }

    func testUseADifferentEmailIsIgnoredOutsideTheAcceptedState() {
        let store = makeStore()
        store.updateEmail("student@nyu.edu")

        store.useDifferentEmail()

        // Editing is not the accepted state, so there is nothing to return
        // from and a half-typed address must not be destroyed.
        XCTAssertEqual(store.phase, .editing)
        XCTAssertEqual(store.email, "student@nyu.edu")
    }

    func testUseADifferentEmailReturnsToTheEditableForm() async {
        let store = makeStore()
        AlertSignupURLProtocol.enqueue(.response(statusCode: 202, data: acceptedBody))
        await store.submit(email: "student@nyu.edu")
        XCTAssertEqual(store.phase, .checkEmail)

        store.useDifferentEmail()

        XCTAssertEqual(store.phase, .editing)
        XCTAssertTrue(store.email.isEmpty)
        XCTAssertNil(store.fieldError)
        XCTAssertNil(store.failure)

        AlertSignupURLProtocol.enqueue(.response(statusCode: 202, data: acceptedBody))
        await store.submit(email: "student@stern.nyu.edu")
        XCTAssertEqual(AlertSignupURLProtocol.capturedRequests.count, 2)
        XCTAssertEqual(store.phase, .checkEmail)
    }

    func testNoAcceptedCopyClaimsASubscriptionConfirmationOrActiveAlerts() {
        let acceptedCopy = [
            AlertSignupView.checkEmailTitle,
            AlertSignupView.checkEmailBody,
            AlertSignupView.useDifferentEmailTitle,
            AlertSignupView.doneTitle,
            AlertSignupView.title,
            AlertSignupView.explanation
        ]

        for copy in acceptedCopy {
            let lowercased = copy.lowercased()
            for claim in ["subscribed", "you’re subscribed", "alerts are active", "active", "confirmation sent", "we sent"] {
                XCTAssertFalse(
                    lowercased.contains(claim),
                    "Accepted copy must not claim \"\(claim)\": \(copy)"
                )
            }
        }

        // "confirm" may appear only as an instruction about what the person may
        // still need to do, never as a report that it already happened.
        XCTAssertFalse(AlertSignupView.checkEmailBody.lowercased().contains("confirmed this address."))
        XCTAssertTrue(AlertSignupView.checkEmailBody.contains("if one is needed"))
    }

    // MARK: - Error mapping

    func testBackendInvalidEmailMapsToTheNYUFieldError() async {
        let store = makeStore()
        AlertSignupURLProtocol.enqueue(.response(
            statusCode: 400,
            data: errorBody(code: "INVALID_EMAIL", message: "Enter an NYU email address ending in @nyu.edu or @stern.nyu.edu.")
        ))

        await store.submit(email: "student@nyu.edu")

        XCTAssertEqual(store.phase, .editing)
        XCTAssertEqual(store.fieldError, .invalidNYUEmail)
        XCTAssertNil(store.failure)
        XCTAssertEqual(
            AlertSignupEmailValidator.invalidEmailMessage,
            "Enter an NYU email address ending in @nyu.edu or @stern.nyu.edu."
        )
    }

    func testPausedSignupMapsDistinctlyAndBlamesNoAddress() async {
        let store = makeStore()
        // The pause gate's actual subscribe body: a bare string, not the
        // structured envelope.
        AlertSignupURLProtocol.enqueue(.response(
            statusCode: 503,
            data: Data(#"{"error":"Meal request alerts are temporarily unavailable"}"#.utf8)
        ))

        await store.submit(email: "student@nyu.edu")

        XCTAssertEqual(store.phase, .editing)
        XCTAssertEqual(store.failure, .paused)
        XCTAssertNil(store.fieldError)

        let message = AlertSignupView.message(for: .paused).lowercased()
        XCTAssertFalse(message.contains("email address"))
        XCTAssertFalse(message.contains("nyu.edu"))
    }

    func testRateLimitingMapsDistinctly() async {
        let store = makeStore()
        AlertSignupURLProtocol.enqueue(.response(
            statusCode: 429,
            data: Data("Too many requests, please try again later.".utf8)
        ))

        await store.submit(email: "student@nyu.edu")

        XCTAssertEqual(store.phase, .editing)
        XCTAssertEqual(store.failure, .rateLimited)
        XCTAssertNil(store.fieldError)
    }

    func testTransportFailureMapsToTheAmbiguousStateAndIsNotRetried() async {
        let store = makeStore()
        AlertSignupURLProtocol.enqueue(.failure(.networkConnectionLost))

        await store.submit(email: "student@nyu.edu")

        XCTAssertEqual(store.phase, .editing)
        XCTAssertEqual(store.failure, .ambiguousOutcome)
        XCTAssertEqual(AlertSignupURLProtocol.capturedRequests.count, 1)
        XCTAssertEqual(
            AlertSignupView.message(for: .ambiguousOutcome),
            "We couldn’t confirm whether your signup was received. Check your email before trying again."
        )
    }

    func testUndecodableAcceptedBodyMapsToTheAmbiguousState() async {
        let store = makeStore()
        AlertSignupURLProtocol.enqueue(.response(statusCode: 202, data: Data("not json".utf8)))

        await store.submit(email: "student@nyu.edu")

        XCTAssertEqual(store.phase, .editing)
        XCTAssertEqual(store.failure, .ambiguousOutcome)
    }

    func testAcceptedResponseWithNoMessageKeyStillAccepts() async {
        let store = makeStore()
        AlertSignupURLProtocol.enqueue(.response(statusCode: 202, data: Data("{}".utf8)))

        await store.submit(email: "student@nyu.edu")

        XCTAssertEqual(store.phase, .checkEmail)
    }

    func testMissingRouteAndUnknownEnvelopeCodeMapToTheBoundedUnknownFailure() async {
        let missingRoute = makeStore()
        AlertSignupURLProtocol.enqueue(.response(statusCode: 404, data: Data("Not Found".utf8)))
        await missingRoute.submit(email: "student@nyu.edu")
        XCTAssertEqual(missingRoute.failure, .unknown)

        AlertSignupURLProtocol.reset()

        let unknownCode = makeStore()
        AlertSignupURLProtocol.enqueue(.response(
            statusCode: 400,
            data: errorBody(code: "SOMETHING_ELSE", message: "Nope.")
        ))
        await unknownCode.submit(email: "student@nyu.edu")
        XCTAssertEqual(unknownCode.failure, .unknown)
        XCTAssertNil(unknownCode.fieldError)
    }

    // MARK: - Cancellation
    //
    // Cancellation is two different outcomes, and the split is the point:
    // before transmission nothing can have reached the backend, so the result
    // is definitive; from transmission onward it may already have been applied.
    //
    // Known coverage limit: `APIClient` reports cancellation from three points
    // — before `URLSession` is called, from a cancelled transport, and after a
    // response was already received. The first and the "already transmitted"
    // pair are pinned below. Distinguishing the second from the third would
    // require suspending the stub mid-response and reaching into `APIClient`'s
    // internals; both are conservatively ambiguous by design, so that
    // distinction is documented here rather than tested with machinery that
    // would outlive its value.

    func testPreTransmissionCancellationIsReportedAsDefinitiveByTheService() async {
        let service = makeService()

        // `Task {}` inherits this @MainActor test's isolation, so its body
        // cannot begin until this synchronous scope suspends. `cancel()`
        // therefore always lands before the first cancellation check.
        let task = Task { try await service.subscribe(email: "student@nyu.edu") }
        task.cancel()

        do {
            try await task.value
            XCTFail("A cancelled signup must not be reported as accepted")
        } catch let error as AlertSubscriptionError {
            switch error {
            case .unknownFailure:
                break
            case .ambiguousSignupOutcome:
                XCTFail("Pre-transmission cancellation is definitive, not ambiguous")
            default:
                XCTFail("Unexpected classification: \(error)")
            }
        } catch {
            // Guards the regression this test exists for: the pre-flight check
            // must not throw a raw CancellationError past the service's own
            // error type and leave classification to whoever catches it.
            XCTFail("Cancellation must be translated by the service, got \(error)")
        }

        XCTAssertTrue(AlertSignupURLProtocol.capturedRequests.isEmpty)
    }

    func testPreTransmissionCancellationNeverShowsTheAmbiguousMessage() async throws {
        let store = makeStore()

        let task = Task { await store.submit(email: "student@nyu.edu") }
        task.cancel()
        await task.value

        XCTAssertTrue(AlertSignupURLProtocol.capturedRequests.isEmpty)
        XCTAssertEqual(store.phase, .editing)
        XCTAssertNotEqual(store.failure, .ambiguousOutcome)
        XCTAssertEqual(store.failure, .unknown)

        // Nothing left the device, so the person must not be told their signup
        // may have been received and sent off to check their email.
        let shown = AlertSignupView.message(for: try XCTUnwrap(store.failure))
        XCTAssertNotEqual(shown, AlertSignupView.message(for: .ambiguousOutcome))
        XCTAssertFalse(shown.lowercased().contains("couldn’t confirm whether"))
    }

    func testCancellationAfterTransmissionRemainsAmbiguous() async {
        let store = makeStore()
        AlertSignupURLProtocol.enqueue(
            .response(statusCode: 202, data: acceptedBody, delay: 0.5)
        )

        let task = Task { await store.submit(email: "student@nyu.edu") }
        // Cancel only once the body is provably on the wire: the stub records
        // the request in `startLoading`, which runs after transmission begins.
        await waitUntil { AlertSignupURLProtocol.capturedRequests.count == 1 }
        task.cancel()
        await task.value

        XCTAssertEqual(store.phase, .editing)
        XCTAssertEqual(store.failure, .ambiguousOutcome)
        XCTAssertEqual(AlertSignupURLProtocol.capturedRequests.count, 1)
    }

    func testEveryFailureStateHasItsOwnMessage() {
        let failures: [AlertSignupFailure] = [
            .paused, .rateLimited, .ambiguousOutcome, .unknown
        ]
        let messages = failures.map(AlertSignupView.message(for:))

        XCTAssertEqual(Set(messages).count, failures.count)
        for message in messages {
            XCTAssertFalse(message.isEmpty)
            let lowercased = message.lowercased()
            // No backend jargon reaches the screen.
            for jargon in ["503", "429", "http", "invalid_email", "envelope", "null"] {
                XCTAssertFalse(lowercased.contains(jargon), "\(message) leaks \(jargon)")
            }
            // No failure may imply the signup worked.
            XCTAssertFalse(lowercased.contains("subscribed"))
            XCTAssertFalse(lowercased.contains("you’re signed up"))
        }
    }

    // MARK: - Helpers

    private var acceptedBody: Data {
        Data(#"{"message":"If confirmation is needed, check your email for the next step."}"#.utf8)
    }

    private func errorBody(code: String, message: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"\#(message)","fields":null}}"#.utf8)
    }

    private func makeService() -> AlertSubscriptionService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AlertSignupURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return AlertSubscriptionService(client: client)
    }

    /// Every store here gets its own in-memory presentation storage, so these
    /// cases keep testing exactly what they tested before and none of them can
    /// touch the developer's real preferences. Cross-launch behavior is covered
    /// in `AlertSignupPresentationTests`.
    private func makeStore() -> AlertSubscriptionStore {
        AlertSubscriptionStore(
            service: makeService(),
            presentationStorage: InMemoryAlertSignupPresentationStorage()
        )
    }

    private func waitUntil(
        timeoutIterations: Int = 100,
        condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<timeoutIterations {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}
