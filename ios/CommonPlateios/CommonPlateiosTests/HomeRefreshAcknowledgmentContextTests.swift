//
//  HomeRefreshAcknowledgmentContextTests.swift
//  CommonPlateiosTests
//
// W4-H3 context-bound success acknowledgment ("Acknowledgment lifetime",
// weekly spec decision 9). The micro-check and the VoiceOver `Updated`
// announcement are one acknowledgment: at the moment it would begin it is
// presented only if Home is still the presented destination AND the scroll
// position is still in the top/header-owned (band) context. Otherwise it is
// dropped — never queued, deferred, or replayed — while the refresh outcome and
// the refreshed data are untouched.
//
// Scope honesty: the pure decision is covered by behavioral tests, including the
// settle's per-sample reaction that applies it at the moment the check would
// begin; the wiring (the single gate in front of both feedback forms, the
// lifecycle writers, no second scroll authority, no change to the
// outcome/deadline path) is covered by source-structure tests. The private
// SwiftUI tasks are not driven here and no navigation architecture is faked:
// exactly-once spoken `Updated`, no focus movement, and the suppressed cases on
// a real device remain the existing physical-device proof.
import XCTest
@testable import CommonPlateios

final class HomeRefreshAcknowledgmentContextTests: XCTestCase {
    private typealias Home = HomeExchangeView

    // MARK: - The decision

    func testAcknowledgmentBeginsOnlyWhileHomeIsPresentedAndTheBandOwnsTheHeader() {
        XCTAssertTrue(Home.shouldBeginRefreshAcknowledgment(isHomePresented: true, ownsBandHeader: true))
    }

    func testScrollingAwayFromTheTopContextSuppressesIt() {
        XCTAssertFalse(Home.shouldBeginRefreshAcknowledgment(isHomePresented: true, ownsBandHeader: false))
    }

    func testNavigatingAwayFromHomeSuppressesIt() {
        XCTAssertFalse(Home.shouldBeginRefreshAcknowledgment(isHomePresented: false, ownsBandHeader: true))
    }

    func testLosingBothContextsSuppressesIt() {
        XCTAssertFalse(Home.shouldBeginRefreshAcknowledgment(isHomePresented: false, ownsBandHeader: false))
    }

    func testTheTopContextIsExactlyTheExistingHeaderOwnershipTruth() {
        // No second scroll threshold: the gate's scroll input is the accepted
        // `ownsBandHeader(scrollOffset:)` result, so rest, pull, and the
        // tolerance band are in context, and ordinary scrolling past the
        // handoff is not.
        for offset in [-120, -1, 0, Home.headerHandoffTolerance] as [CGFloat] {
            XCTAssertTrue(Home.shouldBeginRefreshAcknowledgment(
                isHomePresented: true,
                ownsBandHeader: Home.ownsBandHeader(scrollOffset: offset)
            ), "offset \(offset) is rest/pull/tolerance and stays in context")
        }
        for offset in [Home.headerHandoffTolerance + 0.5, 40, 600] as [CGFloat] {
            XCTAssertFalse(Home.shouldBeginRefreshAcknowledgment(
                isHomePresented: true,
                ownsBandHeader: Home.ownsBandHeader(scrollOffset: offset)
            ), "offset \(offset) is past the handoff and is out of context")
        }
    }

    // MARK: - Applied at the moment the check would begin (and at the settle's start)

    func testTheGateIsTheSameDecisionAtTheSettleStartAndAtTheMomentTheCheckWouldBegin() throws {
        // At the start: no plan at all when the context is already lost.
        XCTAssertNotNil(HomeRefreshSettle.plan(reduceMotion: false, isHomePresented: true, ownsBandHeader: true))
        XCTAssertNil(HomeRefreshSettle.plan(reduceMotion: false, isHomePresented: false, ownsBandHeader: true))
        XCTAssertNil(HomeRefreshSettle.plan(reduceMotion: false, isHomePresented: true, ownsBandHeader: false))
        // At the moment the indicator clears: begins only in context; otherwise retires.
        func outcome(presented: Bool, owns: Bool) throws -> [HomeRefreshSettleMachine.Effect] {
            let machine = HomeRefreshSettleMachine()
            let plan = try XCTUnwrap(HomeRefreshSettle.plan(reduceMotion: false, isHomePresented: true, ownsBandHeader: true))
            _ = machine.begin(plan: plan, ownsBandHeader: true, isHomePresented: true)
            _ = machine.observe(displacement: 40, ownsBandHeader: true, isHomePresented: true)
            return machine.observe(displacement: 4, ownsBandHeader: owns, isHomePresented: presented)
        }
        XCTAssertTrue(try outcome(presented: true, owns: true).contains(.beginAcknowledgment))
        XCTAssertEqual(try outcome(presented: false, owns: true), [.retire], "navigated away before it begins: suppressed, not queued")
        XCTAssertEqual(try outcome(presented: true, owns: false), [.retire], "scrolled away before it begins: suppressed, not queued")
        XCTAssertEqual(try outcome(presented: false, owns: false), [.retire])
    }

    func testASuppressedAcknowledgmentCannotBeReplayedByReturningOrScrollingBack() throws {
        let machine = HomeRefreshSettleMachine()
        let plan = try XCTUnwrap(HomeRefreshSettle.plan(reduceMotion: false, isHomePresented: true, ownsBandHeader: true))
        _ = machine.begin(plan: plan, ownsBandHeader: true, isHomePresented: true)
        _ = machine.observe(displacement: 40, ownsBandHeader: true, isHomePresented: true)
        // Scrolled away: retired. The view resets the machine on a retire.
        XCTAssertEqual(machine.observe(displacement: 30, ownsBandHeader: false, isHomePresented: true), [.retire])
        machine.reset()
        // Returning to the top and collapsing through the clear depth later reacts to nothing.
        for displacement: CGFloat in [20, 4, 0] {
            XCTAssertEqual(machine.observe(displacement: displacement, ownsBandHeader: true, isHomePresented: true), [])
        }
        XCTAssertEqual(machine.nativeEndGraceElapsed(ownsBandHeader: true, isHomePresented: true), [])
    }

    // MARK: - One gate for both feedback forms

    func testBothFeedbackFormsBeginFromTheOneFunctionTheEffectNamesAndNowhereElse() throws {
        let source = try homeSource()
        XCTAssertEqual(source.components(separatedBy: "isShowingRefreshSuccess = true").count - 1, 1)
        XCTAssertEqual(source.components(separatedBy: "AccessibilityNotification.Announcement(").count - 1, 1)

        let begin = try section(of: source, from: "private func beginRefreshAcknowledgment() {", to: "/// Releases the hold alone")
        let check = try XCTUnwrap(begin.range(of: "isShowingRefreshSuccess = true"))
        let announcement = try XCTUnwrap(begin.range(of: "AccessibilityNotification.Announcement("))
        XCTAssertLessThan(check.lowerBound, announcement.lowerBound, "the two begin together, in one place")

        // That function has exactly one caller: the effect's `.beginAcknowledgment`
        // arm, which the machine only emits past the context gate.
        XCTAssertEqual(source.components(separatedBy: "beginRefreshAcknowledgment()").count - 1, 2, "one definition, one call")
        let perform = try section(of: source, from: "private func perform(_ effects: [HomeRefreshSettleMachine.Effect]) {", to: "/// Holds the dynamic region")
        XCTAssertTrue(perform.contains("case .beginAcknowledgment:\n                beginRefreshAcknowledgment()"))

        let settle = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeRefreshSettle.swift")
        let evaluate = try section(of: settle, from: "private func evaluate(", to: "/// Arms the hold from the latest reading")
        let gate = try XCTUnwrap(evaluate.range(of: "HomeExchangeView.shouldBeginRefreshAcknowledgment("))
        let suppress = try XCTUnwrap(evaluate.range(of: "guard inContext else { return [.retire] }"))
        let advance = try XCTUnwrap(evaluate.range(of: "return effects + advanceCollapse()"))
        XCTAssertLessThan(gate.lowerBound, suppress.lowerBound)
        XCTAssertLessThan(suppress.lowerBound, advance.lowerBound, "the context gate precedes every possible begin")
        // The check begins in exactly one place, reached only through the gated
        // paths: `evaluate` (after the gate above) and the grace fallback (below).
        let advanceBody = try section(of: settle, from: "private func advanceCollapse() -> [Effect] {", to: "\n}\n")
        XCTAssertEqual(settle.components(separatedBy: "effects.append(.beginAcknowledgment)").count - 1, 1)
        XCTAssertTrue(advanceBody.contains("effects.append(.beginAcknowledgment)"))
        XCTAssertEqual(settle.components(separatedBy: "advanceCollapse()").count - 1, 3, "one definition, two gated callers")
        // The grace fallback begins only through the same gate.
        let grace = try section(of: settle, from: "func nativeEndGraceElapsed(", to: "/// Ends the settle's monitoring.")
        XCTAssertLessThan(try XCTUnwrap(grace.range(of: "shouldBeginRefreshAcknowledgment(")).lowerBound,
                          try XCTUnwrap(grace.range(of: "return [.beginAcknowledgment]")).lowerBound)
        // The gate failing returns `.retire`: a drop, with no retry or stored pending state.
        XCTAssertTrue(grace.contains(") else { return [.retire] }"))
    }

    func testSuppressionHasNoQueueOrReplayPath() throws {
        let source = try homeSource()
        // Presentation lifetime is a plain Bool written only by appearance /
        // disappearance; nothing records a "pending" acknowledgment to replay
        // when Home reappears or the user scrolls back up.
        XCTAssertTrue(source.contains("@State private var isHomePresented = false"))
        XCTAssertEqual(source.components(separatedBy: "isHomePresented = true").count - 1, 1)
        // The `@State` default plus the one disappearance writer.
        XCTAssertEqual(source.components(separatedBy: "isHomePresented = false").count - 1, 2)
        XCTAssertTrue(source.contains(".onAppear {\n            isHomePresented = true"))
        XCTAssertTrue(source.contains(".onDisappear {\n            isHomePresented = false"))
        for forbidden in ["pendingRefreshAcknowledgment", "deferredRefreshAcknowledgment", ".onChange(of: ownsBandHeader)", ".onChange(of: isHomePresented)"] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }

    // MARK: - Presentation-only; authority untouched

    func testTheContextGateReachesNeitherTheRefreshOutcomePathNorHeaderOwnership() throws {
        let source = try homeSource()

        // The refresh and its success determination know nothing of the view's
        // presentation context, so suppression can neither cancel the refresh,
        // change the outcome, discard data, nor touch the deadline.
        let authored = try section(of: source, from: "private func performAuthoredRefresh() async {", to: "/// Runs the one authoritative reload")
        XCTAssertFalse(authored.contains("isHomePresented"))
        XCTAssertFalse(authored.contains("ownsBandHeader"))
        XCTAssertFalse(authored.contains("shouldBeginRefreshAcknowledgment"))
        XCTAssertTrue(authored.contains("let acknowledgesSuccess = await Self.resolveRefresh(store: store)"))
        XCTAssertTrue(authored.contains("supersedeRefreshSettle()"), "a new refresh still invalidates an older pending acknowledgment")

        let resolve = try section(of: source, from: "static func resolveRefresh(", to: "/// The truthful-success predicate")
        XCTAssertFalse(resolve.contains("isHomePresented"))
        XCTAssertFalse(resolve.contains("ownsBandHeader"))
        XCTAssertFalse(resolve.contains("shouldBeginRefreshAcknowledgment"))

        // Header ownership stays scroll-position-only: its single writer is
        // unchanged and reads neither the lifecycle flag nor the gate.
        XCTAssertEqual(source.components(separatedBy: "ownsBandHeader = owner").count - 1, 1, "single writer")
        let ownership = try section(of: source, from: ".onPreferenceChange(HomeHeaderAnchorKey.self)", to: ".overlayPreferenceValue(HomeHeaderAnchorKey.self)")
        XCTAssertFalse(ownership.contains("isHomePresented"))
        XCTAssertFalse(ownership.contains("shouldBeginRefreshAcknowledgment"))
    }

    func testTheGateAddsNoSecondScrollAuthorityOrTimer() throws {
        let source = try homeSource()
        let begin = try section(of: source, from: "private func beginRefreshAcknowledgment() {", to: "/// Releases the hold alone")
        // The acknowledgment function itself reads no scroll geometry: the
        // machine hands it a decision, and the scroll input to that decision is
        // the accepted `ownsBandHeader` truth, not a second threshold.
        for forbidden in ["headerHandoffTolerance", "contentOffset", "minY", "displacement"] {
            XCTAssertFalse(begin.contains(forbidden), forbidden)
        }
        let handler = try section(of: source, from: ".onPreferenceChange(HomeHeaderAnchorKey.self)", to: ".overlayPreferenceValue(HomeHeaderAnchorKey.self)")
        let feed = try section(of: source, from: "private func observeRefreshSettle(displacement: CGFloat) {", to: "/// Performs what one passive scroll sample")
        XCTAssertTrue(feed.contains("ownsBandHeader: ownsBandHeader"), "reuses the accepted ownership truth")
        XCTAssertTrue(feed.contains("isHomePresented: isHomePresented"), "reads the live presentation flag, not a literal")
        // No timer decides when the acknowledgment begins from a sample; the only
        // delay in the acknowledgment function is the check's own fade-out hold.
        XCTAssertEqual(begin.components(separatedBy: "Task.sleep(").count - 1, 1)
        XCTAssertFalse(handler.contains("sleep"))
        let perform = try section(of: source, from: "private func perform(_ effects: [HomeRefreshSettleMachine.Effect]) {", to: "/// Holds the dynamic region")
        XCTAssertFalse(perform.contains("sleep"))
        XCTAssertFalse(perform.contains("Task"))
    }

    // MARK: - Helpers

    private func homeSource() throws -> String {
        try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")
    }

    private func section(of source: String, from start: String, to end: String) throws -> String {
        let lower = try XCTUnwrap(source.range(of: start), "missing \(start)")
        let upper = try XCTUnwrap(source.range(of: end, range: lower.upperBound..<source.endIndex), "missing \(end)")
        return String(source[lower.lowerBound..<upper.lowerBound])
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
