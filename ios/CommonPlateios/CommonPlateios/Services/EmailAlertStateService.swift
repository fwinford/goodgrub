//
//  EmailAlertStateService.swift
//  CommonPlateios
//
// Owns `GET /api/participant/email-alerts/state` endpoint knowledge (W4-N0),
// per `src/emailAlertStateRoute.ts`. Talks to the backend only through
// `APIClient`. Carries no request body and no query parameters: the only
// input is the participant authority credential, sent as
// `x-commonplate-participant`, exactly as `RequestStore` sends it for other
// participant-gated reads.
//
// Deliberately its own service rather than folded into
// `ParticipantEmailUnsubscribeService` or `AlertSubscriptionService`: this
// reads current Subscriber truth for a verified participant, a different
// relationship than either existing service's mutation.
import Foundation

enum EmailAlertStateErrorCode {
    static let verificationRequired = "PARTICIPANT_VERIFICATION_REQUIRED"
    static let authorityInvalid = "PARTICIPANT_AUTHORITY_INVALID"
    static let verificationUnavailable = "PARTICIPANT_VERIFICATION_UNAVAILABLE"
}

/// Product-safe, structured failure surface. There is deliberately no case
/// that reads as "Off": every failure is either a credential problem the
/// caller must resolve through (re)verification, or `unavailable`, which
/// callers must treat as unknown rather than authoritative Off.
enum EmailAlertStateError: Error {
    /// No participant credential is held on this device.
    case verificationRequired
    /// The held credential is not currently usable.
    case authorityInvalid
    /// The backend could not answer, or this call did not receive and
    /// validate a usable response. Never assumed to mean Off.
    case unavailable(underlying: Error)
}

struct EmailAlertStateService {
    let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    /// Returns the backend's authoritative current Email Request Alert state
    /// for the exact verified participant `authority` resolves to. `true`
    /// means the current verified email is presently an active/confirmed
    /// Email Request Alerts subscriber; `false` means it is not.
    func fetchEmailAlertState(authority: String) async throws -> Bool {
        do {
            try Task.checkCancellation()
        } catch {
            throw EmailAlertStateError.unavailable(underlying: error)
        }

        do {
            let response: EmailAlertStateResponseDTO = try await client.send(
                path: "/api/participant/email-alerts/state",
                method: .get,
                headers: [RequestService.participantAuthorityHeader: authority]
            )
            return response.email.active
        } catch is CancellationError {
            throw EmailAlertStateError.unavailable(underlying: CancellationError())
        } catch let error as APIClientError {
            throw Self.translate(error)
        } catch {
            throw EmailAlertStateError.unavailable(underlying: error)
        }
    }

    private static func translate(_ error: APIClientError) -> EmailAlertStateError {
        switch error {
        case .apiError(let code, _):
            switch code {
            case EmailAlertStateErrorCode.verificationRequired:
                return .verificationRequired
            case EmailAlertStateErrorCode.authorityInvalid:
                return .authorityInvalid
            case EmailAlertStateErrorCode.verificationUnavailable:
                return .unavailable(underlying: error)
            default:
                return .unavailable(underlying: error)
            }
        case .unexpectedStatus, .transport, .decoding, .encoding, .invalidURL:
            return .unavailable(underlying: error)
        }
    }
}
