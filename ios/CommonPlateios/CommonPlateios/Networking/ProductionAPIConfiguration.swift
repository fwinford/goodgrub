import Foundation

enum ProductionAPIConfigurationError: Error, Equatable {
    case unavailable

    var message: String {
        "Configuration unavailable. Please try again after updating the app."
    }
}

extension APIConfiguration {
    static let productionBaseURLInfoKey = "CommonPlateProductionAPIBaseURL"

    /// Phase 2 must resolve this before constructing ContentView and its clients.
    /// Failure carries no backend substitute and never echoes configuration.
    static func resolvedForReleaseLaunch(
        info: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) throws -> APIConfiguration {
        guard let raw = info[productionBaseURLInfoKey] as? String,
              !raw.isEmpty,
              !raw.contains("%"),
              raw.unicodeScalars.allSatisfy({
                  !CharacterSet.whitespacesAndNewlines.contains($0) &&
                  !CharacterSet.controlCharacters.contains($0)
              }),
              let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.path.isEmpty,
              components.query == nil, components.fragment == nil,
              components.port == nil,
              let host = components.host?.lowercased(),
              isProductionDNSHost(host),
              raw.lowercased() == "https://\(host)",
              let url = components.url else {
            throw ProductionAPIConfigurationError.unavailable
        }
        return APIConfiguration(baseURL: url)
    }

    private static func isProductionDNSHost(_ host: String) -> Bool {
        // Require a DNS name, not an IP literal, ambiguous numeric address,
        // single-label/local name, or special-use development suffix.
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.count <= 253, labels.count >= 2,
              !["localhost", "local", "internal", "invalid", "test", "example", "home", "arpa"]
                .contains(String(labels.last ?? "")),
              labels.last?.allSatisfy({ $0.isASCII && $0.isLetter }) == true,
              (labels.last?.count ?? 0) >= 2 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 &&
            label.first != "-" && label.last != "-" &&
            label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}
