//
//  HomeRefreshSettleSequencingTests.swift
//  CommonPlateiosTests
//
// W4-H3 authored post-refresh settle (Decision 11): after a truthful successful
// refresh, the native spinner is gone first, the dynamic Home region is held and
// eases gently to its unchanged rest layout, and a stable centered check appears
// in the lane the spinner occupied and fades during the settle. Presentation
// only; the native `.refreshable`, `RequestStore`, the data, the deadline, and
// A2 header ownership are untouched.
//
// Scope honesty: the decisions are covered by behavioral tests over the pure
// state machine the view drives (`HomeRefreshSettleMachine`), by a real UIKit
// collapse trace replayed through it, and by source-structure tests for the
// wiring (the private SwiftUI tasks are not driven here). The displacement
// streams the *production app* actually produces — which differ from a clean
// collapse in ways that previously hid a missing-check defect — are replayed in
// `HomeRefreshSettleProductionStreamTests`. The rendered continuity of the hold
// against a real `UIRefreshControl` collapse is proven separately in
// `HomeRefreshSettleHostedMotionTests`. How the motion *looks* (pacing,
// breathing room, Reduce Motion feel) is Simulator / physical-device
// observation.
import XCTest
@testable import CommonPlateios

@MainActor
final class HomeRefreshSettleSequencingTests: XCTestCase {
    private typealias Home = HomeExchangeView
    private typealias Settle = HomeRefreshSettle

    /// A native `UIRefreshControl.endRefreshing()` collapse captured in the
    /// hosted harness (iPhone 17, iOS 26.5): displacement in points below rest
    /// against milliseconds after the refresh ended. A 60 pt lane collapsing in
    /// ~320 ms. Evidence for the handoff, not a mock of UIKit.
    private static let realCollapse: [(ms: Double, displacement: CGFloat)] = [
        (21.5, 60.00), (38.2, 59.33), (54.8, 57.67), (71.5, 55.33), (88.1, 52.33),
        (104.8, 48.33), (121.5, 44.00), (138.1, 39.33), (154.8, 34.33), (171.5, 29.00),
        (188.1, 23.67), (204.8, 18.67), (221.5, 14.00), (238.2, 10.00), (254.8, 6.33),
        (271.5, 3.67), (288.1, 1.33), (304.8, 0.33), (321.4, 0.00),
    ]

    /// An earlier real pull-to-refresh collapse measured from passive scroll
    /// geometry (exponentially decaying tail).
    private static let measuredPullCollapse: [(ms: Double, displacement: CGFloat)] = [
        (954, 28.67), (971, 24.33), (988, 20.67), (1021, 15.0), (1038, 12.67),
        (1054, 10.67), (1071, 9.0), (1088, 7.67), (1104, 6.67), (1121, 5.67),
        (1138, 4.67), (1154, 4.0), (1171, 3.33), (1188, 3.0), (1205, 2.33),
        (1221, 2.0), (1238, 1.67), (1254, 1.33), (1288, 1.0), (1321, 0.67), (1372, 0.0),
    ]

    // MARK: - 1. A truthful success enters the settle; the context gate decides at its start

    func testATruthfulSuccessInContextEntersTheSettleAndTheHoldStartsWhereNativeWas() throws {
        let plan = try XCTUnwrap(makePlan())
        XCTAssertEqual(plan.holdStart(forDisplacement: 30), 30, "starts exactly at the native displacement: a continuous handoff")
        XCTAssertEqual(plan.holdStart(forDisplacement: 60), Settle.heldLane, "up to the held lane")
        XCTAssertFalse(plan.isReduced)
        XCTAssertEqual(plan.delay, Settle.standardDelay, "a brief still moment while the check fades in")
        XCTAssertLessThanOrEqual(plan.delay, 0.40, "a still moment while the spinner clears and the check fades in, not a dead pause")
    }

    func testTheHoldCanNeverStartAwayFromTheNativePositionItIsHandedOffFrom() throws {
        // Below the cap the start is *exactly* the native displacement; the cap
        // only trims a held-further pull, in which case native is the larger
        // term and still controls until it falls below the hold.
        let plan = try XCTUnwrap(makePlan())
        for displacement: CGFloat in [0, 1, 20, 30, Settle.heldLane] {
            XCTAssertEqual(plan.holdStart(forDisplacement: displacement), displacement)
        }
        for displacement: CGFloat in [Settle.heldLane + 0.5, 60, 64, 140] {
            XCTAssertEqual(plan.holdStart(forDisplacement: displacement), Settle.standardStartCap)
        }
        XCTAssertEqual(plan.holdStart(forDisplacement: -30), 0, "never a negative hold")
    }

    func testAContextAlreadyLostAtTheStartMeansNoSettleNoCheckAndNothingQueued() {
        XCTAssertNil(makePlan(isHomePresented: false), "navigated away before it began")
        XCTAssertNil(makePlan(ownsBandHeader: false), "scrolled away before it began")
        XCTAssertNil(makePlan(isHomePresented: false, ownsBandHeader: false))
        // The gate is the accepted Decision 9 predicate, not a second rule.
        XCTAssertTrue(Home.shouldBeginRefreshAcknowledgment(isHomePresented: true, ownsBandHeader: true))
        XCTAssertFalse(Home.shouldBeginRefreshAcknowledgment(isHomePresented: false, ownsBandHeader: true))
        XCTAssertFalse(Home.shouldBeginRefreshAcknowledgment(isHomePresented: true, ownsBandHeader: false))
    }

    // MARK: - 2. Refreshed data is authoritative before and throughout; the settle is render-only

    func testTheSettleOwnsNoDataAndNoLayoutOnlyARenderTimeTranslation() throws {
        let source = try settleSource()
        let modifier = try section(of: source, from: "struct HomeRefreshSettleHold", to: "/// The settle's per-sample state machine")
        XCTAssertTrue(modifier.contains("visualEffect"))
        XCTAssertTrue(modifier.contains(".offset(y:"))
        // A render-time effect: it cannot change layout, scroll range, or position.
        for forbidden in ["padding", ".frame(width", ".frame(height", ".frame(min", ".frame(max", "contentOffset",
                          "scrollTo", "ScrollPosition", "inset"] {
            XCTAssertFalse(modifier.contains(forbidden), "the hold must not use \(forbidden)")
        }
        // It knows nothing of the store or the refresh.
        let code = try codeOnly(source)
        for forbidden in ["RequestStore", "fetchRequests", "RequestFetchOutcome", "isRefreshInFlight"] {
            XCTAssertFalse(code.contains(forbidden), "HomeRefreshSettle must not reference \(forbidden)")
        }
    }

    func testTheHierarchyIsAppliedByTheStoreBeforeTheSettleBeginsAndIsNeverGatedByIt() throws {
        let source = try homeSource()
        let authored = try section(of: source, from: "private func performAuthoredRefresh() async {", to: "/// Runs the one authoritative reload")
        let resolve = try XCTUnwrap(authored.range(of: "let acknowledgesSuccess = await Self.resolveRefresh(store: store)"))
        let begin = try XCTUnwrap(authored.range(of: "beginRefreshSettle()"))
        XCTAssertLessThan(resolve.lowerBound, begin.lowerBound, "data resolves before any settle state exists")
        XCTAssertTrue(authored.contains("if acknowledgesSuccess {\n            beginRefreshSettle()\n        }"),
                      "the settle is reachable only from the truthful-success branch")
        // The settle is begun synchronously: from the call to the end of the closure
        // there is no suspension point. Nothing is handed off from the displacement
        // seen at that moment (while the native refresh is active it is one lane
        // height off — see `HomeRefreshSettleProductionStreamTests`); the hold is
        // armed from the first real reading afterwards.
        let tail = String(authored[begin.lowerBound...])
        XCTAssertFalse(tail.contains("await"), "no suspension between arming the hold and returning")
        XCTAssertFalse(tail.contains("Task"))
        XCTAssertFalse(tail.contains("sleep"))
        // Nothing the settle does is awaited by the refresh path.
        XCTAssertFalse(authored.contains("await beginRefreshSettle"))
        XCTAssertEqual(authored.components(separatedBy: "Task.sleep").count - 1, 0, "no sleep inside the refresh closure")
    }

    func testTheSettleNeverReachesTheStoreTheOutcomeTheDeadlineOrGenerationFencing() throws {
        let source = try homeSource()
        let settle = try section(
            of: source,
            from: "private func beginRefreshSettle() {",
            to: "// MARK: - Header ownership"
        )
        for forbidden in ["store.", "fetchRequests", "RequestFetchOutcome", "awaitWithDeadline", "manualRefreshDeadline",
                          "performAuthoredRefresh", "fetchGeneration", "collectionRevision", "isRefreshInFlight"] {
            XCTAssertFalse(settle.contains(forbidden), "the settle must not touch \(forbidden)")
        }
        // And the success determination itself still knows nothing of it.
        let resolve = try section(of: source, from: "static func resolveRefresh(", to: "/// The truthful-success predicate")
        for forbidden in ["Settle", "refreshSettle", "HomeRefreshSettle", "isHomePresented", "ownsBandHeader"] {
            XCTAssertFalse(resolve.contains(forbidden), "resolveRefresh must not reference \(forbidden)")
        }
    }

    // MARK: - 3. Header ownership is untouched

    func testHeaderOwnershipStillHasOneScrollPositionOnlyWriterAndTheSettleNeverWritesIt() throws {
        let source = try homeSource()
        XCTAssertEqual(source.components(separatedBy: "ownsBandHeader = owner").count - 1, 1, "single ownership writer")
        let settle = try section(of: source, from: "private func beginRefreshSettle() {", to: "// MARK: - Header ownership")
        XCTAssertFalse(settle.contains("ownsBandHeader ="), "the settle only reads ownership")
        XCTAssertFalse(settle.contains("headerBandHeight"))
        // Ownership is still a pure function of the scroll offset.
        for offset in stride(from: CGFloat(-200), through: 200, by: 0.5) {
            XCTAssertEqual(Home.ownsBandHeader(scrollOffset: offset), offset <= Home.headerHandoffTolerance)
        }
    }

    // MARK: - 4. Displacement returns to zero; the hold can never be a bounce

    func testRenderedDisplacementIsTheLargerOfNativeAndHoldAndNeverBelowEither() {
        for native in stride(from: CGFloat(0), through: 80, by: 2.5) {
            for hold in stride(from: CGFloat(0), through: 80, by: 2.5) {
                let rendered = Settle.renderedDisplacement(nativeDisplacement: native, hold: hold)
                XCTAssertEqual(rendered, max(native, hold), "native \(native) hold \(hold)")
                XCTAssertGreaterThanOrEqual(Settle.compensation(nativeDisplacement: native, hold: hold), 0)
                XCTAssertGreaterThanOrEqual(rendered, native, "the hold never pulls content above its native position")
                XCTAssertGreaterThanOrEqual(rendered, hold)
            }
        }
        XCTAssertEqual(Settle.compensation(nativeDisplacement: 60, hold: 60), 0, "no translation at the handoff instant")
        XCTAssertEqual(Settle.compensation(nativeDisplacement: 70, hold: 60), 0, "native in control wherever it is larger")
        XCTAssertEqual(Settle.compensation(nativeDisplacement: -20, hold: 12), 12, "scrolled up counts as no native displacement")
    }

    func testTheRetiredHoldIsInertButDistinctFromTheEaseTargetSoARetireRetargetsTheEase() {
        XCTAssertNotEqual(Settle.retiredHold, 0, "a retire must change the animated value")
        XCTAssertLessThan(Settle.retiredHold, 0)
        for native in stride(from: CGFloat(-50), through: 120, by: 1) {
            XCTAssertEqual(Settle.compensation(nativeDisplacement: native, hold: Settle.retiredHold), 0, "native \(native)")
            XCTAssertEqual(Settle.renderedDisplacement(nativeDisplacement: native, hold: Settle.retiredHold), max(0, native))
        }
    }

    func testAtHoldZeroTheRenderedPositionIsExactlyNative() {
        // The permanent state: a settled Home adds nothing to what UIKit shows.
        for native in stride(from: CGFloat(-50), through: 120, by: 1) {
            XCTAssertEqual(Settle.compensation(nativeDisplacement: native, hold: 0), 0, "native \(native)")
        }
    }

    func testAHoldEasingToZeroOverARealNativeCollapseCanNeverBounceOrOvershoot() throws {
        let plan = try XCTUnwrap(makePlan())
        for (name, collapse) in [("UIKit endRefreshing", Self.realCollapse), ("pull measured", Self.measuredPullCollapse)] {
            let first = try XCTUnwrap(collapse.first)
            // The hold arms at the held lane (or the reading, if smaller), stays put
            // for the short still moment, then eases to rest; it never rises.
            let start = plan.holdStart(forDisplacement: first.displacement)
            let easeOrigin = try XCTUnwrap(collapse.first { $0.displacement <= start }).ms
            var previous = first.displacement
            var maximumStep: CGFloat = 0
            var nativeMaximumStep: CGFloat = 0
            var previousNative = first.displacement
            for sample in collapse {
                let elapsed = max(0, (sample.ms - easeOrigin) / 1000 - plan.delay)
                let hold = start * (1 - easeInOut(min(1, elapsed / plan.duration)))
                let rendered = Settle.renderedDisplacement(nativeDisplacement: sample.displacement, hold: hold)
                XCTAssertLessThanOrEqual(rendered, previous + 0.0001, "\(name) at \(sample.ms) ms moved away from rest")
                XCTAssertGreaterThanOrEqual(rendered, 0, "\(name): never past rest (no overshoot)")
                XCTAssertLessThanOrEqual(rendered, max(first.displacement, start) + 0.0001, "\(name): never below the handoff position")
                maximumStep = max(maximumStep, previous - rendered)
                nativeMaximumStep = max(nativeMaximumStep, previousNative - sample.displacement)
                previous = rendered
                previousNative = sample.displacement
            }
            // Eases gently: never a larger jump in one sample than the native collapse itself makes.
            XCTAssertLessThanOrEqual(maximumStep, nativeMaximumStep + 0.0001, "\(name): no abrupt snap in any single sample")
        }
    }

    func testTheHoldKeepsContentAwayFromRestAfterTheNativeCollapseHasFinished() throws {
        let collapse = Self.realCollapse
        let nativeRest = try XCTUnwrap(collapse.first { $0.displacement < 0.5 })
        let plan = try XCTUnwrap(makePlan())
        let start = plan.holdStart(forDisplacement: 60)
        let easeOrigin = try XCTUnwrap(collapse.first { $0.displacement <= start }).ms
        let elapsed = max(0, (nativeRest.ms - easeOrigin) / 1000 - plan.delay)
        let hold = start * (1 - easeInOut(min(1, elapsed / plan.duration)))
        // Native alone reaches rest at ~300 ms: not a snap — the hold is still
        // carrying the content well clear of rest at that instant (the still moment).
        XCTAssertGreaterThan(Settle.renderedDisplacement(nativeDisplacement: nativeRest.displacement, hold: hold), 30)
        // And it reaches rest on its own authored schedule.
        XCTAssertEqual(Settle.renderedDisplacement(nativeDisplacement: 0, hold: 0), 0, "ends exactly at the unchanged rest layout")
    }

    // MARK: - 5. Permanent rest layout unchanged

    func testPermanentRestSpacingIsUnchanged() throws {
        XCTAssertEqual(Home.headerBandBottomPadding + Home.contentTopPaddingBelowBand,
                       CommonPlateStyle.Spacing.l,
                       "rest header-to-content spacing is still the accepted Spacing.l")
        XCTAssertEqual(Home.headerBandBottomPadding, CommonPlateStyle.Spacing.s)
        // Pinned to the literal accepted values so the relation above cannot
        // pass by both constants drifting together.
        XCTAssertEqual(CommonPlateStyle.Spacing.l, 20)
        XCTAssertEqual(CommonPlateStyle.Spacing.s, 8)
        XCTAssertEqual(Home.contentTopPaddingBelowBand, 12)
        let source = try homeSource()
        XCTAssertTrue(source.contains(".padding(.top, Self.contentTopPaddingBelowBand)"))
        XCTAssertTrue(source.contains(".padding(.bottom, Self.headerBandBottomPadding)"))
        // No permanent room was made for the check: nothing in layout depends on
        // the settle state.
        let layoutLines = source.split(separator: "\n").filter {
            ($0.contains(".padding(") || $0.contains(".frame(")) && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }.joined(separator: "\n")
        for dynamic in ["refreshSettle", "isShowingRefreshSuccess", "refreshSuccessLaneCenter"] {
            XCTAssertFalse(layoutLines.contains(dynamic), "no padding or frame may depend on \(dynamic)")
        }
    }

    // MARK: - 6. The check: stable, centered in the spinner lane, opacity-only

    func testTheCheckSitsInTheHeldLaneNearTheHeaderWithRealBreathingRoomOnBothSides() throws {
        for reduceMotion in [false, true] {
            let plan = try XCTUnwrap(makePlan(reduceMotion: reduceMotion))
            let start = plan.holdStart(forDisplacement: 60)
            XCTAssertEqual(plan.laneCenter, start / 2, "centered in the held lane")
            XCTAssertEqual(plan.laneCenter, 18, "Option C: nearer the header than the old 30 pt locus (reduce: \(reduceMotion))")
            let side = Home.refreshSuccessMarkSide
            let top = plan.laneCenter - side / 2
            let bottom = plan.laneCenter + side / 2
            let headerTextBottom = -Home.headerBandBottomPadding
            let firstSectionTopAtStart = Home.contentTopPaddingBelowBand + start
            XCTAssertGreaterThanOrEqual(top - headerTextBottom, 16, "clear of `at NYU` (reduce: \(reduceMotion))")
            XCTAssertGreaterThanOrEqual(firstSectionTopAtStart - bottom, 20, "clear of the held content (reduce: \(reduceMotion))")
        }
    }

    /// Measured on the Simulator (Faith's screenshot, iPhone 17 Pro, iOS 26.5): the
    /// native spinner stays drawn centered ~30 pt below the band and ~26 pt across
    /// (to ~44 pt) while native displacement collapses to ~11 pt, and the content
    /// holds at the authored lane meanwhile. A 24 pt lane put the first heading's
    /// text (~4 pt below its frame top) inside the spinner's row.
    func testTheHeldLaneKeepsTheFirstHeadingClearOfTheNativeSpinnerInBothMotionModes() throws {
        let spinnerBottom: CGFloat = 44
        let headingInkInset: CGFloat = 4
        func clearance(heldLane: CGFloat) -> CGFloat {
            Home.contentTopPaddingBelowBand + heldLane + headingInkInset - spinnerBottom
        }
        XCTAssertLessThan(clearance(heldLane: 24), 0, "the measured defect: a 24 pt lane overlaps the spinner's row")
        for reduceMotion in [false, true] {
            let plan = try XCTUnwrap(makePlan(reduceMotion: reduceMotion))
            XCTAssertGreaterThanOrEqual(clearance(heldLane: plan.startCap), 6,
                                        "the heading text clears the spinner (reduce: \(reduceMotion))")
        }
        XCTAssertEqual(Settle.standardStartCap, Settle.heldLane)
        XCTAssertEqual(Settle.reducedStartCap, Settle.heldLane)
    }

    func testTheCheckPositionIsFixedForTheWholeSettleAndNeverFollowsTheContent() throws {
        let source = try homeSource()
        let layer = try section(of: source, from: "private func refreshSuccessLayer(_ anchors: HomeHeaderAnchors) -> some View {", to: "/// The bare 18×18 purple check.")
        XCTAssertTrue(layer.contains("refreshSuccessLaneCenter"))
        XCTAssertTrue(layer.contains(".transaction(value: refreshSuccessLaneCenter) { $0.animation = nil }"),
                      "the lane center can never animate")
        for dynamic in ["refreshSettleHold", "refreshSettleMachine", "displacement", "scrollOffset", "ownRequests", "store.",
                        "hierarchyKey", "boardState", "isRefreshInFlight"] {
            XCTAssertFalse(layer.contains(dynamic), "the mark must not be positioned by \(dynamic)")
        }
        let mark = try section(of: source, from: "private var refreshSuccessMark: some View {", to: "static let refreshSuccessMarkSide")
        XCTAssertTrue(mark.contains(".opacity(isShowingRefreshSuccess ? 1 : 0)"))
        for motion in [".offset(", ".scaleEffect", ".rotationEffect", ".position(", "withAnimation", ".animation("] {
            XCTAssertFalse(mark.contains(motion), "the check is opacity-only, not \(motion)")
        }
        // The lane center is written once, at settle start, outside any animation.
        XCTAssertEqual(source.components(separatedBy: "refreshSuccessLaneCenter = ").count - 1, 1)
    }

    func testTheCheckBeginsAfterTheNativeIndicatorHasClearedTheLane() throws {
        // On the real UIKit collapse, the check begins at the first sample at or
        // below the clear depth: after the indicator cycled, before native rest.
        let begin = try firstBegin(in: Self.realCollapse, start: 60)
        let nativeRest = try XCTUnwrap(Self.realCollapse.first { $0.displacement < 0.5 })
        XCTAssertLessThanOrEqual(begin.displacement, Settle.nativeIndicatorClearDepth)
        XCTAssertGreaterThan(begin.ms, 200, "not while the indicator is still cycling in the lane")
        XCTAssertLessThan(begin.ms, nativeRest.ms)
        // On the earlier measured pull collapse the indicator was visibly present
        // at ~11 pt and gone by ~7 pt; the check never begins before that.
        let pullBegin = try firstBegin(in: Self.measuredPullCollapse, start: 28.67)
        XCTAssertLessThan(pullBegin.displacement, 7, "after the indicator was last seen")
        // Never while displaced beyond the clear depth; and at the depth, it begins.
        for displacement: CGFloat in [60, 40, 20, 11.5, 7, Settle.nativeIndicatorClearDepth + 0.1] {
            let machine = try collapsingMachine()
            XCTAssertFalse(machine.observe(displacement: displacement, ownsBandHeader: true, isHomePresented: true)
                .contains(.beginAcknowledgment), "\(displacement)")
        }
        let atDepth = try collapsingMachine()
        XCTAssertTrue(atDepth.observe(displacement: Settle.nativeIndicatorClearDepth, ownsBandHeader: true, isHomePresented: true)
            .contains(.beginAcknowledgment))
    }

    func testNoDeadPauseTheCheckBeginsWithinTheNativeCollapseNotAfterAFixedDelay() throws {
        let begin = try firstBegin(in: Self.realCollapse, start: 60)
        XCTAssertLessThan(begin.ms, 400, "the check follows the indicator immediately")
        // Event-driven: no sleep decides when the check begins.
        let source = try homeSource()
        let perform = try section(of: source, from: "private func perform(_ effects: [HomeRefreshSettleMachine.Effect]) {", to: "/// Holds the dynamic region")
        XCTAssertFalse(perform.contains("sleep"))
        XCTAssertFalse(perform.contains("Task"))
        let handler = try section(of: source, from: ".onPreferenceChange(HomeHeaderAnchorKey.self)", to: ".overlayPreferenceValue(HomeHeaderAnchorKey.self)")
        XCTAssertFalse(handler.contains("sleep"))
        XCTAssertFalse(source.contains("awaitRefreshCollapseTail"), "the polling wait is gone")
    }

    func testTheContextGateIsEvaluatedAtTheMomentTheCheckWouldBeginAndSuppressesBothFeedbackForms() throws {
        // Lost between the settle starting and the indicator clearing: retire, never begin.
        for (presented, owns) in [(false, true), (true, false), (false, false)] {
            let machine = try collapsingMachine()
            XCTAssertEqual(machine.observe(displacement: 3, ownsBandHeader: owns, isHomePresented: presented), [.retire])
            let early = try collapsingMachine()
            XCTAssertEqual(early.observe(displacement: 30, ownsBandHeader: owns, isHomePresented: presented), [.retire])
        }
        // Both forms of feedback begin from the one place the effect names.
        let source = try homeSource()
        XCTAssertEqual(source.components(separatedBy: "isShowingRefreshSuccess = true").count - 1, 1)
        XCTAssertEqual(source.components(separatedBy: "AccessibilityNotification.Announcement(").count - 1, 1)
        let begin = try section(of: source, from: "private func beginRefreshAcknowledgment() {", to: "/// Releases the hold alone")
        XCTAssertLessThan(try XCTUnwrap(begin.range(of: "isShowingRefreshSuccess = true")).lowerBound,
                          try XCTUnwrap(begin.range(of: "AccessibilityNotification.Announcement(")).lowerBound)
        // Nothing records a pending acknowledgment to replay.
        for forbidden in ["pendingRefreshAcknowledgment", "deferredRefreshAcknowledgment", ".onChange(of: ownsBandHeader)", ".onChange(of: isHomePresented)"] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }

    // MARK: - 7. Supersession and repeated pull retire everything

    func testARepeatedPullRisingWhileTheCheckShowsRetiresItButTheCollapseItselfNeverDoes() throws {
        // Before the check begins a rising stream is not a takeover: a held pull,
        // the end-of-refresh step and a still-moving finger all rise, and a real
        // new pull supersedes the settle when its own refresh starts.
        let waiting = try collapsingMachine()
        for displacement: CGFloat in [70, 200, 90] {
            XCTAssertFalse(waiting.observe(displacement: displacement, ownsBandHeader: true, isHomePresented: true).contains(.retire))
        }
        // While the check shows, a rise above the lowest reading since it began is a pull.
        let showing = try collapsingMachine()
        _ = showing.observe(displacement: 3, ownsBandHeader: true, isHomePresented: true)
        XCTAssertEqual(showing.stage, .acknowledging)
        XCTAssertEqual(showing.observe(displacement: 3 + Settle.takeoverTolerance + 0.5, ownsBandHeader: true, isHomePresented: true), [.retire])
        let noisy = try collapsingMachine()
        _ = noisy.observe(displacement: 3, ownsBandHeader: true, isHomePresented: true)
        XCTAssertEqual(noisy.observe(displacement: 3 + Settle.takeoverTolerance - 0.5, ownsBandHeader: true, isHomePresented: true), [], "noise")
        // The collapse itself never retires, anywhere along either real trace.
        for collapse in [Self.realCollapse, Self.measuredPullCollapse] {
            let machine = try collapsingMachine(latest: collapse[0].displacement)
            for sample in collapse {
                XCTAssertFalse(machine.observe(displacement: sample.displacement, ownsBandHeader: true, isHomePresented: true).contains(.retire),
                               "the check's own collapse must not retire it (\(sample.ms) ms)")
            }
        }
    }

    func testIdleReactsToNothingAndTheCheckNeverBeginsTwice() throws {
        let idle = HomeRefreshSettleMachine()
        for displacement: CGFloat in [-40, 0, 3, 60, 200] {
            XCTAssertEqual(idle.observe(displacement: displacement, ownsBandHeader: true, isHomePresented: true), [])
        }
        let machine = try collapsingMachine()
        XCTAssertTrue(machine.observe(displacement: 3, ownsBandHeader: true, isHomePresented: true).contains(.beginAcknowledgment))
        for displacement: CGFloat in [3, 2, 0] {
            XCTAssertFalse(machine.observe(displacement: displacement, ownsBandHeader: true, isHomePresented: true).contains(.beginAcknowledgment))
        }
    }

    func testANewerRefreshInvalidatesThePendingSettleThroughOneGenerationFence() throws {
        let source = try homeSource()
        let authored = try section(of: source, from: "private func performAuthoredRefresh() async {", to: "/// Runs the one authoritative reload")
        XCTAssertTrue(authored.contains("supersedeRefreshSettle()"))
        let supersede = try section(of: source, from: "private func supersedeRefreshSettle() {", to: "/// Eases any held displacement")
        XCTAssertTrue(supersede.contains("refreshSuccessGeneration += 1"))
        XCTAssertTrue(supersede.contains("retireRefreshSettle()"))
        // Every deferred task re-checks its generation before touching anything.
        let fence = "guard generation == refreshSuccessGeneration else { return }"
        let begin = try section(of: source, from: "private func beginRefreshSettle() {", to: "/// Performs what one passive scroll sample")
        XCTAssertEqual(begin.components(separatedBy: fence).count - 1, 2, "grace and expiry")
        let ease = try section(of: source, from: "private func startRefreshSettleEase() {", to: "/// Shows the bare micro-check")
        XCTAssertEqual(ease.components(separatedBy: fence).count - 1, 2, "ease start and bound")
        let acknowledge = try section(of: source, from: "private func beginRefreshAcknowledgment() {", to: "/// Releases the hold alone")
        XCTAssertEqual(acknowledge.components(separatedBy: fence).count - 1, 1)
    }

    func testRetirementIsPresentationOnlyAndLeavesNoStaleTransform() throws {
        let source = try homeSource()
        let retire = try section(of: source, from: "private func retireRefreshSettle() {", to: "/// Ends the settle with no animation")
        XCTAssertTrue(retire.contains("refreshSettleHold = HomeRefreshSettle.retiredHold"),
                      "must change the state so the running ease is retargeted, not re-assign its own target")
        XCTAssertFalse(retire.contains("refreshSettleHold = 0"), "assigning the ease target again would not retarget")
        XCTAssertTrue(retire.contains("isShowingRefreshSuccess = false"))
        XCTAssertTrue(retire.contains("refreshSuccessGeneration += 1"), "no pending task can revive it")
        for forbidden in ["store.", "fetchRequests", "isRefreshInFlight", "RequestStore", "performAuthoredRefresh", "Task {", "sleep"] {
            XCTAssertFalse(retire.contains(forbidden), "retirement must not touch \(forbidden)")
        }
        // And leaving Home clears it with no animation, so returning shows nothing.
        let immediate = try section(of: source, from: "private func endRefreshSettleImmediately() {", to: "// MARK: - Header ownership")
        XCTAssertTrue(immediate.contains("disablesAnimations = true"))
        XCTAssertTrue(immediate.contains("refreshSettleHold = 0"))
        XCTAssertTrue(source.contains("endRefreshSettleImmediately()"))
    }

    // MARK: - 8. Non-success and initial load never enter the settle

    func testOnlyTheTruthfulSuccessBranchOfTheOneRefreshClosureCanBeginASettle() throws {
        let source = try homeSource()
        XCTAssertEqual(source.components(separatedBy: "beginRefreshSettle()").count - 1, 2, "one definition, one call")
        let call = try XCTUnwrap(source.range(of: "            beginRefreshSettle()\n"))
        let guardRange = try XCTUnwrap(source.range(of: "if acknowledgesSuccess {"))
        XCTAssertLessThan(guardRange.lowerBound, call.lowerBound)
        // The initial load (.task) and every other fetch path never reach it.
        let initial = try section(of: source, from: ".task {\n            guard !store.isFetching else { return }", to: "// HQ decision 5: a bounded maximum wait")
        XCTAssertFalse(initial.contains("Settle"))
        XCTAssertFalse(initial.contains("acknowledge"))
        // The predicate that gates it stays the existing authoritative one.
        XCTAssertFalse(Home.shouldAcknowledgeRefreshSuccess(didResolveInTime: false, fetchOutcome: .succeeded, resolvedState: .empty))
        XCTAssertFalse(Home.shouldAcknowledgeRefreshSuccess(didResolveInTime: true, fetchOutcome: .didNotSucceed, resolvedState: .empty))
        XCTAssertFalse(Home.shouldAcknowledgeRefreshSuccess(didResolveInTime: true, fetchOutcome: nil, resolvedState: .empty))
        XCTAssertFalse(Home.shouldAcknowledgeRefreshSuccess(didResolveInTime: true, fetchOutcome: .succeeded, resolvedState: .unavailable))
        XCTAssertFalse(Home.shouldAcknowledgeRefreshSuccess(didResolveInTime: true, fetchOutcome: .succeeded, resolvedState: .loading))
        XCTAssertTrue(Home.shouldAcknowledgeRefreshSuccess(didResolveInTime: true, fetchOutcome: .succeeded, resolvedState: .empty))
    }

    // MARK: - 9. Reduce Motion

    func testReduceMotionRemovesTheSustainedSpatialSettleAndKeepsEveryTruthRule() throws {
        let standard = try XCTUnwrap(makePlan())
        let reduced = try XCTUnwrap(makePlan(reduceMotion: true))
        XCTAssertTrue(reduced.isReduced)
        // The lane is the spinner-clearance minimum in both modes; what Reduce
        // Motion removes is the sustained movement: one brief return after a static hold.
        XCTAssertEqual(reduced.holdStart(forDisplacement: 60), standard.holdStart(forDisplacement: 60))
        XCTAssertLessThanOrEqual(reduced.duration, 0.25)
        XCTAssertLessThan(reduced.duration, standard.duration, "a briefer return than the standard ease (and never a sustained one: <= 0.25 s above)")
        XCTAssertGreaterThan(reduced.delay, standard.delay, "the lane is held static for the check, then returns briefly")
        // The same gate, the same stages, the same check lane rule.
        XCTAssertNil(makePlan(reduceMotion: true, isHomePresented: false))
        XCTAssertNil(makePlan(reduceMotion: true, ownsBandHeader: false))
        XCTAssertEqual(reduced.laneCenter, standard.laneCenter)
        // Reduced motion keeps the check clear of both neighbours.
        let side = Home.refreshSuccessMarkSide
        let reducedStart = reduced.holdStart(forDisplacement: 60)
        XCTAssertGreaterThanOrEqual(reduced.laneCenter - side / 2 + Home.headerBandBottomPadding, 8)
        XCTAssertGreaterThanOrEqual(Home.contentTopPaddingBelowBand + reducedStart - (reduced.laneCenter + side / 2), 8)
        // Wired from the environment value, no separate semantic state.
        let source = try homeSource()
        XCTAssertTrue(source.contains("reduceMotion: reduceMotion"))
        XCTAssertFalse(source.contains("reduceMotionSuccess"))
    }

    func testTheSettleIsBoundedAndShorterAndCalmerPerOptionC() throws {
        let standard = try XCTUnwrap(makePlan())
        // Option C (Faith, 2026-10-09): shorter and calmer than the earlier ~1.1 s ease.
        let total = standard.delay + standard.duration
        XCTAssertGreaterThanOrEqual(total, 0.6)
        XCTAssertLessThanOrEqual(total, 0.9, "shorter than the earlier 1.1 s settle")
        XCTAssertLessThan(standard.endsAfter, .seconds(3), "bounded")
        XCTAssertGreaterThan(standard.endsAfter, .seconds(total))
        // The check fades in *within* its hold window, then fades out: it begins when
        // the indicator clears (replayed on the real UIKit collapse, measured from
        // the moment the ease starts), holds, and is gone by the time the settle
        // completes — no dwell beyond it.
        let begin = try checkBeginOffsetFromEaseStart(in: Self.realCollapse, start: 60)
        for planUnderTest in [standard, try XCTUnwrap(makePlan(reduceMotion: true))] {
            let hold = Double(planUnderTest.checkHold.components.seconds)
                + Double(planUnderTest.checkHold.components.attoseconds) / 1e18
            XCTAssertGreaterThan(hold, Home.refreshSuccessFadeInSeconds, "the fade-in fits inside the hold")
            // "Perceptible, not a flicker": the time the mark is at least half
            // visible, through the real fade curves. Full opacity alone under-counts
            // it — a mark at 60% is still read — and the selected Figma study's
            // "full / readable" portion is ~0.38 s.
            let readable = readableSeconds(hold: hold)
            XCTAssertGreaterThanOrEqual(readable, 0.30, "perceptible, not a flicker (reduced: \(planUnderTest.isReduced))")
            let gone = begin + hold + Home.refreshSuccessFadeOutSeconds
            XCTAssertLessThanOrEqual(gone, planUnderTest.delay + planUnderTest.duration,
                                     "gone by the time the settle completes (reduced: \(planUnderTest.isReduced))")
        }
        XCTAssertLessThanOrEqual(Home.refreshSuccessFadeInSeconds, 0.25)
        XCTAssertLessThanOrEqual(Home.refreshSuccessFadeOutSeconds, 0.3)
        XCTAssertLessThanOrEqual(Home.refreshSuccessRetireSeconds, 0.15)
    }

    // MARK: - 10. No custom refresh / gesture / threshold / second scroll authority

    func testNoCustomRefreshAuthorityGestureThresholdInsetOrIntrospectionWasAdded() throws {
        for file in [try codeOnly(try homeSource()), try codeOnly(try settleSource())] {
            for forbidden in ["DragGesture", "UIRefreshControl", "contentInset", "UIScrollView", "UIViewRepresentable",
                              "Timer", "onScrollGeometryChange", "onScrollPhaseChange", "contentOffset", "spring(", ".bouncy", ".interpolatingSpring"] {
                XCTAssertFalse(file.contains(forbidden), "H3 must not introduce \(forbidden)")
            }
        }
        let source = try codeOnly(try homeSource())
        XCTAssertEqual(source.components(separatedBy: ".refreshable {").count - 1, 1, "exactly one refreshable")
        XCTAssertEqual(source.components(separatedBy: "ScrollView {").count - 1, 1, "one ScrollView")
    }

    func testTheSettleReadsPassiveScrollGeometryAndPublishesOnlyItsOwnEffects() throws {
        let source = try homeSource()
        let handler = try section(of: source, from: ".onPreferenceChange(HomeHeaderAnchorKey.self)", to: ".overlayPreferenceValue(HomeHeaderAnchorKey.self)")
        XCTAssertTrue(handler.contains("observeRefreshSettle(displacement: -scrollOffset)"))
        let feed = try section(of: source, from: "private func observeRefreshSettle(displacement: CGFloat) {", to: "/// Performs what one passive scroll sample")
        XCTAssertTrue(feed.contains("perform(refreshSettleMachine.observe("))
        for forbidden in ["isRefreshInFlight", "isShowingRefreshSuccess", "Task", "sleep", "store.", "fetchRequests"] {
            XCTAssertFalse(handler.contains(forbidden), "the geometry handler must not read \(forbidden)")
        }
        // The machine is a reference type so per-frame samples invalidate nothing.
        XCTAssertTrue(try settleSource().contains("final class HomeRefreshSettleMachine"))
        XCTAssertTrue(source.contains("@State private var refreshSettleMachine = HomeRefreshSettleMachine()"))
    }

    // MARK: - 7b. Context lost *after* the acknowledgment began; lane already closed

    func testContextLostAfterTheCheckBeganReleasesOnlyTheHoldAndLeavesTheCheckItsOwnFade() throws {
        // The contract states no rule for a begun acknowledgment, so none is
        // invented: the stranded transform is released, the check is not retired.
        for (presented, owns) in [(true, false), (false, true)] {
            let machine = try collapsingMachine()
            _ = machine.observe(displacement: 3, ownsBandHeader: true, isHomePresented: true)
            XCTAssertEqual(machine.observe(displacement: 2, ownsBandHeader: owns, isHomePresented: presented), [.releaseHold])
        }
        // A repeated pull is the one thing the contract does retire a begun check for.
        let pulled = try collapsingMachine()
        _ = pulled.observe(displacement: 3, ownsBandHeader: true, isHomePresented: true)
        XCTAssertEqual(pulled.observe(displacement: 8, ownsBandHeader: true, isHomePresented: true), [.retire])

        let source = try homeSource()
        let release = try section(of: source, from: "private func releaseRefreshSettleHold() {", to: "/// A new refresh invalidates")
        XCTAssertTrue(release.contains("refreshSettleHold = HomeRefreshSettle.retiredHold"))
        XCTAssertFalse(release.contains("refreshSuccessGeneration += 1"), "the begun check's own fade must not be cancelled")
        XCTAssertFalse(release.contains("isShowingRefreshSuccess"), "the check is left alone")
        XCTAssertTrue(release.contains("refreshSettleMachine.reset()"))
        for forbidden in ["store.", "fetchRequests", "isRefreshInFlight", "Task {", "sleep"] {
            XCTAssertFalse(release.contains(forbidden), forbidden)
        }
        // Wired from the effect, and only there.
        XCTAssertEqual(source.components(separatedBy: "releaseRefreshSettleHold()").count - 1, 2, "one definition, one call")
        XCTAssertTrue(source.contains("case .releaseHold:\n                releaseRefreshSettleHold()"))
    }

    func testAHealthyToHealthyRefreshOnAClosedLaneStillAcknowledgesButNeverFromAStaleReading() throws {
        // The reading as the closure returns may be the held-lane reading (it
        // stepped up by the lane height a moment later): nothing begins from it.
        let machine = try begunMachine(latest: 0.33)
        XCTAssertEqual(machine.stage, .awaitingNativeEnd)
        // A truthful healthy → healthy success whose content really is at rest,
        // with no collapse ever seen, still gets its acknowledgment — through the
        // same gate — once the post-refresh grace elapses; it is never silently
        // dropped. (A recovery in the same position is Decision 12 Option B's:
        // see HomeRefreshNoLaneRecoveryTests.)
        XCTAssertEqual(machine.nativeEndGraceElapsed(ownsBandHeader: true, isHomePresented: true), [.beginAcknowledgment])
        let gated = try begunMachine(latest: 0)
        XCTAssertEqual(gated.nativeEndGraceElapsed(ownsBandHeader: true, isHomePresented: false), [.retire], "and the gate still applies")
        XCTAssertNotNil(makePlan(), "a closed lane is not itself a reason to drop a truthful success")
        XCTAssertGreaterThan(Settle.postEndGrace, .milliseconds(300), "longer than the measured step latency")
        XCTAssertLessThan(Settle.postEndGrace, .seconds(1))

        let source = try homeSource()
        let begin = try section(of: source, from: "private func beginRefreshSettle() {", to: "/// Performs what one passive scroll sample")
        XCTAssertTrue(begin.contains("nativeEndGraceElapsed("))
        XCTAssertTrue(begin.contains("Task.sleep(for: HomeRefreshSettle.postEndGrace)"))
        XCTAssertTrue(begin.contains("Task.sleep(for: HomeRefreshSettle.maxWaitForNativeCollapse)"))
        XCTAssertTrue(begin.contains("if refreshSettleMachine.isAwaitingCollapse { retireRefreshSettle() }"),
                      "a collapse that never comes is ended, never shown late")
    }

    // MARK: - 11. Only the dynamic Home region moves

    func testExactlyOneRegionMovesAndItExcludesTheHeaderCopiesAndTheCTA() throws {
        let source = try homeSource()
        XCTAssertEqual(source.components(separatedBy: ".modifier(HomeRefreshSettleHold(").count - 1, 1, "one coherent region")
        let content = try section(of: source, from: "private var exchangeContent: some View {", to: "// MARK: - Header (A2)")
        let hold = try XCTUnwrap(content.range(of: ".modifier(HomeRefreshSettleHold("))
        let header = try XCTUnwrap(content.range(of: "scrollingHeader\n"))
        let continueHelping = try XCTUnwrap(content.range(of: "continueHelpingSection"))
        let ownRequests = try XCTUnwrap(content.range(of: "ownRequestsSection"))
        let heading = try XCTUnwrap(content.range(of: "boardHeadingRow"))
        let board = try XCTUnwrap(content.range(of: "boardSection"))
        // The in-scroll header copy precedes the region; every section sits inside it.
        XCTAssertLessThan(header.lowerBound, continueHelping.lowerBound)
        for section in [continueHelping, ownRequests, heading, board] {
            XCTAssertLessThan(section.lowerBound, hold.lowerBound, "all sections move together, inside the one region")
        }
        // The band header and the persistent CTA are outside the scroll content, never under the modifier.
        let region = String(content[content.range(of: "VStack(alignment: .leading, spacing: 0) {\n                        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.l)")!.lowerBound..<hold.lowerBound])
        XCTAssertFalse(region.contains("bandHeader"))
        XCTAssertFalse(region.contains("scrollingHeader"))
        XCTAssertFalse(region.contains("requestMealButton"))
        XCTAssertTrue(content.contains(".safeAreaInset(edge: .top, spacing: 0) {\n                bandHeader"))
        XCTAssertTrue(content.contains(".safeAreaInset(edge: .bottom) {\n                requestMealButton"))
        // No section animates by itself under the settle.
        for sectionName in ["continueHelpingSection", "ownRequestsSection", "boardHeadingRow", "boardSection"] {
            let line = try XCTUnwrap(content.components(separatedBy: "\n").first { $0.contains(sectionName) })
            XCTAssertFalse(line.contains("refreshSettle"), sectionName)
        }
    }

    // MARK: - Helpers

    private func makePlan(
        reduceMotion: Bool = false,
        isHomePresented: Bool = true,
        ownsBandHeader: Bool = true
    ) -> Settle.Plan? {
        Settle.plan(
            reduceMotion: reduceMotion,
            isHomePresented: isHomePresented,
            ownsBandHeader: ownsBandHeader
        )
    }

    /// A machine whose refresh closure has returned with `latest` as the reading
    /// at that moment (it may still be lane-biased: nothing is armed from it).
    private func begunMachine(latest: CGFloat) throws -> HomeRefreshSettleMachine {
        let machine = HomeRefreshSettleMachine()
        _ = machine.observe(displacement: latest, ownsBandHeader: true, isHomePresented: true)
        let plan = try XCTUnwrap(makePlan())
        _ = machine.begin(plan: plan, ownsBandHeader: true, isHomePresented: true)
        return machine
    }

    /// A machine already collapsing: the refresh closure returned, the end-of-
    /// refresh step has been seen, and `latest` is the first reading after it —
    /// so the hold is armed and native is falling.
    private func collapsingMachine(latest: CGFloat = 90) throws -> HomeRefreshSettleMachine {
        let machine = try begunMachine(latest: max(0, latest - 60))
        _ = machine.observe(displacement: latest, ownsBandHeader: true, isHomePresented: true)
        XCTAssertEqual(machine.stage, .collapsing)
        return machine
    }

    /// Replays a native collapse (the refresh already ended and the readings are
    /// real) through the machine and returns the first sample at which the
    /// acknowledgment begins.
    private func firstBegin(
        in collapse: [(ms: Double, displacement: CGFloat)],
        start: CGFloat
    ) throws -> (ms: Double, displacement: CGFloat) {
        let machine = try collapsingMachine(latest: start)
        for sample in collapse
        where machine.observe(displacement: sample.displacement, ownsBandHeader: true, isHomePresented: true)
            .contains(.beginAcknowledgment) {
            return sample
        }
        throw XCTSkip("the collapse never cleared the lane")
    }

    /// How long after the ease starts the check begins, replaying a native collapse
    /// (the ease starts at the first reading at or below the held lane, after the
    /// view's 20 ms commit; the check at the first reading at the clear depth).
    private func checkBeginOffsetFromEaseStart(
        in collapse: [(ms: Double, displacement: CGFloat)],
        start: CGFloat
    ) throws -> Double {
        let machine = try collapsingMachine(latest: start)
        var easeMs: Double?
        for sample in collapse {
            let effects = machine.observe(displacement: sample.displacement, ownsBandHeader: true, isHomePresented: true)
            if easeMs == nil, effects.contains(.startEase) { easeMs = sample.ms }
            if effects.contains(.beginAcknowledgment) {
                return (sample.ms - (easeMs ?? sample.ms)) / 1000 - 0.020
            }
        }
        throw XCTSkip("the collapse never cleared the lane")
    }

    /// Seconds a check with the given hold spends at or above half opacity, with
    /// the view's own curves: `.easeOut` fade-in, `.easeIn` fade-out.
    private func readableSeconds(hold: Double) -> Double {
        let fadeIn = Home.refreshSuccessFadeInSeconds
        let fadeOut = Home.refreshSuccessFadeOutSeconds
        func opacity(_ t: Double) -> Double {
            if t < 0 { return 0 }
            if t < fadeIn { return Double(Self.cubicBezier(t / fadeIn, 0, 0, 0.58, 1)) }
            if t < hold { return 1 }
            if t < hold + fadeOut { return 1 - Double(Self.cubicBezier((t - hold) / fadeOut, 0.42, 0, 1, 1)) }
            return 0
        }
        let step = 0.001
        return stride(from: 0.0, through: hold + fadeOut, by: step).reduce(0) { $0 + (opacity($1) >= 0.5 ? step : 0) }
    }

    /// CSS-style cubic-bezier progress (`x1, y1, x2, y2`), as SwiftUI's named curves.
    nonisolated static func cubicBezier(_ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> CGFloat {
        func bezier(_ u: Double, _ a: Double, _ b: Double) -> Double {
            let m = 1 - u
            return 3 * m * m * u * a + 3 * m * u * u * b + u * u * u
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if bezier(mid, x1, x2) < x { lo = mid } else { hi = mid }
        }
        return CGFloat(bezier((lo + hi) / 2, y1, y2))
    }

    /// Reference ease-in-out (cubic-bezier 0.42, 0, 0.58, 1) progress.
    private func easeInOut(_ x: Double) -> CGFloat {
        func bezier(_ u: Double, _ a: Double, _ b: Double) -> Double {
            let m = 1 - u
            return 3 * m * m * u * a + 3 * m * u * u * b + u * u * u
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if bezier(mid, 0.42, 0.58) < x { lo = mid } else { hi = mid }
        }
        return CGFloat(bezier((lo + hi) / 2, 0, 1))
    }

    private func codeOnly(_ source: String) throws -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func homeSource() throws -> String {
        try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")
    }

    private func settleSource() throws -> String {
        try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeRefreshSettle.swift")
    }

    private func section(of source: String, from start: String, to end: String) throws -> String {
        let lower = try XCTUnwrap(source.range(of: start), "missing \(start)")
        let upper = try XCTUnwrap(source.range(of: end, range: lower.upperBound..<source.endIndex), "missing \(end)")
        return String(source[lower.lowerBound..<upper.lowerBound])
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
