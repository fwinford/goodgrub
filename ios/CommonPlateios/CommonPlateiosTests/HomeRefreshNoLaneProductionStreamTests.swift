//
//  HomeRefreshNoLaneProductionStreamTests.swift
//  CommonPlateiosTests
//
// W4-H3 Decision 12 Option B: regression proof against the passive displacement
// streams the production app actually produces, so the exceptional no-lane
// fallback is pinned to real shapes and not only to hand-fed readings.
//
// What is recorded and what is not:
//   • RECORDED: the held-lane stream and the deep-held stream below were captured
//     from the production view on the H3 Simulator (iOS 26.5, Debug, temporary
//     diagnostics that have since been removed) while Faith pulled an
//     Unavailable → healthy recovery. Samples are (milliseconds, displacement
//     below rest in points) exactly as the view's preference change delivered
//     them. The deep-held stream is subsampled.
//   • CONSTRUCTED: the natural-collapse stream is NOT a recording. It is the
//     shape `HomeRefreshSettle.postEndGrace` describes for content already at rest
//     with no collapse to wait for; it is labeled as constructed where used.
//
// What this does not prove: the second Decision 12 condition (no genuinely open
// lane) is represented in the machine only by "no end-of-refresh step was seen
// within the grace". These tests pin that representation against real streams;
// they do not establish a lane-open signal for a pull a finger is still holding
// at a lane-biased reading of 6 pt or less (roughly 66 pt or less of drawn
// displacement, spinner visibly drawn) after the data returns. That residual case
// is not reproduced here and is recorded as an open finding for Week HQ.
import XCTest
@testable import CommonPlateios

@MainActor
final class HomeRefreshNoLaneProductionStreamTests: XCTestCase {
    private typealias Sample = (ms: Double, displacement: CGFloat)
    private typealias Effect = HomeRefreshSettleMachine.Effect
    private typealias Settle = HomeRefreshSettle

    // MARK: - Recorded: a held lane that reads at rest for seconds

    /// The finger lifts and the content falls onto the native refresh lane: the
    /// passive reading reads 0.33 — "at rest" — for about 1.9 s while the lane is
    /// genuinely open and the spinner is drawn. The refresh closure then returns.
    private static let heldLanePre: [Sample] = [
        (0, 240), (29, 209.33), (46, 181), (63, 156.33), (79, 134.67), (96, 116),
        (113, 100), (129, 86), (146, 74), (163, 63.67), (179, 54.67), (196, 46.67),
        (213, 40), (229, 34.33), (247, 29.33), (263, 25.33), (280, 21.67), (297, 18.33),
        (313, 15.67), (330, 13.33), (347, 11.33), (363, 9.67), (379, 8.33), (397, 7),
        (413, 6), (429, 5.33), (447, 4.33), (463, 3.67), (480, 3.33), (497, 2.67),
        (513, 2.33), (530, 2), (546, 1.67), (563, 1.33), (597, 1), (629, 0.67),
        (680, 0.33)
    ]
    /// The end-of-refresh step arrives 4 ms after the closure returned (2614 ms),
    /// then the real collapse carries the content to rest.
    private static let heldLanePost: [Sample] = [
        (2618, 60.33), (2629, 60), (2646, 59), (2662, 57), (2679, 54.33), (2696, 50.67),
        (2712, 46.67), (2729, 42), (2746, 37), (2762, 31.67), (2779, 26.33), (2796, 21.33),
        (2812, 16.33), (2829, 12), (2846, 8), (2863, 5), (2879, 2.33), (2896, 0.67),
        (2913, 0)
    ]
    private static let heldLaneClosureReturnedAtMs = 2614.0

    // MARK: - Recorded (subsampled): a pull still held deep when the closure returns

    /// The closure returned with the pull held at 194 pt; the reading stayed flat
    /// until the finger lifted, when it stepped up by one lane (194 → 254) and the
    /// collapse ran.
    private static let deepHeldReadingAtClosure: CGFloat = 194.33
    private static let deepHeldAfterLift: [CGFloat] = [254, 214.33, 143, 92, 60.33, 36.67, 20, 8.67, 5.33]

    // MARK: - Held lane: genuinely open, reads at rest, and is acknowledged

    func testARecoveryOnAHeldLaneThatReadsAtRestForSecondsIsAcknowledgedNormally() throws {
        for isRecovery in [true, false] {
            let machine = HomeRefreshSettleMachine()
            for sample in Self.heldLanePre {
                XCTAssertEqual(machine.observe(displacement: sample.displacement, ownsBandHeader: true, isHomePresented: true), [],
                               "an idle machine reacts to nothing (\(sample.ms) ms)")
            }
            XCTAssertEqual(machine.latestDisplacement, 0.33, accuracy: 0.01)

            // The reading was at or within the clear depth for the whole
            // pre-closure interval below — over two seconds with the lane open.
            let firstAtRest = try XCTUnwrap(Self.heldLanePre.first { $0.displacement <= Settle.nativeIndicatorClearDepth })
            XCTAssertGreaterThan(Self.heldLaneClosureReturnedAtMs - firstAtRest.ms, 2000,
                                 "the lane read at rest for over two seconds while genuinely open")

            let plan = try XCTUnwrap(Settle.plan(reduceMotion: false, isHomePresented: true, ownsBandHeader: true))
            XCTAssertEqual(machine.begin(plan: plan, ownsBandHeader: true, isHomePresented: true, isRecovery: isRecovery), [],
                           "nothing is decided from the held-lane reading when the closure returns")
            XCTAssertEqual(machine.stage, .awaitingNativeEnd)

            var timeline: [(ms: Double, effects: [Effect])] = []
            for sample in Self.heldLanePost {
                let effects = machine.observe(displacement: sample.displacement, ownsBandHeader: true, isHomePresented: true)
                if !effects.isEmpty { timeline.append((sample.ms, effects)) }
            }

            let step = try XCTUnwrap(timeline.first)
            XCTAssertEqual(step.ms, 2618)
            XCTAssertEqual(step.effects, [.armHold(start: Settle.heldLane)],
                           "the step arms the hold: a genuine lane, acknowledged normally (recovery: \(isRecovery))")
            let all = timeline.flatMap(\.effects)
            XCTAssertEqual(all.filter { $0 == .beginAcknowledgment }.count, 1, "exactly once")
            XCTAssertEqual(all.filter { $0 == .endWithoutAcknowledgment }.count, 0, "Option B is never consulted")
            XCTAssertEqual(all.filter { $0 == .retire }.count, 0)
            XCTAssertEqual(machine.stage, .acknowledging)
        }
    }

    func testTheStepArrivesFarInsideTheGraceSoTheFallbackCannotPreemptARealLaneEnd() {
        let stepLatencyMs = Self.heldLanePost[0].ms - Self.heldLaneClosureReturnedAtMs
        XCTAssertEqual(stepLatencyMs, 4)
        // Run A (the earlier recorded slow-backend run) measured ~40 ms.
        for latency in [stepLatencyMs, 40] {
            XCTAssertLessThan(Duration.milliseconds(Int(latency)), Settle.postEndGrace,
                              "a step \(Int(latency)) ms after the closure is decided before the grace can elapse")
        }
    }

    func testTheGraceElapsingAfterTheStepNeverReachesOptionB() throws {
        let machine = HomeRefreshSettleMachine()
        for sample in Self.heldLanePre {
            _ = machine.observe(displacement: sample.displacement, ownsBandHeader: true, isHomePresented: true)
        }
        let plan = try XCTUnwrap(Settle.plan(reduceMotion: false, isHomePresented: true, ownsBandHeader: true))
        _ = machine.begin(plan: plan, ownsBandHeader: true, isHomePresented: true, isRecovery: true)
        _ = machine.observe(displacement: Self.heldLanePost[0].displacement, ownsBandHeader: true, isHomePresented: true)
        XCTAssertEqual(machine.stage, .collapsing)
        XCTAssertEqual(machine.nativeEndGraceElapsed(ownsBandHeader: true, isHomePresented: true), [],
                       "the grace timer firing later finds the collapse already running")
    }

    // MARK: - Deep held pull: the grace arms a hold, never Option B

    func testARecoveryHeldDeepWhenTheClosureReturnsIsArmedByTheGraceAndAcknowledgedAfterTheLift() throws {
        let machine = HomeRefreshSettleMachine()
        _ = machine.observe(displacement: Self.deepHeldReadingAtClosure, ownsBandHeader: true, isHomePresented: true)
        let plan = try XCTUnwrap(Settle.plan(reduceMotion: false, isHomePresented: true, ownsBandHeader: true))
        XCTAssertEqual(machine.begin(plan: plan, ownsBandHeader: true, isHomePresented: true, isRecovery: true), [])

        // No step before the grace: the finger still holds the pull.
        let grace = machine.nativeEndGraceElapsed(ownsBandHeader: true, isHomePresented: true)
        XCTAssertEqual(grace, [.armHold(start: Settle.heldLane)], "content is displaced: hand off, never Option B")
        XCTAssertEqual(machine.stage, .collapsing)

        var all: [Effect] = []
        for reading in Self.deepHeldAfterLift {
            let effects = machine.observe(displacement: reading, ownsBandHeader: true, isHomePresented: true)
            all += effects
            if reading > Settle.nativeIndicatorClearDepth {
                XCTAssertFalse(effects.contains(.beginAcknowledgment), "not while \(reading) pt is still displaced")
            }
        }
        XCTAssertEqual(all.filter { $0 == .startEase }.count, 1)
        XCTAssertEqual(all.filter { $0 == .beginAcknowledgment }.count, 1, "acknowledged once native has cleared the lane")
        XCTAssertEqual(all.filter { $0 == .endWithoutAcknowledgment }.count, 0)
        XCTAssertEqual(machine.stage, .acknowledging)
    }

    // MARK: - Constructed: a refresh that returned before any lane opened

    /// CONSTRUCTED, not recorded: the unbiased natural collapse of a refresh that
    /// returned before a native lane held it open. Every reading falls; none rises.
    /// No end-of-refresh step exists, because there was no lane to step out of.
    func testAFallingStreamWithNoStepIsNeverTreatedAsTheStepAndEndsPerOptionB() throws {
        let falling: [CGFloat] = [120, 96, 74, 55, 40, 28, 19, 12, 7.5, 4.5, 2.5, 1.2, 0.5]

        let recovery = try fallingMachine(isRecovery: true, falling: falling)
        XCTAssertEqual(recovery.stage, .awaitingNativeEnd, "a falling reading is not the end-of-refresh step")
        XCTAssertLessThanOrEqual(recovery.latestDisplacement, Settle.nativeIndicatorClearDepth)
        XCTAssertEqual(recovery.nativeEndGraceElapsed(ownsBandHeader: true, isHomePresented: true), [.endWithoutAcknowledgment],
                       "recovery at rest with no lane: data applies, no check, no `Updated`")

        // Option B is a recovery exception: the same stream for healthy → healthy
        // keeps its acknowledgment exactly as before.
        let healthy = try fallingMachine(isRecovery: false, falling: falling)
        XCTAssertEqual(healthy.nativeEndGraceElapsed(ownsBandHeader: true, isHomePresented: true), [.beginAcknowledgment])
    }

    // MARK: - Structure: where the exceptional state can be evaluated

    /// Documents (does not endorse) that the exceptional state is consulted at one
    /// site only: the grace fallback. If a later contract adds an independent
    /// lane-open signal, this test is expected to change with it.
    func testTheExceptionalStateIsConsultedAtTheGraceFallbackOnly() throws {
        let settle = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ios/CommonPlateios/CommonPlateios/Views/HomeRefreshSettle.swift"), encoding: .utf8)
        XCTAssertEqual(settle.components(separatedBy: "isExceptionalNoLaneRecovery(").count - 1, 2,
                       "one definition and one call")
        let lower = try XCTUnwrap(settle.range(of: "func nativeEndGraceElapsed("))
        let upper = try XCTUnwrap(settle.range(of: "/// Ends the settle's monitoring.", range: lower.upperBound..<settle.endIndex))
        XCTAssertTrue(settle[lower.lowerBound..<upper.lowerBound].contains("isExceptionalNoLaneRecovery("),
                      "the single call is inside the grace fallback")
    }

    // MARK: - Helpers

    private func fallingMachine(isRecovery: Bool, falling: [CGFloat]) throws -> HomeRefreshSettleMachine {
        let machine = HomeRefreshSettleMachine()
        _ = machine.observe(displacement: 140, ownsBandHeader: true, isHomePresented: true)
        let plan = try XCTUnwrap(Settle.plan(reduceMotion: false, isHomePresented: true, ownsBandHeader: true))
        XCTAssertEqual(machine.begin(plan: plan, ownsBandHeader: true, isHomePresented: true, isRecovery: isRecovery), [])
        for reading in falling {
            XCTAssertEqual(machine.observe(displacement: reading, ownsBandHeader: true, isHomePresented: true), [],
                           "\(reading) pt: a falling reading arms and decides nothing")
        }
        return machine
    }
}
