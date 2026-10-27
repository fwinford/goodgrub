//
//  CommonPlateBrandDisplayScopeTests.swift
//  CommonPlateiosTests
//
// Focused W4-F1 coverage that `commonPlateBrandDisplay` stays exactly as
// selective as Faith's decision requires: reserved for the one rare brand
// moment F1 owns (the "GoodGrub" wordmark on Home), never spread across
// functional UI. Read via source inspection — matching the existing
// `ParticipantVerificationHierarchyTests` pattern — since there is no
// UI-test target to render and inspect the real view tree.
import Foundation
import XCTest
@testable import CommonPlateios

final class CommonPlateBrandDisplayScopeTests: XCTestCase {
    /// W4-H2: the wordmark moved from R1's centered `CommonPlateBrandHeader()`
    /// to a left-aligned header row (title + Settings gear) inside
    /// `HomeExchangeView`, since the exchange board's Figma-approved layout
    /// has no room for a full-width centered brand block above the board.
    /// The scope invariant itself — exactly one `commonPlateBrandDisplay`
    /// use, specifically on the "GoodGrub" wordmark — still applies.
    func testHomeUsesBrandDisplayExactlyOnceForTheWordmark() throws {
        let home = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")
        let header = try declarationSource(
            "private var header: some View {",
            in: home
        )
        let occurrences = header.components(separatedBy: "commonPlateBrandDisplay").count - 1
        XCTAssertEqual(occurrences, 1, "expected exactly one commonPlateBrandDisplay use on Home")

        // Scoped: the usage must sit on the "GoodGrub" wordmark line, not
        // the campus qualifier or any other Home text, so a future edit that moves it
        // elsewhere on the same screen still fails this test.
        guard let brandRange = header.range(of: "Text(AppBrand.name)") else {
            XCTFail("expected the \(AppBrand.name) wordmark Text to still exist")
            return
        }
        let afterWordmark = header[brandRange.upperBound...]
        guard let nextTextRange = afterWordmark.range(of: "Text(\"at \\(AppBrand.campus)\")") else {
            XCTFail("expected the campus qualifier Text to still follow the wordmark")
            return
        }
        let betweenWordmarkAndSubtitle = afterWordmark[..<nextTextRange.lowerBound]
        XCTAssertTrue(
            betweenWordmarkAndSubtitle.contains("commonPlateBrandDisplay"),
            "expected commonPlateBrandDisplay to style the \(AppBrand.name) wordmark specifically"
        )
    }

    /// Verification is the other approved rare display moment: its human
    /// heading, not its fields or action labels, uses Quiet Fraunces.
    func testParticipantVerificationUsesBrandDisplayOnlyForItsHeadline() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/ParticipantVerificationView.swift")
        XCTAssertEqual(source.components(separatedBy: "commonPlateBrandDisplay").count - 1, 1)
        let header = try declarationSource(
            "private var verificationBrandHeader: some View {",
            in: source
        )
        XCTAssertTrue(header.contains("Text(\n                store.flow?.purpose"))
        XCTAssertTrue(header.contains("commonPlateBrandDisplay(.title2,"))
    }

    private func fileSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CommonPlateiosTests
            .deletingLastPathComponent() // CommonPlateios
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repository root
        let url = root.appendingPathComponent(relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "expected \(relativePath) at \(url.path)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func declarationSource(_ startMarker: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        return String(source[start.lowerBound...])
    }
}
