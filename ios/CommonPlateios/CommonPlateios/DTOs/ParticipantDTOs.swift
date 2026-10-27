//
//  ParticipantDTOs.swift
//  CommonPlateios
//
// Wire-level types for participant verification (W3-I1), per
// docs/system-contract.md. These decode/encode exactly what the backend
// contracts define; nothing here decides lifecycle or presentation.
import Foundation

// MARK: - Challenge

/// `POST /api/participant/verification` — start or resend the emailed code.
struct StartParticipantVerificationPayload: Encodable {
    let email: String
}

/// The challenge's own timings, and deliberately nothing about the address.
/// Whether a participant already exists for it is not something this response
/// may reveal.
struct ParticipantVerificationChallengeDTO: Decodable {
    let expiresAt: Date
    let resendAvailableAt: Date
}

struct StartParticipantVerificationResponseDTO: Decodable {
    let verification: ParticipantVerificationChallengeDTO
}

// MARK: - Redemption

/// `POST /api/participant/verification/redeem`.
struct RedeemParticipantVerificationPayload: Encodable {
    let email: String
    let code: String
}

/// The verified principal. The backend returns the exact normalized address it
/// established, which is what the app remembers and displays — never the
/// student's own typing, which may differ in case or whitespace.
struct VerifiedParticipantDTO: Decodable {
    let email: String
}

/// The one response that establishes participant authority. `authority` is an
/// opaque bearer credential: it is stored on this installation, sent on
/// participant actions, and never displayed, logged, or written anywhere a
/// backup could carry it off this device.
struct RedeemParticipantVerificationResponseDTO: Decodable {
    let participant: VerifiedParticipantDTO
    let authority: String
}

// MARK: - Errors

/// Stable backend participant error codes, centralized so handling cannot
/// drift into scattered string literals — the same reason `ClaimErrorCode`
/// exists.
enum ParticipantErrorCode {
    /// No participant credential was presented. The action needs verification.
    static let verificationRequired = "PARTICIPANT_VERIFICATION_REQUIRED"
    /// A credential was presented and is not usable: malformed, revoked, or
    /// naming a participant the backend no longer has. Distinct from the code
    /// above because the client's next step differs — it must discard what it
    /// stored rather than simply ask for verification.
    static let authorityInvalid = "PARTICIPANT_AUTHORITY_INVALID"
    /// The gate could not decide. Never presented as "you are not verified".
    static let verificationUnavailable = "PARTICIPANT_VERIFICATION_UNAVAILABLE"
    /// The payload named an address other than the verified principal.
    static let principalMismatch = "PARTICIPANT_PRINCIPAL_MISMATCH"

    static let invalidEmail = "INVALID_EMAIL"
    static let resendTooSoon = "VERIFICATION_RESEND_TOO_SOON"
    static let codeInvalid = "VERIFICATION_CODE_INVALID"
    static let codeExpired = "VERIFICATION_CODE_EXPIRED"
    static let codeNotRequested = "VERIFICATION_CODE_NOT_REQUESTED"
    static let attemptsExceeded = "VERIFICATION_ATTEMPTS_EXCEEDED"
    static let emailUnavailable = "VERIFICATION_EMAIL_UNAVAILABLE"
    static let unavailable = "VERIFICATION_UNAVAILABLE"
    /// W4-B1: Change Email refused because the participant has unfinished
    /// requester or helper activity.
    static let replacementBlocked = "EMAIL_REPLACEMENT_BLOCKED"
}

/// W4-B1 unfinished activity that blocks Change Email. Backend-authoritative
/// reasons only; an unrecognized reason is dropped, never guessed into one.
enum EmailReplacementBlocker: String, Equatable, CaseIterable {
    case helping
    case ownRequestHelped
    case ownRequestOpen
}

/// `GET /api/participant/email-replacement-eligibility`
struct EmailReplacementEligibilityDTO: Decodable {
    let eligible: Bool
    let blockers: [String]
}
