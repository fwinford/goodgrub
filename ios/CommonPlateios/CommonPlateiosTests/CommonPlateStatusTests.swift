//
//  CommonPlateStatusTests.swift
//  CommonPlateiosTests
//
// Focused W4-F1 coverage for the shared semantic-state foundation. These
// tests prove deterministic symbols/accessibility labels and the authored
// uncertain-color asset definition. They deliberately do not claim rendered
// SwiftUI color resolution, which this target cannot inspect without UI tests.
import Foundation
import XCTest
@testable import CommonPlateios

final class CommonPlateStatusTests: XCTestCase {
    private let allKinds = CommonPlateStatusKind.allCases

    func testEveryKindHasADistinctSymbol() {
        let symbols = allKinds.map(\.symbolName)
        XCTAssertEqual(Set(symbols).count, allKinds.count)
    }

    func testEveryKindHasADistinctAccessibilityPrefix() {
        let prefixes = allKinds.map(\.accessibilityPrefix)
        XCTAssertEqual(Set(prefixes).count, allKinds.count)
    }

    func testGenericUnavailableUsesANeutralActionSymbol() {
        XCTAssertEqual(CommonPlateStatusKind.unavailable.symbolName, "nosign")
        XCTAssertNotEqual(CommonPlateStatusKind.unavailable.symbolName, "wifi.slash")
        XCTAssertEqual(CommonPlateStatusKind.unavailable.accessibilityPrefix, "Temporarily unavailable.")
    }

    /// Warning and conflict intentionally use the same system-orange family;
    /// their distinct symbols remain the non-color distinction. Source
    /// inspection is the stable boundary, rather than `Color` identity.
    func testWarningAndConflictUseOrangeButRetainDistinctSymbols() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Design/CommonPlateStatus.swift")
        XCTAssertTrue(source.contains("case .conflict: return .orange"))
        XCTAssertTrue(source.contains("case .warning: return .orange"))

        let symbols = [CommonPlateStatusKind.conflict, .warning].map(\.symbolName)
        XCTAssertEqual(Set(symbols).count, symbols.count)
    }

    /// The authored asset is the stable proof for the calm blue-gray contract.
    /// It checks sRGB source values for both appearances, not rendered color.
    func testUncertainAssetDefinesTheAcceptedCalmBlueGrayInBothAppearances() throws {
        let colors = try uncertainTintComponents()
        let light = try XCTUnwrap(colors.light)
        let dark = try XCTUnwrap(colors.dark)

        for components in [light, dark] {
            XCTAssertTrue((0...1).contains(components.red))
            XCTAssertTrue((0...1).contains(components.green))
            XCTAssertTrue((0...1).contains(components.blue))
            XCTAssertGreaterThan(components.blue, components.green)
            XCTAssertGreaterThan(components.green, components.red)
        }

        XCTAssertTrue(
            light.red != dark.red || light.green != dark.green || light.blue != dark.blue,
            "expected the asset's light and dark appearances to remain intentionally distinct"
        )
    }

    /// The production mapping reserves red/orange for error, conflict, and
    /// warning. Together with the blue-dominant asset data above, this proves
    /// source-level semantic-family distinction without resolving adaptive
    /// system colors in a unit test.
    func testUncertainAssetDefinitionIsDistinctFromErrorWarningAndConflictFamilies() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Design/CommonPlateStatus.swift")
        XCTAssertTrue(source.contains("case .error: return .red"))
        XCTAssertTrue(source.contains("case .conflict: return .orange"))
        XCTAssertTrue(source.contains("case .warning: return .orange"))
        XCTAssertTrue(source.contains("case .uncertain: return Color(\"CommonPlateUncertainTint\")"))

        let colors = try uncertainTintComponents()
        for components in [try XCTUnwrap(colors.light), try XCTUnwrap(colors.dark)] {
            XCTAssertGreaterThan(components.blue, components.red)
            XCTAssertGreaterThan(components.blue, components.green)
        }
    }

    func testUncertainKeepsItsOwnSymbolAndSpokenSemanticIdentity() {
        XCTAssertEqual(CommonPlateStatusKind.uncertain.symbolName, "questionmark.circle")
        XCTAssertEqual(CommonPlateStatusKind.uncertain.accessibilityPrefix, "Outcome uncertain.")
        XCTAssertEqual(
            CommonPlateInlineStatus.accessibilityLabel(kind: .uncertain, message: "Try again in a moment."),
            "Outcome uncertain. Try again in a moment."
        )
    }

    func testAccessibilityLabelLeadsWithTheSpokenPrefixAndKeepsTheMessage() {
        let label = CommonPlateInlineStatus.accessibilityLabel(kind: .error, message: "Something went wrong.")
        XCTAssertTrue(label.hasPrefix(CommonPlateStatusKind.error.accessibilityPrefix))
        XCTAssertTrue(label.contains("Something went wrong."))
    }

    func testAccessibilityLabelDiffersAcrossKindsForTheSameMessage() {
        let message = "Try again in a moment."
        let labels = allKinds.map { CommonPlateInlineStatus.accessibilityLabel(kind: $0, message: message) }
        XCTAssertEqual(Set(labels).count, allKinds.count)
    }

    // MARK: - Asset-source helpers

    private func uncertainTintComponents() throws -> (light: RGBComponents?, dark: RGBComponents?) {
        let data = try Data(contentsOf: repositoryFile(
            "ios/CommonPlateios/CommonPlateios/Assets.xcassets/CommonPlateUncertainTint.colorset/Contents.json"
        ))
        let asset = try JSONDecoder().decode(ColorAsset.self, from: data)
        var light: RGBComponents?
        var dark: RGBComponents?

        for entry in asset.colors {
            if entry.appearances?.contains(where: { $0.appearance == "luminosity" && $0.value == "dark" }) == true {
                dark = entry.color.components
            } else {
                light = entry.color.components
            }
        }
        return (light, dark)
    }

    private func fileSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryFile(relativePath), encoding: .utf8)
    }

    private func repositoryFile(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CommonPlateiosTests
            .deletingLastPathComponent() // CommonPlateios
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repository root
            .appendingPathComponent(relativePath)
    }
}

private struct ColorAsset: Decodable {
    let colors: [ColorEntry]
}

private struct ColorEntry: Decodable {
    let appearances: [Appearance]?
    let color: ColorDefinition
}

private struct Appearance: Decodable {
    let appearance: String
    let value: String
}

private struct ColorDefinition: Decodable {
    let components: RGBComponents
}

private struct RGBComponents: Decodable {
    let red: Double
    let green: Double
    let blue: Double

    private enum CodingKeys: String, CodingKey {
        case red
        case green
        case blue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        red = try Self.component(.red, from: container)
        green = try Self.component(.green, from: container)
        blue = try Self.component(.blue, from: container)
    }

    private static func component(
        _ key: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Double {
        let string = try container.decode(String.self, forKey: key)
        guard let value = Double(string) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Expected an Xcode color-asset numeric string."
            )
        }
        return value
    }
}
