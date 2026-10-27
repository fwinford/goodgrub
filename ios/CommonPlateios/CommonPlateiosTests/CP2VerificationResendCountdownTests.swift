import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class CP2VerificationResendCountdownTests: XCTestCase {
    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    func testCountdownMatchesP2CopyAndEnablesAtTheBackendDeadline() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let availableAt = now.addingTimeInterval(60)

        XCTAssertEqual(
            ParticipantVerificationView.resendTitle(availableAt: availableAt, now: now),
            "Send a new code in 1:00"
        )
        XCTAssertEqual(
            ParticipantVerificationView.resendTitle(
                availableAt: now.addingTimeInterval(0.1),
                now: now
            ),
            "Send a new code in 0:01"
        )
        XCTAssertFalse(ParticipantVerificationView.canResend(
            availableAt: availableAt,
            now: now,
            isRequesting: false,
            isSubmitting: false
        ))
        XCTAssertTrue(ParticipantVerificationView.canResend(
            availableAt: availableAt,
            now: availableAt,
            isRequesting: false,
            isSubmitting: false
        ))
        XCTAssertEqual(
            ParticipantVerificationView.resendTitle(availableAt: now, now: now),
            "Send a new code"
        )
    }

    func testResendRemainsDisabledWhileVerificationRequestIsInFlight() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(ParticipantVerificationView.canResend(
            availableAt: now,
            now: now,
            isRequesting: true,
            isSubmitting: false
        ))
        XCTAssertFalse(ParticipantVerificationView.canResend(
            availableAt: now,
            now: now,
            isRequesting: false,
            isSubmitting: true
        ))
    }

    func testSuccessfulResendRefreshesTheDeadlineFromTheBackend() async throws {
        let store = makeIdentityStore()
        store.beginVerificationIfNeeded()
        let initialDeadline = Date(timeIntervalSince1970: 1_900_000_060)
        let refreshedDeadline = Date(timeIntervalSince1970: 1_900_000_120)

        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 202,
            data: challengeResponse(resendAvailableAt: initialDeadline)
        ))
        await store.requestCode(for: "student@nyu.edu")
        XCTAssertEqual(resendDeadline(in: store), initialDeadline)

        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 202,
            data: challengeResponse(resendAvailableAt: refreshedDeadline)
        ))
        await store.resendCode()

        XCTAssertEqual(resendDeadline(in: store), refreshedDeadline)
        XCTAssertNil(store.verificationError)
    }

    private func resendDeadline(in store: ParticipantIdentityStore) -> Date? {
        guard case .awaitingCode(_, _, let deadline)? = store.flow?.stage else {
            return nil
        }
        return deadline
    }

    private func makeIdentityStore() -> ParticipantIdentityStore {
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

    private func challengeResponse(resendAvailableAt: Date) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiresAt = formatter.string(from: resendAvailableAt.addingTimeInterval(9 * 60))
        let resendDate = formatter.string(from: resendAvailableAt)
        return Data(
            #"{"verification":{"expiresAt":"\#(expiresAt)","resendAvailableAt":"\#(resendDate)"}}"#.utf8
        )
    }
}
