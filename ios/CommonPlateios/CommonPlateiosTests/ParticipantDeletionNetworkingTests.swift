import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class ParticipantDeletionNetworkingTests: XCTestCase {
    let operation = "a3f1c2b4-5e6d-4a1b-8c9d-0e1f2a3b4c5d"
    let namespace = "dn1_" + String(repeating: "a", count: 64)

    override func tearDown() {
        ParticipantEmailUnsubscribeURLProtocol.reset()
        super.tearDown()
    }

    func service(fence: ParticipantDeletionNetworkFence? = nil) -> RequestService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ParticipantEmailUnsubscribeURLProtocol.self]
        return RequestService(client: APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://example.test")!),
            session: URLSession(configuration: config), deletionFence: fence
        ))
    }

    func enqueue(_ object: [String: Any], status: Int = 200, delay: TimeInterval = 0) throws {
        ParticipantEmailUnsubscribeURLProtocol.enqueue(.response(
            statusCode: status, data: try JSONSerialization.data(withJSONObject: object), delay: delay
        ))
    }

    func response(phase: String = "ready", namespace: String? = nil) -> [String: Any] {
        var object: [String: Any] = [
            "operationId": operation, "namespaceBinding": namespace ?? self.namespace,
            "phase": phase, "readinessGeneration": 2,
        ]
        if phase == "challengeIssued" {
            object["challenge"] = [
                "expiresAt": "2026-10-24T20:10:00.000Z",
                "cooldownEndsAt": "2026-10-24T20:01:00.000Z", "attemptsRemaining": 5,
            ]
        }
        if phase == "authorized" {
            object["authorization"] = ["expiresAt": "2026-10-24T20:05:00.000Z"]
        }
        return object
    }

    func status(phase: String = "ready") throws -> ParticipantDeletionStatus {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let value = formatter.date(from: raw) else {
                throw ParticipantDeletionError.invalidResponse
            }
            return value
        }
        return try decoder.decode(
            ParticipantDeletionStatus.self, from: JSONSerialization.data(withJSONObject: response(phase: phase))
        )
    }

    func testEligibilityAndWaitingAreBackendTruthAndStartNeverChallenges() async throws {
        let service = service()
        try enqueue(["eligible": false, "categories": ["activeRequest"]])
        let eligibility = try await service.deletionEligibility(authority: canonicalParticipantAuthorityFixture)
        XCTAssertFalse(eligibility.eligible)
        try enqueue(response(phase: "waiting"), status: 201)
        let waiting = try await service.startDeletion(authority: canonicalParticipantAuthorityFixture)
        XCTAssertEqual(waiting.phase, .waiting)
        XCTAssertEqual(waiting.namespaceBinding, namespace)
        XCTAssertEqual(ParticipantEmailUnsubscribeURLProtocol.capturedRequests.map(\.path), [
            "/api/participant/deletion/eligibility", "/api/participant/deletion",
        ])
    }

    func testContradictoryEligibilityFailsClosed() async throws {
        try enqueue(["eligible": true, "categories": ["activeRequest"]])
        do {
            _ = try await service().deletionEligibility(authority: canonicalParticipantAuthorityFixture)
            XCTFail("contradictory eligibility must not establish readiness")
        } catch {}
    }

    func testStatusBindsExactOperationAndOpaqueNamespaceWithoutDerivingIt() async throws {
        let service = service()
        try enqueue(response())
        _ = try await service.deletionStatus(
            operationID: operation, namespace: namespace, authority: canonicalParticipantAuthorityFixture
        )
        let captured = try XCTUnwrap(ParticipantEmailUnsubscribeURLProtocol.capturedRequests.last)
        XCTAssertEqual(captured.headers[RequestService.deletionNamespaceHeader], namespace)
        try enqueue(response(namespace: "dn1_" + String(repeating: "b", count: 64)))
        do {
            _ = try await service.deletionStatus(
                operationID: operation, namespace: namespace, authority: canonicalParticipantAuthorityFixture
            )
            XCTFail("foreign namespace must not advance state")
        } catch {}
    }

    func testMissingMalformedOrUnknownStartResponsesFailClosed() async throws {
        for mutation in ["missing", "malformed", "unknown-phase", "invalid-generation", "wrong-type"] {
            var object = response()
            if mutation == "missing" { object.removeValue(forKey: "namespaceBinding") }
            if mutation == "malformed" { object["namespaceBinding"] = "dn1_bad" }
            if mutation == "unknown-phase" { object["phase"] = "deleted" }
            if mutation == "invalid-generation" { object["readinessGeneration"] = -1 }
            if mutation == "wrong-type" { object["namespaceBinding"] = [namespace] }
            try enqueue(object)
            do {
                _ = try await service().startDeletion(authority: canonicalParticipantAuthorityFixture)
                XCTFail("invalid start response: \(mutation)")
            } catch {}
        }
    }

    func testDeletionSpecificChallengeAndRedeemNeverCallOrdinaryVerification() async throws {
        let service = service()
        try enqueue(response(phase: "challengeIssued"), status: 202)
        let challenge = try await service.challengeDeletion(
            status: status(), authority: canonicalParticipantAuthorityFixture
        )
        XCTAssertEqual(challenge.challenge?.attemptsRemaining, 5)
        XCTAssertNotNil(challenge.challenge?.expiresAt)
        var redeemed = response(phase: "authorized")
        redeemed["recoveryCapability"] = "opaque-test-recovery-capability"
        try enqueue(redeemed)
        let authorized = try await service.redeemDeletion(
            status: challenge, code: "123456", authority: canonicalParticipantAuthorityFixture
        )
        XCTAssertEqual(authorized.status.phase, .authorized)
        XCTAssertEqual(authorized.capability, "opaque-test-recovery-capability")
        let encodedStatus = try JSONEncoder().encode(authorized.status)
        XCTAssertFalse(String(decoding: encodedStatus, as: UTF8.self).contains("opaque-test-recovery-capability"))
        XCTAssertEqual(ParticipantEmailUnsubscribeURLProtocol.capturedRequests.map(\.path), [
            "/api/participant/deletion/challenge", "/api/participant/deletion/redeem",
        ])
    }

    func testRedeemRequiresSixASCIIDigitsAndOpaqueCapability() async throws {
        let service = service()
        for code in ["12345", "1234567", "１２３４５６", "12a456"] {
            do {
                _ = try await service.redeemDeletion(
                    status: status(phase: "challengeIssued"), code: code,
                    authority: canonicalParticipantAuthorityFixture
                )
                XCTFail("invalid deletion code")
            } catch {}
        }
        XCTAssertTrue(ParticipantEmailUnsubscribeURLProtocol.capturedRequests.isEmpty)
        try enqueue(response(phase: "authorized"))
        do {
            _ = try await service.redeemDeletion(
                status: status(phase: "challengeIssued"), code: "123456",
                authority: canonicalParticipantAuthorityFixture
            )
            XCTFail("authorization without recovery capability is unavailable")
        } catch {}
    }

    func testCompleteIsExplicitAndRecoveryDoesNotUseParticipantAuthority() async throws {
        let service = service()
        try enqueue(["outcome": "completed"])
        try await service.completeDeletion(
            status: status(phase: "authorized"), capability: "opaque", authority: canonicalParticipantAuthorityFixture
        )
        try enqueue(["outcome": "completed"])
        try await service.recoverDeletion(operationID: operation, namespace: namespace, capability: "opaque")
        let captures = ParticipantEmailUnsubscribeURLProtocol.capturedRequests
        XCTAssertEqual(captures.map(\.path), [
            "/api/participant/deletion/complete", "/api/participant/deletion/recovery",
        ])
        XCTAssertNil(captures.last?.headers[RequestService.participantAuthorityHeader])
        XCTAssertEqual(captures.last?.headers[RequestService.deletionNamespaceHeader], namespace)
    }

    func testMalformedCompletionAndUnavailableRecoveryNeverSucceed() async throws {
        let service = service()
        for object in [["outcome": "unknown"], ["outcome": "ready"], [:]] {
            try enqueue(object)
            do {
                try await service.recoverDeletion(operationID: operation, namespace: namespace, capability: "opaque")
                XCTFail("must not fabricate completion")
            } catch {}
        }
        try enqueue(["error": ["code": "PARTICIPANT_VERIFICATION_UNAVAILABLE", "message": "Unavailable"]], status: 503)
        do {
            try await service.recoverDeletion(operationID: operation, namespace: namespace, capability: "opaque")
            XCTFail("expired/unavailable capability is not completion")
        } catch {}
    }

    func testComparisonConsumesOnlyServerBooleanAndCancelUsesExactNamespace() async throws {
        let service = service()
        try enqueue(["matches": false])
        let matches = try await service.compareDeletionLedger(
            status: status(), recordedLedger: "b3f1c2b4-5e6d-4a1b-8c9d-0e1f2a3b4c5d",
            authority: canonicalParticipantAuthorityFixture
        )
        XCTAssertFalse(matches)
        try enqueue(response(phase: "canceled"))
        let canceled = try await service.cancelDeletion(
            operationID: operation, namespace: namespace, authority: canonicalParticipantAuthorityFixture
        )
        XCTAssertEqual(canceled.phase, .canceled)
    }

    func testFreezeRejectsLateOrdinaryCallbacksEvenAfterCancelButAllowsDeletionRecovery() async throws {
        let fence = ParticipantDeletionNetworkFence()
        let service = service(fence: fence)
        try enqueue(["requests": []], delay: 0.15)
        let read = Task { try await service.fetchActiveRequests(participantAuthority: canonicalParticipantAuthorityFixture) }
        while ParticipantEmailUnsubscribeURLProtocol.capturedRequests.isEmpty { await Task.yield() }
        fence.setFrozen(true)
        fence.setFrozen(false)
        do {
            _ = try await read.value
            XCTFail("a retired ordinary response must not publish")
        } catch {}
        fence.setFrozen(true)
        try enqueue(["outcome": "completed"])
        try await service.recoverDeletion(operationID: operation, namespace: namespace, capability: "opaque")
    }
}
