//
//  InstallationPushService.swift
//  CommonPlateios
//
// Owns `PUT /api/installations/push` endpoint knowledge, per
// `src/installationPushRoute.ts` (Week 3 Day 6 Slice 6A). Talks to the
// backend only through `APIClient`, never `URLSession` directly, and never
// retries a synchronization automatically — matching
// `AlertSubscriptionService`, which this deliberately parallels rather than
// extends: push and email share no domain, response shape, or error surface.
import Foundation

/// Stable backend error codes this service recognizes.
enum InstallationPushErrorCode {
    static let invalidRequest = "INVALID_INSTALLATION_REQUEST"
    static let publicActionsPaused = "PUBLIC_ACTIONS_PAUSED"
}

enum InstallationPushSyncError: Error {
    case participantAuthorityRequired
    /// The request body itself was malformed. Should not occur from this
    /// client's own construction; definitive when it does.
    case invalidRequest
    /// Public actions are paused, so installation registration is closed.
    /// Definitive, and not a device or permission problem.
    case publicActionsPaused
    /// Throttled before the handler ran. Definitive; only a manual, later
    /// retry is appropriate.
    case rateLimited
    /// The request may have been received and applied, but this call did not
    /// receive and validate a usable response. Never retried automatically.
    case ambiguousOutcome(underlying: Error)
    /// A failure known not to represent an uncertain outcome, but with no
    /// specific recovery to offer.
    case unknownFailure(underlying: Error)
}

@MainActor
struct InstallationPushService {
    let client: APIClient
    private let nextMutationVersion: () -> Int?
    private let participantIdentityStore: ParticipantIdentityStore?

    init(
        client: APIClient,
        nextMutationVersion: @escaping () -> Int? = { nil },
        participantIdentityStore: ParticipantIdentityStore? = nil
    ) {
        self.client = client
        self.nextMutationVersion = nextMutationVersion
        self.participantIdentityStore = participantIdentityStore
    }

    /// Enable or refresh: reports this installation's credential, current
    /// APNs token, and environment. Returns the backend-confirmed enabled
    /// state — the only thing the response contains.
    func synchronizeEnabled(
        credential: String,
        apnsToken: String,
        environment: APNsEnvironment
    ) async throws -> Bool {
        guard let authority = participantIdentityStore?.currentAuthority(),
              !authority.isEmpty else {
            throw InstallationPushSyncError.participantAuthorityRequired
        }
        return try await send(
            InstallationPushEnableRequest(
                installationCredential: credential,
                apnsToken: apnsToken,
                environment: environment.rawValue,
                mutationVersion: nextMutationVersion()
            ),
            authority: authority
        )
    }

    /// Disable: reports only the credential. No token or environment key is
    /// ever encoded, matching the backend's stricter disable contract.
    func synchronizeDisabled(credential: String) async throws -> Bool {
        try await send(InstallationPushDisableRequest(
            installationCredential: credential, mutationVersion: nextMutationVersion()
        ))
    }

    func synchronizeAssociation(credential: String, authority: String?) async throws -> Bool {
        do {
            try Task.checkCancellation()
        } catch {
            throw InstallationPushSyncError.unknownFailure(underlying: error)
        }
        do {
            let response: InstallationAssociationResponse = try await client.send(
                path: "/api/installations/push",
                method: .put,
                body: InstallationAssociationRequest(
                    installationCredential: credential,
                    association: authority == nil ? "clear" : "replace",
                    mutationVersion: nextMutationVersion()
                ),
                headers: authority.map { ["x-commonplate-participant": $0] } ?? [:]
            )
            guard response.association.confirmed,
                  authority != nil || !response.push.enabled else {
                throw InstallationPushSyncError.ambiguousOutcome(underlying: URLError(.badServerResponse))
            }
            return response.push.enabled
        } catch let error as InstallationPushSyncError {
            throw error
        } catch let error as APIClientError {
            throw Self.translate(error)
        } catch {
            throw InstallationPushSyncError.ambiguousOutcome(underlying: error)
        }
    }

    private func send<Body: Encodable>(_ body: Body, authority: String? = nil) async throws -> Bool {
        // Mirrors `AlertSubscriptionService.subscribe`: cancellation observed
        // here is definitive, because nothing has been encoded or handed to
        // the transport yet. Cancellation observed after this point may
        // already have reached the backend and is treated as ambiguous below.
        do {
            try Task.checkCancellation()
        } catch {
            throw InstallationPushSyncError.unknownFailure(underlying: error)
        }

        do {
            let response: InstallationPushResponseDTO = try await client.send(
                path: "/api/installations/push",
                method: .put,
                body: body,
                headers: authority.map { ["x-commonplate-participant": $0] } ?? [:]
            )
            return response.push.enabled
        } catch is CancellationError {
            throw InstallationPushSyncError.ambiguousOutcome(underlying: CancellationError())
        } catch let error as APIClientError {
            throw Self.translate(error)
        } catch {
            throw InstallationPushSyncError.ambiguousOutcome(underlying: error)
        }
    }

    private static func translate(_ error: APIClientError) -> InstallationPushSyncError {
        switch error {
        case .apiError(let code, _):
            switch code {
            case InstallationPushErrorCode.invalidRequest:
                return .invalidRequest
            case InstallationPushErrorCode.publicActionsPaused:
                return .publicActionsPaused
            default:
                // A decoded envelope is the backend deciding and saying so,
                // so the outcome is definitive even when the code is
                // unfamiliar (for example `INTERNAL_FAILURE`, which this
                // client has no specific recovery for).
                return .unknownFailure(underlying: error)
            }
        case .unexpectedStatus(404):
            return .unknownFailure(underlying: error)
        case .unexpectedStatus(429):
            return .rateLimited
        // Unlike `POST /api/subscribe`, this endpoint's pause response
        // always carries the structured envelope (`app.ts` registers it with
        // `"PUBLIC_ACTIONS_PAUSED"`), so a bare 503 with no decodable
        // envelope is not this endpoint's known paused shape — it is
        // genuinely indeterminate, like any other undecodable status.
        case .unexpectedStatus, .transport, .decoding:
            return .ambiguousOutcome(underlying: error)
        // Both fail before anything is transmitted.
        case .encoding, .invalidURL:
            return .unknownFailure(underlying: error)
        }
    }
}
