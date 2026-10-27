import Foundation
import XCTest
@testable import CommonPlateios

/// CP5 fix lane: a student who typed the wrong address can leave the code step
/// and correct it. The step back is local — it sends nothing, keeps no code,
/// and never changes the identity or the operation-scoped continuation.
@MainActor
final class ParticipantEmailEntryBackNavigationTests: XCTestCase {
    private let principal = "wrong@nyu.edu"
    private let existingPrincipal = "current@nyu.edu"
    private let authority =
        "64c0000000000000000000c1.1." + String(repeating: "C", count: 42) + "A"

    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    func testFirstVerificationCanReturnToEmailEntryWithoutAnIdentityOrRequest() async throws {
        let store = makeStore()
        store.beginVerificationIfNeeded()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
        await store.requestCode(for: principal)
        guard case .awaitingCode? = store.flow?.stage else {
            return XCTFail("expected the code step")
        }
        let sent = RequestFetchingURLProtocol.capturedRequestedPaths.count

        store.returnToEmailEntry()

        XCTAssertEqual(store.flow?.stage, .enteringEmail)
        XCTAssertEqual(store.flow?.purpose, .firstVerification)
        XCTAssertNil(store.identity)
        XCTAssertNil(store.currentAuthority())
        XCTAssertNil(store.verificationError)
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths.count, sent)
    }

    func testReturningKeepsTheOperationScopedContinuation() async throws {
        let store = makeStore()
        let continuation = ParticipantVerificationContinuation.requestCreation(operationID: UUID())
        XCTAssertTrue(store.beginVerification(for: continuation))
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
        await store.requestCode(for: principal)

        store.returnToEmailEntry()

        XCTAssertEqual(store.pendingContinuation, continuation)
        XCTAssertEqual(store.flow?.stage, .enteringEmail)
    }

    func testReplacementReturnKeepsTheCurrentVerifiedIdentity() async throws {
        let store = makeStore()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: verifiedResponse(existingPrincipal)))
        store.beginVerificationIfNeeded()
        await store.requestCode(for: existingPrincipal)
        let verified = await store.submitCode("424242")
        XCTAssertTrue(verified)
        let before = store.identity

        store.beginEmailReplacement()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
        await store.requestCode(for: principal)
        store.returnToEmailEntry()

        XCTAssertEqual(store.flow?.purpose, .emailReplacement)
        XCTAssertEqual(store.flow?.stage, .enteringEmail)
        XCTAssertEqual(store.identity, before)
        XCTAssertEqual(store.currentAuthority(), authority)
    }

    func testReturnIsANoOpOutsideTheCodeStep() {
        let store = makeStore()
        store.returnToEmailEntry()
        XCTAssertNil(store.flow)

        store.beginVerificationIfNeeded()
        store.returnToEmailEntry()
        XCTAssertEqual(store.flow?.stage, .enteringEmail)
    }

    func testVerificationViewOffersTheStepBackWithAccessibleTarget() throws {
        let view = try source("Views/ParticipantVerificationView.swift")
        XCTAssertEqual(ParticipantVerificationView.useDifferentEmailTitle, "Use a different email")
        XCTAssertTrue(view.contains("store.returnToEmailEntry()"))
        XCTAssertTrue(view.contains("participant-verification-change-email"))
        XCTAssertTrue(view.contains(".frame(maxWidth: .infinity, minHeight: 44)"))
        // The typed code is discarded on the way back.
        let start = try XCTUnwrap(view.range(of: "Button(Self.useDifferentEmailTitle) {"))
        let end = try XCTUnwrap(view.range(of: ".accessibilityIdentifier(\"participant-verification-change-email\")",
                                          range: start.upperBound..<view.endIndex))
        let action = String(view[start.upperBound..<end.lowerBound])
        let clearCode = try XCTUnwrap(action.range(of: "code = \"\""))
        let returnToEmail = try XCTUnwrap(action.range(of: "store.returnToEmailEntry()"))
        XCTAssertLessThan(clearCode.lowerBound, returnToEmail.lowerBound)
    }

    private func makeStore() -> ParticipantIdentityStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
        return ParticipantIdentityStore(
            service: ParticipantVerificationService(client: client),
            storage: InMemoryParticipantIdentityStorage()
        )
    }

    private func challengeResponse() -> Data {
        Data(#"{"verification":{"expiresAt":"2026-08-09T17:10:00.000Z","resendAvailableAt":"2026-08-09T17:01:00.000Z"}}"#.utf8)
    }

    private func verifiedResponse(_ email: String) -> Data {
        Data(#"{"participant":{"email":"\#(email)"},"authority":"\#(authority)"}"#.utf8)
    }

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
