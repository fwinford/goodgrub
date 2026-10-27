//
//  SubscriptionDTOs.swift
//  CommonPlateios
//
// Wire-level types for the alert-subscription domain, per
// docs/system-contract.md section 9.1. These decode/encode exactly what the
// backend contract defines and are kept separate from the request DTOs: the
// two domains share no shape and have different privacy rules.
import Foundation

/// Payload for `POST /api/subscribe`. The backend rejects any body with more
/// than this one key, so no other field may be added here. The address is
/// normalized before it reaches this type.
struct SubscribePayload: Encodable {
    let email: String
}

/// Response for `POST /api/subscribe` → HTTP 202 `{ "message": "..." }`.
///
/// The message is optional and is deliberately never displayed. The accepted
/// response is identical for a brand-new, pending, confirmed, or unsubscribed
/// address, so it carries no status to show; the app presents its own truthful
/// copy instead. Optionality keeps a body-wording change on the backend from
/// turning an accepted signup into an ambiguous outcome on the client.
struct SubscribeAcceptedDTO: Decodable {
    let message: String?
}

/// Response for `GET /api/participant/email-alerts/state` (W4-N0) → HTTP 200
/// `{ "email": { "active": Bool } }`. The only truth this route exposes: no
/// Subscriber id, credential, or lifecycle field is ever present here, per
/// `src/emailAlertStateRoute.ts`.
struct EmailAlertStateResponseDTO: Decodable {
    struct Email: Decodable {
        let active: Bool
    }
    let email: Email
}
