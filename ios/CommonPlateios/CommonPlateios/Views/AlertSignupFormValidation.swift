//
//  AlertSignupFormValidation.swift
//  CommonPlateios
//

import Foundation

/// Alert signup's view of the shared NYU rule. Every member forwards to
/// `NYUEmailPolicy`, which the food-request form now uses as well, so the two
/// forms cannot enforce different allowlists or describe the same refusal
/// differently. Signup's own behavior is unchanged.
enum AlertSignupEmailValidator {
    static var allowedDomains: Set<String> { NYUEmailPolicy.allowedDomains }

    static var invalidEmailMessage: String { NYUEmailPolicy.requiredMessage }

    static func normalize(_ value: String) -> String {
        NYUEmailPolicy.normalize(value)
    }

    static func domain(of value: String) -> String? {
        NYUEmailPolicy.domain(of: value)
    }

    static func isAllowedNYUEmail(_ value: String) -> Bool {
        NYUEmailPolicy.isAllowed(value)
    }
}
