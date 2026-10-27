//
//  HomeContinuousScrollCompositionTests.swift
//  CommonPlateiosTests
//
// W4-H4 focused coverage for the Home continuous-scroll composition and the
// persistent `Request Food` action. The repository has no iOS UI-test
// target, so these cases prove the production `HomeExchangeView` source
// establishes one unified scrolling region (header/priorities, `Continue
// Helping`, the ownership partition, the shared board heading, and `Needs
// help right now` inside the same refreshable `ScrollView`) with the
// persistent `Request Food` action anchored outside it via
// `.safeAreaInset(edge: .bottom)` — not rendered scroll reachability,
// Dynamic Type, VoiceOver order, or on-device safe-area behavior, which
// remain Simulator/physical-device proof.
import Foundation
import XCTest
@testable import CommonPlateios

final class HomeContinuousScrollCompositionTests: XCTestCase {
    // MARK: - One unified scroll region

    func testExactlyOneScrollViewAndOneRefreshableBackHome() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        XCTAssertEqual(
            source.components(separatedBy: "ScrollView {").count - 1,
            1,
            "expected exactly one ScrollView — no second/nested Home scroll region"
        )
        XCTAssertEqual(
            source.components(separatedBy: ".refreshable {").count - 1,
            1,
            "expected exactly one .refreshable, attached to the single unified Home scroll"
        )
    }

    /// H4 supersedes H2's split composition: the header/priorities,
    /// `Continue Helping`, and the ownership partition must no longer sit
    /// outside a separately refreshable inner `ScrollView` — they, the board
    /// heading, and `Needs help right now` all live inside the same
    /// `ScrollView`/`.refreshable` region, in accepted order.
    func testHeaderPrioritiesOwnershipAndBoardAllRenderInsideTheSingleUnifiedScroll() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        guard let scrollViewRange = source.range(of: "ScrollView {"),
              let refreshableRange = source.range(of: ".refreshable {", range: scrollViewRange.upperBound..<source.endIndex) else {
            return XCTFail("expected a ScrollView followed by .refreshable")
        }
        // `.refreshable` is chained after the ScrollView's own closing
        // brace, so scanning through its opening brace still covers every
        // view mounted inside the ScrollView's content closure.
        let scrollRegion = source[scrollViewRange.lowerBound..<refreshableRange.lowerBound]

        for token in ["header", "continueHelpingSection", "ownRequestsSection", "boardHeadingRow", "boardSection"] {
            XCTAssertTrue(
                scrollRegion.contains(token),
                "expected \(token) to be mounted inside the single unified Home ScrollView"
            )
        }

        // Accepted order (Section outcome 1-5): header, Continue Helping,
        // ownership, board heading, then the board content.
        let offsets = ["header", "continueHelpingSection", "ownRequestsSection", "boardHeadingRow", "boardSection"]
            .map { token -> String.Index in
                guard let range = scrollRegion.range(of: token) else {
                    XCTFail("expected \(token) to be present")
                    return scrollRegion.startIndex
                }
                return range.lowerBound
            }
        XCTAssertEqual(offsets, offsets.sorted(), "expected accepted Home ordering inside the unified scroll")
    }

    // MARK: - Persistent Request Food, outside the scroll

    /// The persistent action must be anchored via `.safeAreaInset(edge:
    /// .bottom)` attached directly to the `ScrollView` (not inside the
    /// ScrollView's own content closure), so it remains reachable without
    /// scrolling and never becomes a second scroll region. Attaching it
    /// directly to the `ScrollView` — rather than to the outer
    /// `GeometryReader` — is a physical-device fix (W4-H4 ACTIVE / FIX): the
    /// higher attachment point did not reliably reach the `ScrollView`'s
    /// underlying `UIScrollView.contentInset`, letting a long `Needs help`
    /// board's last card render partially beneath the button.
    func testRequestMealButtonIsAnchoredOutsideTheScrollViaBottomSafeAreaInset() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        XCTAssertEqual(
            source.components(separatedBy: ".safeAreaInset(edge: .bottom) {").count - 1,
            1,
            "expected exactly one persistent bottom safe-area inset on Home"
        )
        guard let refreshableRange = source.range(of: ".refreshable {"),
              let refreshableCloseRange = source.range(of: "}\n            .safeAreaInset(edge: .bottom) {\n                requestMealButton\n            }") else {
            return XCTFail("expected .refreshable, then the persistent Request Food safeAreaInset attached to the same ScrollView (after the W4-H3 top-band inset)")
        }
        XCTAssertLessThan(refreshableRange.upperBound, refreshableCloseRange.lowerBound)

        // Not mounted a second time inside the scroll content itself.
        guard let scrollViewRange = source.range(of: "ScrollView {") else {
            return XCTFail("expected a ScrollView")
        }
        let scrollRegion = source[scrollViewRange.lowerBound..<refreshableRange.lowerBound]
        XCTAssertFalse(scrollRegion.contains("requestMealButton"))
    }

    func testRequestMealButtonRemainsTheOnlyRequestFoodEntryPointOnHome() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        XCTAssertTrue(source.contains("private var requestMealButton: some View {"))
        XCTAssertTrue(source.contains("accessibilityIdentifier(\"home-request-a-meal\")"))
        // W4-H4 revised contract explicitly authorizes the ownership-preview
        // `See all N` action; it must not introduce a competing paging/
        // carousel entry point for Request Food itself.
        XCTAssertFalse(source.contains("TabView"))
        XCTAssertFalse(source.contains("PageTabViewStyle"))
    }

    // MARK: - No R2/H3-authored motion absorbed by this composition change

    func testNoNewAutoScrollOrHighlightMotionIntroduced() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        XCTAssertFalse(source.contains("scrollTo("))
        XCTAssertFalse(source.contains("ScrollViewReader"))
        XCTAssertFalse(source.contains("proxy.scrollTo"))
    }

    // MARK: - Persistent-CTA visual completion (soft floating, column-aligned)

    /// `Request a Meal`'s left/right edges must use the exact same
    /// `CommonPlateStyle.Metrics.homeContentColumnInset` horizontal margin
    /// the header/ownership/board content uses in `exchangeContent` — not
    /// the narrower, centered R1 `commonPlateMajorActionFrame()` width,
    /// which does not line up with the request-card column, and not a
    /// separate CTA-only literal.
    func testRequestMealButtonAlignsWithTheHomeContentColumnSpacing() throws {
        let button = try requestMealButtonSource()

        XCTAssertTrue(
            button.contains(".padding(.horizontal, CommonPlateStyle.Metrics.homeContentColumnInset)"),
            "expected the CTA to reuse the shared Home content-column horizontal margin"
        )
        XCTAssertFalse(
            button.contains(".commonPlateMajorActionFrame()"),
            "the centered/narrower R1 major-action width does not align with the request-card column"
        )
    }

    /// W4-H4 final shared-content-column reconciliation: ownership cards,
    /// `Needs help` cards, and the persistent CTA must all read
    /// from the exact same `homeContentColumnInset` authority — never three
    /// independently sized margins — and that authority must not be the
    /// general-purpose `Spacing.l` step other unrelated screens also use,
    /// since widening `Spacing.l` itself would restyle those other screens.
    func testOwnershipCardsNeedsHelpCardsAndTheCTAShareOneColumnAuthority() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        // Scope to `exchangeContent` (the header/ownership/board composition)
        // plus the CTA itself — Empty/Unavailable state copy elsewhere in
        // this file legitimately keeps its own unrelated `Spacing.l`
        // horizontal padding and is out of scope for the shared column.
        guard let exchangeContentStart = source.range(of: "private var exchangeContent: some View {"),
              let exchangeContentEnd = source.range(of: "private var header: some View {", range: exchangeContentStart.upperBound..<source.endIndex) else {
            return XCTFail("expected exchangeContent followed by the header")
        }
        let exchangeContentRegion = source[exchangeContentStart.lowerBound..<exchangeContentEnd.lowerBound]
        let button = try requestMealButtonSource()

        let sharedColumnUsages = exchangeContentRegion.components(
            separatedBy: ".padding(.horizontal, CommonPlateStyle.Metrics.homeContentColumnInset)"
        ).count - 1
        + button.components(
            separatedBy: ".padding(.horizontal, CommonPlateStyle.Metrics.homeContentColumnInset)"
        ).count - 1
        XCTAssertEqual(
            sharedColumnUsages,
            4,
            "expected exactly four shared-column horizontal-inset call sites: the shared header composition (W4-H3 band and in-scroll copies), the ownership stack, the board stack, and the CTA"
        )

        XCTAssertFalse(
            exchangeContentRegion.contains(".padding(.horizontal, CommonPlateStyle.Spacing.l)"),
            "expected no remaining Home board-composition margin still pinned to the general-purpose Spacing.l step"
        )
        XCTAssertFalse(
            button.contains(".padding(.horizontal, CommonPlateStyle.Spacing.l)"),
            "expected no remaining CTA margin still pinned to the general-purpose Spacing.l step"
        )
    }

    /// The hard opaque cutoff Faith flagged on physical device is replaced
    /// with a static transparent-to-canvas gradient — no scroll-driven
    /// animation, pulse, or authored fade-in/out, per Faith's explicit soft-
    /// floating-CTA selection.
    func testRequestMealButtonUsesAStaticSoftTransitionNotAHardOpaqueCutoff() throws {
        let button = try requestMealButtonSource()

        XCTAssertTrue(button.contains("LinearGradient"), "expected a soft scrim above the CTA")
        XCTAssertTrue(button.contains("CommonPlateStyle.Color.baseCanvas.opacity(0)"))
        XCTAssertFalse(button.contains(".animation("))
        XCTAssertFalse(button.contains("repeatForever"))
        XCTAssertFalse(button.contains(".transition("))
    }

    /// The shared column inset must be a modest step beyond `Spacing.l`
    /// (the prior implementation's margin) and short of `Spacing.xl` — a
    /// bounded proportion correction toward the approved H2 Figma, not the
    /// dramatic narrowing the contract explicitly forbids.
    func testHomeContentColumnInsetIsAModestNotDramaticCorrection() throws {
        XCTAssertGreaterThan(
            CommonPlateStyle.Metrics.homeContentColumnInset,
            CommonPlateStyle.Spacing.l,
            "expected the shared column to narrow relative to the prior Spacing.l margin"
        )
        XCTAssertLessThan(
            CommonPlateStyle.Metrics.homeContentColumnInset,
            CommonPlateStyle.Spacing.xl,
            "expected a modest correction, not a jump to the much larger Spacing.xl step"
        )
    }

    private func requestMealButtonSource() throws -> Substring {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")
        guard let start = source.range(of: "private var requestMealButton: some View {"),
              let end = source.range(of: "// MARK: - Copy", range: start.upperBound..<source.endIndex) else {
            XCTFail("expected requestMealButton followed by the Copy section")
            return Substring("")
        }
        return source[start.lowerBound..<end.lowerBound]
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
