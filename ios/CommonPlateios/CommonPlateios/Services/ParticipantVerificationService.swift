//
//  ParticipantVerificationService.swift
//  CommonPlateios
//
// Owns the participant verification endpoints and their DTO-to-domain
// mapping (W3-I1). Talks to the backend only through APIClient; holds no
// SwiftUI state, no stored identity, and no user-facing copy.
import Foundation

/// Product-safe, structured failure surface for participant verification.
///
/// Every case here is a *backend answer* or a definitively-failed attempt.
/// There is deliberately no ambiguous case: neither endpoint is a mutation the
/// client must avoid repeating. Requesting a code again is what Resend is for,
/// and submitting the same code again is answered as the success it already
/// was, so an unreadable response can always be retried without inventing
/// state — which is the one thing a verification client must never do.
enum ParticipantVerificationError: Error, Equatable {
    /// The address is not one that may become a participant.
    case ineligibleEmail(message: String)
    /// A code was requested again too soon. Carries when it reopens, when the
    /// backend said so, so the app can re-enable Resend at the right moment
    /// instead of guessing.
    case resendTooSoon(resendAvailableAt: Date?)
    case codeIncorrect
    case codeExpired
    case codeNotRequested
    case attemptsExceeded
    /// The code could not be mailed, or the backend could not answer.
    case temporarilyUnavailable
    /// W4-B1: the participant has unfinished requester or helper activity, so
    /// Change Email was refused with the existing identity untouched.
    case replacementBlocked
    /// Transport, decoding, or an unmapped status. Nothing was established.
    case couldNotReachBackend

    static func == (
        lhs: ParticipantVerificationError,
        rhs: ParticipantVerificationError
    ) -> Bool {
        switch (lhs, rhs) {
        case (.ineligibleEmail(let left), .ineligibleEmail(let right)):
            return left == right
        case (.resendTooSoon(let left), .resendTooSoon(let right)):
            return left == right
        case (.codeIncorrect, .codeIncorrect),
             (.codeExpired, .codeExpired),
             (.codeNotRequested, .codeNotRequested),
             (.attemptsExceeded, .attemptsExceeded),
             (.temporarilyUnavailable, .temporarilyUnavailable),
             (.replacementBlocked, .replacementBlocked),
             (.couldNotReachBackend, .couldNotReachBackend):
            return true
        default:
            return false
        }
    }
}

/// What a started challenge tells the app: nothing about the address, only
/// about the challenge.
struct ParticipantVerificationChallenge: Equatable {
    let expiresAt: Date
    let resendAvailableAt: Date
}

/// Backend-established participant authority. `authority` is an opaque bearer
/// credential; `principal` is the exact normalized address the backend
/// verified, which is what the app remembers and shows.
struct VerifiedParticipantIdentity: Equatable {
    let principal: String
    let authority: String
}

struct ParticipantVerificationService {
    let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    /// `POST /api/participant/verification`
    ///
    /// `replacingAuthority` is the current credential, sent only by Change
    /// Email so the backend can apply the active-activity gate. First-time
    /// verification passes `nil` and sends no credential.
    func startVerification(
        email: String,
        replacingAuthority: String? = nil
    ) async throws -> ParticipantVerificationChallenge {
        try Task.checkCancellation()
        do {
            let response: StartParticipantVerificationResponseDTO = try await client.send(
                path: "/api/participant/verification",
                method: .post,
                body: StartParticipantVerificationPayload(email: email),
                headers: Self.replacementHeaders(replacingAuthority)
            )
            return ParticipantVerificationChallenge(
                expiresAt: response.verification.expiresAt,
                resendAvailableAt: response.verification.resendAvailableAt
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.translate(error)
        }
    }

    /// `POST /api/participant/verification/redeem`
    ///
    /// The only call that can establish identity. A response this method cannot
    /// fully decode is an error, never a partial success: an app that kept the
    /// principal without the credential, or vice versa, would be fabricating
    /// verification the backend never granted.
    func redeemVerification(
        email: String,
        code: String,
        replacingAuthority: String? = nil
    ) async throws -> VerifiedParticipantIdentity {
        try Task.checkCancellation()
        do {
            let response: RedeemParticipantVerificationResponseDTO = try await client.send(
                path: "/api/participant/verification/redeem",
                method: .post,
                body: RedeemParticipantVerificationPayload(email: email, code: code),
                headers: Self.replacementHeaders(replacingAuthority)
            )
            guard ParticipantAuthorityShape.isCanonical(response.authority),
                  !response.participant.email.isEmpty else {
                throw ParticipantVerificationError.couldNotReachBackend
            }
            return VerifiedParticipantIdentity(
                principal: response.participant.email,
                authority: response.authority
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ParticipantVerificationError {
            throw error
        } catch {
            throw Self.translate(error)
        }
    }

    /// `GET /api/participant/email-replacement-eligibility`
    ///
    /// Read-only. Any answer other than a decoded one is an error, so the
    /// caller fails closed instead of assuming the participant is eligible.
    func readEmailReplacementEligibility(
        authority: String
    ) async throws -> [EmailReplacementBlocker] {
        try Task.checkCancellation()
        do {
            let response: EmailReplacementEligibilityDTO = try await client.send(
                path: "/api/participant/email-replacement-eligibility",
                method: .get,
                headers: [RequestService.participantAuthorityHeader: authority]
            )
            let blockers = response.blockers.compactMap(EmailReplacementBlocker.init(rawValue:))
            // Contradictory answers are unknown, never eligible.
            if response.eligible && !blockers.isEmpty {
                throw ParticipantVerificationError.couldNotReachBackend
            }
            // Blocked for a reason this app does not recognize is still blocked.
            if !response.eligible && blockers.isEmpty {
                throw ParticipantVerificationError.replacementBlocked
            }
            return blockers
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ParticipantVerificationError {
            throw error
        } catch {
            throw Self.translate(error)
        }
    }

    private static func replacementHeaders(_ authority: String?) -> [String: String] {
        guard let authority else { return [:] }
        return [RequestService.participantAuthorityHeader: authority]
    }

    /// Maps a decoded envelope to the structured surface above. An unmapped
    /// code is never guessed into a specific meaning — it becomes
    /// `couldNotReachBackend`, which asks the student to try again rather than
    /// telling them something untrue about their code.
    private static func translate(_ error: Error) -> ParticipantVerificationError {
        guard let clientError = error as? APIClientError else {
            return .couldNotReachBackend
        }

        switch clientError {
        case .apiError(let code, let message):
            switch code {
            case ParticipantErrorCode.invalidEmail:
                return .ineligibleEmail(message: message)
            case ParticipantErrorCode.resendTooSoon:
                // The reopening instant lives beside the code in the envelope;
                // the generic decoder does not carry it, so a nil here simply
                // means the app falls back to its own cooldown display.
                return .resendTooSoon(resendAvailableAt: nil)
            case ParticipantErrorCode.codeInvalid:
                return .codeIncorrect
            case ParticipantErrorCode.codeExpired:
                return .codeExpired
            case ParticipantErrorCode.codeNotRequested:
                return .codeNotRequested
            case ParticipantErrorCode.attemptsExceeded:
                return .attemptsExceeded
            case ParticipantErrorCode.replacementBlocked:
                return .replacementBlocked
            case ParticipantErrorCode.emailUnavailable,
                 ParticipantErrorCode.unavailable:
                return .temporarilyUnavailable
            default:
                return .couldNotReachBackend
            }
        case .transport, .decoding, .encoding, .invalidURL, .unexpectedStatus:
            return .couldNotReachBackend
        }
    }
}
