//
//  RequestCreationContinuityHomeRevealTests.swift
//  CommonPlateiosTests
//
// Focused coverage for the W4-D2 physical-device FIX: the progressive Home
// reveal that makes an overlap between the travelling continuity card and an
// existing Home request card structurally impossible, the stable-measurement
// rule that keeps the travel one continuous motion, and the landing travel
// curve that replaced the micro-settle curve this travel had inherited.
//
// Scope honesty (`docs/testing.md`): this repository has no UI-test target, so
// these cases exercise the production policy and motion rules directly — the
// same pure functions and constants the views call — plus bounded source
// assertions for the wiring facts that have no non-UI seam. They prove the
// mechanism and the wiring. They do NOT prove rendered smoothness, rendered
// geometry, or the absence of a visible overlap on a device; that remains
// physical-device evidence and is still outstanding for this fix.
import CoreGraphics
import Foundation
import XCTest
@testable import CommonPlateios

final class RequestCreationContinuityHomeRevealTests: XCTestCase {

    // MARK: - Progressive Home reveal policy

    /// The central invariant of the fix: while a standard-motion continuity is
    /// presenting, Home holds back every card-bearing zone other than the
    /// travelling card's own destination slot.
    func testStandardMotionContinuityDefersHomeContentReveal() {
        XCTAssertTrue(
            HomeExchangeView.isDeferringContinuityHomeContent(
                hasLiveContinuity: true,
                reduceMotion: false
            )
        )
        XCTAssertEqual(
            HomeExchangeView.continuityDeferredContentOpacity(
                hasLiveContinuity: true,
                reduceMotion: false
            ),
            0
        )
    }

    /// With no continuity presenting, Home is exactly the ordinary Home —
    /// this policy must never suppress content outside the one presentation
    /// that owns it.
    func testNoContinuityLeavesHomeEntirelyUnaffected() {
        for reduceMotion in [false, true] {
            XCTAssertFalse(
                HomeExchangeView.isDeferringContinuityHomeContent(
                    hasLiveContinuity: false,
                    reduceMotion: reduceMotion
                ),
                "reduceMotion \(reduceMotion)"
            )
            XCTAssertEqual(
                HomeExchangeView.continuityDeferredContentOpacity(
                    hasLiveContinuity: false,
                    reduceMotion: reduceMotion
                ),
                1,
                "reduceMotion \(reduceMotion)"
            )
        }
    }

    /// Reduce Motion is physically verified as smooth and is deliberately left
    /// on its accepted composition: it performs only the bounded landing
    /// displacement, so its card never sweeps across the cards below it and
    /// there is no overlap for this policy to prevent.
    func testReduceMotionKeepsItsAcceptedFullHomeComposition() {
        XCTAssertFalse(
            HomeExchangeView.isDeferringContinuityHomeContent(
                hasLiveContinuity: true,
                reduceMotion: true
            )
        )
        XCTAssertEqual(
            HomeExchangeView.continuityDeferredContentOpacity(
                hasLiveContinuity: true,
                reduceMotion: true
            ),
            1
        )
    }

    /// The multi-existing-request case physical acceptance actually failed on:
    /// with three owned requests, the newly created card is carried by the
    /// overlay and every *other* owned card is invisible, so there is no
    /// frame in which the travelling card and another Home request card are
    /// both on screen.
    func testMultipleExistingOwnedCardsAreAllInvisibleWhileTheCardIsInFlight() {
        let createdRequestID = "req-new"
        let ownedRequestIDs = [createdRequestID, "req-older", "req-oldest"]

        let visibleOtherCards = ownedRequestIDs
            .filter { $0 != createdRequestID }
            .filter { _ in
                HomeExchangeView.continuityDeferredContentOpacity(
                    hasLiveContinuity: true,
                    reduceMotion: false
                ) > 0
            }

        XCTAssertTrue(
            visibleOtherCards.isEmpty,
            "no existing owned card may be visible while the continuity card is travelling"
        )
    }

    /// The reveal is opacity, never insertion or removal, and it completes
    /// after the accepted 1.6s Success dwell has already ended — so it cannot
    /// reflow Home, cannot move the measured destination, and cannot extend
    /// the dwell.
    func testHomeContentRevealIsBoundedAndOutsideTheAcceptedSuccessDwell() {
        XCTAssertGreaterThan(RequestCreationContinuityMotionPlan.homeContentRevealSeconds, 0)
        XCTAssertLessThanOrEqual(RequestCreationContinuityMotionPlan.homeContentRevealSeconds, 0.35)
        // The dwell itself is untouched by this fix.
        XCTAssertEqual(
            RequestCreationContinuityMotionPlan.standard.totalDuration,
            RequestCreationContinuityMotionPlan.successDwellDuration
        )
        XCTAssertEqual(
            RequestCreationContinuityMotionPlan.reducedMotion.totalDuration,
            RequestCreationContinuityMotionPlan.successDwellDuration
        )
    }

    /// The policy is actually wired to the zones that produced the overlap:
    /// `Continue helping`, the non-destination owned cards, `See all N`, the
    /// board heading, and the board itself — and the destination card opts out
    /// by request identity rather than by list position.
    func testHomeWiresTheProgressiveRevealToEveryCardBearingZone() throws {
        // Whitespace-normalized so these assert the wiring, not this file's
        // current line breaks.
        let source = Self.normalized(try homeSource())

        XCTAssertTrue(
            source.contains(
                "isDeferring: !isLandingContinuityCard(request) && isDeferringContinuityHomeContent"
            ),
            "the destination slot must opt out by identity, not by index"
        )

        // One per card-bearing zone: `Continue helping`, the non-destination
        // owned cards, `See all N`, the board heading row, and the board
        // section itself. The modifier's own declaration carries no `(`, so it
        // is not counted here.
        let deferredSites = source.components(separatedBy: "ContinuityDeferredReveal(").count - 1
        XCTAssertEqual(deferredSites, 5, "every card-bearing Home zone must apply the reveal")

        for zone in [
            "continueHelpingSection .modifier(ContinuityDeferredReveal(",
            "boardHeadingRow .modifier(ContinuityDeferredReveal("
        ] {
            XCTAssertTrue(source.contains(zone), "expected \(zone)")
        }

        // Opacity, never conditional presence: the layout — and therefore the
        // published first-slot geometry — must be identical throughout.
        XCTAssertTrue(source.contains("content .opacity(isDeferring ? 0 : 1)"))
        // And the destination slot keeps its own existing continuity opacity
        // rule, unchanged by this fix.
        XCTAssertTrue(source.contains(".opacity(landingContinuityCardOpacity(request))"))
    }

    private static func normalized(_ source: String) -> String {
        source
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Stable measurement during the landing

    private typealias Layout = RequestCreationContinuityLayout
    private typealias Capture = RequestCreationContinuityLayout.EndpointCapture

    private static let container = CGSize(width: 390, height: 844)
    private static let settledCard = CGRect(x: 24, y: 309, width: 342, height: 121)
    private static let homeSlot = CGRect(x: 24, y: 164, width: 342, height: 121)
    /// Frames Home might publish *after* the landing commit — its own
    /// re-appearance fetch resolving, a relayout, a board arriving.
    private static let laterLiveHomeSlots: [CGRect?] = [
        CGRect(x: 24, y: 164, width: 342, height: 121),
        CGRect(x: 24, y: 402, width: 342, height: 103),
        CGRect(x: 20, y: 220, width: 350, height: 140),
        nil
    ]

    /// What the continuity view derives on one frame, composed from exactly
    /// the production functions `RequestCreationContinuityView.card(...)`,
    /// `cardOffset`, and `cardOpacity` call, in the same order.
    private struct LandingFrame: Equatable {
        let translation: CGSize
        let overlayVisible: Bool
        let homeCardRevealed: Bool
        let cardWidth: CGFloat
    }

    private func landingFrame(
        phase: RequestCreationContinuityView.Phase = .landing,
        reduceMotion: Bool,
        liveHomeSlot: CGRect?,
        homeSlotCapture: Capture,
        liveSettledCard: CGRect? = RequestCreationContinuityHomeRevealTests.settledCard,
        settledCardCapture: Capture = .captured(RequestCreationContinuityHomeRevealTests.settledCard)
    ) -> LandingFrame {
        let measuredHomeSlot = Layout.stableFrame(phase: phase, live: liveHomeSlot, capture: homeSlotCapture)
        let landingSlot = Layout.landingSlot(homeSlot: measuredHomeSlot, containerFrame: CGRect(origin: .zero, size: Self.container))
        let settled = Layout.stableFrame(phase: phase, live: liveSettledCard, capture: settledCardCapture)
        let translation = reduceMotion
            ? Layout.reducedMotionLandingTranslation(from: settled, to: landingSlot)
            : Layout.landingTranslation(from: settled, to: landingSlot)
        return LandingFrame(
            translation: translation,
            overlayVisible: Layout.isOverlayCardVisible(
                phase: phase,
                reduceMotion: reduceMotion,
                hasLandingDestination: landingSlot != nil
            ),
            homeCardRevealed: Layout.isHomeCardRevealed(
                phase: phase,
                reduceMotion: reduceMotion,
                hasLandingDestination: landingSlot != nil
            ),
            cardWidth: Layout.cardWidth(containerWidth: Self.container.width, homeSlot: measuredHomeSlot)
        )
    }

    /// Before the landing, the presentation always reads Home's live
    /// measurement, so the destination is the real current slot — whatever
    /// the capture state.
    func testMeasurementIsLiveUntilTheLandingBegins() {
        let live = CGRect(x: 24, y: 164, width: 342, height: 121)
        let captured = CGRect(x: 24, y: 900, width: 342, height: 121)

        for phase: RequestCreationContinuityView.Phase in [.entering, .settled] {
            for capture: Capture in [.pending, .captured(captured), .captured(nil)] {
                XCTAssertEqual(
                    Layout.stableFrame(phase: phase, live: live, capture: capture),
                    live,
                    "\(phase) \(capture)"
                )
                XCTAssertNil(
                    Layout.stableFrame(phase: phase, live: nil, capture: capture),
                    "\(phase) \(capture)"
                )
            }
        }
    }

    /// Pre-landing, live geometry keeps updating normally: an uncommitted
    /// capture follows every newly published Home frame.
    func testPreLandingGeometryKeepsUpdatingUntilTheCommit() {
        var capture: Capture = .pending
        var live: CGRect? = nil
        for next in [nil, Self.homeSlot, CGRect(x: 24, y: 402, width: 342, height: 103)] as [CGRect?] {
            live = next
            XCTAssertEqual(Layout.stableFrame(phase: .settled, live: live, capture: capture), next)
        }
        XCTAssertEqual(capture, .pending, "reading live geometry must never commit a capture")

        capture.commit(live)
        XCTAssertEqual(capture, .captured(CGRect(x: 24, y: 402, width: 342, height: 103)))
    }

    /// Once the landing is committed, the captured measurement wins — a Home
    /// relayout arriving mid-flight (its own re-appearance fetch resolving, on
    /// a device, inside this exact window) can no longer silently retarget a
    /// motion that is already running.
    func testCommittedLandingIgnoresALaterRepublishedHomeFrame() {
        let committed = CGRect(x: 24, y: 164, width: 342, height: 121)
        let republishedMidFlight = CGRect(x: 24, y: 402, width: 342, height: 103)

        XCTAssertEqual(
            Layout.stableFrame(
                phase: .landing,
                live: republishedMidFlight,
                capture: .captured(committed)
            ),
            committed
        )
    }

    /// W4-D2 rereview FIX (reverses the prior expectation, which codified the
    /// defect): a landing reads only its capture. "Captured, and there was no
    /// frame" stays `nil` even when live geometry later exists, and a landing
    /// with nothing captured has no endpoint rather than reacquiring one live.
    /// Neither case invents a measurement, and neither produces travel.
    func testCaptureNeverInventsAMeasurement() {
        let live = CGRect(x: 24, y: 164, width: 342, height: 121)

        XCTAssertNil(Layout.stableFrame(phase: .landing, live: live, capture: .captured(nil)))
        XCTAssertNil(Layout.stableFrame(phase: .landing, live: live, capture: .pending))
        XCTAssertNil(Layout.stableFrame(phase: .landing, live: nil, capture: .captured(nil)))
        XCTAssertEqual(
            Layout.landingTranslation(
                from: Self.settledCard,
                to: Layout.stableFrame(phase: .landing, live: live, capture: .captured(nil))
            ),
            .zero
        )
    }

    /// The commit is exactly once, including a `nil` result: a second commit
    /// in the same presentation cannot replace either kind of capture.
    func testCommitCapturesExactlyOnceIncludingAMissingEndpoint() {
        var missing: Capture = .pending
        missing.commit(nil)
        missing.commit(Self.homeSlot)
        XCTAssertEqual(missing, .captured(nil))
        XCTAssertNotEqual(missing, .pending, "captured-nil must differ from not-yet-captured")

        var measured: Capture = .pending
        measured.commit(Self.homeSlot)
        measured.commit(CGRect(x: 24, y: 402, width: 342, height: 103))
        measured.commit(nil)
        XCTAssertEqual(measured, .captured(Self.homeSlot))
    }

    /// (1) Captured-nil Home target, later non-nil live target: still no
    /// destination for the whole landing — zero translation, and the
    /// in-place crossfade (W4-D2 final geometry-fallback card handoff), never
    /// a switch into travel.
    func testCapturedMissingHomeSlotStaysMissingWhenHomeLaterPublishes() {
        for reduceMotion in [false, true] {
            for later in Self.laterLiveHomeSlots {
                XCTAssertNil(Layout.stableFrame(phase: .landing, live: later, capture: .captured(nil)))
                let frame = landingFrame(
                    reduceMotion: reduceMotion,
                    liveHomeSlot: later,
                    homeSlotCapture: .captured(nil)
                )
                XCTAssertEqual(frame.translation, .zero, "reduceMotion \(reduceMotion) later \(String(describing: later))")
                XCTAssertTrue(frame.homeCardRevealed, "reduceMotion \(reduceMotion) later \(String(describing: later))")
                XCTAssertFalse(frame.overlayVisible, "reduceMotion \(reduceMotion) later \(String(describing: later))")
            }
        }
    }

    /// (2) Captured valid Home target, later different live target: the
    /// original capture remains the destination.
    func testCapturedHomeSlotRemainsTheDestinationWhenHomeLaterRelayouts() {
        let expected = CGSize(
            width: Self.homeSlot.minX - Self.settledCard.minX,
            height: Self.homeSlot.minY - Self.settledCard.minY
        )
        for later in Self.laterLiveHomeSlots {
            XCTAssertEqual(
                Layout.stableFrame(phase: .landing, live: later, capture: .captured(Self.homeSlot)),
                Self.homeSlot
            )
            let frame = landingFrame(
                reduceMotion: false,
                liveHomeSlot: later,
                homeSlotCapture: .captured(Self.homeSlot)
            )
            XCTAssertEqual(frame.translation, expected, "later \(String(describing: later))")
            XCTAssertEqual(frame.cardWidth, Self.homeSlot.width, "later \(String(describing: later))")
        }
    }

    /// (3) Captured-nil settled-card frame, later non-nil live frame: the
    /// settled endpoint remains missing for that landing, so no travel is
    /// computed from a reacquired origin.
    func testCapturedMissingSettledCardStaysMissingWhenLaterMeasured() {
        XCTAssertNil(Layout.stableFrame(phase: .landing, live: Self.settledCard, capture: .captured(nil)))
        for reduceMotion in [false, true] {
            let frame = landingFrame(
                reduceMotion: reduceMotion,
                liveHomeSlot: Self.homeSlot,
                homeSlotCapture: .captured(Self.homeSlot),
                liveSettledCard: Self.settledCard,
                settledCardCapture: .captured(nil)
            )
            XCTAssertEqual(frame.translation, .zero, "reduceMotion \(reduceMotion)")
        }
    }

    /// (5) A new presentation starts from `.pending` and captures its own
    /// real geometry normally, independent of a prior presentation's
    /// captured-nil. The production reset is view identity: the capture
    /// state is per-view `@State` initialized `.pending`, and the call site
    /// keys the view to the continuity's identity.
    func testNextPresentationCapturesItsOwnGeometry() throws {
        var previous: Capture = .pending
        previous.commit(nil)
        XCTAssertEqual(previous, .captured(nil))

        var next: Capture = .pending
        XCTAssertNil(Layout.stableFrame(phase: .landing, live: Self.homeSlot, capture: next))
        next.commit(Self.homeSlot)
        XCTAssertEqual(Layout.stableFrame(phase: .landing, live: nil, capture: next), Self.homeSlot)

        let source = Self.normalized(try continuitySource())
        XCTAssertTrue(source.contains(
            "@State private var settledCardCapture: RequestCreationContinuityLayout.EndpointCapture = .pending"
        ))
        XCTAssertTrue(source.contains(
            "@State private var homeSlotCapture: RequestCreationContinuityLayout.EndpointCapture = .pending"
        ))
        let contentView = Self.normalized(try String(
            contentsOf: repositoryFile("ios/CommonPlateios/CommonPlateios/ContentView.swift"),
            encoding: .utf8
        ))
        XCTAssertTrue(contentView.contains(
            "onFinished: { id in _ = guidanceLedger.recordGuidanceShown("
        ))
        XCTAssertTrue(contentView.contains(
            "ownerPhase: requestStore.ownerRequests.first { $0.id == continuity.request.id }?.phase, isFirstRequest: guidanceLedger.showsGuidance("
        ))
        XCTAssertTrue(contentView.contains(
            "currentAuthority: participantIdentityStore.currentAuthority()"
        ))
    }

    /// (6) Reduce Motion: a captured-nil destination remains the in-place
    /// crossfade fallback on every frame of the landing — later live geometry
    /// cannot switch it into bounded travel.
    func testReduceMotionCapturedMissingTargetNeverSwitchesIntoBoundedTravel() {
        let atCommit = landingFrame(reduceMotion: true, liveHomeSlot: nil, homeSlotCapture: .captured(nil))
        XCTAssertEqual(atCommit.translation, .zero)
        XCTAssertFalse(atCommit.overlayVisible)
        XCTAssertTrue(atCommit.homeCardRevealed)

        for later in Self.laterLiveHomeSlots {
            XCTAssertEqual(
                landingFrame(reduceMotion: true, liveHomeSlot: later, homeSlotCapture: .captured(nil)),
                atCommit,
                "later \(String(describing: later))"
            )
        }

        // The valid-target branch itself is unchanged: 24pt-capped measured
        // direction plus the crossfade handoff.
        let valid = landingFrame(
            reduceMotion: true,
            liveHomeSlot: CGRect(x: 24, y: 402, width: 342, height: 103),
            homeSlotCapture: .captured(Self.homeSlot)
        )
        XCTAssertEqual(
            (valid.translation.width * valid.translation.width
                + valid.translation.height * valid.translation.height).squareRoot(),
            Layout.reducedMotionMaximumLandingDisplacement,
            accuracy: 0.0001
        )
        XCTAssertLessThan(valid.translation.height, 0)
        XCTAssertFalse(valid.overlayVisible)
        XCTAssertTrue(valid.homeCardRevealed)
    }

    /// (7) Standard motion: a captured-nil destination remains the in-place
    /// crossfade fallback — no travel begins mid-phase, the handoff does not
    /// flip back, and the card's width does not change to a later-published
    /// slot's width.
    func testStandardMotionCapturedMissingTargetNeverBeginsTravelMidPhase() {
        let atCommit = landingFrame(reduceMotion: false, liveHomeSlot: nil, homeSlotCapture: .captured(nil))
        XCTAssertEqual(atCommit.translation, .zero)
        XCTAssertFalse(atCommit.overlayVisible)
        XCTAssertTrue(atCommit.homeCardRevealed)
        XCTAssertEqual(atCommit.cardWidth, HomeExchangeView.contentCardWidth(containerWidth: Self.container.width))

        for later in Self.laterLiveHomeSlots {
            XCTAssertEqual(
                landingFrame(reduceMotion: false, liveHomeSlot: later, homeSlotCapture: .captured(nil)),
                atCommit,
                "later \(String(describing: later))"
            )
        }
    }

    /// The off-screen validity rule still applies to a captured frame: a slot
    /// captured outside the presentation's bounds is no usable destination,
    /// and a later on-screen live slot does not rescue it into travel.
    func testCapturedOffScreenSlotRemainsTheFallback() {
        let offScreen = CGRect(x: 24, y: 900, width: 342, height: 121)
        for reduceMotion in [false, true] {
            let frame = landingFrame(
                reduceMotion: reduceMotion,
                liveHomeSlot: Self.homeSlot,
                homeSlotCapture: .captured(offScreen)
            )
            XCTAssertEqual(frame.translation, .zero, "reduceMotion \(reduceMotion)")
            XCTAssertFalse(frame.overlayVisible, "reduceMotion \(reduceMotion)")
            XCTAssertTrue(frame.homeCardRevealed, "reduceMotion \(reduceMotion)")
        }
    }

    /// The view commits both endpoints through the one-time capture and feeds
    /// the landing only from it — the `frozen ?? live` shape cannot return.
    func testViewCommitsBothEndpointsThroughTheOneTimeCapture() throws {
        let source = Self.normalized(try continuitySource())
        XCTAssertTrue(source.contains("settledCardCapture.commit(settledCardFrame)"))
        // W4-D2 physical-device FIX: the landing commit reads the mirrored
        // `latestHomeSlotFrame` — the value actually current on this render —
        // never the `homeSlotFrame` parameter directly, which a long-running
        // `.task` would otherwise read stale from whichever render started it.
        XCTAssertTrue(source.contains("homeSlotCapture.commit(latestHomeSlotFrame)"))
        XCTAssertFalse(source.contains("homeSlotCapture.commit(homeSlotFrame)"))
        XCTAssertTrue(source.contains("live: latestHomeSlotFrame, capture: homeSlotCapture"))
        XCTAssertTrue(source.contains("live: settledCardFrame, capture: settledCardCapture"))
        XCTAssertFalse(source.contains("frozen ?? live"))
        // The mirror itself is kept current for the whole presentation,
        // including the value already delivered before this view's first
        // render.
        XCTAssertTrue(source.contains(
            ".onChange(of: homeSlotFrame, initial: true) { _, newValue in latestHomeSlotFrame = newValue }"
        ))
    }

    // MARK: - Standard-motion travel curve

    /// The sticky/stalling read physical acceptance found, expressed as a
    /// checkable property. The micro-settle curve this travel had inherited
    /// (`0.22, 0.78, 0.24, 1`) delivers ~79% of the distance in the first 30%
    /// of the duration and then crawls; the landing curve must distribute the
    /// travel across the landing instead.
    func testLandingTravelIsNotFrontLoadedIntoACrawl() {
        let atThirty = RequestCreationContinuityLayout.landingTravelProgress(atDurationFraction: 0.3)
        let atFifty = RequestCreationContinuityLayout.landingTravelProgress(atDurationFraction: 0.5)

        XCTAssertLessThan(
            atThirty,
            0.6,
            "the travel must not dump most of its distance into its opening frames"
        )
        XCTAssertLessThan(atFifty, 0.85)
        // And it must still be decelerating into the slot, not linear or
        // accelerating: half the duration carries more than half the distance.
        XCTAssertGreaterThan(atFifty, 0.5)
    }

    /// The curve still starts at rest and arrives exactly on the slot at the
    /// end of the landing phase, so the handoff to Home's real card at
    /// retirement remains position-exact.
    func testLandingTravelStartsAtRestAndArrivesExactlyOnTheSlot() {
        XCTAssertEqual(
            RequestCreationContinuityLayout.landingTravelProgress(atDurationFraction: 0),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RequestCreationContinuityLayout.landingTravelProgress(atDurationFraction: 1),
            1,
            accuracy: 0.0001
        )
        // Essentially arrived well before the phase ends, so the swap cannot
        // catch the card short of its destination.
        XCTAssertGreaterThan(
            RequestCreationContinuityLayout.landingTravelProgress(atDurationFraction: 0.92),
            0.99
        )
    }

    /// Progress is monotonic — the card never reverses or hesitates within the
    /// travel itself.
    func testLandingTravelProgressIsMonotonic() {
        var previous = -1.0
        for step in 0...100 {
            let progress = RequestCreationContinuityLayout.landingTravelProgress(
                atDurationFraction: Double(step) / 100
            )
            XCTAssertGreaterThanOrEqual(progress, previous, "step \(step)")
            previous = progress
        }
    }

    /// The rendered animation is built from the same control points this
    /// contract is proved against, and from the plan's own duration — so the
    /// proof above cannot drift away from what actually runs, and the old
    /// micro-settle curve cannot quietly return.
    func testRenderedLandingAnimationIsBuiltFromTheProvenCurve() throws {
        let source = try continuitySource()

        XCTAssertTrue(
            source.contains(
                ".timingCurve(curve.x1, curve.y1, curve.x2, curve.y2, duration: plan.landingSeconds)"
            )
        )
        XCTAssertFalse(
            source.contains(".timingCurve(0.22, 0.78, 0.24, 1"),
            "the micro-settle curve must not drive this travel again"
        )
    }

    /// Home is genuinely present behind the last, slowest part of the travel
    /// rather than still fading for the whole landing — and this costs no
    /// additional time, being a fraction of the existing landing duration.
    func testHomeRevealCompletesBeforeTheTravelDoesWithoutExtendingIt() {
        let plan = RequestCreationContinuityMotionPlan.standard

        XCTAssertLessThan(plan.chromeRevealSeconds, plan.landingSeconds)
        XCTAssertGreaterThan(plan.chromeRevealSeconds, 0)
        XCTAssertEqual(plan.totalDuration, RequestCreationContinuityMotionPlan.successDwellDuration)
    }

    // MARK: - Helpers

    private func continuitySource() throws -> String {
        try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestCreationContinuityView.swift"
            ),
            encoding: .utf8
        )
    }

    private func homeSource() throws -> String {
        try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift"
            ),
            encoding: .utf8
        )
    }

    /// Matching `RequestCreationContinuityLandingTests`' own resolution.
    private func repositoryFile(_ relativePath: String) -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CommonPlateiosTests
            .deletingLastPathComponent() // CommonPlateios
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repository root
        let url = root.appendingPathComponent(relativePath)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "expected \(relativePath) at \(url.path)"
        )
        return url
    }
}
