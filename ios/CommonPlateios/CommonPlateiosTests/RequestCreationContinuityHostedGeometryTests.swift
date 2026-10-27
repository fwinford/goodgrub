//
//  RequestCreationContinuityHostedGeometryTests.swift
//  CommonPlateiosTests
//
// W4-D2 hosted regression coverage for the two proven physical-device
// geometry defects:
//
// 1. The named coordinate space `RequestCreationContinuityLayout` used to
//    declare did not resolve across `NavigationStack`'s own hosting
//    boundary — Home's published slot and the continuity overlay's own card
//    were being measured in two different origins and then subtracted,
//    landing the card ~62pt (the simulator's safe-area top inset) below
//    Home's real slot on the diagnosis device. The fix measures both in
//    `.global` instead, which — unlike a name declared above the boundary —
//    is anchored to the window and resolves identically on both sides of it.
// 2. `homeSlotCapture.commit(homeSlotFrame)` ran inside a long-running
//    `.task` that read a plain `let` parameter — captured once, at whichever
//    render started the task — rather than the latest value actually
//    delivered to this presentation before the commit. The fix mirrors the
//    parameter into `@State` (`latestHomeSlotFrame`) and commits that
//    instead.
//
// This supersedes the temporary, assertion-free
// `D2DiagnosticCoordinateSpaceProbeTests` diagnosis probe (deleted). These
// mount the real production `RequestCreationContinuityView`,
// `HomeOwnedRequestSlotFrameKey` wiring, and a real `NavigationStack`-hosted
// Home slot in a UIWindow with the simulator's own non-zero safe area, then
// read the actually-drawn pixels — not a reconstructed value — for where the
// continuity card ends up, matching this repository's only available
// hosted-proof technique (`docs/testing.md`: no UI-test target).
//
// Scope honesty: this proves rendered end-state geometry against Home's real
// slot for the scenarios below. It does not replace physical-device
// verification of smoothness or the absence of a visible jump mid-travel.
import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

final class RequestCreationContinuityHostedGeometryTests: XCTestCase {

    // MARK: - Mounting

    @MainActor
    private func mount<V: View>(_ view: V) throws -> UIWindow {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        for _ in 0..<10 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            window.layoutIfNeeded()
        }
        return window
    }

    private func makeContinuity(id: String, resource: RequestResource = .unspecified) -> RequestCreationContinuity {
        let request = FoodRequest(
            id: id,
            diningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            foodDescription: "Rice bowl",
            pickupWindowText: "ASAP",
            mealSwipes: 1,
            resource: resource,
            windowStart: nil,
            windowEnd: nil,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            status: .open,
            ownership: .own
        )
        return RequestCreationContinuity(operationId: "op-\(id)", participantAuthority: "a", request: request)
    }

    /// Rendered (post-transform) vertical extent of any drawn content in the
    /// card column, in window (= `.global`) points. The Home slot's own card
    /// is opacity 0 and the spacer is clear, so once the base canvas has
    /// faded the only drawn content in this column is the overlay card —
    /// matching the technique the W4-D2 diagnosis used to prove the original
    /// defect.
    private func renderedCardRows(_ window: UIWindow) -> ClosedRange<CGFloat>? {
        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return nil }
        let scale = image.scale
        let bpr = cg.bytesPerRow
        func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let o = y * bpr + x * 4
            return (Int(ptr[o]), Int(ptr[o + 1]), Int(ptr[o + 2]))
        }
        let ref = px(Int(5 * scale), Int(120 * scale))
        var minRow: Int?
        var maxRow: Int?
        for y in 0..<cg.height {
            var hit = false
            var x = Int(40 * scale)
            while x < Int(360 * scale) {
                let p = px(x, y)
                if abs(p.0 - ref.0) + abs(p.1 - ref.1) + abs(p.2 - ref.2) > 24 { hit = true; break }
                x += 2
            }
            if hit { minRow = minRow ?? y; maxRow = y }
        }
        guard let minRow, let maxRow else { return nil }
        return (CGFloat(minRow) / scale)...(CGFloat(maxRow) / scale)
    }

    /// Runs `root` until `settleDwell` (1100ms) + `landingDuration` (500ms)
    /// plus margin have elapsed, then returns the rendered card rows.
    @MainActor
    private func runToLanded(_ root: some View) throws -> (window: UIWindow, homeSlot: CGRect?, landedRows: ClosedRange<CGFloat>?) {
        let recorder = HostedSlotRecorder()
        let window = try mount(RootWithRecorder(recorder: recorder) { root })
        RunLoop.main.run(until: Date().addingTimeInterval(1.9))
        return (window, recorder.homeSlotGlobalFrame, renderedCardRows(window))
    }

    // MARK: - (1) NavigationStack + safe-area endpoint

    /// The core coordinate-system proof: mounted with the simulator's real,
    /// non-zero safe-area top inset, Home's slot inside `NavigationStack` and
    /// the continuity overlay's own card — a sibling of it — must resolve to
    /// the SAME real rendered position once the landing completes. Before the
    /// `.global` fix this failed by approximately the safe-area inset (proven
    /// at 62pt on the diagnosis device); this must now hold within a small
    /// rendering tolerance.
    @MainActor
    func testOverlayLandsExactlyOnHomeSlotAcrossTheNavigationStackBoundary() throws {
        let continuity = makeContinuity(id: "safe-area")
        let root = ProbeScenario(continuity: continuity, spacerBefore: 120, spacerAfter: 120, spacerChangeAt: nil, overlayDelay: 0)
        let (window, homeSlot, landedRows) = try runToLanded(root)

        XCTAssertGreaterThan(
            window.safeAreaInsets.top,
            0,
            "this proof only demonstrates the fix while a real non-zero safe area is present"
        )
        let slot = try XCTUnwrap(homeSlot)
        let landed = try XCTUnwrap(landedRows)

        XCTAssertEqual(landed.lowerBound, slot.minY, accuracy: 2)
        window.isHidden = true
    }

    @MainActor
    func testRefinedCardMatchesTheWholeLandingSlotWithAndWithoutOwnerStatus() throws {
        let resource = RequestResource(
            menuPath: .mealExchange,
            mealItems: [MealItem(name: String(repeating: "Verbatim wrap ", count: 20), details: "Not shown on Home")],
            orderDetails: nil, estimatedDiningDollarsCents: 250
        )
        let phases: [OwnerRequestPhase?] = [nil, .available, .reserved]
        for phase in phases {
            let continuity = makeContinuity(id: "refined-\(String(describing: phase))", resource: resource)
            let root = ProbeScenario(
                continuity: continuity, spacerBefore: 120, spacerAfter: 120,
                spacerChangeAt: nil, overlayDelay: 0, ownerPhase: phase
            )
            let (window, slot, rows) = try runToLanded(root)
            defer { window.isHidden = true }
            let target = try XCTUnwrap(slot)
            let rendered = try XCTUnwrap(rows)
            XCTAssertEqual(rendered.lowerBound, target.minY, accuracy: 2)
            XCTAssertEqual(rendered.upperBound, target.maxY, accuracy: 2)
        }
    }

    // MARK: - (2) Commit-time live target

    /// Home publishes slot A, then — before the landing commit at
    /// `settleDwell` (1100ms) — republishes a moved slot B. The committed
    /// landing must target B, the latest value actually delivered before
    /// commit, not A, the value current when the overlay first mounted.
    @MainActor
    func testLandingUsesTheLatestHomeSlotPublishedBeforeCommit() throws {
        let continuity = makeContinuity(id: "live-retarget")
        let root = ProbeScenario(continuity: continuity, spacerBefore: 40, spacerAfter: 260, spacerChangeAt: 0.4, overlayDelay: 0)
        let (window, homeSlot, landedRows) = try runToLanded(root)

        let slotB = try XCTUnwrap(homeSlot)
        let landed = try XCTUnwrap(landedRows)

        XCTAssertEqual(landed.lowerBound, slotB.minY, accuracy: 2)
        window.isHidden = true
    }

    // MARK: - (3) Initial nil, valid before commit

    /// Home publishes no slot at all when the overlay first mounts (the board
    /// has not resolved yet), then a real slot arrives before the landing
    /// commit. The commit must select the measured-travel branch — landing on
    /// that slot — rather than staying on the no-target fallback because of
    /// the stale initial `nil`.
    @MainActor
    func testInitialNilHomeSlotBecomingValidBeforeCommitSelectsMeasuredTravel() throws {
        let continuity = makeContinuity(id: "initial-nil")
        let root = ProbeScenario(
            continuity: continuity,
            spacerBefore: 40,
            spacerAfter: 40,
            spacerChangeAt: nil,
            overlayDelay: 0,
            homeSlotAppearsAt: 0.4
        )
        let (window, homeSlot, landedRows) = try runToLanded(root)

        let slot = try XCTUnwrap(homeSlot, "the slot must have arrived and been measured before commit")
        let landed = try XCTUnwrap(landedRows)

        // Measured travel: the card actually reaches the real slot, not the
        // in-place fallback (which would leave it well above, at its settled
        // entrance position).
        XCTAssertEqual(landed.lowerBound, slot.minY, accuracy: 2)
        window.isHidden = true
    }

    // MARK: - (5) Off-screen target remains the fallback

    /// A captured Home slot outside the presentation's real bounds is no
    /// usable destination: the card stays exactly where it settled (zero
    /// travel), never flying off the edge of the screen.
    @MainActor
    func testOffScreenCapturedSlotRemainsTheNoTravelFallback() throws {
        let continuity = makeContinuity(id: "off-screen")
        // A spacer large enough that the slot lands off the bottom of the
        // window, well outside the presentation's own bounds.
        let root = ProbeScenario(continuity: continuity, spacerBefore: 4000, spacerAfter: 4000, spacerChangeAt: nil, overlayDelay: 0)

        let recorder = HostedSlotRecorder()
        // `mount()` already pumps ~1.0s of run loop time while bringing the
        // hierarchy up — enough for the entrance spring to have settled, but
        // still short of the 1100ms landing commit — so the settled position
        // is sampled the instant it returns, with no further wait added
        // before it (adding one here previously pushed the sample past
        // commit, into the crossfade fade-out, and made this flaky-nil).
        let window = try mount(RootWithRecorder(recorder: recorder) { root })
        let settled = try XCTUnwrap(renderedCardRows(window))

        // The commit lands ~100ms later; sample shortly after, while the
        // no-target crossfade's fade-out (500ms) is only just under way and
        // the card is still well within detection contrast. Home's own real
        // card is scrolled far off the window in this scenario — by the time
        // the crossfade actually finishes there is nothing left anywhere in
        // the window to detect, which is the correct outcome (an off-screen
        // destination is never travelled to) but makes a *post*-crossfade
        // sample unusable as a positional proof; this samples the position
        // itself, not the completed handoff.
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let landing = try XCTUnwrap(renderedCardRows(window))

        XCTAssertEqual(landing.lowerBound, settled.lowerBound, accuracy: 2)
        window.isHidden = true
    }
}

// MARK: - Harness

/// Records the real production `HomeOwnedRequestSlotFrameKey` publication —
/// the same value `ContentView` relays into `RequestCreationContinuityView`
/// — so tests can compare it against the actually-rendered card position.
private final class HostedSlotRecorder {
    var homeSlotGlobalFrame: CGRect?
}

/// Relays `HomeOwnedRequestSlotFrameKey` into `recorder`, matching
/// `ContentView`'s own relay, so `content` only has to publish the
/// preference like `HomeExchangeView` does.
private struct RootWithRecorder<Content: View>: View {
    let recorder: HostedSlotRecorder
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .onPreferenceChange(HomeOwnedRequestSlotFrameKey.self) { frame in
                recorder.homeSlotGlobalFrame = frame
            }
    }
}

/// A `NavigationStack`-hosted Home slot (publishing
/// `HomeOwnedRequestSlotFrameKey` exactly as `HomeExchangeView.
/// firstOwnedSlotFrameReporter` does) alongside the real
/// `RequestCreationContinuityView` overlay, composed as siblings exactly like
/// `ContentView` composes them. A controllable spacer stands in for Home's
/// scroll position, and the slot's own appearance can be delayed, so each
/// hosted scenario is driven from its own parameters rather than a new type.
private struct ProbeScenario: View {
    let continuity: RequestCreationContinuity
    var spacerBefore: CGFloat = 120
    var spacerAfter: CGFloat = 120
    /// Seconds after mount at which the spacer changes from `spacerBefore` to
    /// `spacerAfter`. `nil` means it never changes.
    var spacerChangeAt: Double?
    /// Seconds after mount before the overlay itself is mounted. `0` mounts
    /// it immediately, alongside Home.
    var overlayDelay: Double = 0
    /// Seconds after mount at which the Home slot first appears at all.
    /// `nil` means it is present (and publishing) from the start.
    var homeSlotAppearsAt: Double?
    var ownerPhase: OwnerRequestPhase? = nil

    @State private var homeSlot: CGRect?
    @State private var showOverlay = false
    @State private var spacer: CGFloat?
    @State private var isSlotShown = false
    /// Mirrors `HomeExchangeView`'s own real crossfade wiring
    /// (`isRevealingLandingContinuityCard`), relayed here exactly as
    /// `ContentView` relays it, so Home's slot card only becomes visible when
    /// production would actually reveal it (Reduce Motion or the no-target
    /// in-place crossfade) — never hardcoded invisible, which would make the
    /// no-target fallback's own crossfade unobservable.
    @State private var isRevealingLandingContinuityCard = false

    var body: some View {
        ZStack {
            NavigationStack {
                GeometryReader { _ in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Color.clear.frame(height: spacer ?? spacerBefore)
                            if homeSlotAppearsAt == nil || isSlotShown {
                                RequestCardView(
                                    request: continuity.request,
                                    kind: .own,
                                    showsOwnershipEyebrow: false,
                                    ownerPhase: ownerPhase,
                                    isHomePresentation: true
                                )
                                .opacity(HomeExchangeView.landingContinuityCardOpacity(
                                    isContinuityCard: true,
                                    isRevealing: isRevealingLandingContinuityCard
                                ))
                                .background(
                                    GeometryReader { proxy in
                                        Color.clear.preference(
                                            key: HomeOwnedRequestSlotFrameKey.self,
                                            value: proxy.frame(in: .global)
                                        )
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, CommonPlateStyle.Metrics.homeContentColumnInset)
                    }
                }
            }
            if showOverlay || overlayDelay == 0 {
                RequestCreationContinuityView(
                    continuity: continuity,
                    homeSlotFrame: homeSlot,
                    reduceMotion: false,
                    onFinished: { _ in },
                    ownerPhase: ownerPhase
                )
                .zIndex(3)
            }
        }
        .task {
            if overlayDelay > 0 {
                try? await Task.sleep(for: .seconds(overlayDelay))
                showOverlay = true
            }
            if let spacerChangeAt {
                try? await Task.sleep(for: .seconds(max(0, spacerChangeAt - overlayDelay)))
                spacer = spacerAfter
            }
        }
        .task {
            guard let homeSlotAppearsAt else { return }
            try? await Task.sleep(for: .seconds(homeSlotAppearsAt))
            isSlotShown = true
        }
        .onPreferenceChange(HomeOwnedRequestSlotFrameKey.self) { frame in
            homeSlot = frame
        }
        .onPreferenceChange(RequestCreationContinuityHandoffKey.self) { isRevealing in
            isRevealingLandingContinuityCard = isRevealing
        }
    }
}
