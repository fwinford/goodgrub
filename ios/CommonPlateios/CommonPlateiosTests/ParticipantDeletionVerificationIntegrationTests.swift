import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class ParticipantDeletionVerificationIntegrationTests: XCTestCase {
    private let email = "student@nyu.edu"
    private let participantID = "64c0000000000000000000a1"

    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    private func makeStore(
        storage: InMemoryParticipantIdentityStorage = InMemoryParticipantIdentityStorage()
    ) -> ParticipantIdentityStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        return ParticipantIdentityStore(
            service: ParticipantVerificationService(client: APIClient(
                configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
                session: URLSession(configuration: configuration)
            )),
            storage: storage
        )
    }

    private var challenge: Data {
        Data(#"""
        {"verification":{"expiresAt":"2099-10-26T16:10:00.000Z","resendAvailableAt":"2099-10-26T16:01:00.000Z"}}
        """#.utf8)
    }

    private func enqueueCooldown() {
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 429,
            data: Data(#"{"error":{"code":"VERIFICATION_RESEND_TOO_SOON","message":"detail","fields":null}}"#.utf8)
        ))
    }

    func testConfirmedSendShortcutSurvivesIntegrationButNotDeletionFreeze() async {
        let store = makeStore()
        store.beginVerificationIfNeeded()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challenge))
        await store.requestCode(for: email)
        store.returnToEmailEntry()
        enqueueCooldown()
        await store.requestCode(for: email)
        guard case .awaitingCode(let current, _, _)? = store.flow?.stage else {
            return XCTFail("A confirmed send in this flow must still permit code entry.")
        }
        XCTAssertEqual(current, email)
        XCTAssertNil(store.verificationError)

        store.freezeForDeletion()
        store.beginVerificationIfNeeded()
        XCTAssertNil(store.flow)
        store.restoreAfterCanceledDeletion()
        store.beginVerificationIfNeeded()
        enqueueCooldown()
        await store.requestCode(for: email)
        XCTAssertEqual(store.flow?.stage, .enteringEmail)
        XCTAssertEqual(store.verificationError, .resendTooSoon)
        XCTAssertFalse(store.isVerified)
    }

    func testDeletionHoldPreservesIdentityAndBlocksReplacementRemovalAndRejection() async {
        let record = ParticipantIdentityRecord(
            principal: email, authority: canonicalParticipantAuthorityFixture, verifiedAt: Date()
        )
        let storage = InMemoryParticipantIdentityStorage(stored: record)
        let store = makeStore(storage: storage)
        var associationCalls = 0
        store.configureInstallationAssociation { _ in associationCalls += 1 }
        store.holdForDeletion()
        store.beginEmailReplacement()
        await store.startEmailReplacement()
        await store.removeIdentity()
        store.discardRejectedIdentity()
        XCTAssertNil(store.flow)
        XCTAssertEqual(associationCalls, 0)
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
        XCTAssertEqual(store.currentAuthority(), record.authority)
        XCTAssertEqual(storage.stored, record)
        XCTAssertFalse(store.wasIdentityRevoked)

        store.restoreAfterCanceledDeletion()
        store.beginEmailReplacement()
        XCTAssertEqual(store.flow?.purpose, .emailReplacement)
    }

    func testLateSendAfterFreezeCannotRestoreCodeEntryOrConfirmedSendKnowledge() async throws {
        let store = makeStore()
        store.beginVerificationIfNeeded()
        let gate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challenge, gate: gate))
        let send = Task { await store.requestCode(for: email) }
        defer { gate.open() }
        for _ in 0..<500 {
            if gate.isWaiting { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(gate.isWaiting)
        store.freezeForDeletion()
        gate.open()
        await send.value
        XCTAssertNil(store.flow)
        XCTAssertFalse(store.isRequestingCode)

        store.restoreAfterCanceledDeletion()
        store.beginVerificationIfNeeded()
        enqueueCooldown()
        await store.requestCode(for: email)
        XCTAssertEqual(store.flow?.stage, .enteringEmail)
        XCTAssertEqual(store.verificationError, .resendTooSoon)
    }

    func testLateReplacementRedemptionCannotResurrectCompletedParticipant() async throws {
        let record = ParticipantIdentityRecord(
            principal: email, authority: canonicalParticipantAuthorityFixture, verifiedAt: Date()
        )
        let storage = InMemoryParticipantIdentityStorage(stored: record)
        let store = makeStore(storage: storage)
        store.beginEmailReplacement()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challenge))
        await store.requestCode(for: "replacement@nyu.edu")
        let gate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 200,
            data: Data("""
            {"authority":"\(replacementParticipantAuthorityFixture)","participant":{"email":"replacement@nyu.edu"}}
            """.utf8),
            gate: gate
        ))
        let redeem = Task { await store.submitCode("123456") }
        defer { gate.open() }
        for _ in 0..<500 {
            if gate.isWaiting { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(gate.isWaiting)
        store.fenceCompletedDeletion(participantID: participantID)
        gate.open()
        let verified = await redeem.value
        XCTAssertFalse(verified)
        XCTAssertNil(store.flow)
        XCTAssertFalse(store.isVerified)
        XCTAssertNil(store.currentAuthority())
        XCTAssertEqual(storage.stored, record, "Fencing must not bypass checked cleanup or adopt the late replacement.")
        store.beginEmailReplacement()
        store.beginVerificationIfNeeded()
        XCTAssertNil(store.flow)
    }
}
