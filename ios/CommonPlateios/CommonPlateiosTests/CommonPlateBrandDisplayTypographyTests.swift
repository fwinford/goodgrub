//
//  CommonPlateBrandDisplayTypographyTests.swift
//  CommonPlateiosTests
//
// Focused W4-F1 coverage for `Font.commonPlateBrandDisplay(_:)` — the
// Faith-accepted Quiet Fraunces brand/display accent. This pins the semantic
// boundary: the registered embedded font and SwiftUI Dynamic Type-relative
// helper. It cannot prove rendered placement (the repository has no UI-test
// target), which is why `ContentView.swift`'s scoped usage separately bounds
// "CommonPlate" to this helper and system SF typography everywhere else.
import UIKit
import XCTest
@testable import CommonPlateios

final class CommonPlateBrandDisplayTypographyTests: XCTestCase {
    func testQuietFrauncesAxesStayInTheApprovedQuietDirection() throws {
        let axes = CommonPlateStyle.BrandDisplay.quietVariationAxes
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(axes["SOFT"]), 40)
        XCTAssertEqual(try XCTUnwrap(axes["WONK"]), 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(axes["wght"]), 450)
        XCTAssertLessThanOrEqual(try XCTUnwrap(axes["wght"]), 600)
    }

    func testFrauncesFontIsRegisteredFromTheEmbeddedAppResource() {
        XCTAssertNotNil(
            UIFont(name: CommonPlateStyle.BrandDisplay.fontName, size: 34),
            "expected the UIAppFonts-registered Fraunces asset to be available"
        )
    }

    func testBrandDisplayUsesUIFontMetricsAndASystemFallback() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Design/CommonPlateStyle.swift")
        XCTAssertTrue(source.contains("UIFontMetrics(forTextStyle: textStyle).scaledFont(for: quietFraunces)"))
        XCTAssertTrue(source.contains("UIFont.preferredFont(forTextStyle: textStyle)"))
        XCTAssertTrue(source.contains("Font(CommonPlateStyle.BrandDisplay.uiFont(for: style))"))
    }

    private func fileSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CommonPlateiosTests
            .deletingLastPathComponent() // CommonPlateios
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repository root
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
