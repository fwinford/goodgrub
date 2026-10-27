//
//  ParticipantReportDTOs.swift
//  CommonPlateios
//
// Wire types for contextual participant reporting (W4-U1.2).
//
import Foundation

enum ParticipantReportReason: String, CaseIterable, Identifiable, Encodable {
    case harassmentOrHatefulBehavior = "Harassment or hateful behavior"
    case sexualOrInappropriateContent = "Sexual or inappropriate content"
    case threatsOrUnsafeBehavior = "Threats or unsafe behavior"
    case spamOrMisuseOfCommonPlate = "Spam or misuse of CommonPlate"
    case otherConcern = "Other concern"

    var id: String { rawValue }

    // The wire value stays stable; only the visible label uses the GoodGrub name.
    var title: String {
        self == .spamOrMisuseOfCommonPlate ? "Spam or misuse of \(AppBrand.name)" : rawValue
    }
}

struct ParticipantReportSubmissionPayload: Encodable {
    let operationId: String
    let reason: ParticipantReportReason
    let explanation: String?
    let reportAuthorization: String?
}

enum ParticipantReportSubmissionOutcomeDTO: String, Decodable {
    case reported
}

struct ParticipantReportSubmissionResponseDTO: Decodable {
    let outcome: ParticipantReportSubmissionOutcomeDTO
}

enum ParticipantReportOperationOutcomeDTO: String, Decodable {
    case created
    case noCreate = "no-create"
    case refused
}

struct ParticipantReportOperationResponseDTO: Decodable {
    let outcome: ParticipantReportOperationOutcomeDTO
}

struct ParticipantRestrictionResponseDTO: Decodable {
    let restricted: Bool?
}
