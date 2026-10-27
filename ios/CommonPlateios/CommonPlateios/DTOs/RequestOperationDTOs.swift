//
//  RequestOperationDTOs.swift
//  CommonPlateios
//
// W4-D2 exact-operation terminal reconciliation wire shapes
// (`POST /api/request-operation/terminal`, `src/requestOperationTerminalRoute.ts`,
// and `GET /api/request-operation/authority`, `src/requestOperationAuthority.ts`).
import Foundation

/// The terminal outcome discriminator the backend answers with. An
/// unrecognized value fails decoding, which the caller treats as
/// inconclusive — never as either outcome.
enum RequestOperationTerminalOutcomeWire: String, Decodable {
    case created
    case notCreated = "not-created"
}

/// `200 { outcome: "created", request }` or `200 { outcome: "not-created" }`.
struct RequestOperationTerminalResponseDTO: Decodable {
    let outcome: RequestOperationTerminalOutcomeWire
    let request: RequestResponseDTO?
}

/// `GET /api/request-operation/authority`: the ledger identity behind this
/// backend right now.
struct RequestOperationAuthorityResponseDTO: Decodable {
    let operationAuthority: String
}

/// Backend terminal authority's answer for one exact create operation.
enum RequestOperationTerminalOutcome {
    /// This exact operation created this Request.
    case created(FoodRequest)
    /// Terminal NO-CREATE: this exact operation never created a Request and
    /// never will.
    case notCreated
}
