//
//  AlertSubscriptionService.swift
//  CommonPlateios
//
// Owns `POST /api/subscribe` endpoint knowledge, per docs/system-contract.md.
// Talks to the backend only through APIClient; never calls URLSession
// directly. Contains no SwiftUI state and no user-facing copy, and never
// retries a signup automatically.
//
// This is deliberately separate from RequestService. The request lifecycle and
// the subscription lifecycle share no state, no response shape, and no error
// semantics, and folding one into the other would give both a surface that is
// wrong for at least one of them.
import Foundation

/// Stable backend error codes this service recognizes. Anything else stays an
/// unrecognized code and is reported as a definitive unknown failure rather
/// than guessed at.
enum AlertSubscriptionErrorCode {
    static let invalidEmail = "INVALID_EMAIL"
}

/// Product-safe, structured failure surface for alert signup. Each case is a
/// distinct thing that happened, so presentation can tell the person something
/// true about their next step; mapping cases to copy is the view's job.
enum AlertSubscriptionError: Error {
    /// The backend refused the address: malformed, or not on the NYU domain
    /// allowlist. Definitive — nothing was created.
    case invalidEmail
    /// Public actions are paused, so signup is closed. Definitive, and not an
    /// address problem.
    case publicActionsPaused
    /// Throttled before the handler ran. Definitive; only a manual, later
    /// retry is appropriate.
    case rateLimited
    /// The POST may have been received and applied, but iOS did not receive
    /// and validate a usable accepted response. Never retried automatically.
    case ambiguousSignupOutcome(underlying: Error)
    /// A failure known not to represent an uncertain signup outcome, but with
    /// no specific recovery to offer.
    case unknownFailure(underlying: Error)
}

struct AlertSubscriptionService {
    let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    /// `POST /api/subscribe`
    ///
    /// Returns normally only on the backend's generic accepted response, which
    /// is identical for every subscriber state and therefore proves only that
    /// the request was received — never that an address is new, pending,
    /// confirmed, or that any email was sent.
    func subscribe(email: String) async throws {
        // Cancellation observed here is definitive, and is classified as such
        // on purpose rather than by falling through to a caller's default.
        // Nothing has been encoded or handed to the transport yet, so no
        // signup can have been received, and telling someone their signup
        // "may have been received" would be a claim this path disproves.
        //
        // Cancellation is not one outcome: everything after this point may
        // already have reached the backend, so it is treated as ambiguous
        // below. This split is the whole reason the check is separated out.
        do {
            try Task.checkCancellation()
        } catch {
            throw AlertSubscriptionError.unknownFailure(underlying: error)
        }

        do {
            let _: SubscribeAcceptedDTO = try await client.send(
                path: "/api/subscribe",
                method: .post,
                body: SubscribePayload(email: email)
            )
        } catch is CancellationError {
            // Cancelled during or after transmission. `APIClient` reports
            // cancellation from three points — before `URLSession` is called,
            // from a cancelled transport, and after a response was already
            // received — and only the first is knowably harmless. It is caught
            // above; anything reaching here may have been applied by the
            // backend, so the outcome is uncertain rather than a known failure.
            throw AlertSubscriptionError.ambiguousSignupOutcome(underlying: CancellationError())
        } catch let error as APIClientError {
            throw Self.translate(error)
        } catch {
            throw AlertSubscriptionError.ambiguousSignupOutcome(underlying: error)
        }
    }

    private static func translate(_ error: APIClientError) -> AlertSubscriptionError {
        switch error {
        case .apiError(let code, _):
            switch code {
            case AlertSubscriptionErrorCode.invalidEmail:
                return .invalidEmail
            default:
                // A decoded envelope is the backend deciding and saying so, so
                // the outcome is definitive even when the code is unfamiliar.
                return .unknownFailure(underlying: error)
            }
        // A 404 is definitive at the HTTP level: the route does not exist at
        // this base URL, so no signup was recorded.
        case .unexpectedStatus(404):
            return .unknownFailure(underlying: error)
        case .unexpectedStatus(429):
            return .rateLimited
        // The pause gate refuses `POST /api/subscribe` with a bare
        // `{ "error": "<message>" }` string rather than the structured
        // envelope, so a 503 that carries no decodable envelope is exactly the
        // paused response. Confirmation-email provider failure no longer
        // surfaces as a distinct public status/code at all (W3-N2): the
        // generic accepted response covers that case too.
        case .unexpectedStatus(503):
            return .publicActionsPaused
        // Anything else here is genuinely indeterminate: transport loss or a
        // timeout after the body may already have been sent, an undecodable
        // accepted body, or a status whose response does not prove that no
        // subscriber state changed.
        case .unexpectedStatus, .transport, .decoding:
            return .ambiguousSignupOutcome(underlying: error)
        // Both fail before anything is transmitted.
        case .encoding, .invalidURL:
            return .unknownFailure(underlying: error)
        }
    }
}
