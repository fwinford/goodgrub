//
//  InstallationPushDTOs.swift
//  CommonPlateios
//
// Wire-level types for `PUT /api/installations/push`
// (`src/installationPushRoute.ts`, Week 3 Day 6 Slice 6A). Kept separate from
// `SubscriptionDTOs.swift`: push and email share no endpoint, no response
// shape, and no privacy rule.
//
// Two distinct request types rather than one with optional fields, so an
// enabled request missing a token and a disabled request carrying one are
// both impossible to construct, not merely invalid at runtime. The backend's
// body schema is `.strict()` on both branches: a disable body that includes
// `apnsToken` or `environment` is rejected outright, so this client must
// never send either key when disabling — not even as `null`.
import Foundation

/// `{"installationCredential", "enabled": true, "apnsToken", "environment"}`
struct InstallationPushEnableRequest: Encodable {
    let installationCredential: String
    let enabled = true
    let apnsToken: String
    let environment: String
    var mutationVersion: Int? = nil
}

/// `{"installationCredential", "enabled": false}` — no `apnsToken` key and no
/// `environment` key are ever present.
struct InstallationPushDisableRequest: Encodable {
    let installationCredential: String
    let enabled = false
    var mutationVersion: Int? = nil
}

struct InstallationAssociationRequest: Encodable {
    let installationCredential: String
    let association: String
    var mutationVersion: Int? = nil
}

struct InstallationAssociationResponse: Decodable {
    struct Association: Decodable {
        let confirmed: Bool
    }
    let association: Association
    let push: InstallationPushResponseDTO.State
}

/// `{"push": {"enabled": Bool}}` — the only response shape the backend ever
/// returns. Nothing backend-sensitive (the credential, its digest, or the
/// APNs token) is ever present, so nothing else is decoded here.
struct InstallationPushResponseDTO: Decodable {
    struct State: Decodable {
        let enabled: Bool
    }
    let push: State
}
