//
//  ScreenshotHelpPresentationTests.swift
//  CommonPlateiosTests
//

import XCTest
@testable import CommonPlateios

final class ScreenshotHelpPresentationTests: XCTestCase {
    /// W4-R2 2026-09-01 sync items 6-7: renamed overview label, removed
    /// per-row subtitle, removed the unsupported-screens disclaimer.
    /// W4-R2 2026-09-05 sync item 3: the accepted overview hierarchy is
    /// exhaustively `Title` -> two example rows -> `Got it`; no `WORKS` (or
    /// any other) eyebrow is named or rendered above the rows.
    func testApprovedOverviewCopyAndExampleHierarchy() {
        XCTAssertEqual(ScreenshotHelpView.title, "What should I screenshot?")
        XCTAssertEqual(ScreenshotHelpView.dismissLabel, "Got it")
        XCTAssertEqual(ScreenshotExampleKind.cart.overviewTitle, "Your pickup order")
        XCTAssertEqual(ScreenshotExampleKind.pastOrder.overviewTitle, "A past order")
    }

    /// W4-R2 2026-09-05 sync item 3: `WORKS` must not be rendered anywhere in
    /// the overview, and no replacement eyebrow/label was invented in its
    /// place — this is a pure removal, not a relabeling.
    func testWorksEyebrowIsRemovedWithNoReplacementLabel() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/ScreenshotHelpView.swift")

        XCTAssertFalse(source.contains("\"WORKS\""))
        XCTAssertFalse(source.contains("worksLabel"))
    }

    /// W4-R2 2026-09-05 sync item 3: the detail composition must render the
    /// enlarged image before the explanation, and both centered — not the
    /// prior leading-aligned instruction-before-image order item 8 already
    /// prohibited.
    func testDetailImageIsCenteredAndPrecedesTheExplanationBeneathIt() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/ScreenshotHelpView.swift")

        let mockRange = try XCTUnwrap(source.range(of: "ScreenshotExampleMock(kind: kind)"))
        let instructionRange = try XCTUnwrap(source.range(of: "Text(kind.detailInstruction)"))
        XCTAssertTrue(
            mockRange.lowerBound < instructionRange.lowerBound,
            "the image must render before the explanation beneath it"
        )

        guard let vstackRange = source.range(of: "VStack(alignment: .center, spacing: 10) {") else {
            XCTFail("expected the detail body to use a centered VStack")
            return
        }
        XCTAssertTrue(vstackRange.upperBound < mockRange.lowerBound)
        XCTAssertFalse(
            source.contains("VStack(alignment: .leading, spacing: 10) {\n                    Text(kind.detailInstruction)"),
            "the obsolete leading-aligned instruction-before-image composition must not remain"
        )
    }

    func testApprovedDetailTitlesInstructionsAndProportions() {
        XCTAssertEqual(ScreenshotExampleKind.cart.detailTitle, "Pickup order example")
        XCTAssertEqual(
            ScreenshotExampleKind.cart.detailInstruction,
            "Use the screen before checkout where your food items are visible."
        )
        XCTAssertEqual(ScreenshotExampleMock.height(for: .cart), 260)

        XCTAssertEqual(ScreenshotExampleKind.pastOrder.detailTitle, "Past order example")
        XCTAssertEqual(
            ScreenshotExampleKind.pastOrder.detailInstruction,
            "Open a previous order so the food items and modifiers are visible."
        )
        XCTAssertEqual(ScreenshotExampleMock.height(for: .pastOrder), 338)
        XCTAssertEqual(ScreenshotExampleMock.width, 240)
    }

    /// W4-R2 2026-09-01 sync item 6: no `overviewSummary` (removed subtitle)
    /// and no `unsupportedNotice` disclaimer remain in the source at all —
    /// not merely unused.
    func testRemovedOverviewSubtitleAndUnsupportedDisclaimerAreGone() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/ScreenshotHelpView.swift")

        XCTAssertFalse(source.contains("overviewSummary"))
        XCTAssertFalse(source.contains("unsupportedNotice"))
        XCTAssertFalse(source.contains("aren’t supported yet"))
    }

    /// W4-R2 2026-09-01 sync item 6: two light/open disclosure rows, not a
    /// heavy bordered card-in-card treatment.
    func testOverviewRowsAreLightOpenDisclosureRowsNotHeavyCards() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/ScreenshotHelpView.swift")

        guard let rowRange = source.range(of: "private func exampleRow(") else {
            XCTFail("expected to find exampleRow")
            return
        }
        guard let endRange = source.range(of: "\n    static let title", range: rowRange.upperBound..<source.endIndex) else {
            XCTFail("expected to find the end of exampleRow")
            return
        }
        let rowBody = String(source[rowRange.upperBound..<endRange.lowerBound])

        XCTAssertFalse(rowBody.contains("strokeBorder"))
        XCTAssertFalse(rowBody.contains("RoundedRectangle(cornerRadius: 16"))
        XCTAssertFalse(rowBody.contains("minHeight: 116"))
        XCTAssertTrue(rowBody.contains("CommonPlateDisclosureIndicator()"))
    }

    func testOverviewUsesCenteredLocalOverlayWithPopupDetailsAndNoShippedRaster() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/ScreenshotHelpView.swift")
        let requestSource = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift")

        XCTAssertFalse(requestSource.contains(".sheet(isPresented: $isPresentingScreenshotHelp)"))
        XCTAssertTrue(requestSource.contains("if isPresentingScreenshotHelp"))
        XCTAssertTrue(requestSource.contains("Color.black.opacity(0.34)"))
        XCTAssertTrue(requestSource.contains(".frame(width: 314)"))
        // Independent-review dead-space fix: the height cap only applies at
        // accessibility Dynamic Type sizes — see `dynamicTypeSize`'s
        // declaration in `RequestFoodView.swift`.
        XCTAssertTrue(requestSource.contains(".frame(maxHeight: dynamicTypeSize.isAccessibilitySize ? 480 : nil)"))
        XCTAssertTrue(requestSource.contains("request-screenshot-help-modal"))
        XCTAssertFalse(source.contains("NavigationStack {"))
        XCTAssertFalse(source.contains("NavigationLink"))
        XCTAssertTrue(source.contains("@State private var selectedExample"))
        XCTAssertTrue(source.contains("ScreenshotExampleDetailView(kind: selectedExample)"))
        XCTAssertTrue(source.contains("screenshot-example-detail-back"))
        XCTAssertFalse(source.contains("presentationDetents"))
        XCTAssertFalse(source.contains("presentationDragIndicator"))
        XCTAssertFalse(source.contains("Image(\""))
        XCTAssertFalse(source.contains("UIImage"))
    }

    /// W4-R2 2026-08-31 round-2 follow-up (independent-review fix): every
    /// runtime-measurement strategy tried here failed for reasons specific to
    /// *measuring `overviewContent` at runtime* in this app: `.scrollBounceBehavior(.basedOnSize)`
    /// never touches the size a `ScrollView` reports during layout;
    /// `.fixedSize(horizontal: false, vertical: true)` could leave oversized
    /// content merely clipped rather than in a real scrollable viewport;
    /// `GeometryReader`/`PreferenceKey` measurement was confirmed, via a
    /// direct `UIHostingController` layout diagnostic, to never settle to a
    /// real measured value in this app's runtime regardless of where the
    /// reader was placed; and `ViewThatFits` was confirmed by the same
    /// diagnostic to select its correct, non-scrolling candidate for
    /// *content*, but to still report its own outer size as the full
    /// ancestor proposal — centering the smaller chosen content and leaving
    /// equal dead space above and below it, which is what the physical
    /// walkthrough actually saw. `overview` now reads `\.dynamicTypeSize`
    /// (a plain, synchronous `@Environment` value, with none of the
    /// proposal-negotiation or preference-propagation behavior above) to
    /// choose between plain, non-scrolling content (ordinary sizes — proven
    /// by the same diagnostic to reliably hug to its own true height
    /// regardless of what its parent proposes) and a height-capped
    /// `ScrollView` (accessibility sizes only).
    func testOverviewChoosesHuggingOrScrollingFromDynamicTypeSizeNotRuntimeMeasurement() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/ScreenshotHelpView.swift")

        guard let overviewRange = source.range(of: "private var overview: some View {") else {
            XCTFail("expected to find the overview property")
            return
        }
        let overviewBody = String(source[overviewRange.upperBound...].prefix(500))
        XCTAssertTrue(overviewBody.contains("dynamicTypeSize.isAccessibilitySize"))
        XCTAssertTrue(overviewBody.contains("ScrollView {"))
        XCTAssertTrue(overviewBody.contains("overviewContent"))
        XCTAssertTrue(overviewBody.contains(".frame(maxHeight: Self.maxOverviewHeight)"))
        XCTAssertFalse(
            overviewBody.contains(".scrollBounceBehavior"),
            "a scroll-interaction modifier is not a layout-sizing fix"
        )
        XCTAssertFalse(
            overviewBody.contains(".fixedSize"),
            "fixedSize plus ancestor clipping could leave oversized content clipped rather than scrollable"
        )
        XCTAssertFalse(
            overviewBody.contains("GeometryReader"),
            "GeometryReader/PreferenceKey measurement of this content never settled to a real value"
        )
        XCTAssertFalse(
            overviewBody.contains("ViewThatFits"),
            "ViewThatFits reported its outer size as the full ancestor proposal, not the chosen candidate's size"
        )

        XCTAssertTrue(source.contains("@Environment(\\.dynamicTypeSize) private var dynamicTypeSize"))
        XCTAssertTrue(source.contains("static let maxOverviewHeight: CGFloat = 480"))
        XCTAssertTrue(source.contains("private var overviewContent: some View {"))
    }

    /// Regression fix: making the presenting `RequestFoodView` wrapper's
    /// `.frame(maxHeight:)` `nil` at ordinary sizes (the overview dead-space
    /// fix above) correctly let `overview` hug its own small content, but
    /// also removed `ScreenshotExampleDetailView`'s only height bound —
    /// its own internal `ScrollView` has none of its own — so it expanded to
    /// the full ambient screen height: a near-full-screen card, a large
    /// empty region below the enlarged example, and the header/Back control
    /// pushed up near the status area, all one direct consequence of the
    /// missing bound. Confirmed by a temporary `UIHostingController` layout
    /// diagnostic (removed) that the exact production wrapper chain now
    /// renders the detail card at a bounded 480pt with the Back control at a
    /// normal position near the top of that card, not the full ~852pt
    /// screen height. This source check protects that specific wiring
    /// against regressing again; the diagnostic established the actual
    /// rendered proof.
    func testDetailIsAlwaysHeightBoundedUnlikeOverviewWhichOnlyBoundsAtAccessibilitySizes() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/ScreenshotHelpView.swift")

        guard let selectedExampleRange = source.range(of: "if let selectedExample {"),
              let elseRange = source.range(of: "} else {", range: selectedExampleRange.upperBound..<source.endIndex)
        else {
            XCTFail("expected to find the detail branch")
            return
        }
        let detailBranch = String(source[selectedExampleRange.upperBound..<elseRange.lowerBound])
        XCTAssertTrue(
            detailBranch.contains(".frame(maxHeight: Self.maxOverviewHeight)"),
            "the detail branch must always be height-bounded — its own ScrollView has no bound of its own"
        )
    }

    /// W4-R2 2026-09-01 sync item 1: the returning-user form no longer shows
    /// a permanent `What should I screenshot?` support row (or any other
    /// permanent Examples/help affordance) — Screenshot Help now appears only
    /// as automatic first-use contextual education, driven from the tap
    /// handler below rather than a standalone always-visible row/button.
    func testScreenshotAssistanceRowHasNoPermanentHelpAffordance() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift")
        let rowRange = try XCTUnwrap(source.range(of: "private var screenshotAssistanceRow: some View {"))
        let endRange = try XCTUnwrap(
            source.range(of: "static let screenshotCheckedLabel", range: rowRange.upperBound..<source.endIndex)
        )
        let rowBody = String(source[rowRange.upperBound..<endRange.lowerBound])

        XCTAssertFalse(rowBody.contains("screenshotHelpTitle"))
        XCTAssertFalse(rowBody.contains("isPresentingScreenshotHelp = true"))
        XCTAssertFalse(rowBody.contains("\"Examples\""))
    }

    private func fileSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
