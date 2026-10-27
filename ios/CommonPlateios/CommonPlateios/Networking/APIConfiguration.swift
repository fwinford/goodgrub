//
//  APIConfiguration.swift
//  CommonPlateios
//
//  Created by faith on 7/13/26.
//
// Centralizes backend base-URL ownership, per docs/system-contract.md.
// Views, services, and stores must not hard-code backend URLs; they receive
// configuration through this type instead.
//
// Debug builds use the local simulator backend. Release builds use only the
// explicit production HTTPS origin in `ProductionAPIConfiguration.swift` and
// fail closed when it is absent or invalid.
//
// W4-QA1 adds a Debug-only way to point a development build at a different
// *local* backend without editing source. It is compiled out of every other
// configuration, so a Release or distribution build neither contains nor reads
// it, and it is not production endpoint selection.
import Foundation

struct APIConfiguration {
    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

#if DEBUG
    /// Simulator local backend. Port matches `app.ts`'s default (`process.env.PORT || 3000`);
    /// the simulator reaches the host Mac's loopback interface directly.
    /// Uses stable loopback rather than a specific global/temporary IPv6
    /// address, which can rotate (SLAAC privacy addressing) and go stale.
    static let localSimulator = APIConfiguration(
        baseURL: URL(string: "http://127.0.0.1:3000")!
    )
#endif
}

#if DEBUG
/// Why an explicitly supplied Debug backend override was refused. Messages are
/// fixed text and never echo the supplied value, which could carry credentials
/// in its user-info component.
enum APIConfigurationOverrideError: Error, Equatable, CustomStringConvertible {
    case empty
    case malformed
    case unsupportedScheme
    case credentialsNotAllowed
    case unexpectedComponents
    case invalidPort
    case nonLocalHost

    var description: String {
        switch self {
        case .empty:
            return "is set but empty"
        case .malformed:
            return "is not a valid URL"
        case .unsupportedScheme:
            return "must use http://"
        case .credentialsNotAllowed:
            return "must not contain a user name or password"
        case .unexpectedComponents:
            return "must be only a scheme, host and optional port"
        case .invalidPort:
            return "has an invalid port"
        case .nonLocalHost:
            return "must name a loopback, private-network, or .local development host"
        }
    }
}

extension APIConfiguration {
    /// Environment variable a Debug build reads to select a local backend, e.g.
    /// `SIMCTL_CHILD_COMMONPLATE_DEBUG_API_BASE_URL=http://127.0.0.1:3001` when
    /// launching in the Simulator. Absent means the existing default.
    static let debugOverrideEnvironmentKey = "COMMONPLATE_DEBUG_API_BASE_URL"

    /// The configuration this launch should use: the validated override when the
    /// variable is present, otherwise `localSimulator` exactly as before. A
    /// present-but-unacceptable value throws; it is never replaced by a
    /// different backend.
    static func resolvedForDebugLaunch(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> APIConfiguration {
        guard let raw = environment[debugOverrideEnvironmentKey] else {
            return .localSimulator
        }
        return APIConfiguration(baseURL: try validatedDebugOverride(raw))
    }

    static func validatedDebugOverride(_ raw: String) throws -> URL {
        guard !raw.isEmpty else { throw APIConfigurationOverrideError.empty }
        // Nothing is trimmed or repaired: a value that needs fixing is refused.
        guard raw.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased() else {
            throw APIConfigurationOverrideError.malformed
        }
        guard scheme == "http" else { throw APIConfigurationOverrideError.unsupportedScheme }
        guard components.user == nil, components.password == nil else {
            throw APIConfigurationOverrideError.credentialsNotAllowed
        }
        guard components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw APIConfigurationOverrideError.unexpectedComponents
        }
        guard let host = components.host?.lowercased(), !host.isEmpty else {
            throw APIConfigurationOverrideError.malformed
        }
        if let port = components.port, !(1...65535).contains(port) {
            throw APIConfigurationOverrideError.invalidPort
        }
        guard isApprovedLocalDevelopmentHost(host) else {
            throw APIConfigurationOverrideError.nonLocalHost
        }

        var normalized = URLComponents()
        normalized.scheme = "http"
        normalized.host = host
        normalized.port = components.port
        guard let url = normalized.url else { throw APIConfigurationOverrideError.malformed }
        return url
    }

    /// Loopback, RFC 1918 private IPv4, or an mDNS `.local` name. Anything else,
    /// including every other hostname (which could resolve to a public
    /// address), is not an approved development target.
    static func isApprovedLocalDevelopmentHost(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        if host.hasSuffix(".local") {
            let label = host.dropLast(".local".count)
            return !label.isEmpty && !label.hasPrefix(".") && !label.hasSuffix(".")
        }
        guard let octets = canonicalIPv4Octets(host) else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// Strict dotted-quad: exactly four canonical decimal parts, so shorthand
    /// and leading-zero (octal-looking) forms are not interpreted.
    private static func canonicalIPv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part == "0" || !part.hasPrefix("0"),
                  let value = Int(part), value <= 255 else { return nil }
            octets.append(value)
        }
        return octets
    }
}
#endif

extension APIConfiguration {
    /// The configuration for this launch, or the reason none is available.
    /// Debug honors the validated local override (an invalid one stops the
    /// launch visibly). Every other configuration resolves only the explicit
    /// production HTTPS value and never substitutes another backend.
    static func resolvedForLaunch() -> Result<APIConfiguration, ProductionAPIConfigurationError> {
        #if DEBUG
        return .success(forLaunch())
        #else
        do {
            return .success(try resolvedForReleaseLaunch())
        } catch {
            return .failure(.unavailable)
        }
        #endif
    }
}

#if DEBUG
extension APIConfiguration {
    /// Debug-only launch entry point: the validated local override when the
    /// variable is present, otherwise `localSimulator`.
    static func forLaunch() -> APIConfiguration {
        do {
            return try resolvedForDebugLaunch()
        } catch {
            preconditionFailure(
                "\(debugOverrideEnvironmentKey) \(error). Fix or unset it; CommonPlate will not fall back to another backend."
            )
        }
    }
}
#endif
