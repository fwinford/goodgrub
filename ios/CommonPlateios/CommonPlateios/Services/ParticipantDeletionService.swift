import Foundation

enum ParticipantDeletionPhase: String, Codable {
    case waiting, ready, challengeIssued, authorized, completed, canceled
}

struct ParticipantDeletionStatus: Codable, Equatable {
    struct Challenge: Codable, Equatable {
        let expiresAt: Date
        let cooldownEndsAt: Date
        let attemptsRemaining: Int
    }

    struct Authorization: Codable, Equatable {
        let expiresAt: Date
    }

    let operationId: String
    let namespaceBinding: String
    let phase: ParticipantDeletionPhase
    let readinessGeneration: Int
    let challenge: Challenge?
    let authorization: Authorization?
    fileprivate let recoveryCapability: String?

    static func isNamespaceBinding(_ value: String) -> Bool {
        value.count == 68 && value.hasPrefix("dn1_") &&
            value.dropFirst(4).unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdef").contains($0)
            }
    }

    func validated(
        operationID: String? = nil,
        namespace: String? = nil
    ) throws -> Self {
        guard UUID(uuidString: operationId) != nil,
              Self.isNamespaceBinding(namespaceBinding),
              operationID == nil || operationID == operationId,
              namespace == nil || namespace == namespaceBinding,
              readinessGeneration >= 0 else {
            throw ParticipantDeletionError.invalidResponse
        }
        if phase == .challengeIssued {
            guard let challenge,
                  (0...5).contains(challenge.attemptsRemaining),
                  challenge.expiresAt.timeIntervalSince1970.isFinite,
                  challenge.cooldownEndsAt.timeIntervalSince1970.isFinite else {
                throw ParticipantDeletionError.invalidResponse
            }
        }
        if phase == .authorized, authorization == nil {
            throw ParticipantDeletionError.invalidResponse
        }
        return self
    }

    // The capability never enters view-readable status or a non-secure journal.
    func withoutCapability() -> Self {
        Self(
            operationId: operationId, namespaceBinding: namespaceBinding,
            phase: phase, readinessGeneration: readinessGeneration,
            challenge: challenge, authorization: authorization,
            recoveryCapability: nil
        )
    }
}

struct ParticipantDeletionEligibility: Decodable, Equatable {
    enum Category: String, Decodable {
        case activeRequest, activeHelpingOrPickup, unknown
    }
    let eligible: Bool
    let categories: [Category]
}

enum ParticipantDeletionError: Error {
    case invalidResponse
    case storageUnavailable
    case identityChanged
    case unresolved
}

struct ParticipantDeletionRedemption {
    let status: ParticipantDeletionStatus
    let capability: String
}

private struct DeletionOperationBody: Encodable {
    let operationId: String
}

private struct DeletionChallengeBody: Encodable {
    let operationId: String
    let readinessGeneration: Int
}

private struct DeletionRedeemBody: Encodable {
    let operationId: String
    let readinessGeneration: Int
    let code: String
}

private struct DeletionCompleteBody: Encodable {
    let operationId: String
    let readinessGeneration: Int
    let capability: String
}

private struct DeletionRecoveryBody: Encodable {
    let operationId: String
    let capability: String
}

private struct DeletionProvenanceBody: Encodable {
    let operationId: String
    let recordedLedger: String
}

private struct DeletionComparisonResponse: Decodable {
    let matches: Bool
}

private struct DeletionCompletionResponse: Decodable {
    enum Outcome: String, Decodable { case completed }
    let outcome: Outcome
}

extension RequestService {
    static let deletionNamespaceHeader = "x-commonplate-deletion-namespace"

    private func deletionHeaders(authority: String?, namespace: String? = nil) throws -> [String: String] {
        var headers: [String: String] = [:]
        if let authority {
            guard ParticipantAuthorityShape.isCanonical(authority) else {
                throw ParticipantDeletionError.identityChanged
            }
            headers[Self.participantAuthorityHeader] = authority
        }
        if let namespace {
            guard ParticipantDeletionStatus.isNamespaceBinding(namespace) else {
                throw ParticipantDeletionError.invalidResponse
            }
            headers[Self.deletionNamespaceHeader] = namespace
        }
        return headers
    }

    func deletionEligibility(authority: String) async throws -> ParticipantDeletionEligibility {
        let response: ParticipantDeletionEligibility = try await client.send(
            path: "/api/participant/deletion/eligibility", method: .get,
            headers: try deletionHeaders(authority: authority)
        )
        guard response.eligible == response.categories.isEmpty else {
            throw ParticipantDeletionError.invalidResponse
        }
        return response
    }

    func startDeletion(authority: String) async throws -> ParticipantDeletionStatus {
        let response: ParticipantDeletionStatus = try await client.send(
            path: "/api/participant/deletion", method: .post,
            headers: try deletionHeaders(authority: authority)
        )
        return try response.validated().withoutCapability()
    }

    func deletionStatus(
        operationID: String, namespace: String, authority: String
    ) async throws -> ParticipantDeletionStatus {
        guard UUID(uuidString: operationID) != nil else {
            throw ParticipantDeletionError.invalidResponse
        }
        let response: ParticipantDeletionStatus = try await client.send(
            path: "/api/participant/deletion/status?operationId=\(operationID)", method: .get,
            headers: try deletionHeaders(authority: authority, namespace: namespace)
        )
        return try response.validated(operationID: operationID, namespace: namespace).withoutCapability()
    }

    func cancelDeletion(
        operationID: String, namespace: String, authority: String
    ) async throws -> ParticipantDeletionStatus {
        let response: ParticipantDeletionStatus = try await client.send(
            path: "/api/participant/deletion/cancel", method: .post,
            body: DeletionOperationBody(operationId: operationID),
            headers: try deletionHeaders(authority: authority, namespace: namespace)
        )
        return try response.validated(operationID: operationID, namespace: namespace).withoutCapability()
    }

    func challengeDeletion(
        status: ParticipantDeletionStatus, authority: String
    ) async throws -> ParticipantDeletionStatus {
        let response: ParticipantDeletionStatus = try await client.send(
            path: "/api/participant/deletion/challenge", method: .post,
            body: DeletionChallengeBody(
                operationId: status.operationId, readinessGeneration: status.readinessGeneration
            ),
            headers: try deletionHeaders(authority: authority, namespace: status.namespaceBinding)
        )
        let validated = try response.validated(
            operationID: status.operationId, namespace: status.namespaceBinding
        )
        guard validated.phase == .challengeIssued else { throw ParticipantDeletionError.invalidResponse }
        return validated.withoutCapability()
    }

    func redeemDeletion(
        status: ParticipantDeletionStatus, code: String, authority: String
    ) async throws -> ParticipantDeletionRedemption {
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw ParticipantDeletionError.invalidResponse
        }
        let response: ParticipantDeletionStatus = try await client.send(
            path: "/api/participant/deletion/redeem", method: .post,
            body: DeletionRedeemBody(
                operationId: status.operationId,
                readinessGeneration: status.readinessGeneration, code: code
            ),
            headers: try deletionHeaders(authority: authority, namespace: status.namespaceBinding)
        )
        let validated = try response.validated(
            operationID: status.operationId, namespace: status.namespaceBinding
        )
        guard validated.phase == .authorized, let capability = validated.recoveryCapability,
              !capability.isEmpty else { throw ParticipantDeletionError.invalidResponse }
        return ParticipantDeletionRedemption(status: validated.withoutCapability(), capability: capability)
    }

    func compareDeletionLedger(
        status: ParticipantDeletionStatus, recordedLedger: String, authority: String
    ) async throws -> Bool {
        guard RequestOperationAuthorityIdentity.isValidLedger(recordedLedger) else {
            throw ParticipantDeletionError.invalidResponse
        }
        let response: DeletionComparisonResponse = try await client.send(
            path: "/api/participant/deletion/provenance", method: .post,
            body: DeletionProvenanceBody(operationId: status.operationId, recordedLedger: recordedLedger),
            headers: try deletionHeaders(authority: authority, namespace: status.namespaceBinding)
        )
        return response.matches
    }

    func completeDeletion(
        status: ParticipantDeletionStatus, capability: String, authority: String
    ) async throws {
        let _: DeletionCompletionResponse = try await client.send(
            path: "/api/participant/deletion/complete", method: .post,
            body: DeletionCompleteBody(
                operationId: status.operationId,
                readinessGeneration: status.readinessGeneration, capability: capability
            ),
            headers: try deletionHeaders(authority: authority, namespace: status.namespaceBinding)
        )
    }

    func recoverDeletion(
        operationID: String, namespace: String, capability: String
    ) async throws {
        let _: DeletionCompletionResponse = try await client.send(
            path: "/api/participant/deletion/recovery", method: .post,
            body: DeletionRecoveryBody(operationId: operationID, capability: capability),
            headers: try deletionHeaders(authority: nil, namespace: namespace)
        )
    }
}
