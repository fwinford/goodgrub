//
//  HomeRefreshExperienceTests.swift
//  CommonPlateiosTests
//
// W4-H3 — Home Refresh Experience. Focused coverage of the presentation
// contract layered over H2's unchanged refresh authority: board copy, the
// truthful-success predicate matrix, unavailable-body presentation, A2 header
// ownership (band / in-scroll handoff from scroll position only), and the
// structural invariants (one native refresh trigger, no custom
// gesture/threshold, the opacity-only non-focusable micro-check). Real
// store-level outcome truth is covered by `HomeRefreshOutcomeTests`. Rendered
// pull feel, header stationarity, native-indicator placement, handoff
// smoothness, VoiceOver, and Reduce Motion are physical-device checks, not
// proven here.
import Foundation
import XCTest
@testable import CommonPlateios

final class HomeRefreshExperienceTests: XCTestCase {
    private typealias Home = HomeExchangeView

    private func request(id: String) -> FoodRequest {
        FoodRequest(
            id: id,
            diningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            foodDescription: "Rice bowl",
            pickupWindowText: "ASAP",
            mealSwipes: 2,
            windowStart: nil,
            windowEnd: nil,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            status: .open,
            ownership: .notOwn
        )
    }

    // MARK: - Board copy

    func testBoardHeadingIsNeedsHelpInEveryHomeState() {
        XCTAssertEqual(Home.needsHelpHeading, "Needs help")
        XCTAssertEqual(Home.emptyHeading, "Needs help")
        XCTAssertEqual(Home.unavailableHeading, "Needs help")
        XCTAssertEqual(Home.loadingHeading, "Needs help")
    }

    func testNeedsHelpRightNowCopyIsGoneFromHome() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")
        // User-facing literal only; historical doc comments may still
        // describe earlier states by name.
        XCTAssertFalse(source.contains("\"Needs help right now\""))
    }

    // MARK: - Truthful-success predicate (W4-H3)

    private func acknowledges(
        inTime: Bool = true,
        outcome: RequestFetchOutcome?,
        state: Home.BoardState
    ) -> Bool {
        Home.shouldAcknowledgeRefreshSuccess(didResolveInTime: inTime, fetchOutcome: outcome, resolvedState: state)
    }

    func testEveryTruthfulSuccessCaseIsAcknowledgedWhateverTheDestination() {
        // Healthy → healthy, and each Unavailable → healthy destination, all
        // resolve to a healthy board and a succeeded outcome — the predicate
        // is destination-agnostic (Continue Helping / Your request(s) are
        // categories *within* a populated board).
        XCTAssertTrue(acknowledges(outcome: .succeeded, state: .populated([request(id: "a")])))
        XCTAssertTrue(acknowledges(outcome: .succeeded, state: .empty))
    }

    func testHealthyToHealthyIsAcknowledgedEvenWhenTheDataIsUnchanged() {
        // The predicate has no data-comparison input at all, so identical
        // refreshed data cannot suppress a truthful success.
        let same = Home.BoardState.populated([request(id: "a")])
        XCTAssertTrue(acknowledges(outcome: .succeeded, state: same))
    }

    func testTimeoutIsNeverAcknowledgedEvenIfTheOutcomeAndStateLookHealthy() {
        let populated = Home.BoardState.populated([request(id: "a")])
        XCTAssertFalse(acknowledges(inTime: false, outcome: .succeeded, state: populated))
        XCTAssertFalse(acknowledges(inTime: false, outcome: nil, state: populated))
        XCTAssertFalse(acknowledges(inTime: false, outcome: nil, state: .unavailable))
    }

    func testAnOutcomeThatDidNotSucceedIsNeverAcknowledgedOverHealthyData() {
        // A failed, cancelled, or superseded refresh that leaves stale healthy
        // data on screen looks identical to success at the view layer; only
        // the operation's own outcome distinguishes them.
        let stale = Home.BoardState.populated([request(id: "a")])
        XCTAssertFalse(acknowledges(outcome: .didNotSucceed, state: stale))
        XCTAssertFalse(acknowledges(outcome: .didNotSucceed, state: .empty))
        XCTAssertFalse(acknowledges(outcome: nil, state: stale))
    }

    func testUnresolvedOrUnavailableResultsAreNeverAcknowledged() {
        XCTAssertFalse(acknowledges(outcome: .succeeded, state: .loading))
        XCTAssertFalse(acknowledges(outcome: .succeeded, state: .unavailable))
        XCTAssertFalse(acknowledges(outcome: .didNotSucceed, state: .unavailable))
    }

    func testAccessibilityAnnouncementTextIsUpdatedAndNeverVisibleCopy() throws {
        XCTAssertEqual(Home.refreshSuccessText, "Updated")
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")
        // Only ever posted as the one announcement; never rendered in a Text.
        XCTAssertTrue(source.contains("AccessibilityNotification.Announcement(Self.refreshSuccessText).post()"))
        XCTAssertEqual(source.components(separatedBy: "AccessibilityNotification.Announcement(").count - 1, 1)
        XCTAssertFalse(source.contains("Text(Self.refreshSuccessText)"))
        XCTAssertFalse(source.contains("Text(HomeExchangeView.refreshSuccessText)"))
        XCTAssertFalse(source.contains("Text(\"Updated\")"))
    }

    // MARK: - Micro-check presentation

    func testMicroCheckIsABareEighteenPointNonFocusableNonInteractiveMark() throws {
        XCTAssertEqual(Home.refreshSuccessMarkSide, 18)
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")
        guard let markRange = source.range(of: "private var refreshSuccessMark: some View {"),
              let markEnd = source.range(of: "static let refreshSuccessMarkSide", range: markRange.upperBound..<source.endIndex)
        else {
            return XCTFail("expected refreshSuccessMark")
        }
        let mark = source[markRange.lowerBound..<markEnd.lowerBound]
        XCTAssertTrue(mark.contains("Image(systemName: \"checkmark\")"), "bare check glyph, not checkmark.circle")
        XCTAssertFalse(mark.contains("circle"))
        XCTAssertFalse(mark.contains("Text("))
        XCTAssertTrue(mark.contains(".foregroundStyle(Color.accentColor)"))
        XCTAssertTrue(mark.contains(".accessibilityHidden(true)"))
        XCTAssertTrue(mark.contains(".allowsHitTesting(false)"))
        XCTAssertFalse(mark.contains("Button"))
        XCTAssertFalse(mark.contains("NavigationLink"))
        XCTAssertFalse(mark.contains(".accessibilityLabel"))
        XCTAssertEqual(source.components(separatedBy: "refreshSuccessMark\n").count - 1, 1, "mounted in exactly one place")
    }

    func testMicroCheckSitsInTheTransientRefreshLaneNotInsideTheScrollOrTheRestGap() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")
        // Mounted as a non-scrolling layer over the one ScrollView, positioned
        // from the passive header anchors; no longer an overlay on the band's
        // rest gap.
        XCTAssertTrue(source.contains(".overlayPreferenceValue(HomeHeaderAnchorKey.self) { anchors in\n                refreshSuccessLayer(anchors)"))
        XCTAssertFalse(source.contains("bandHeader\n                    .overlay(alignment: .bottom)"))
    }

    func testSuccessTimingIsBriefAndNeverGatesHomeContent() throws {
        // The check begins on the native indicator clearing (event-driven; see
        // `HomeRefreshSettleSequencingTests`), not a fixed lead-in; the visible
        // mark is under a second and gates no hierarchy.
        XCTAssertLessThanOrEqual(Home.refreshSuccessRetireSeconds, 0.15)
        XCTAssertLessThanOrEqual(Home.refreshSuccessFadeInSeconds, 0.25)
        XCTAssertLessThanOrEqual(Home.refreshSuccessFadeOutSeconds, 0.3)
        let plan = try XCTUnwrap(HomeRefreshSettle.plan(
            reduceMotion: false, isHomePresented: true, ownsBandHeader: true
        ))
        XCTAssertLessThanOrEqual(plan.checkHold, .milliseconds(300))
        XCTAssertLessThanOrEqual(try XCTUnwrap(HomeRefreshSettle.plan(
            reduceMotion: true, isHomePresented: true, ownsBandHeader: true
        )).checkHold, .milliseconds(300))
    }

    // MARK: - Unavailable body

    func testUnavailableAreaPresentationPhases() {
        XCTAssertEqual(Home.unavailableAreaPresentation(isRefreshInFlight: false), .atRest)
        XCTAssertEqual(Home.unavailableAreaPresentation(isRefreshInFlight: true), .refreshing)
    }

    func testUnavailableTitleAndCueYieldWhileNeedsHelpHeadingStaysMounted() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")
        XCTAssertTrue(source.contains(".opacity(isBodyYielding ? 0 : 1)"))
        // `Needs help` is the shared heading row, rendered outside the
        // per-state board branches, so it is never part of what yields.
        XCTAssertTrue(source.contains("boardHeadingRow\n                                    .modifier"))
        XCTAssertEqual(source.components(separatedBy: "PullRefreshCue()").count - 1, 1)
    }

    // MARK: - Native refresh authority

    func testSingleNativeRefreshTriggerWithNoCustomGestureOrThreshold() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")
        XCTAssertEqual(source.components(separatedBy: ".refreshable {").count - 1, 1)
        XCTAssertFalse(source.contains("DragGesture"))
        XCTAssertFalse(source.contains("Release to refresh"))
        XCTAssertFalse(source.contains("releaseToRefresh"))
        XCTAssertTrue(source.contains("await store.fetchRequests()"))
        XCTAssertEqual(Home.manualRefreshDeadline, .seconds(5))
        XCTAssertEqual(source.components(separatedBy: "ScrollView {").count - 1, 1, "one scroll surface only")
    }

    func testNoForbiddenHeaderOrRefreshMechanismExists() throws {
        // Executable source only: doc comments may legitimately name a
        // rejected mechanism to explain why it is absent.
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(source.contains("UIRefreshControl"))
        XCTAssertFalse(source.contains("UIScrollView"))
        XCTAssertFalse(source.contains("contentInset"), "no manual content-inset manipulation")
        XCTAssertFalse(source.contains("UIViewRepresentable"))
        XCTAssertFalse(source.contains("Timer"))
        XCTAssertFalse(source.contains("onScrollGeometryChange"), "iOS 18-only; the deployment target is 17.6")
        XCTAssertFalse(source.contains("onScrollPhaseChange"))
    }

    // MARK: - A2 header ownership

    func testBandHeaderOwnsRestPullAndTheToleranceBand() {
        XCTAssertTrue(Home.ownsBandHeader(scrollOffset: 0))
        XCTAssertTrue(Home.ownsBandHeader(scrollOffset: -80), "pulled down: the band header stays")
        XCTAssertTrue(Home.ownsBandHeader(scrollOffset: Home.headerHandoffTolerance), "inside the tolerance is still rest")
    }

    func testInScrollHeaderOwnsOnlyOncePastTheTolerance() {
        XCTAssertFalse(Home.ownsBandHeader(scrollOffset: Home.headerHandoffTolerance + 0.5))
        XCTAssertFalse(Home.ownsBandHeader(scrollOffset: 120))
    }

    func testScrollOffsetIsTheInScrollCopysTravelFromTheBandCopy() {
        XCTAssertEqual(Home.headerScrollOffset(bandMinY: 100, scrollingMinY: 100), 0)
        XCTAssertEqual(Home.headerScrollOffset(bandMinY: 100, scrollingMinY: 60), 40, "scrolled up 40")
        XCTAssertEqual(Home.headerScrollOffset(bandMinY: 100, scrollingMinY: 160), -60, "pulled down 60")
    }

    func testCommonGlobalTranslationDoesNotChangeScrollOffset() {
        let original = Home.headerScrollOffset(bandMinY: 100, scrollingMinY: 60)
        let translated = Home.headerScrollOffset(bandMinY: 273, scrollingMinY: 233)
        XCTAssertEqual(translated, original)
    }

    func testExactlyOneHeaderRepresentationIsActiveForAnyOwnership() {
        for ownsBand in [true, false] {
            let band = Home.isHeaderRepresentationActive(.band, ownsBandHeader: ownsBand)
            let scrolling = Home.isHeaderRepresentationActive(.scrolling, ownsBandHeader: ownsBand)
            XCTAssertNotEqual(band, scrolling, "exactly one representation is active (ownsBand=\(ownsBand))")
        }
        XCTAssertTrue(Home.isHeaderRepresentationActive(.band, ownsBandHeader: true))
        XCTAssertTrue(Home.isHeaderRepresentationActive(.scrolling, ownsBandHeader: false))
    }

    func testOneRuleDrivesVisibilityHitTestingAndAccessibilityForBothHeaderCopies() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")
        guard let start = source.range(of: "private func ownedHeader(_ representation: HeaderRepresentation) -> some View {"),
              let end = source.range(of: "private var bandHeader: some View {", range: start.upperBound..<source.endIndex)
        else {
            return XCTFail("expected ownedHeader")
        }
        let body = source[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(body.contains("let isActive = Self.isHeaderRepresentationActive(representation, ownsBandHeader: ownsBandHeader)"))
        XCTAssertTrue(body.contains(".opacity(isActive ? 1 : 0)"))
        XCTAssertTrue(body.contains(".allowsHitTesting(isActive)"))
        XCTAssertTrue(body.contains(".accessibilityHidden(!isActive)"))
        XCTAssertTrue(body.contains(".transaction { $0.animation = nil }"), "the handoff itself is never animated")
        // Both copies render the one shared composition and one Settings link.
        XCTAssertEqual(source.components(separatedBy: "NavigationLink(value: AppRoute.settings)").count - 1, 1)
        XCTAssertEqual(source.components(separatedBy: "ownedHeader(.").count - 1, 2)
        XCTAssertTrue(source.contains("headerComposition\n            .background("))
    }

    func testOwnershipIsDerivedFromScrollGeometryAloneNeverRefreshStateOrTimers() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")
        XCTAssertEqual(source.components(separatedBy: "ownsBandHeader = owner").count - 1, 1, "single writer")
        guard let start = source.range(of: ".onPreferenceChange(HomeHeaderAnchorKey.self)"),
              let end = source.range(of: ".background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())", range: start.upperBound..<source.endIndex)
        else {
            return XCTFail("expected the single ownership writer")
        }
        let writer = source[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(writer.contains("Self.ownsBandHeader("))
        XCTAssertTrue(writer.contains("Self.headerScrollOffset(bandMinY: bandMinY, scrollingMinY: scrollingMinY)"))
        XCTAssertFalse(writer.contains("isRefreshInFlight"))
        XCTAssertFalse(writer.contains("isShowingRefreshSuccess"))
        XCTAssertFalse(writer.contains("Task"))
        XCTAssertFalse(writer.contains("sleep"))
    }

    func testBandIsAReservedTopInsetWithNoChromeAndInScrollCopyAddsNoLayoutHeight() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")
        XCTAssertTrue(source.contains(".safeAreaInset(edge: .top, spacing: 0) {\n                bandHeader"))
        guard let start = source.range(of: "private var headerComposition: some View {"),
              let end = source.range(of: "private func ownedHeader(", range: start.upperBound..<source.endIndex)
        else {
            return XCTFail("expected headerComposition")
        }
        // No bar/divider/background chrome on the shared composition.
        XCTAssertFalse(source[start.lowerBound..<end.lowerBound].contains(".background(CommonPlateStyle"))
        // The in-scroll copy has zero layout height, so it cannot create
        // scroll range, and short content is sized to the band-reduced
        // viewport.
        XCTAssertTrue(source.contains("Color.clear\n            .frame(height: 0)\n            .overlay(alignment: .bottomLeading)"))
        XCTAssertTrue(source.contains(".frame(minHeight: max(0, geometry.size.height - headerBandHeight), alignment: .top)"))
        XCTAssertEqual(Home.contentTopPaddingBelowBand + CommonPlateStyle.Spacing.s, CommonPlateStyle.Spacing.l,
                       "rest header-to-content spacing is unchanged from before the band")
    }

    func testRequestAMealRemainsStructurallyOutsideTheScroll() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")
        XCTAssertTrue(source.contains(".safeAreaInset(edge: .bottom) {\n                requestMealButton"))
    }

    func testHierarchyResolutionAnimationIsRefreshScopedAndSuppressedUnderReduceMotion() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")
        // The refresh resolution stays scoped to refresh-driven changes; the
        // selected pickup collapse (Figma 1603:7208) owns the one change it causes.
        XCTAssertTrue(source.contains("(animatesHierarchyResolution ? .easeInOut(duration: 0.25) : nil)"))
        XCTAssertTrue(source.contains("reduceMotion\n                        ? nil\n                        : (isPlayingPickupCollapse"))
    }

    // MARK: - Stale healthy refresh is unchanged

    func testPreviouslyHealthyBoardStaysPopulatedWhenARefreshFailsAfterSuccess() {
        let requests = [request(id: "a")]
        let state = Home.boardState(
            hasSuccessfullyFetchedRequests: true,
            hasAttemptedRequestFetch: true,
            hasFailedInitialFetchAtLeastOnce: false,
            isFetching: false,
            requests: requests
        )
        XCTAssertEqual(state, .populated(requests))
    }

    // MARK: - 3+ owned `See all`

    func testSeeAllIsCountFreeAndOnlyForThreeOrMoreOwned() {
        let owned = (1...4).map { request(id: "r\($0)") }
        XCTAssertNil(Home.ownRequestsPreview([]).seeAllCount)
        XCTAssertNil(Home.ownRequestsPreview(Array(owned.prefix(1))).seeAllCount)
        XCTAssertNil(Home.ownRequestsPreview(Array(owned.prefix(2))).seeAllCount)
        XCTAssertEqual(Home.ownRequestsPreview(Array(owned.prefix(3))).seeAllCount, 3)
        XCTAssertEqual(Home.ownRequestsHeading(count: 3), "Your requests")
        XCTAssertEqual(Home.seeAllOwnRequestsTitle, "See all")
        XCTAssertEqual(Home.seeAllOwnRequestsAccessibilityLabel(count: 4), "See all 4 requests")
    }

    func testSeeAllKeepsDestinationFortyFourPointTargetAndLargeTypeLayout() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")
        XCTAssertTrue(source.contains("seeAllRoute: seeAllCount == nil ? nil : .ownRequests(ownRequests)"))
        XCTAssertTrue(source.contains("NavigationLink(value: seeAllRoute)"))
        XCTAssertTrue(source.contains(".frame(minWidth: 44, minHeight: 44, alignment: .trailing)"))
        XCTAssertTrue(source.contains("dynamicTypeSize.isAccessibilitySize"))
        XCTAssertTrue(source.contains(".accessibilityLabel(Self.seeAllOwnRequestsAccessibilityLabel(count: seeAllCount))"))
    }

    // MARK: - Prototype deletion

    func testStaleDebugRefreshPrototypeIsDeleted() throws {
        let root = repoRoot()
        let prototype = root.appendingPathComponent(
            "ios/CommonPlateios/CommonPlateios/Views/Prototypes/RefreshMotionPrototypeView.swift"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: prototype.path))
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func fileSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }
}
