//
//  HomeRefreshNoLaneRecoveryTests.swift
//  CommonPlateiosTests
//
// W4-H3 Decision 12 Option B: the narrow exceptional fallback for a successful
// Unavailable → healthy recovery that is effectively at rest (at or within 6 pt)
// with no genuinely open transient lane. Recovered data applies normally; no
// authored check and no `Updated` are emitted, and nothing is overlaid on
// ordinary resting Home.
//
// Scope honesty: the decision is proven at the pure presentation seam
// (`HomeRefreshSettle.isExceptionalNoLaneRecovery` and the
// `HomeRefreshSettleMachine` the view drives) plus source-structure wiring for
// the private SwiftUI effect handling. It is not rendered here, and it says
// nothing about physical VoiceOver behavior.
import XCTest
@testable import CommonPlateios

@MainActor
final class HomeRefreshNoLaneRecoveryTests: XCTestCase {
    private typealias Settle = HomeRefreshSettle
    private typealias Home = HomeExchangeView

    // MARK: - The predicate's inputs, and recovery (the armed-hold input is constant false at the one production call site)

    func testTheExceptionalStateRequiresRecoveryAtRestAndNoArmedLane() {
        let clear = Settle.nativeIndicatorClearDepth
        XCTAssertEqual(clear, 6, "the contract's 'at or within 6 pt of rest'")
        XCTAssertTrue(Settle.isExceptionalNoLaneRecovery(isRecovery: true, nativeDisplacement: 0, isHoldArmed: false))
        XCTAssertTrue(Settle.isExceptionalNoLaneRecovery(isRecovery: true, nativeDisplacement: clear, isHoldArmed: false), "6 pt is inside")
        XCTAssertFalse(Settle.isExceptionalNoLaneRecovery(isRecovery: true, nativeDisplacement: clear + 0.01, isHoldArmed: false), "past 6 pt is not at rest")
        // A reading at rest ALONE is not sufficient: an armed hold is a genuine lane.
        XCTAssertFalse(Settle.isExceptionalNoLaneRecovery(isRecovery: true, nativeDisplacement: 0, isHoldArmed: true))
        XCTAssertFalse(Settle.isExceptionalNoLaneRecovery(isRecovery: true, nativeDisplacement: clear, isHoldArmed: true))
        // Option B is a recovery exception; it never removes healthy → healthy feedback.
        XCTAssertFalse(Settle.isExceptionalNoLaneRecovery(isRecovery: false, nativeDisplacement: 0, isHoldArmed: false))
    }

    // MARK: - The machine: exceptional fallback

    func testRecoveryAtRestWithNoLaneEndsWithNoCheckAndNoAnnouncementEffect() throws {
        let machine = try begunMachine(isRecovery: true, latest: 0.33)
        XCTAssertEqual(machine.stage, .awaitingNativeEnd, "no hold was ever armed: no lane")
        let effects = machine.nativeEndGraceElapsed(ownsBandHeader: true, isHomePresented: true)
        XCTAssertEqual(effects, [.endWithoutAcknowledgment])
        XCTAssertFalse(effects.contains(.beginAcknowledgment), "no check, and no `Updated` (they begin together or not at all)")
        XCTAssertFalse(effects.contains(where: { if case .armHold = $0 { return true } else { return false } }), "no lane is created to host it")
        XCTAssertEqual(machine.stage, .idle)
        // Nothing begins later: no queue, no replay.
        for displacement: CGFloat in [0, 3, 40, 2, 0] {
            XCTAssertEqual(machine.observe(displacement: displacement, ownsBandHeader: true, isHomePresented: true), [])
        }
        XCTAssertEqual(machine.nativeEndGraceElapsed(ownsBandHeader: true, isHomePresented: true), [])
    }

    func testTheSixPointBoundaryIsInclusiveAndAboveItTheLaneIsGenuine() throws {
        let atBoundary = try begunMachine(isRecovery: true, latest: 6)
        XCTAssertEqual(atBoundary.nativeEndGraceElapsed(ownsBandHeader: true, isHomePresented: true), [.endWithoutAcknowledgment])

        // Just above 6 pt the content is not at rest: the grace path arms a hold and
        // the normal collapse/acknowledgment applies.
        let above = try begunMachine(isRecovery: true, latest: 6.5)
        let effects = above.nativeEndGraceElapsed(ownsBandHeader: true, isHomePresented: true)
        XCTAssertFalse(effects.contains(.endWithoutAcknowledgment))
        XCTAssertTrue(effects.contains(where: { if case .armHold = $0 { return true } else { return false } }))
    }

    // MARK: - ≤ 6 pt alone does not suppress when a genuine lane exists

    func testAReadingAtRestAloneNeverSuppressesWhenAHoldIsArmed() throws {
        // The normal production shape: the refresh ends with the end-of-refresh
        // step, the hold arms from the first real reading, native collapses through
        // the clear depth. The reading IS ≤ 6 pt at the moment the check begins —
        // and the check still begins, because a lane is genuinely open.
        let machine = try begunMachine(isRecovery: true, latest: 0)
        XCTAssertTrue(machine.observe(displacement: 60, ownsBandHeader: true, isHomePresented: true)
            .contains(where: { if case .armHold = $0 { return true } else { return false } }))
        XCTAssertEqual(machine.stage, .collapsing)
        XCTAssertEqual(machine.observe(displacement: 30, ownsBandHeader: true, isHomePresented: true).contains(.beginAcknowledgment), false)
        for atRest: CGFloat in [6, 4, 0.5] {
            let lane = try collapsingMachine(isRecovery: true)
            let effects = lane.observe(displacement: atRest, ownsBandHeader: true, isHomePresented: true)
            XCTAssertTrue(effects.contains(.beginAcknowledgment), "\(atRest) pt with an armed lane is acknowledged")
            XCTAssertFalse(effects.contains(.endWithoutAcknowledgment))
        }
        // Once collapsing/acknowledging, the grace fallback can never reach Option B.
        let begun = try collapsingMachine(isRecovery: true)
        _ = begun.observe(displacement: 5, ownsBandHeader: true, isHomePresented: true)
        XCTAssertEqual(begun.stage, .acknowledging)
        XCTAssertEqual(begun.nativeEndGraceElapsed(ownsBandHeader: true, isHomePresented: true), [])
        let collapsing = try collapsingMachine(isRecovery: true)
        XCTAssertEqual(collapsing.nativeEndGraceElapsed(ownsBandHeader: true, isHomePresented: true), [])
    }

    func testAGenuineLaneRecoveryReachedThroughTheGracePathIsAcknowledgedNormally() throws {
        // No step seen, content still displaced when the grace elapses: a hold is
        // armed and the collapse then acknowledges as usual.
        let machine = try begunMachine(isRecovery: true, latest: 40)
        let first = machine.nativeEndGraceElapsed(ownsBandHeader: true, isHomePresented: true)
        XCTAssertFalse(first.contains(.endWithoutAcknowledgment))
        XCTAssertEqual(machine.stage, .collapsing)
        XCTAssertTrue(machine.observe(displacement: 4, ownsBandHeader: true, isHomePresented: true).contains(.beginAcknowledgment))
    }

    // MARK: - Healthy → healthy and other paths are unaffected

    func testHealthyToHealthyAtRestStillAcknowledgesExactlyAsBefore() throws {
        let machine = try begunMachine(isRecovery: false, latest: 0)
        XCTAssertEqual(machine.nativeEndGraceElapsed(ownsBandHeader: true, isHomePresented: true), [.beginAcknowledgment])
    }

    func testTheContextGateStillWinsAndSuppressionNeverQueues() throws {
        for (presented, owns) in [(false, true), (true, false)] {
            let machine = try begunMachine(isRecovery: true, latest: 0)
            XCTAssertEqual(machine.nativeEndGraceElapsed(ownsBandHeader: owns, isHomePresented: presented), [.retire])
        }
    }

    func testBeginAlwaysRewritesTheRecoveryClassificationForANewRefresh() throws {
        let machine = try begunMachine(isRecovery: true, latest: 0)
        machine.reset()
        let plan = try XCTUnwrap(Settle.plan(reduceMotion: false, isHomePresented: true, ownsBandHeader: true))
        _ = machine.begin(plan: plan, ownsBandHeader: true, isHomePresented: true)
        XCTAssertEqual(machine.nativeEndGraceElapsed(ownsBandHeader: true, isHomePresented: true), [.beginAcknowledgment],
                       "a later healthy → healthy refresh is not carried into Option B")
    }

    // MARK: - Motion parameters are exactly the approved ones

    func testStandardAndReduceMotionPlansAreUnchanged() throws {
        let standard = try XCTUnwrap(Settle.plan(reduceMotion: false, isHomePresented: true, ownsBandHeader: true))
        XCTAssertEqual(Settle.heldLane, 36)
        XCTAssertEqual(standard.startCap, 36)
        XCTAssertEqual(standard.laneCenter, 18)
        XCTAssertEqual(standard.delay, 0.35)
        XCTAssertEqual(standard.duration, 0.4)
        XCTAssertEqual(standard.checkHold, .milliseconds(200))
        XCTAssertFalse(standard.isReduced)

        let reduced = try XCTUnwrap(Settle.plan(reduceMotion: true, isHomePresented: true, ownsBandHeader: true))
        XCTAssertEqual(reduced.startCap, 36)
        XCTAssertEqual(reduced.laneCenter, 18)
        XCTAssertEqual(reduced.delay, 0.5)
        XCTAssertEqual(reduced.duration, 0.2)
        XCTAssertEqual(reduced.checkHold, .milliseconds(200))
        XCTAssertTrue(reduced.isReduced)
    }

    // MARK: - Data truth and non-success paths stay outside Option B

    func testNonSuccessGatingIsUnchangedSoOptionBIsOnlyReachableFromATruthfulSuccess() {
        XCTAssertFalse(Home.shouldAcknowledgeRefreshSuccess(didResolveInTime: false, fetchOutcome: .succeeded, resolvedState: .empty))
        XCTAssertFalse(Home.shouldAcknowledgeRefreshSuccess(didResolveInTime: true, fetchOutcome: .didNotSucceed, resolvedState: .empty))
        XCTAssertFalse(Home.shouldAcknowledgeRefreshSuccess(didResolveInTime: true, fetchOutcome: nil, resolvedState: .empty))
        XCTAssertFalse(Home.shouldAcknowledgeRefreshSuccess(didResolveInTime: true, fetchOutcome: .succeeded, resolvedState: .unavailable))
        // A recovery success is unchanged by Option B: it is still a success and
        // still begins a settle; only its acknowledgment can be withheld.
        XCTAssertTrue(Home.shouldAcknowledgeRefreshSuccess(didResolveInTime: true, fetchOutcome: .succeeded, resolvedState: .empty))
    }

    func testOptionBLivesInPresentationOnlyAndTouchesNoRefreshOrDataAuthority() throws {
        let settle = try settleSource()
        for forbidden in ["RequestStore", "fetchRequests", "fetchGeneration", "collectionRevision",
                          "manualRefreshDeadline", "DragGesture", "UIRefreshControl", "contentInset", "store."] {
            XCTAssertFalse(settle.contains(forbidden), "settle file must stay presentation-only: \(forbidden)")
        }
        let home = try homeSource()

        // The recovery classification is read before the fetch and feeds only the settle.
        let authored = try section(of: home, from: "private func performAuthoredRefresh() async {", to: "/// Runs the one authoritative reload")
        let classify = try XCTUnwrap(authored.range(of: "isRecoveryRefresh = currentBoardState == .unavailable"))
        let resolve = try XCTUnwrap(authored.range(of: "let acknowledgesSuccess = await Self.resolveRefresh(store: store)"))
        XCTAssertLessThan(classify.lowerBound, resolve.lowerBound, "read before the fetch applies")
        XCTAssertTrue(authored.contains("if acknowledgesSuccess {\n            beginRefreshSettle()\n        }"),
                      "success gating is unchanged: data and outcome truth are not touched")

        // The classification actually reaches the machine (the machine's default is
        // `false`, so dropping this argument would silently disable Option B).
        let begin = try section(of: home, from: "private func beginRefreshSettle() {", to: "/// Feeds one passive displacement sample")
        XCTAssertTrue(begin.contains("isRecovery: isRecoveryRefresh"))

        // The new effect ends the settle through the retire path only: no check, no announcement.
        XCTAssertTrue(home.contains("case .retire, .endWithoutAcknowledgment:\n                retireRefreshSettle()"))
        XCTAssertEqual(home.components(separatedBy: "AccessibilityNotification.Announcement(").count - 1, 1,
                       "`Updated` has exactly one posting site, behind beginAcknowledgment")
        XCTAssertEqual(home.components(separatedBy: "isShowingRefreshSuccess = true").count - 1, 1,
                       "the check has exactly one showing site, behind beginAcknowledgment")
        XCTAssertTrue(home.contains("case .beginAcknowledgment:\n                beginRefreshAcknowledgment()"))

        // The fallback never delays or gates the data: the one reload stays inside
        // resolveRefresh, which finishes before the settle begins.
        let resolveBody = try section(of: home, from: "static func resolveRefresh(", to: "/// The truthful-success predicate")
        XCTAssertTrue(resolveBody.contains("store.fetchRequests()"))
        XCTAssertFalse(resolveBody.contains("isRecoveryRefresh"), "the classification never reaches the fetch")
    }

    func testTheOwnerDateCommentAboveTheHeldLaneIsGone() throws {
        let settle = try settleSource()
        XCTAssertFalse(settle.contains("Option C direction (2026-10-09)"))
        XCTAssertFalse(settle.contains("Faith's Option C"))
    }

    // MARK: - Helpers

    private func begunMachine(isRecovery: Bool, latest: CGFloat) throws -> HomeRefreshSettleMachine {
        let machine = HomeRefreshSettleMachine()
        _ = machine.observe(displacement: latest, ownsBandHeader: true, isHomePresented: true)
        let plan = try XCTUnwrap(Settle.plan(reduceMotion: false, isHomePresented: true, ownsBandHeader: true))
        _ = machine.begin(plan: plan, ownsBandHeader: true, isHomePresented: true, isRecovery: isRecovery)
        return machine
    }

    /// Refresh ended (step seen), hold armed, native still well above rest.
    private func collapsingMachine(isRecovery: Bool) throws -> HomeRefreshSettleMachine {
        let machine = try begunMachine(isRecovery: isRecovery, latest: 30)
        _ = machine.observe(displacement: 90, ownsBandHeader: true, isHomePresented: true)
        XCTAssertEqual(machine.stage, .collapsing)
        return machine
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
