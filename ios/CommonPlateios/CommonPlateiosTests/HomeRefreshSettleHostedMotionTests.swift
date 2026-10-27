//
//  HomeRefreshSettleHostedMotionTests.swift
//  CommonPlateiosTests
//
// W4-H3 hosted proof of the native → authored handoff. Mounts the production
// `HomeRefreshSettleHold` modifier on a real SwiftUI `ScrollView` + `.refreshable`
// inside a real `UIWindow`, ends a real `UIRefreshControl` refresh (UIKit then
// collapses the lane exactly as it does for the app), and samples where the
// content is actually rendered on every display frame.
//
// What this proves: the rendered displacement starts where the native lane left
// off (no jump), never moves away from rest (no bounce), never passes rest
// (no overshoot), has no abrupt snap, is held clear of rest after the native
// collapse has finished (no immediate snap to rest), ends exactly at rest, and
// that with no hold the modifier adds nothing to the native motion.
//
// What it does not prove: a physical pull, the production `HomeExchangeView`
// composition around the region (header band, CTA, board), or how the motion
// looks — those remain Simulator / physical-device observation. The harness
// reproduces the production structure (band safe-area inset, zero-height
// in-scroll header, one dynamic region carrying the modifier).
import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

private final class MotionModel: ObservableObject {
    @Published var hold: CGFloat = 0
    var restMinY: CGFloat = 0
}

private struct MotionHarness: View {
    @ObservedObject var model: MotionModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 0)
                VStack(spacing: 0) {
                    Color(red: 1, green: 0, blue: 0).frame(height: 100)
                    Color(red: 0, green: 0, blue: 1).frame(height: 1200)
                }
                .modifier(HomeRefreshSettleHold(hold: model.hold, restMinY: model.restMinY))
            }
        }
        .scrollBounceBehavior(.always, axes: .vertical)
        .refreshable {}
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 80) }
    }
}

@MainActor
final class HomeRefreshSettleHostedMotionTests: XCTestCase {
    private struct Frame {
        let ms: Double
        /// Rendered displacement of the probe below its rest position.
        let rendered: CGFloat
    }

    private let laneHeight: CGFloat = 60
    private let tolerance: CGFloat = 0.75

    // MARK: - The handoff from the native collapse

    func testTheHoldCarriesContentOnFromARealUIKitCollapseWithoutAJumpABounceOrAnOvershoot() async throws {
        let frames = try await run(hold: .plan(try productionPlan()))

        let first = try XCTUnwrap(frames.first)
        XCTAssertEqual(first.rendered, laneHeight, accuracy: 1.5, "the first frame is where the native lane left off: no jump")

        var previous = first.rendered
        var largestStep: CGFloat = 0
        for frame in frames {
            XCTAssertLessThanOrEqual(frame.rendered, previous + tolerance,
                                     "\(frame.ms) ms: rendered moved away from rest (a bounce)")
            XCTAssertGreaterThanOrEqual(frame.rendered, -tolerance, "\(frame.ms) ms: rendered passed rest (an overshoot)")
            XCTAssertLessThanOrEqual(frame.rendered, laneHeight + 1.5, "\(frame.ms) ms: pushed below the handoff position")
            largestStep = max(largestStep, previous - frame.rendered)
            previous = frame.rendered
        }
        // Down to the held lane the content follows the native collapse at its own pace
        // (its largest per-frame step on a 60 pt lane is ~5 pt); the hold adds no jump of its own.
        XCTAssertLessThan(largestStep, 6.5, "no abrupt snap in any single frame")
        XCTAssertEqual(try XCTUnwrap(frames.last).rendered, 0, accuracy: 0.5, "ends exactly at the unchanged rest position")
    }

    func testArmingTheHoldInTheSameTurnAsTheNativeCollapseStillHandsOffWithoutABump() async throws {
        let frames = try await run(hold: .planArmedInTheSameTurnAsTheCollapse(try productionPlan()))

        // The worst case: nothing settled between arming and the first collapse
        // frame. Still no jump away from the lane, no frame that moves away from
        // rest, and no overshoot.
        XCTAssertEqual(try XCTUnwrap(frames.first).rendered, laneHeight, accuracy: 3,
                       "the first rendered frame is at or very near the native lane")
        var previous = try XCTUnwrap(frames.first).rendered
        var largestRise: CGFloat = 0
        for frame in frames {
            largestRise = max(largestRise, frame.rendered - previous)
            XCTAssertGreaterThanOrEqual(frame.rendered, -tolerance, "\(frame.ms) ms: overshoot")
            previous = frame.rendered
        }
        XCTAssertLessThanOrEqual(largestRise, 2.5, "no visible bump even when armed in the same turn")
        let held = try productionPlan().holdStart(forDisplacement: laneHeight)
        let at300 = try XCTUnwrap(frames.first { $0.ms >= 300 })
        XCTAssertGreaterThan(at300.rendered, held - 3, "the hold still carries the content once native has finished")
        XCTAssertEqual(try XCTUnwrap(frames.last).rendered, 0, accuracy: 0.5)
    }

    func testContentIsStillClearOfRestWhenTheNativeCollapseAloneWouldHaveFinished() async throws {
        let plan = try productionPlan()
        let frames = try await run(hold: .plan(plan))
        let held = plan.holdStart(forDisplacement: laneHeight)

        // Native alone settles in ~320 ms. The hold keeps carrying the content: it
        // holds at the lane for the brief still moment, so at 400 ms (the still moment
        // is over and the ease is under way, but far from done) it is well displaced.
        let at300 = try XCTUnwrap(frames.first { $0.ms >= 300 })
        XCTAssertGreaterThan(at300.rendered, held - 3, "content must not snap to rest when native finishes")
        let at400 = try XCTUnwrap(frames.first { $0.ms >= 400 })
        XCTAssertGreaterThan(at400.rendered, held * 0.5, "still on its way, not at rest")
        // And it is on its way, not stuck: it is home by the end of its authored schedule.
        let end = (plan.delay + plan.duration) * 1000 + 150
        let atEnd = try XCTUnwrap(frames.first { $0.ms >= end })
        XCTAssertLessThan(atEnd.rendered, 1.5)
    }

    func testWithNoHoldTheModifierAddsNothingAndNativeMotionIsUntouched() async throws {
        let frames = try await run(hold: .none)

        // Without a hold the content follows the native collapse: at rest by ~350 ms.
        let lastDisplaced = frames.last { $0.rendered > 0.5 }
        XCTAssertLessThan(try XCTUnwrap(lastDisplaced).ms, 450, "no extra hold: the native collapse is what is rendered")
        var previous = try XCTUnwrap(frames.first).rendered
        for frame in frames {
            XCTAssertLessThanOrEqual(frame.rendered, previous + tolerance)
            previous = frame.rendered
        }
        XCTAssertEqual(try XCTUnwrap(frames.last).rendered, 0, accuracy: 0.5)
    }

    func testRetiringMidSettleReturnsToRestWithoutMovingAwayFromItAndLeavesNoStaleTransform() async throws {
        let frames = try await run(hold: .planThenRetire(try productionPlan(), retireAtMs: 450))

        var previous = try XCTUnwrap(frames.first).rendered
        for frame in frames {
            XCTAssertLessThanOrEqual(frame.rendered, previous + tolerance, "\(frame.ms) ms: retire moved away from rest")
            previous = frame.rendered
        }
        let settled = try XCTUnwrap(frames.first { $0.ms >= 450 + 400 })
        XCTAssertEqual(settled.rendered, 0, accuracy: 0.5, "a retired settle leaves no stale transform")
        XCTAssertEqual(try XCTUnwrap(frames.last).rendered, 0, accuracy: 0.5)
    }

    /// A second pull retires the settle while the delayed ease is still waiting out
    /// its still moment: the model value is already 0 but the displayed hold has not
    /// moved. The retire must retarget from the *displayed* hold and return to rest
    /// promptly — the interaction behind a reported "frozen check on the second pull".
    func testRetiringInsideTheStillMomentReturnsToRestPromptlyInStandardMotion() async throws {
        let plan = try productionPlan()
        let retireAt = plan.delay * 1000 * 0.5
        let frames = try await run(hold: .planThenRetire(plan, retireAtMs: retireAt))

        var previous = try XCTUnwrap(frames.first).rendered
        for frame in frames {
            XCTAssertLessThanOrEqual(frame.rendered, previous + tolerance, "\(frame.ms) ms: retire moved away from rest")
            previous = frame.rendered
        }
        let settled = try XCTUnwrap(frames.first { $0.ms >= retireAt + 250 })
        XCTAssertEqual(settled.rendered, 0, accuracy: 0.5, "back at rest well before the pending delay would have ended")
        XCTAssertLessThan(settled.ms, plan.delay * 1000 + plan.duration * 1000,
                          "it did not wait out the delayed ease to return")
        XCTAssertEqual(try XCTUnwrap(frames.last).rendered, 0, accuracy: 0.5, "no stranded transform")
    }

    func testRetiringInsideTheStillMomentReturnsToRestPromptlyUnderReduceMotion() async throws {
        let plan = try productionPlan(reduceMotion: true)
        XCTAssertTrue(plan.isReduced)
        let retireAt = plan.delay * 1000 * 0.75
        let frames = try await run(hold: .planThenRetire(plan, retireAtMs: retireAt))

        var previous = try XCTUnwrap(frames.first).rendered
        for frame in frames {
            XCTAssertLessThanOrEqual(frame.rendered, previous + tolerance, "\(frame.ms) ms: retire moved away from rest")
            previous = frame.rendered
        }
        let settled = try XCTUnwrap(frames.first { $0.ms >= retireAt + 250 })
        XCTAssertEqual(settled.rendered, 0, accuracy: 0.5, "back at rest, not held at the lane for the rest of the delay")
        XCTAssertEqual(try XCTUnwrap(frames.last).rendered, 0, accuracy: 0.5, "no stranded transform")
    }

    func testReduceMotionHoldsASmallStaticLaneThenReturnsBrieflyWithoutAnyMoveAwayFromRest() async throws {
        let plan = try productionPlan(reduceMotion: true)
        XCTAssertTrue(plan.isReduced)
        let frames = try await run(hold: .plan(plan))

        // Native carries the content from the 60 pt lane down to the held lane;
        // from there the hold keeps it still (no sustained spatial drift)...
        var previous = try XCTUnwrap(frames.first).rendered
        for frame in frames {
            XCTAssertLessThanOrEqual(frame.rendered, previous + tolerance, "\(frame.ms) ms: moved away from rest")
            XCTAssertGreaterThanOrEqual(frame.rendered, -tolerance)
            previous = frame.rendered
        }
        let held = try XCTUnwrap(frames.first { $0.ms >= 400 })
        XCTAssertEqual(held.rendered, plan.holdStart(forDisplacement: laneHeight), accuracy: 1.5, "static while the check is shown")
        let held350 = try XCTUnwrap(frames.first { $0.ms >= 350 })
        XCTAssertEqual(held350.rendered, held.rendered, accuracy: 1.5, "no drift during the hold")
        // ...then returns briefly: one short return, not the standard sustained ease.
        let home = try XCTUnwrap(frames.first { $0.rendered < 0.5 })
        XCTAssertLessThan(home.ms, (plan.delay + plan.duration) * 1000 + 250)
        XCTAssertEqual(try XCTUnwrap(frames.last).rendered, 0, accuracy: 0.5)
    }

    // MARK: - Driving a real collapse

    private enum HoldMode {
        case none
        /// The production plan: its start displacement, curve, duration, and delay.
        case plan(HomeRefreshSettle.Plan)
        case planThenRetire(HomeRefreshSettle.Plan, retireAtMs: Double)
        /// Worst case for the handoff: the hold is armed in the very run-loop turn
        /// that ends the refresh (no settling frames in between), and the ease is
        /// started only after production's commit interval.
        case planArmedInTheSameTurnAsTheCollapse(HomeRefreshSettle.Plan)
    }

    private func productionPlan(reduceMotion: Bool = false) throws -> HomeRefreshSettle.Plan {
        try XCTUnwrap(HomeRefreshSettle.plan(
            reduceMotion: reduceMotion, isHomePresented: true, ownsBandHeader: true
        ))
    }

    /// Mounts the harness, puts the real refresh control in its held state with
    /// the lane open, arms the hold exactly as production does (un-animated, at
    /// the native displacement), ends the refresh so UIKit collapses the lane,
    /// and records the rendered displacement of the probe on every display frame.
    private func run(hold mode: HoldMode) async throws -> [Frame] {
        let model = MotionModel()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MotionHarness(model: model))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        settle(window)

        let scrollView = try XCTUnwrap(findScrollView(in: window))
        let refreshControl = try XCTUnwrap(scrollView.refreshControl, "SwiftUI installs a UIRefreshControl for .refreshable")
        let baseTop = scrollView.adjustedContentInset.top
        model.restMinY = window.safeAreaInsets.top + 80
        model.objectWillChange.send()
        settle(window)
        let rest = try XCTUnwrap(probeMinY(in: window), "probe layer not found")

        // The held refresh state: UIKit adds the control's height to the inset and
        // the content rests one lane below its normal position.
        refreshControl.beginRefreshing()
        scrollView.setContentOffset(CGPoint(x: 0, y: -(baseTop + refreshControl.frame.height)), animated: true)
        settle(window)
        let startDisplacement = try XCTUnwrap(probeMinY(in: window)) - rest
        XCTAssertEqual(startDisplacement, laneHeight, accuracy: 1.5, "the native lane is open before the refresh ends")

        switch mode {
        case .none:
            break
        case .planArmedInTheSameTurnAsTheCollapse:
            break
        case .plan(let plan), .planThenRetire(let plan, _):
            // Armed exactly as production does: un-animated, at the plan's start.
            var immediate = Transaction()
            immediate.disablesAnimations = true
            withTransaction(immediate) { model.hold = plan.holdStart(forDisplacement: laneHeight) }
            settle(window)
        }

        let recorder = FrameRecorder(window: window, rest: rest)
        let link = CADisplayLink(target: recorder, selector: #selector(FrameRecorder.tick))
        recorder.start = CACurrentMediaTime()
        link.add(to: .main, forMode: .common)

        if case .planArmedInTheSameTurnAsTheCollapse(let plan) = mode {
            var immediate = Transaction()
            immediate.disablesAnimations = true
            withTransaction(immediate) { model.hold = plan.holdStart(forDisplacement: laneHeight) }
        }
        refreshControl.endRefreshing()
        switch mode {
        case .none:
            break
        case .planArmedInTheSameTurnAsTheCollapse(let plan):
            RunLoop.main.run(until: Date().addingTimeInterval(
                Double(HomeRefreshSettle.commitInterval.components.attoseconds) / 1e18
            ))
            withAnimation(plan.animation) { model.hold = 0 }
        case .plan(let plan):
            withAnimation(plan.animation) { model.hold = 0 }
        case .planThenRetire(let plan, let retireAtMs):
            withAnimation(plan.animation) { model.hold = 0 }
            RunLoop.main.run(until: Date().addingTimeInterval(retireAtMs / 1000))
            // Production retires to the inert sentinel: the ease already targets 0, and
            // re-assigning an unchanged value would not retarget the running animation.
            withAnimation(.easeOut(duration: 0.1)) { model.hold = HomeRefreshSettle.retiredHold }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1.8))
        link.invalidate()

        return recorder.frames.map { Frame(ms: $0.ms, rendered: $0.rendered) }
    }

    @MainActor
    private final class FrameRecorder: NSObject {
        struct Sample { let ms: Double; let rendered: CGFloat }
        var frames: [Sample] = []
        var start: CFTimeInterval = 0
        let window: UIWindow
        let rest: CGFloat

        init(window: UIWindow, rest: CGFloat) {
            self.window = window
            self.rest = rest
        }

        @objc func tick() {
            guard let minY = HomeRefreshSettleHostedMotionTests.probeMinY(in: window) else { return }
            frames.append(Sample(ms: (CACurrentMediaTime() - start) * 1000, rendered: minY - rest))
        }
    }

    // MARK: - Reading the rendered position

    /// The probe is a solid red 100 pt band; SwiftUI renders it as a layer with a
    /// matching `backgroundColor`, whose *presentation* frame is what is on screen.
    static func probeMinY(in window: UIWindow) -> CGFloat? {
        func visit(_ layer: CALayer) -> CGFloat? {
            if let color = layer.backgroundColor, let components = color.components, components.count >= 3,
               abs(components[0] - 1) < 0.01, components[1] < 0.01, components[2] < 0.01,
               layer.bounds.height > 90, layer.bounds.height < 110 {
                let presentation = layer.presentation() ?? layer
                return presentation.convert(presentation.bounds, to: window.layer).minY
            }
            for sublayer in layer.sublayers ?? [] {
                if let found = visit(sublayer) { return found }
            }
            return nil
        }
        return visit(window.layer)
    }

    private func probeMinY(in window: UIWindow) -> CGFloat? {
        Self.probeMinY(in: window)
    }

    private func settle(_ window: UIWindow) {
        for _ in 0..<8 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            window.layoutIfNeeded()
        }
    }

    private func findScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView, scrollView.bounds.height > 100 { return scrollView }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) { return found }
        }
        return nil
    }
}
