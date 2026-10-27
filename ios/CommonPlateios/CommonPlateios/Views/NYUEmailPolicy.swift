//
//  NYUEmailPolicy.swift
//  CommonPlateios
//

import Foundation

/// The one NYU email rule this app applies, shared by alert signup and food
/// requests. The backend enforces the identical allowlist on both endpoints and
/// remains authoritative; this exists only to keep an obviously ineligible
/// address beside its field instead of spending a request on it.
///
/// It lives beside neither form for the same reason `src/allowedEmailDomains.ts`
/// lives beside neither route: two copies of an allowlist are two allowlists.
///
/// This verifies control of an eligible NYU-domain address. It is not
/// authentication and does not prove current enrollment.
enum NYUEmailPolicy {
    /// The exact accepted domains. Membership is tested against the whole
    /// normalized domain after the final `@` — never by suffix or substring,
    /// either of which would accept `fake-nyu.edu`, `nyu.edu.example.com`, and
    /// every unlisted subdomain such as `law.nyu.edu`.
    static let allowedDomains: Set<String> = ["nyu.edu", "stern.nyu.edu"]

    /// One sentence for every surface that refuses an address, local or
    /// backend, so the two cannot describe the same rule differently.
    static let requiredMessage =
        "Enter an NYU email address ending in @nyu.edu or @stern.nyu.edu."

    /// Trims surrounding whitespace and lowercases, matching what the backend
    /// compares and stores.
    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The exact normalized domain, or `nil` when there is no usable one. A
    /// value with no local part has no address to allow, so it yields `nil`
    /// rather than a bare domain.
    static func domain(of value: String) -> String? {
        let normalized = normalize(value)
        guard let separator = normalized.lastIndex(of: "@"),
              separator != normalized.startIndex else {
            return nil
        }
        let domain = String(normalized[normalized.index(after: separator)...])
        return domain.isEmpty ? nil : domain
    }

    /// Whether this address is worth sending. Shape is checked with the app's
    /// one existing email pattern so neither form drifts into a second,
    /// slightly different idea of a valid address.
    static func isAllowed(_ value: String) -> Bool {
        let normalized = normalize(value)
        guard FulfillmentFormValidator.isValidEmail(normalized),
              let domain = domain(of: normalized) else {
            return false
        }
        return allowedDomains.contains(domain)
    }
}
