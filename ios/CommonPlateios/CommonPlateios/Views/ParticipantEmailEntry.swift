//
//  ParticipantEmailEntry.swift
//  CommonPlateios
//
// W4-B1 presentation helpers for the verification entry. Neither type changes
// who is eligible: `NYUEmailPolicy` (and the backend) still own the allowlist.

import Foundation

/// How the verification entry classifies what the student typed. Only
/// `.supported` may reach `startVerification`; malformed and ineligible
/// addresses receive local feedback and never request or send a code.
enum ParticipantEmailClassification: Equatable {
    case malformed
    case unsupportedSchool
    case supported

    var validationMessage: String? {
        switch self {
        case .malformed:
            return "Enter a valid email address."
        case .unsupportedSchool:
            return "Enter a valid NYU email address."
        case .supported:
            return nil
        }
    }

    static func classify(_ value: String) -> ParticipantEmailClassification {
        let normalized = NYUEmailPolicy.normalize(value)
        guard FulfillmentFormValidator.isValidEmail(normalized) else { return .malformed }
        return NYUEmailPolicy.isAllowed(normalized) ? .supported : .unsupportedSchool
    }
}

enum ParticipantEmailEntryAction: Equatable {
    case showValidation(String)
    case requestVerification(String)

    static func forSubmission(_ value: String) -> ParticipantEmailEntryAction {
        let normalized = NYUEmailPolicy.normalize(value)
        let classification = ParticipantEmailClassification.classify(normalized)
        if let message = classification.validationMessage {
            return .showValidation(message)
        }
        return .requestVerification(normalized)
    }
}

/// Where "Contact GoodGrub" goes. The address is configuration, never a
/// compiled-in placeholder: with none configured the action is unavailable and
/// nothing is invoked or implied.
struct SupportContact: Equatable {
    static let infoDictionaryKey = "BrandSupportEmail"
    static let subject = "Bringing \(AppBrand.name) to my campus"

    let address: String?

    init(address: String?) {
        let trimmed = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.address = FulfillmentFormValidator.isValidEmail(trimmed) ? trimmed : nil
    }

    init(bundle: Bundle = .main) {
        self.init(address: bundle.object(forInfoDictionaryKey: Self.infoDictionaryKey) as? String)
    }

    var isConfigured: Bool { address != nil }

    /// A `mailto:` with the fixed subject and a blank body.
    var mailtoURL: URL? {
        guard let address else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [URLQueryItem(name: "subject", value: Self.subject)]
        return components.url
    }

    static let openFailedTitle = "Couldn't open your email app"
    static let openFailedBody = "You can copy our email address and contact us from another email app."
    static let copyActionTitle = "Copy email address"
}
