//
//  RequesterVenueClassifier.swift
//  CommonPlateios
//
//  R4.2 selection-local venue anchoring. This Requester policy deliberately
//  consumes only V1 Meal Exchange identity lines from eligible OCR evidence.
//  It neither broadens catalog matching nor gives the shared runtime any
//  Requester-shaped authority.
import Foundation

enum RequesterVenueDisposition: Equatable {
    case supported(DiningSpot)
    case unresolved
    case unsupported(String)
    case conflicting

    var blocksProposalApplication: Bool {
        switch self {
        case .unsupported, .conflicting: return true
        case .supported, .unresolved: return false
        }
    }
}

/// The venue disposition plus the one evidence fact the store needs in order
/// to decide whether the accepted catalog recognition may still stand.
struct RequesterVenueClassification: Equatable {
    let disposition: RequesterVenueDisposition
    /// At least one eligible image carried a V1 Meal Exchange identity line,
    /// whether or not it was reliable. When false, no V1 evidence exists and
    /// the accepted catalog-derived recognition (for example Dining Dollars
    /// without a Meal Exchange header) is the only venue evidence.
    let hasV1Observation: Bool
}

enum RequesterVenueClassifier {
    private enum Observation {
        case supported(DiningSpot, key: String)
        case unsupported(key: String)
        case indeterminate
        case none
    }

    static func classify(imageEvidenceTexts: [String], vendors: [DiningSpot]) -> RequesterVenueClassification {
        let observations = imageEvidenceTexts.map { observeImage($0, vendors: vendors) }
        let hasV1Observation = observations.contains { if case .none = $0 { return false }; return true }
        func result(_ disposition: RequesterVenueDisposition) -> RequesterVenueClassification {
            RequesterVenueClassification(disposition: disposition, hasV1Observation: hasV1Observation)
        }
        let reliable = observations.filter {
            if case .supported = $0 { return true }
            if case .unsupported = $0 { return true }
            return false
        }
        for left in reliable.indices {
            for right in reliable.indices where right > left {
                if conflicts(reliable[left], reliable[right]) { return result(.conflicting) }
            }
        }

        let supported = observations.compactMap { observation -> DiningSpot? in
            if case .supported(let vendor, _) = observation { return vendor }
            return nil
        }
        let unsupported = observations.compactMap { observation -> String? in
            if case .unsupported(let key) = observation { return key }
            return nil
        }
        let hasIndeterminate = observations.contains { if case .indeterminate = $0 { return true }; return false }
        if !unsupported.isEmpty && supported.isEmpty && !hasIndeterminate,
           RequesterOrderDeterministicEvidence.groundedVendorMatches(
                imageEvidenceTexts.joined(separator: "\n"), vendors: vendors
           ).isEmpty {
            return result(.unsupported(unsupported[0]))
        }
        // Reliable V1 support stands only when no image's V1 evidence is
        // indeterminate; otherwise the selection is unresolved (A).
        if let vendor = supported.first, !hasIndeterminate { return result(.supported(vendor)) }
        return result(.unresolved)
    }

    nonisolated static func venueKey(_ text: String) -> String {
        String(text.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A: return Unicode.Scalar(scalar.value + (scalar.value >= 0x41 ? 0x20 : 0))
            case 0x61...0x7A: return scalar
            default: return nil
            }
        }.map(Character.init))
    }

    /// Downgrade-only OCR similarity. A true value never selects a vendor.
    static func keysAreNear(_ left: String, _ right: String) -> Bool {
        if ScreenshotJSText.literalEquals(left, right) { return true }
        let shorter = min(left.count, right.count)
        if shorter >= 4 && (ScreenshotJSText.literalContains(left, right) || ScreenshotJSText.literalContains(right, left)) {
            return true
        }
        return shorter >= 6 && levenshtein(left, right) <= 2
    }

    private static func observeImage(_ text: String, vendors: [DiningSpot]) -> Observation {
        let prefixes = v1Prefixes(text)
        guard !prefixes.isEmpty else { return .none }
        let keys = prefixes.map(venueKey)
        guard !prefixes.contains(where: { asciiLetterCount($0) < 3 }),
              !prefixes.contains(where: { $0.hasSuffix("...") || $0.hasSuffix("…") }),
              Set(keys).count == 1 else { return .indeterminate }

        let matches = prefixes.flatMap {
            RequesterOrderDeterministicEvidence.groundedVendorMatches(
                "\($0) - meal exchange", vendors: vendors
            )
        }
        let names = Set(matches.map(\.name))
        if names.count == 1, let vendor = matches.first { return .supported(vendor, key: keys[0]) }
        if names.count > 1 || isNearCatalog(keys[0], vendors: vendors) { return .indeterminate }
        return .unsupported(key: keys[0])
    }

    private static func v1Prefixes(_ text: String) -> [String] {
        let lines = RequesterOrderDeterministicEvidence.normalizedLines(text)
        var prefixes: [String] = []
        for index in lines.indices {
            let line = lines[index]
            if line.hasSuffix(" - meal exchange") {
                let prefix = String(line.dropLast(" - meal exchange".count))
                if !prefix.isEmpty { prefixes.append(prefix) }
            } else if line.hasSuffix(" - meal"),
                      lines.indices.contains(index + 1),
                      ScreenshotJSText.literalEquals(lines[index + 1], "exchange") {
                let prefix = String(line.dropLast(" - meal".count))
                if !prefix.isEmpty { prefixes.append(prefix) }
            }
        }
        return prefixes
    }

    private static func conflicts(_ left: Observation, _ right: Observation) -> Bool {
        switch (left, right) {
        case (.supported(let a, _), .supported(let b, _)):
            return a.name != b.name
        case (.unsupported(let a), .unsupported(let b)):
            return !keysAreNear(a, b)
        case (.supported, .unsupported), (.unsupported, .supported):
            return true
        default:
            return false
        }
    }

    private static func isNearCatalog(_ key: String, vendors: [DiningSpot]) -> Bool {
        vendors.contains { vendor in
            let full = venueKey(vendor.name)
            let base = venueKey(vendor.name.components(separatedBy: " - ").first ?? vendor.name)
            return keysAreNear(key, full) || keysAreNear(key, base)
        }
    }

    /// The V1 observation threshold is deliberately letters-only. Digits are
    /// still retained in `venueKey` for downgrade-only near-miss comparison,
    /// but cannot make an otherwise unreadable venue name affirmative B/C
    /// evidence.
    private static func asciiLetterCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value) {
                count += 1
            }
        }
    }

    private static func levenshtein(_ left: String, _ right: String) -> Int {
        let lhs = Array(left.utf8)
        let rhs = Array(right.utf8)
        var row = Array(0...rhs.count)
        for (leftIndex, leftByte) in lhs.enumerated() {
            var diagonal = row[0]
            row[0] = leftIndex + 1
            for (rightIndex, rightByte) in rhs.enumerated() {
                let above = row[rightIndex + 1]
                row[rightIndex + 1] = min(
                    row[rightIndex + 1] + 1,
                    row[rightIndex] + 1,
                    diagonal + (leftByte == rightByte ? 0 : 1)
                )
                diagonal = above
            }
        }
        return row[rhs.count]
    }
}
