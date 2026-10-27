//
//  ParticipantEmailUnsubscribeService.swift
//  CommonPlateios
//
// Owns `POST /api/participant/email-alerts/unsubscribe` endpoint knowledge
// (W3-N2), per `src/participantEmailUnsubscribeRoute.ts`. Talks to the
// backend only through `APIClient`. Carries no request body: the only input
// is the participant authority credential, sent as
// `x-commonplate-participant`, exactly as `RequestStore` sends it for
// participant-gated request actions.
//
// Deliberately its own service rather than folded into
// `AlertSubscriptionService` or `ParticipantVerificationService`: this
// mutates Subscriber state using participant authority, which is a new,
// narrow relationship between two identities that otherwise stay separate.
import Foundation

enum ParticipantEmailUnsubscribeErrorCode {
    static let verificationRequired = "PARTICIPANT_VERIFICATION_REQUIRED"
    static let authorityInvalid = "PARTICIPANT_AUTHORITY_INVALID"
    static let verificationUnavailable = "PARTICIPANT_VERIFICATION_UNAVAILABLE"
    static let publicActionsPaused = "PUBLIC_ACTIONS_PAUSED"
}

/// Product-safe, structured failure surface. There is deliberately no
/// ambiguous case distinct from `unavailable`: unlike push, this operation is
/// declarative and idempotent in one direction only — retrying it can never
/// silently reassert the wrong desired state, so an uncertain outcome is
/// simply reported as unavailable and safe to retry.
enum ParticipantEmailUnsubscribeError: Error {
    /// No participant credential is held on this device. The caller's next
    /// step is verification, not a retry of this call.
    case verificationRequired
    /// The held credential is not currently usable. The caller's next step is
    /// re-verification.
    case authorityInvalid
    /// Public actions are paused, so this action is closed. Not a credential
    /// problem.
    case publicActionsPaused
    /// Throttled before the handler ran.
    case rateLimited
    /// The backend could not answer, or this call did not receive and
    /// validate a usable response. Never assumed to mean Off.
    case unavailable(underlying: Error)
}

struct ParticipantEmailUnsubscribeService {
    let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    /// Returns normally only on the backend's confirmed declarative Off
    /// result. `authority` is the participant credential this installation
    /// holds; the backend resolves the exact principal to act on from it —
    /// no email or Subscriber ID is ever sent.
    func unsubscribe(authority: String) async throws {
        do {
            try Task.checkCancellation()
        } catch {
            throw ParticipantEmailUnsubscribeError.unavailable(underlying: error)
        }

        do {
            let _: ParticipantEmailUnsubscribeResponseDTO = try await client.send(
                path: "/api/participant/email-alerts/unsubscribe",
                method: .post,
                headers: [RequestService.participantAuthorityHeader: authority]
            )
        } catch is CancellationError {
            throw ParticipantEmailUnsubscribeError.unavailable(underlying: CancellationError())
        } catch let error as APIClientError {
            throw Self.translate(error)
        } catch {
            throw ParticipantEmailUnsubscribeError.unavailable(underlying: error)
        }
    }

    private static func translate(_ error: APIClientError) -> ParticipantEmailUnsubscribeError {
        switch error {
        case .apiError(let code, _):
            switch code {
            case ParticipantEmailUnsubscribeErrorCode.verificationRequired:
                return .verificationRequired
            case ParticipantEmailUnsubscribeErrorCode.authorityInvalid:
                return .authorityInvalid
            case ParticipantEmailUnsubscribeErrorCode.publicActionsPaused:
                return .publicActionsPaused
            case ParticipantEmailUnsubscribeErrorCode.verificationUnavailable:
                return .unavailable(underlying: error)
            default:
                return .unavailable(underlying: error)
            }
        case .unexpectedStatus(429):
            return .rateLimited
        case .unexpectedStatus, .transport, .decoding:
            return .unavailable(underlying: error)
        case .encoding, .invalidURL:
            return .unavailable(underlying: error)
        }
    }
}

struct ParticipantEmailUnsubscribeResponseDTO: Decodable {
    struct Email: Decodable {
        let unsubscribed: Bool
    }
    let email: Email
}
