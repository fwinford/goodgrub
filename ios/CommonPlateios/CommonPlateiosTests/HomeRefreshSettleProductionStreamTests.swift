//
//  HomeRefreshSettleProductionStreamTests.swift
//  CommonPlateiosTests
//
// W4-H3 regression for "the success check never appears" (visual gate failure).
//
// The settle's decisions are driven by the passive displacement stream the real
// refresh produces. Earlier tests injected displacement traces the app cannot
// actually observe (a clean 60 pt lane that collapses once the refresh closure
// returns). These tests replay the two streams the *production app* produced
// when Faith pulled to refresh in the Simulator (iPhone 17 Pro, iOS 26.5, Debug,
// recorded with temporary DEBUG diagnostics that have since been removed), and
// pin the behaviours the real stream demands:
//
//   • the native refresh begins while the finger is still down, may end before
//     or long after the finger lifts, and while it is active the layout reading
//     is one lane height (60 pt) lower than the content is drawn — so it steps
//     UP by 60 when the refresh ends, and a held pull holds the reading flat;
//   • none of that is a new pull; the settle must neither retire on it nor take
//     a reading it sees while the refresh may still be active as real — it hands
//     off from the first reading after the end-of-refresh step;
//   • the check begins only when the content has been carried back to the native
//     indicator-clear depth after the refresh ended, with the hold still clear
//     of rest.
//
// Samples are (milliseconds since the first recorded sample, displacement below
// rest in points) exactly as the view's `onPreferenceChange` received them.
import XCTest
@testable import CommonPlateios

@MainActor
final class HomeRefreshSettleProductionStreamTests: XCTestCase {
    private typealias Sample = (ms: Double, displacement: CGFloat)
    private typealias Effect = HomeRefreshSettleMachine.Effect
    private typealias Settle = HomeRefreshSettle
    private typealias Home = HomeExchangeView

    // MARK: - Recorded production streams

    /// Run A — slow backend (the fetch took 3.3 s). The pull was held at ~130 pt
    /// for ~1.8 s with the refresh already active, released, and the content fell
    /// to ~0.3 — the active-refresh reading of a held lane — a full second BEFORE
    /// the refresh closure returned (4590 ms). Once it returned, the reading
    /// stepped to 60.33 and collapsed to rest over ~270 ms. The check was
    /// started the instant the closure returned (reading 0.33) and retired by the
    /// step: a split-second flash.
    private static let runAPre: [Sample] = [
        (0, 11.33), (39, 40.33), (47, 49.67), (70, 60.0), (93, 64.67), (116, 71.33),
        (130, 77.67), (146, 81.33), (163, 85.33), (179, 89.33), (196, 92.67), (213, 95.67),
        (230, 98.0), (249, 100.33), (263, 103.67), (280, 106.67), (296, 110.33), (321, 116.33),
        (337, 119.33), (355, 122.0), (372, 124.33), (388, 126.0), (404, 126.67), (420, 127.67),
        (438, 128.33), (455, 129.33), (470, 130.67), (488, 133.0), (504, 135.33), (525, 137.67),
        (538, 140.67), (554, 143.33), (570, 145.67), (587, 147.67), (604, 149.33), (622, 151.33),
        (637, 153.33), (655, 156.0), (671, 159.67), (687, 163.0), (704, 167.0), (728, 170.67),
        (778, 174.0), (1152, 132.33), (1243, 134.33), (2972, 131.67), (2980, 116.67), (2996, 103.0),
        (3012, 90.67), (3029, 79.67), (3046, 69.67), (3062, 61.0), (3079, 53.0), (3096, 46.33),
        (3113, 40.0), (3130, 34.67), (3146, 30.33), (3162, 26.0), (3180, 22.67), (3196, 19.33),
        (3213, 16.67), (3229, 14.33), (3246, 12.33), (3263, 10.67), (3280, 9.33), (3296, 8.0),
        (3313, 6.67), (3329, 6.0), (3346, 5.0), (3363, 4.33), (3380, 3.67), (3396, 3.0),
        (3413, 2.67), (3429, 2.33), (3446, 2.0), (3463, 1.67), (3480, 1.33), (3512, 1.0),
        (3546, 0.67), (3603, 0.33)
    ]
    private static let runAPost: [Sample] = [
        (4630, 60.33), (4646, 60.0), (4663, 58.67), (4679, 56.33), (4696, 53.33), (4712, 49.67),
        (4729, 45.33), (4746, 40.33), (4763, 35.33), (4780, 30.33), (4796, 25.0), (4812, 20.0),
        (4829, 15.0), (4846, 10.67), (4864, 7.0), (4883, 4.0), (4896, 1.67)
    ]
    private static let runAEndMs = 4590.0

    /// Run B — the pull was held at ~189 pt (finger down) while the refresh was
    /// active and the closure returned at 1627 ms. The reading did not change
    /// until the finger lifted (1935 ms), when it stepped to 249 and then
    /// decelerated to rest. The settle was retired by that step before it could
    /// begin: no check at all.
    private static let runBPre: [Sample] = [
        (0, 15.67), (45, 62.67), (71, 94.33), (84, 102.0), (117, 117.33), (134, 125.33),
        (150, 132.0), (167, 138.67), (184, 143.67), (201, 147.67), (217, 152.67), (234, 160.33),
        (250, 168.67), (275, 174.67), (380, 134.33), (388, 154.67), (457, 172.67), (476, 176.33),
        (500, 182.0), (517, 184.67), (534, 186.33), (550, 187.67), (567, 188.33), (583, 189.0)
    ]
    private static let runBPost: [Sample] = [
        (1935, 249.0), (1950, 213.33), (1968, 182.67), (1984, 156.33), (2001, 134.0), (2016, 114.67),
        (2033, 98.0), (2050, 83.67), (2067, 71.33), (2083, 61.0), (2100, 52.0), (2117, 44.33),
        (2134, 38.0), (2151, 32.33), (2168, 27.67), (2183, 23.33), (2200, 20.0), (2234, 14.67),
        (2250, 12.33), (2267, 10.67), (2283, 9.0), (2300, 7.67), (2316, 6.67), (2333, 5.67),
        (2350, 4.67), (2368, 4.0), (2384, 3.33), (2400, 3.0), (2417, 2.33), (2434, 2.0),
        (2451, 1.67), (2484, 1.33), (2500, 1.0), (2534, 0.67)
    ]
    private static let runBEndMs = 1627.0

    // MARK: - Run A: lane already closed when the closure returns; the step follows

    func testRunAClosureReturningOnAClosedLaneHandsOffNothingAndDoesNotStartTheCheckEarly() throws {
        let replay = try replay(pre: Self.runAPre, post: Self.runAPost, endMs: Self.runAEndMs)
        // The reading when the closure returned is the held-lane reading (0.33),
        // not content at rest: nothing is armed and no check begins from it.
        XCTAssertEqual(replay.latestAtBegin, 0.33, accuracy: 0.01)
        XCTAssertEqual(replay.atBegin, [], "nothing handed off from, and no check begun by, the stale held-lane reading")
        XCTAssertNil(replay.firstMs(of: .beginAcknowledgment, before: 4630 - 1), "the check is not started at the moment the closure returns")
    }

    func testRunAArmsTheHoldFromTheFirstRealReadingAfterTheRefreshEndedAndEasesOnceNativeReachesIt() throws {
        let replay = try replay(pre: Self.runAPre, post: Self.runAPost, endMs: Self.runAEndMs)
        let step = try XCTUnwrap(replay.samples.first)
        XCTAssertEqual(step.displacement, 60.33, accuracy: 0.01, "the step the refresh ending produces")
        XCTAssertEqual(replay.effects(at: step.ms), [.armHold(start: Settle.heldLane)],
                       "armed from the real reading, capped to the held lane; the ease begins once native has fallen to it")
        let ease = try XCTUnwrap(replay.sample(of: .startEase))
        XCTAssertLessThanOrEqual(ease.displacement, Settle.heldLane)
        XCTAssertGreaterThan(ease.ms, step.ms)
    }

    func testRunACheckBeginsOnlyWhenNativeHasCarriedTheContentBackToTheClearDepthAndNeverRetires() throws {
        let replay = try replay(pre: Self.runAPre, post: Self.runAPost, endMs: Self.runAEndMs)
        let begin = try XCTUnwrap(replay.sample(of: .beginAcknowledgment))
        XCTAssertLessThanOrEqual(begin.displacement, Settle.nativeIndicatorClearDepth)
        XCTAssertEqual(replay.count(of: .beginAcknowledgment), 1, "exactly once")
        let step = try XCTUnwrap(replay.samples.first)
        XCTAssertGreaterThan(begin.ms - step.ms, 200, "not while the indicator is still cycling in the lane")
        for forbidden in [Effect.retire, .releaseHold] {
            XCTAssertEqual(replay.count(of: forbidden), 0, "the native collapse must never retire the settle (\(forbidden))")
        }
        // The check begins while the authored hold still carries the content well
        // clear of rest: native alone would already have been at rest.
        let rendered = replay.renderedDisplacement(atMs: begin.ms)
        XCTAssertGreaterThan(rendered, 30, "content is still held clear of rest when the check begins")
        XCTAssertLessThan(begin.displacement, 6.01)
    }

    func testRunAContentNeverMovesAwayFromRestBecauseOfTheSettleAndEndsAtRest() throws {
        let replay = try replay(pre: Self.runAPre, post: Self.runAPost, endMs: Self.runAEndMs)
        try replay.assertSettleAddsNoRiseAndNoOvershoot()
        XCTAssertEqual(replay.renderedDisplacement(atMs: Self.runAEndMs + 2500), 0, accuracy: 0.01, "ends exactly at the unchanged rest layout")
    }

    // MARK: - Run B: the pull is held with the refresh active; the step comes after the finger lifts

    func testRunBClosureReturningWhileThePullIsHeldHandsOffNothingUntilTheRefreshEndsAndTheStepArrives() throws {
        let replay = try replay(pre: Self.runBPre, post: Self.runBPost, endMs: Self.runBEndMs)
        XCTAssertEqual(replay.latestAtBegin, 189, accuracy: 0.01)
        XCTAssertEqual(replay.atBegin, [], "while the pull is held the reading is still lane-biased: nothing is armed from it")
        let step = try XCTUnwrap(replay.samples.first)
        XCTAssertEqual(step.displacement, 249, accuracy: 0.01)
        XCTAssertEqual(replay.effects(at: step.ms), [.armHold(start: Settle.standardStartCap)],
                       "armed from the first reading after the step, capped to the held lane, ease reserved")
        XCTAssertNil(replay.firstMs(of: .startEase, before: step.ms + 1), "the ease is not spent while the finger holds the pull")
    }

    func testRunBTheEndOfRefreshStepAndTheReleaseDoNotRetireTheSettle() throws {
        let replay = try replay(pre: Self.runBPre, post: Self.runBPost, endMs: Self.runBEndMs)
        let step = try XCTUnwrap(replay.samples.first)
        XCTAssertGreaterThan(step.displacement, Self.runBPre.last!.displacement + 50, "the +60 step the old rule read as a new pull")
        XCTAssertFalse(replay.effects(at: step.ms).contains(.retire), "a step is not a takeover")
        for forbidden in [Effect.retire, .releaseHold] {
            XCTAssertEqual(replay.count(of: forbidden), 0, "(\(forbidden))")
        }
    }

    func testRunBEaseStartsOnlyOnceNativeHasFallenToTheHoldAndTheCheckFollowsTheClearDepth() throws {
        let replay = try replay(pre: Self.runBPre, post: Self.runBPost, endMs: Self.runBEndMs)
        let ease = try XCTUnwrap(replay.sample(of: .startEase))
        XCTAssertLessThanOrEqual(ease.displacement, Settle.standardStartCap)
        let begin = try XCTUnwrap(replay.sample(of: .beginAcknowledgment))
        XCTAssertLessThanOrEqual(begin.displacement, Settle.nativeIndicatorClearDepth)
        XCTAssertLessThan(ease.ms, begin.ms, "the settle is already carrying the content when the check begins")
        XCTAssertEqual(replay.count(of: .beginAcknowledgment), 1)
        XCTAssertGreaterThan(replay.renderedDisplacement(atMs: begin.ms), 25, "held clear of rest when the check begins")
        XCTAssertLessThanOrEqual(ease.displacement, Settle.heldLane)
        try replay.assertSettleAddsNoRiseAndNoOvershoot()
        XCTAssertEqual(replay.renderedDisplacement(atMs: Self.runBEndMs + 3000), 0, accuracy: 0.01)
    }

    // MARK: - The check's fade clears its lane before the first heading arrives

    /// The first heading rises through the check's own lane as the content eases
    /// to rest (the check sits where the heading's frame top will pass on its way to
    /// the permanent gap), so the fade must be under way while the heading is still
    /// clear of the check, and the mark mostly gone by the time the heading is level
    /// with it. (It is not gone at the heading's first contact: the fade-out eases
    /// in, so the mark is still partly visible for ~0.1 s after the fade starts.) Each run supplies when the check actually began relative
    /// to the ease (the recorded production streams), the geometry comes from the
    /// production constants, and the curves are the view's own.
    func testTheFadeBeginsWhileTheFirstHeadingIsStillClearOfTheCheckAndTheCheckIsMostlyGoneByTheTimeTheHeadingIsLevelWithIt() throws {
        // Both recorded streams, in both motion modes: the check begins 0.10 s
        // (run A) and 0.16 s (run B) after the ease starts, and the fade has to hold up across both.
        let headingInkInset: CGFloat = 4
        for reduceMotion in [false, true] {
            for (name, result) in [("A", try replay(pre: Self.runAPre, post: Self.runAPost, endMs: Self.runAEndMs, reduceMotion: reduceMotion)),
                                   ("B", try replay(pre: Self.runBPre, post: Self.runBPost, endMs: Self.runBEndMs, reduceMotion: reduceMotion))] {
                let label = "run \(name) (reduce motion \(reduceMotion))"
                let start = try XCTUnwrap(result.armedHold, label)
                let plan = result.plan
                let easeBegin = try XCTUnwrap(result.sample(of: .startEase), label).ms + 20 // the view's commit interval
                let checkBegin = try XCTUnwrap(result.sample(of: .beginAcknowledgment), label).ms
                let hold = Double(plan.checkHold.components.seconds) + Double(plan.checkHold.components.attoseconds) / 1e18
                let fadeIn = Home.refreshSuccessFadeInSeconds
                let fadeOut = Home.refreshSuccessFadeOutSeconds

                // Geometry, in points below the band's bottom edge.
                let checkCenter = plan.laneCenter
                let side = Home.refreshSuccessMarkSide
                func displacement(_ t: Double) -> CGFloat {
                    start * (1 - Self.easeProgress(t, plan: plan))
                }
                func headingFrameTop(_ t: Double) -> CGFloat { Home.contentTopPaddingBelowBand + displacement(t) }
                func headingTextTop(_ t: Double) -> CGFloat { headingFrameTop(t) + headingInkInset }
                func opacity(_ t: Double) -> Double {
                    let sinceBegin = t - (checkBegin - easeBegin) / 1000
                    if sinceBegin < 0 { return 0 }
                    if sinceBegin < fadeIn { return Double(HomeRefreshSettleSequencingTests.cubicBezier(sinceBegin / fadeIn, 0, 0, 0.58, 1)) }
                    if sinceBegin < hold { return 1 }
                    if sinceBegin < hold + fadeOut { return 1 - Double(HomeRefreshSettleSequencingTests.cubicBezier((sinceBegin - hold) / fadeOut, 0.42, 0, 1, 1)) }
                    return 0
                }
                func time(whenHeadingTextTopReaches y: CGFloat) -> Double {
                    var lo = 0.0, hi = plan.delay + plan.duration
                    for _ in 0..<50 {
                        let mid = (lo + hi) / 2
                        if headingTextTop(mid) > y { lo = mid } else { hi = mid }
                    }
                    return (lo + hi) / 2
                }

                let fadeStart = (checkBegin - easeBegin) / 1000 + hold
                let clearance = headingTextTop(fadeStart) - (checkCenter + side / 2)
                XCTAssertGreaterThanOrEqual(clearance, 8, "\(label): the fade begins with comfortable separation from the heading")

                let atBottom = time(whenHeadingTextTopReaches: checkCenter + side / 2)
                XCTAssertLessThanOrEqual(opacity(atBottom), 0.45,
                                         "\(label): by the time the heading's text reaches the check's bottom edge the mark is largely faded")
                let atCenter = time(whenHeadingTextTopReaches: checkCenter)
                XCTAssertLessThanOrEqual(opacity(atCenter), 0.15,
                                         "\(label): by the time the heading's text is level with the check's center the mark is essentially gone")
                XCTAssertLessThanOrEqual((checkBegin - easeBegin) / 1000 + hold + fadeOut, plan.delay + plan.duration,
                                         "\(label): gone by the time the settle completes")

                // Still a deliberate, readable acknowledgment, not a blink: at least half
                // visible for ~0.3 s or more (the Figma reference's readable portion is ~0.38 s).
                let readable = stride(from: 0.0, through: 1.5, by: 0.001).reduce(0.0) { $0 + (opacity($1) >= 0.5 ? 0.001 : 0) }
                XCTAssertGreaterThanOrEqual(readable, 0.30, label)
                XCTAssertLessThanOrEqual(readable, 0.60, "\(label): no dwell")
            }
        }
    }

    /// The check's lane center is the plan's, whatever reading the hold armed from.
    /// A very fast refresh (10–13 ms, seen in the diagnostic trace) leaves no
    /// end-of-refresh step, so after the grace the hold arms from a small reading —
    /// 8 pt in the recorded case — which used to put the check 4 pt below the band,
    /// against the header.
    func testAFastRefreshThatArmsFromASmallReadingStillPlacesTheCheckAtTheStableLane() throws {
        let machine = try begunMachine(latest: 8)
        XCTAssertEqual(machine.nativeEndGraceElapsed(ownsBandHeader: true, isHomePresented: true),
                       [.armHold(start: 8), .startEase], "armed from the small reading it is handed")
        XCTAssertEqual(machine.observe(displacement: 6, ownsBandHeader: true, isHomePresented: true), [.beginAcknowledgment])
        for reduceMotion in [false, true] {
            let plan = try XCTUnwrap(Settle.plan(reduceMotion: reduceMotion, isHomePresented: true, ownsBandHeader: true))
            XCTAssertEqual(plan.laneCenter, Settle.heldLane / 2, "fixed by the plan, not by the reading (reduce: \(reduceMotion))")
        }
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift"), encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "refreshSuccessLaneCenter = ").count - 1, 1, "one writer")
        XCTAssertTrue(source.contains("refreshSuccessLaneCenter = plan.laneCenter"))
    }

    func testTheFadeCurvesTheTimingModelAssumesAreTheOnesTheViewUses() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("withAnimation(.easeOut(duration: Self.refreshSuccessFadeInSeconds))"))
        XCTAssertTrue(source.contains("withAnimation(.easeIn(duration: Self.refreshSuccessFadeOutSeconds))"))
        XCTAssertEqual(Home.refreshSuccessFadeInSeconds, 0.15)
        XCTAssertEqual(Home.refreshSuccessFadeOutSeconds, 0.25)
    }

    // MARK: - The machine's own rules

    func testNothingBeginsFromAnAlreadyClosedLaneUntilTheGraceElapsesWithNoDisplacedSampleForHealthyToHealthy() throws {
        let machine = try begunMachine(latest: 0.33)
        XCTAssertEqual(machine.stage, .awaitingNativeEnd)
        XCTAssertEqual(machine.nativeEndGraceElapsed(ownsBandHeader: true, isHomePresented: true), [.beginAcknowledgment],
                       "healthy → healthy at rest and no collapse seen: the acknowledgment begins (a recovery ends with no check: Option B)")
        XCTAssertEqual(machine.stage, .acknowledging)
        XCTAssertEqual(machine.nativeEndGraceElapsed(ownsBandHeader: true, isHomePresented: true), [], "only once")
    }

    func testTheGraceNeverBeginsTheCheckWhileTheContentIsStillDisplaced() throws {
        let machine = try begunMachine(latest: 0.33)
        _ = machine.observe(displacement: 40, ownsBandHeader: true, isHomePresented: true)
        XCTAssertEqual(machine.stage, .collapsing)
        XCTAssertEqual(machine.nativeEndGraceElapsed(ownsBandHeader: true, isHomePresented: true), [], "the collapse is running")
        let held = try begunMachine(latest: 130)
        let effects = held.nativeEndGraceElapsed(ownsBandHeader: true, isHomePresented: true)
        XCTAssertFalse(effects.contains(.beginAcknowledgment), "a pull still held at 130 pt must not start the check")
        XCTAssertEqual(effects, [.armHold(start: Settle.standardStartCap)],
                       "no step ever came: stop waiting for one and hand off from the reading as it is")
    }

    func testTheGraceFallbackAppliesTheContextGate() throws {
        let machine = try begunMachine(latest: 0)
        XCTAssertEqual(machine.nativeEndGraceElapsed(ownsBandHeader: false, isHomePresented: true), [.retire])
        let away = try begunMachine(latest: 0)
        XCTAssertEqual(away.nativeEndGraceElapsed(ownsBandHeader: true, isHomePresented: false), [.retire])
    }

    func testARiseBeforeTheCheckBeginsIsNotATakeoverButARiseWhileItShowsRetiresIt() throws {
        let machine = try begunMachine(latest: 0.33)
        // Before the check: a rising stream (the end-of-refresh step, a held or
        // moving pull) retires nothing.
        for displacement: CGFloat in [60, 120, 80, 200, 90] {
            XCTAssertFalse(machine.observe(displacement: displacement, ownsBandHeader: true, isHomePresented: true).contains(.retire),
                           "\(displacement)")
        }
        // While the check shows, a rise above the lowest reading since it began is a repeated pull.
        _ = machine.observe(displacement: 5, ownsBandHeader: true, isHomePresented: true)
        XCTAssertEqual(machine.stage, .acknowledging)
        XCTAssertEqual(machine.observe(displacement: 5 + Settle.takeoverTolerance - 0.5, ownsBandHeader: true, isHomePresented: true), [], "noise")
        XCTAssertEqual(machine.observe(displacement: 5 + Settle.takeoverTolerance + 0.5, ownsBandHeader: true, isHomePresented: true), [.retire])
    }

    func testContextLostAtAnyStageBeforeTheCheckSuppressesItAndAfterItOnlyReleasesTheHold() throws {
        for stage in ["awaiting", "collapsing"] {
            let machine = try begunMachine(latest: 0.33)
            if stage == "collapsing" { _ = machine.observe(displacement: 40, ownsBandHeader: true, isHomePresented: true) }
            XCTAssertEqual(machine.observe(displacement: 30, ownsBandHeader: false, isHomePresented: true), [.retire], stage)
            XCTAssertEqual(machine.observe(displacement: 30, ownsBandHeader: true, isHomePresented: false), [.retire], stage)
        }
        let begun = try begunMachine(latest: 0.33)
        _ = machine(begun, observing: [40, 10, 4])
        XCTAssertEqual(begun.stage, .acknowledging)
        XCTAssertEqual(begun.observe(displacement: 3, ownsBandHeader: false, isHomePresented: true), [.releaseHold])
        XCTAssertEqual(begun.observe(displacement: 3, ownsBandHeader: true, isHomePresented: false), [.releaseHold])
    }

    func testAResetMachineReactsToNothingSoASuppressedAcknowledgmentIsNeverReplayed() throws {
        let machine = try begunMachine(latest: 0.33)
        _ = machine.observe(displacement: 40, ownsBandHeader: true, isHomePresented: true)
        machine.reset()
        XCTAssertEqual(machine.stage, .idle)
        XCTAssertNil(machine.plan)
        for displacement: CGFloat in [40, 10, 4, 0] {
            XCTAssertEqual(machine.observe(displacement: displacement, ownsBandHeader: true, isHomePresented: true), [])
        }
        XCTAssertEqual(machine.nativeEndGraceElapsed(ownsBandHeader: true, isHomePresented: true), [])
    }

    func testTheHoldStartsAtTheFirstReadingAfterTheStepUpToTheCapAndNeverNegative() throws {
        for (reading, expected) in [(CGFloat(30), CGFloat(30)), (Settle.heldLane, Settle.heldLane), (Settle.heldLane + 1, Settle.heldLane), (64, Settle.heldLane), (249, Settle.heldLane)] {
            let machine = try begunMachine(latest: 0.33)
            XCTAssertEqual(machine.observe(displacement: reading, ownsBandHeader: true, isHomePresented: true).first,
                           .armHold(start: expected), "reading \(reading)")
        }
        let plan = try XCTUnwrap(Settle.plan(reduceMotion: false, isHomePresented: true, ownsBandHeader: true))
        XCTAssertEqual(plan.holdStart(forDisplacement: -30), 0)
    }

    func testAReadingThatDidNotStepUpIsNeverAHandoffPoint() throws {
        // Before the end-of-refresh step readings may be lane-biased: falling,
        // creeping or holding, none of it arms anything.
        let machine = try begunMachine(latest: 120)
        for reading: CGFloat in [118, 100, 70, 40, 31, 20, 9, 4] {
            XCTAssertEqual(machine.observe(displacement: reading, ownsBandHeader: true, isHomePresented: true), [], "\(reading)")
        }
        XCTAssertEqual(machine.stage, .awaitingNativeEnd, "no hold, and no check begun from a biased reading at the clear depth")
        // A rise just under the step threshold is not the step either.
        XCTAssertEqual(machine.observe(displacement: 4 + Settle.refreshEndStepThreshold - 1, ownsBandHeader: true, isHomePresented: true), [])
        // The step itself (>= threshold) is.
        let stepped = machine.observe(displacement: 4 + Settle.refreshEndStepThreshold - 1 + Settle.refreshEndStepThreshold,
                                      ownsBandHeader: true, isHomePresented: true)
        if case .armHold = stepped.first {} else { XCTFail("the step arms the hold: \(stepped)") }
        XCTAssertFalse(stepped.contains(.beginAcknowledgment))
    }

    // MARK: - The review's two mid-release cases (constructed from the measured mechanism)

    /// The closure returns while the content is still decelerating after the finger
    /// lifted: readings are lane-biased (60 pt below the drawn position) until the
    /// refresh-end step. Built from the measured bias and step, not recorded: the
    /// drawn position is the reading plus 60 until the step. The old logic armed a
    /// 40 pt hold from the biased reading at the moment the closure returned, which
    /// drew the content further from rest than native for the biased frames and
    /// then hopped back at the step.
    func testClosureReturningMidReleaseNeverArmsFromTheBiasedReadingsAndNeverDoubleDisplaces() throws {
        let pre: [Sample] = [(0, 0.33), (16, 60), (33, 120), (50, 140), (66, 132), (83, 118), (100, 100),
                             (116, 84), (133, 70), (150, 58), (166, 46), (183, 40)]
        let biased: [Sample] = [(200, 32), (216, 22), (233, 12)]
        let real: [Sample] = [(250, 62), (266, 52), (283, 43), (300, 34), (316, 26), (333, 19),
                              (350, 13), (366, 8.5), (383, 5), (400, 2.5), (416, 1), (433, 0)]
        let replay = try replay(pre: pre, post: biased + real, endMs: 190)
        XCTAssertEqual(replay.latestAtBegin, 40, accuracy: 0.01)
        XCTAssertEqual(replay.atBegin, [], "40 pt is a biased reading: nothing is armed from it")
        XCTAssertNil(replay.firstMs(of: .startEase, before: 250), "nothing eases before the step")
        let arm = try XCTUnwrap(replay.timeline.first { $0.effects.contains { if case .armHold = $0 { return true } else { return false } } })
        XCTAssertEqual(arm.ms, 250, "armed only from the first reading after the step")

        // In drawn space (what the user sees) the hold only ever carries content.
        var previous = CGFloat.greatestFiniteMagnitude
        for sample in biased + real {
            let isBiased = sample.ms < 250
            let drawn = isBiased ? sample.displacement + 60 : sample.displacement
            let hold = replay.holdValue(atMs: sample.ms)
            if isBiased {
                XCTAssertEqual(hold, 0, "\(sample.ms) ms: no hold before the step, so nothing double-displaces a biased frame")
            }
            let rendered = max(drawn, hold)
            XCTAssertLessThanOrEqual(rendered, previous + 0.0001, "\(sample.ms) ms: content moved away from rest")
            previous = rendered
        }
        XCTAssertEqual(replay.count(of: .retire), 0)
        XCTAssertEqual(replay.count(of: .beginAcknowledgment), 1)
        let begin = try XCTUnwrap(replay.sample(of: .beginAcknowledgment))
        XCTAssertGreaterThan(begin.ms, 250, "the check follows the collapse, never a biased reading")
    }

    /// The refresh ended while a finger is still down and the user drags the
    /// content back up to the top before lifting: biased readings fall through the
    /// clear depth, but no check may begin from them; the lift's step then arms the
    /// hold and the real collapse begins the check once, with no retire.
    func testDraggingBackUpUnderAFingerAfterTheRefreshEndedDoesNotBeginTheCheckFromBiasedReadings() throws {
        let pre: [Sample] = [(0, 0.33), (20, 80), (40, 170), (60, 176), (80, 120)]
        // Biased readings as the finger drags the content up to the top...
        var post: [Sample] = [(120, 90), (140, 60), (160, 30), (180, 8), (200, 3)]
        // ...then the lift: the step to the drawn position, and the real collapse.
        post += [(700, 63), (716, 57), (733, 48), (750, 38), (766, 29), (783, 20), (800, 12), (816, 6), (833, 2), (850, 0)]
        let replay = try replay(pre: pre, post: post, endMs: 100)
        XCTAssertEqual(replay.atBegin, [])
        let early = replay.timeline.filter { $0.ms < 700 }
        XCTAssertTrue(early.isEmpty, "biased readings falling through the clear depth must not arm or acknowledge: \(early)")
        let step = try XCTUnwrap(post.first { $0.ms == 700 })
        XCTAssertTrue(replay.effects(at: step.ms).contains { if case .armHold = $0 { return true } else { return false } })
        XCTAssertEqual(replay.count(of: .beginAcknowledgment), 1)
        XCTAssertEqual(replay.count(of: .retire), 0, "the lift's step must not retire a check that has not begun")
        let begin = try XCTUnwrap(replay.sample(of: .beginAcknowledgment))
        XCTAssertLessThanOrEqual(begin.displacement, Settle.nativeIndicatorClearDepth)
        XCTAssertGreaterThan(begin.ms, step.ms)
    }

    func testReduceMotionArmsTheSmallerLaneFromTheSameStream() throws {
        let machine = try begunMachine(latest: 0.33, reduceMotion: true)
        XCTAssertEqual(machine.observe(displacement: 60.33, ownsBandHeader: true, isHomePresented: true),
                       [.armHold(start: Settle.reducedStartCap)],
                       "capped to the reduced lane; the ease waits until native has fallen to it")
        XCTAssertEqual(machine.observe(displacement: 24, ownsBandHeader: true, isHomePresented: true), [.startEase])
        XCTAssertEqual(machine.observe(displacement: 5, ownsBandHeader: true, isHomePresented: true), [.beginAcknowledgment])
    }

    // MARK: - Replay harness

    private struct Replay {
        let samples: [Sample]
        let timeline: [(ms: Double, effects: [Effect])]
        let atBegin: [Effect]
        let latestAtBegin: CGFloat
        let endMs: Double
        let plan: Settle.Plan

        func effects(at ms: Double) -> [Effect] {
            timeline.first { $0.ms == ms }?.effects ?? []
        }

        /// The hold the settle armed, if any.
        var armedHold: CGFloat? {
            for entry in timeline {
                for effect in entry.effects {
                    if case .armHold(let start) = effect { return start }
                }
            }
            return nil
        }

        func firstMs(of effect: Effect, before limit: Double) -> Double? {
            timeline.first { $0.ms < limit && $0.effects.contains(effect) }?.ms
        }

        func sample(of effect: Effect) -> Sample? {
            guard let hit = timeline.first(where: { $0.effects.contains(effect) }) else { return nil }
            return samples.first { $0.ms == hit.ms }
        }

        func count(of effect: Effect) -> Int {
            timeline.reduce(0) { $0 + $1.effects.filter { $0 == effect }.count }
        }

        /// The armed hold and the instant its ease begins, modelled with the same
        /// curve and commit interval the view uses.
        private var hold: (start: CGFloat, easeBeginMs: Double?)? {
            var start: CGFloat?
            var easeBegin: Double?
            for entry in timeline {
                for effect in entry.effects {
                    switch effect {
                    case .armHold(let value): start = value
                    case .startEase: easeBegin = entry.ms + 20
                    default: break
                    }
                }
            }
            if let start { return (start, easeBegin) }
            return nil
        }

        /// The hold at a given time (0 before it is armed): the armed start until
        /// its ease begins, then the same curve and commit interval the view uses.
        func holdValue(atMs ms: Double) -> CGFloat {
            guard let hold,
                  let armedAt = timeline.first(where: { $0.effects.contains { if case .armHold = $0 { return true } else { return false } } })?.ms,
                  ms >= armedAt else { return 0 }
            guard let easeBegin = hold.easeBeginMs, ms > easeBegin else { return hold.start }
            return hold.start * (1 - HomeRefreshSettleProductionStreamTests.easeProgress((ms - easeBegin) / 1000, plan: plan))
        }

        /// Rendered displacement = max(native, hold) at a given time, with native
        /// read from the recorded stream (last sample at or before the time).
        func renderedDisplacement(atMs ms: Double) -> CGFloat {
            let native = samples.last { $0.ms <= ms }?.displacement ?? latestAtBegin
            guard let hold else { return max(0, native) }
            let armedAt = timeline.first { $0.effects.contains { if case .armHold = $0 { return true } else { return false } } }?.ms ?? 0
            guard ms >= armedAt else { return max(0, native) }
            var value = hold.start
            if let easeBegin = hold.easeBeginMs, ms > easeBegin {
                value = hold.start * (1 - HomeRefreshSettleProductionStreamTests.easeProgress((ms - easeBegin) / 1000, plan: plan))
            }
            return Settle.renderedDisplacement(nativeDisplacement: native, hold: value)
        }

        /// The settle may only ever *hold* content: wherever rendered rises it is
        /// native's own motion, never the hold's, and it never passes rest.
        func assertSettleAddsNoRiseAndNoOvershoot(file: StaticString = #filePath, line: UInt = #line) throws {
            var previousRendered: CGFloat?
            var previousNative: CGFloat?
            for sample in samples {
                let rendered = renderedDisplacement(atMs: sample.ms)
                XCTAssertGreaterThanOrEqual(rendered, -0.0001, "overshoot at \(sample.ms) ms", file: file, line: line)
                if let previousRendered, let previousNative, rendered > previousRendered + 0.0001 {
                    XCTAssertGreaterThan(sample.displacement, previousNative,
                                         "\(sample.ms) ms: content rose without native rising (the hold moved it away from rest)",
                                         file: file, line: line)
                    XCTAssertEqual(rendered, max(0, sample.displacement), accuracy: 0.0001, "\(sample.ms) ms: a rise is native's", file: file, line: line)
                }
                previousRendered = rendered
                previousNative = sample.displacement
            }
        }
    }

    private func replay(
        pre: [Sample],
        post: [Sample],
        endMs: Double,
        reduceMotion: Bool = false
    ) throws -> Replay {
        let machine = HomeRefreshSettleMachine()
        // Before the closure returns the machine is idle but keeps the latest reading.
        for sample in pre {
            XCTAssertEqual(machine.observe(displacement: sample.displacement, ownsBandHeader: true, isHomePresented: true), [],
                           "an idle machine reacts to nothing (\(sample.ms) ms)")
        }
        let plan = try XCTUnwrap(Settle.plan(reduceMotion: reduceMotion, isHomePresented: true, ownsBandHeader: true))
        let latestAtBegin = machine.latestDisplacement
        let atBegin = machine.begin(plan: plan, ownsBandHeader: true, isHomePresented: true)
        var timeline: [(ms: Double, effects: [Effect])] = []
        if !atBegin.isEmpty { timeline.append((endMs, atBegin)) }
        // The diagnostics logged only readings above 0.5 pt, so the final approach
        // to rest was not recorded; the content ended at rest. That last reading is
        // the only sample not taken from the app.
        let stream = post + [(ms: (post.last?.ms ?? endMs) + 50, displacement: 0)]
        for sample in stream {
            let effects = machine.observe(displacement: sample.displacement, ownsBandHeader: true, isHomePresented: true)
            if !effects.isEmpty { timeline.append((sample.ms, effects)) }
        }
        return Replay(samples: stream, timeline: timeline, atBegin: atBegin, latestAtBegin: latestAtBegin, endMs: endMs, plan: plan)
    }

    private func begunMachine(latest: CGFloat, reduceMotion: Bool = false) throws -> HomeRefreshSettleMachine {
        let machine = HomeRefreshSettleMachine()
        _ = machine.observe(displacement: latest, ownsBandHeader: true, isHomePresented: true)
        let plan = try XCTUnwrap(Settle.plan(reduceMotion: reduceMotion, isHomePresented: true, ownsBandHeader: true))
        _ = machine.begin(plan: plan, ownsBandHeader: true, isHomePresented: true)
        return machine
    }

    @discardableResult
    private func machine(_ machine: HomeRefreshSettleMachine, observing readings: [CGFloat]) -> [[Effect]] {
        readings.map { machine.observe(displacement: $0, ownsBandHeader: true, isHomePresented: true) }
    }

    /// Progress of the settle's ease `elapsed` seconds after the ease started: the
    /// plan's delay (the still moment), then its curve — ease-in-out in standard
    /// motion, ease-out in Reduce Motion — over its duration.
    nonisolated static func easeProgress(_ elapsed: Double, plan: HomeRefreshSettle.Plan) -> CGFloat {
        let x = min(1, max(0, (elapsed - plan.delay) / plan.duration))
        return plan.isReduced
            ? HomeRefreshSettleSequencingTests.cubicBezier(x, 0, 0, 0.58, 1)
            : HomeRefreshSettleSequencingTests.cubicBezier(x, 0.42, 0, 0.58, 1)
    }
}
