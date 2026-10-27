//
//  RequestCreationContinuityView.swift
//  CommonPlateios
//
// W4-D2 Success → Home continuity (approved canonical Figma
// `o5VXC3QZWs4w9tQ8drVRC4`, `REQUESTER · 2 Submit and confirm`, primary node
// `577:3799`; Success continuity stack `683:2826`, Success request card
// `683:2827`, Home-reveal / card-in-flight keyframe `684:2829`, zero-existing
// landing `684:2841`, multi-existing landing `684:2853`).
//
// Why this lives above the navigation stack rather than inside Request Food:
// the accepted contract requires the *same* card the requester sees on
// Success to land in Home's first requester-owned slot, with Home already
// visible by the landing and with no width, wrapping, position, scale, or
// visibility jump at the handoff. A view pushed inside `NavigationStack`
// cannot reveal Home beneath itself, and cannot know Home's real slot
// geometry — so a Success-layer card could only ever be replaced by an
// independently laid-out Home card, which is the defect this replaces.
// Presenting the continuity as one overlay sibling of the stack (the same
// architecture `HelperSuccessView` already uses for W4-H1) lets one
// continuously mounted card travel into geometry measured from Home's actual
// first slot.
//
// This view is presentation only. It holds no create, ownership, recovery, or
// navigation authority: `RequestStore` has already authoritatively confirmed
// CREATED, resolved ownership, and inserted the card into the collection Home
// renders before this can exist, and `RequestCreationContinuity`'s own
// identity decides whether a presentation is still current at all.
import SwiftUI
import UIKit

/// Home publishes the frame of its first requester-owned card slot here, in
/// `.global` — the one coordinate system genuinely shared across the
/// `NavigationStack` hosting boundary (see
/// `RequestCreationContinuityLayout.landingSlot`) — so the continuity card's
/// landing geometry is measured from the real Home layout rather than
/// reconstructed from assumed insets, headings, or device metrics.
///
/// `nil` means Home currently renders no first owned slot (for example the
/// board has not resolved yet). That is a real state, not an error: the
/// landing then degrades to an in-place crossfade rather than inventing a
/// destination — see `RequestCreationContinuityLayout.landingTranslation`.
struct HomeOwnedRequestSlotFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        // The first owned slot is the only one that publishes, so a later
        // non-nil value simply replaces an earlier one.
        if let next = nextValue() {
            value = next
        }
    }
}

/// Pure layout rules for the continuity presentation. Extracted so the
/// width/no-reflow and landing-geometry contracts are directly testable
/// without mounting SwiftUI, and so there is exactly one place either rule
/// can be changed.
enum RequestCreationContinuityLayout {
    /// The continuity card's rendered width.
    ///
    /// Measured from Home's actual first owned slot whenever Home has one, so
    /// the Success card and the Home card are the same width by construction
    /// — not by two independently maintained inset values that can drift.
    /// With no measured slot, it falls back to the *same* shared Home content
    /// column rule Home itself applies
    /// (`HomeExchangeView.contentCardWidth(containerWidth:)`), never to a
    /// compensating offset or a hardcoded width.
    static func cardWidth(containerWidth: CGFloat, homeSlot: CGRect?) -> CGFloat {
        if let homeSlot, homeSlot.width > 0 {
            return homeSlot.width
        }
        return HomeExchangeView.contentCardWidth(containerWidth: containerWidth)
    }

    /// Home's first owned slot, but only when it is a destination the
    /// requester can actually see land.
    ///
    /// Home keeps its own scroll position, so its first owned slot can be
    /// partly or wholly off-screen when the requester returns to it — a card
    /// flying off the top of the screen would be a worse handoff than none.
    /// A slot that is not fully within the presentation's own bounds is
    /// therefore not used as a landing destination, and the landing
    /// crossfades in place instead. The slot is still Home's real geometry
    /// either way; this only decides whether travelling to it is presentable.
    ///
    /// W4-D2 coordinate-system FIX: `containerFrame` is the overlay's own
    /// real measured frame — in the same coordinate system `homeSlot` was
    /// measured in — not an assumed zero-origin rect the size of the
    /// container. The overlay's container is not guaranteed to sit at that
    /// system's origin, so containment must be evaluated against its actual
    /// bounds or a genuinely visible slot near a non-zero-origin edge could
    /// be wrongly rejected (or an off-screen one wrongly accepted).
    static func landingSlot(homeSlot: CGRect?, containerFrame: CGRect) -> CGRect? {
        guard let homeSlot, homeSlot.width > 0, containerFrame.height > 0 else { return nil }
        return containerFrame.contains(homeSlot) ? homeSlot : nil
    }

    /// The translation that carries the settled continuity card into Home's
    /// real first owned slot.
    ///
    /// Both rectangles are frames in the shared app coordinate space, so this
    /// is a measured delta, not a tuned offset. Returns `.zero` when either
    /// is unavailable: with no real destination to land in, the card stays
    /// exactly where it settled and the landing crossfades in place instead
    /// of moving to a guessed position.
    static func landingTranslation(from settledCard: CGRect?, to homeSlot: CGRect?) -> CGSize {
        guard let settledCard, let homeSlot, homeSlot.width > 0 else { return .zero }
        return CGSize(
            width: homeSlot.minX - settledCard.minX,
            height: homeSlot.minY - settledCard.minY
        )
    }

    /// W4-D2 Reduce Motion FIX: the bounded travel Reduce Motion is allowed to
    /// perform, regardless of how far the measured Home slot actually is.
    ///
    /// This is a hard cap on magnitude, not a proportional fraction of the
    /// full delta: a distant Home slot must not still read as a full
    /// travelling-card animation just scaled down, and a fixed cap keeps the
    /// motion "substantially reduced" no matter the device or scroll
    /// position that produced the measured distance.
    static let reducedMotionMaximumLandingDisplacement: CGFloat = 24

    /// The Reduce Motion counterpart to `landingTranslation(from:to:)`.
    ///
    /// Direction is preserved from the same measured delta — this never
    /// invents a different destination or a fixed guessed offset — but
    /// magnitude is clamped to `reducedMotionMaximumLandingDisplacement`. The
    /// gap between this bounded travel and the real destination is covered by
    /// the card's own crossfade (see `RequestCreationContinuityView.cardOpacity`),
    /// not by finishing the full measured landing.
    ///
    /// Returns `.zero` under exactly the same fallback conditions as
    /// `landingTranslation` — a slot that produces no real delta produces no
    /// bounded delta either, so this can never diverge from the geometry
    /// fallback's own "no travelling-card motion" rule.
    static func reducedMotionLandingTranslation(from settledCard: CGRect?, to homeSlot: CGRect?) -> CGSize {
        clamped(
            landingTranslation(from: settledCard, to: homeSlot),
            toMaximumMagnitude: reducedMotionMaximumLandingDisplacement
        )
    }

    private static func clamped(_ size: CGSize, toMaximumMagnitude maximum: CGFloat) -> CGSize {
        let magnitude = (size.width * size.width + size.height * size.height).squareRoot()
        guard magnitude > maximum, magnitude > 0 else { return size }
        let scale = maximum / magnitude
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    // MARK: - W4-D2 landing handoff branches

    /// The three distinct ways a landing hands the continuity card over to
    /// Home's real card. Decided once from motion preference and whether the
    /// committed landing has a usable destination, so the overlay's fade-out
    /// and Home's fade-in are both derived from the same branch rather than
    /// from separately maintained conditions.
    enum LandingHandoff: Equatable {
        /// Standard motion, usable destination: the card performs the full
        /// measured travel into Home's real slot and stays opaque; Home's
        /// card becomes visible when the presentation retires, at the exact
        /// position the overlay card already occupies.
        case measuredTravel
        /// Reduce Motion, usable destination: bounded travel toward the real
        /// slot, with the overlay card crossfading into Home's real card.
        case reducedMotionBoundedCrossfade
        /// No usable destination, either motion preference (W4-D2 final
        /// geometry-fallback card handoff): zero travel; the overlay card
        /// fades out where it settled while Home's real card for the same
        /// request fades in at its actual slot, as one crossfade.
        case inPlaceCrossfade
    }

    static func landingHandoff(reduceMotion: Bool, hasLandingDestination: Bool) -> LandingHandoff {
        guard hasLandingDestination else { return .inPlaceCrossfade }
        return reduceMotion ? .reducedMotionBoundedCrossfade : .measuredTravel
    }

    /// True whenever the continuity overlay's own card should still be drawn
    /// at full opacity above Home. It is always the exact complement of
    /// `isHomeCardRevealed` once the card has entered, so during the landing
    /// the two cards are never both hidden: the only branch that keeps the
    /// overlay card opaque through the landing (`.measuredTravel`) is the one
    /// that does not reveal Home's card early.
    static func isOverlayCardVisible(
        phase: RequestCreationContinuityView.Phase,
        reduceMotion: Bool,
        hasLandingDestination: Bool
    ) -> Bool {
        if phase == .entering { return false }
        return !isHomeCardRevealed(
            phase: phase,
            reduceMotion: reduceMotion,
            hasLandingDestination: hasLandingDestination
        )
    }

    // MARK: - W4-D2 physical-device FIX: stable measurement during landing

    /// The frame this presentation actually measures against on a given frame.
    ///
    /// Before the landing, that is simply whatever Home publishes right now —
    /// the live measurement, so the destination is always the real current
    /// slot. From the instant the landing begins, it is the frame captured at
    /// that instant instead.
    ///
    /// Why the capture exists (physical-device FIX): Home re-runs its own
    /// `.task` load when the navigation stack pops back to it, which it does
    /// at the *start* of this presentation. On a device against a real
    /// backend that `GET /api/requests` resolves hundreds of milliseconds
    /// later — routinely inside this presentation's own 1.6s — and republishes
    /// `requests`. Any resulting relayout republishes a different first-slot
    /// frame. Because `cardOffset(landingSlot:)` is a plain function of that
    /// published value, a mid-flight change silently *retargeted the card with
    /// no animation attached*, which reads on device as the travel stalling or
    /// snapping. Freezing the two endpoints at the one instant the landing is
    /// committed makes the travel a single continuous motion by construction
    /// rather than by the fetch happening to land outside the window.
    ///
    /// This is still the standard measured target — the real frame Home
    /// published, captured — never a guessed or reconstructed coordinate, and
    /// `nil` still degrades to the accepted in-place crossfade.
    ///
    /// W4-D2 rereview FIX: during the landing only the capture is read, never
    /// the live value. A capture whose result was `nil` stays `nil` for the
    /// whole landing, so geometry that Home publishes *after* the commit can
    /// neither turn the in-place fallback into travel nor activate the Reduce
    /// Motion handoff partway through. A landing with no capture at all (not
    /// reachable in production, which always commits first) likewise has no
    /// endpoint rather than reacquiring one live.
    static func stableFrame(
        phase: RequestCreationContinuityView.Phase,
        live: CGRect?,
        capture: EndpointCapture
    ) -> CGRect? {
        guard phase == .landing else { return live }
        switch capture {
        case .pending:
            return nil
        case .captured(let frame):
            return frame
        }
    }

    /// W4-D2 rereview FIX: one landing endpoint's capture state. Keeps
    /// "not captured yet" distinct from "captured, and there was no frame" —
    /// the two states a plain `CGRect?` conflated, which let a missing
    /// endpoint be silently replaced by later live geometry mid-landing.
    enum EndpointCapture: Equatable {
        /// The landing has not been committed; live geometry is authoritative.
        case pending
        /// Committed exactly once. `nil` records that no measured endpoint
        /// existed at the commit — final for this presentation, not a gap to
        /// be filled later.
        case captured(CGRect?)

        /// Records `live` as the endpoint, only on the first commit. A later
        /// commit within the same presentation cannot replace it.
        mutating func commit(_ live: CGRect?) {
            guard case .pending = self else { return }
            self = .captured(live)
        }
    }

    // MARK: - W4-D2 physical-device FIX: standard-motion travel curve

    /// The standard-motion landing travel's cubic-Bézier control points.
    ///
    /// Why these are named rather than written inline (physical-device FIX):
    /// the landing previously reused `timingCurve(0.22, 0.78, 0.24, 1)`, the
    /// curve this app uses for its *micro* settles (`ContentView`'s 2pt brand
    /// landing and 6pt route entrance). On a 2-9pt displacement its extreme
    /// front-loading is invisible. On the landing's real ~145pt travel it is
    /// not: that curve delivers 79% of the distance in the first 150ms and
    /// then spends the remaining 350ms covering the last ~10pt, which is
    /// exactly the "sticky", stalling read physical-device acceptance found —
    /// present whether or not any other card is on screen. These control
    /// points distribute the same travel across the same duration instead
    /// (~50% at the midpoint), so the motion decelerates into the slot rather
    /// than arriving and then crawling.
    ///
    /// `landingTravelProgress(atDurationFraction:)` below is the checkable
    /// form of that property, and `RequestCreationContinuityView`'s own
    /// `Animation` is built from these same values, so the proof and the
    /// rendered curve cannot drift apart.
    static let standardLandingCurve = (x1: 0.33, y1: 0.0, x2: 0.20, y2: 1.0)

    /// The fraction of the landing travel completed at `fraction` of the
    /// landing duration, for `standardLandingCurve`.
    ///
    /// A cubic Bézier timing curve is parametric, so progress at a given time
    /// is found by first solving for the parameter that produces that time.
    /// The curve's x control points are within `0...1`, so x is monotonic in
    /// the parameter and bisection resolves it exactly enough for a contract
    /// assertion.
    static func landingTravelProgress(atDurationFraction fraction: Double) -> Double {
        let clamped = min(max(fraction, 0), 1)
        let curve = standardLandingCurve
        func axis(_ c1: Double, _ c2: Double, _ s: Double) -> Double {
            let inverse = 1 - s
            return 3 * inverse * inverse * s * c1 + 3 * inverse * s * s * c2 + s * s * s
        }
        var low = 0.0
        var high = 1.0
        for _ in 0..<60 {
            let mid = (low + high) / 2
            if axis(curve.x1, curve.x2, mid) < clamped {
                low = mid
            } else {
                high = mid
            }
        }
        return axis(curve.y1, curve.y2, (low + high) / 2)
    }

    /// True once Home's own real destination card should already be visible
    /// while this exact continuity is still presenting above it — the other
    /// half of the crossfade handoff `isOverlayCardVisible` describes. True
    /// during the landing for both crossfading branches
    /// (`.reducedMotionBoundedCrossfade` and `.inPlaceCrossfade`); never for
    /// `.measuredTravel`, and never before the landing is committed.
    ///
    /// `RequestCreationContinuityView` publishes this through
    /// `RequestCreationContinuityHandoffKey`, and `HomeExchangeView` reads it
    /// directly, so the overlay's fade-out and Home's fade-in only ever react
    /// to one shared signal — never two independently guessed animation
    /// timelines that could drift apart. Both sides also animate that
    /// reaction with the identical
    /// `RequestCreationContinuityMotionPlan.handoffCrossfadeAnimation`, timed
    /// by the same `landingSeconds` this function's own truth-value
    /// transition is timed against.
    static func isHomeCardRevealed(
        phase: RequestCreationContinuityView.Phase,
        reduceMotion: Bool,
        hasLandingDestination: Bool
    ) -> Bool {
        guard phase == .landing else { return false }
        return landingHandoff(
            reduceMotion: reduceMotion,
            hasLandingDestination: hasLandingDestination
        ) != .measuredTravel
    }
}

/// W4-D2 crossfade handoff signal (Reduce Motion rereview FIX, extended to
/// the no-usable-target in-place crossfade). Relayed from
/// the continuity overlay through `ContentView` into `HomeExchangeView`,
/// matching the existing `HomeOwnedRequestSlotFrameKey` relay pattern — see
/// `RequestCreationContinuityLayout.isHomeCardRevealed(phase:reduceMotion:hasLandingDestination:)`.
struct RequestCreationContinuityHandoffKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// Engineering-owned motion values for the accepted sequence. The metaphor,
/// endpoints, and dwell come from the contract and canonical Figma; these are
/// the SwiftUI timing and displacement choices that express them.
struct RequestCreationContinuityMotionPlan: Equatable {
    /// Active time from first appearance until the landing begins: the card
    /// rising from below, its restrained grow/settle, and the posted-success
    /// message.
    let settleDwell: Duration
    /// The landing itself: Home revealed, the same card travelling into its
    /// real first slot.
    let landingDuration: Duration
    /// How far below its settled position the card starts.
    let entranceRise: CGFloat
    /// The restrained grow the card settles out of.
    let entranceScale: CGFloat

    /// The accepted total Success dwell, unchanged by W4-D2: the sequence is
    /// split inside this same total rather than lengthening it, and Posting is
    /// never extended to make room for it.
    static let successDwellDuration: Duration = .milliseconds(1600)

    /// CP2 (Faith, 2026-10-26): a participant's first post on this install
    /// also shows `successGuidance`, so only its settle is lengthened, to
    /// 3000ms, leaving time to read it before the landing.
    static let firstRequestSuccessDwellDuration: Duration = .milliseconds(3500)

    static let standard = RequestCreationContinuityMotionPlan(
        settleDwell: .milliseconds(1100),
        landingDuration: .milliseconds(500),
        entranceRise: 140,
        entranceScale: 0.92
    )

    /// Reduce Motion: the entrance displacement and the grow are removed
    /// entirely (the card crossfades into place), and the landing runs as a
    /// short non-springy ease rather than a spring with overshoot. The
    /// destination is deliberately identical — the same measured Home first
    /// slot — because a different destination would be a different outcome,
    /// not reduced motion.
    static let reducedMotion = RequestCreationContinuityMotionPlan(
        settleDwell: .milliseconds(1100),
        landingDuration: .milliseconds(500),
        entranceRise: 0,
        entranceScale: 1
    )

    static func plan(reduceMotion: Bool) -> RequestCreationContinuityMotionPlan {
        reduceMotion ? .reducedMotion : .standard
    }

    static func plan(reduceMotion: Bool, isFirstRequest: Bool) -> RequestCreationContinuityMotionPlan {
        let base = plan(reduceMotion: reduceMotion)
        guard isFirstRequest else { return base }
        return RequestCreationContinuityMotionPlan(
            settleDwell: firstRequestSuccessDwellDuration - base.landingDuration,
            landingDuration: base.landingDuration,
            entranceRise: base.entranceRise,
            entranceScale: base.entranceScale
        )
    }

    var totalDuration: Duration {
        settleDwell + landingDuration
    }

    /// `landingDuration` as seconds, for the `Animation` APIs that take a
    /// `Double` rather than a `Duration` — matching
    /// `HelperSuccessMotionPlan.transformSeconds`'s existing conversion.
    ///
    /// W4-D2 Reduce Motion rereview FIX: this is the *one* place the Reduce
    /// Motion landing's animated duration is derived. Before this fix,
    /// `RequestCreationContinuityView.landingAnimation` independently
    /// hardcoded `0.4` while the actual landing phase ran for
    /// `landingDuration` (500ms) — a guessed second timeline that drifted
    /// ~0.1s from the real one and left the overlay card fully transparent
    /// before Home's real card became visible. Both the overlay's own
    /// fade-out and (via `RequestCreationContinuityHandoffKey`) Home's
    /// fade-in now read this same value, so they cannot drift apart again.
    var landingSeconds: Double {
        let components = landingDuration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// The one animation both halves of a landing crossfade use: the overlay
    /// card's fade-out and Home's real card's fade-in. Spanning exactly
    /// `landingSeconds` on the same curve keeps the two opacities
    /// complementary for the whole landing window, and finishes the handoff
    /// as the landing phase — and so the accepted Success dwell — ends.
    var handoffCrossfadeAnimation: Animation {
        .easeInOut(duration: landingSeconds)
    }

    // MARK: - W4-D2 physical-device FIX: Home reveal staging

    /// How much of the landing the Home-chrome reveal takes.
    ///
    /// The accepted contract requires Home to be revealed *before or with* the
    /// final landing. Previously the base canvas crossfaded on the same curve
    /// and duration as the card travel, so Home was still partly veiled for
    /// the whole landing while the card was already at rest. Completing the
    /// reveal inside the first 60% of the landing puts a fully solid Home
    /// behind the last, slowest part of the travel — Home is genuinely there
    /// before the card arrives, which is the reading the contract asks for.
    /// It adds no time: it is a fraction of the existing `landingDuration`.
    var chromeRevealSeconds: Double {
        landingSeconds * 0.6
    }

    /// How long Home's deferred requester/board content takes to crossfade in
    /// once the travelling card has landed and the presentation has retired —
    /// see `HomeExchangeView.isDeferringContinuityHomeContent(...)`.
    ///
    /// This runs *after* the accepted Success dwell has already ended, on
    /// a Home that is by then live and fully interactive. It does not extend
    /// the dwell, and nothing waits on it.
    static let homeContentRevealSeconds: Double = 0.24
}

struct RequestCreationContinuityView: View {
    /// The exact operation-scoped continuity being presented. `.id(...)` on
    /// this view at the call site keys the whole presentation to it, so a
    /// different continuity can never inherit this one's phase or its
    /// already-fired acknowledgement.
    let continuity: RequestCreationContinuity
    /// Home's real first owned-slot frame, relayed from its own layout.
    let homeSlotFrame: CGRect?
    let reduceMotion: Bool
    /// Retires this exact continuity. Called when the sequence completes and
    /// again if the presentation goes away first, so a cancelled or
    /// interrupted sequence can never leave continuity state behind.
    let onFinished: (UUID) -> Void
    /// Match Home's current authoritative status without inventing availability.
    var ownerPhase: OwnerRequestPhase? = nil
    /// Whether this participant's first post on this install is being shown:
    /// adds `successGuidance` and the longer first-request dwell. The call
    /// site records it as shown only once this presentation finishes, so the
    /// value is stable for the presentation's whole lifetime.
    var isFirstRequest = false

    enum Phase: Equatable {
        /// The card is below its settled position, not yet grown in.
        case entering
        /// Settled under the posted-success message; the readable Success dwell.
        case settled
        /// Home revealed; the same card travelling into its real first slot.
        case landing
    }

    @State private var phase: Phase = .entering
    /// The card's own layout frame — measured on the un-offset layout slot, so
    /// it is stable across every motion phase.
    @State private var settledCardFrame: CGRect?
    /// Fences the one semantic success haptic and the one VoiceOver
    /// announcement if SwiftUI re-evaluates this task while the same
    /// presentation stays mounted.
    @State private var hasAcknowledged = false
    /// W4-D2 physical-device FIX: the two real measured endpoints, captured at
    /// the one instant the landing is committed, so a relayout arriving
    /// mid-flight cannot silently retarget a motion that is already running —
    /// see `RequestCreationContinuityLayout.stableFrame(phase:live:capture:)`.
    /// Both start `.pending` with each presentation: the call site keys this
    /// view to `continuity.id`, so a later continuity gets fresh state and
    /// measures independently.
    @State private var settledCardCapture: RequestCreationContinuityLayout.EndpointCapture = .pending
    @State private var homeSlotCapture: RequestCreationContinuityLayout.EndpointCapture = .pending
    /// W4-D2 physical-device FIX: the latest Home-slot value actually
    /// delivered to this presentation, mirrored from the `homeSlotFrame`
    /// parameter into `@State` so it survives for the lifetime of the
    /// presentation's identity rather than the render that started the long-
    /// running `.task` below.
    ///
    /// `homeSlotFrame` is a plain `let` on this value-type view. The `.task`
    /// closure that commits the landing endpoint runs across many renders,
    /// but it was created once and closes over the `self` from the render
    /// that started it — so reading `homeSlotFrame` directly from inside that
    /// closure read whatever Home had published at that first render, not
    /// what it had published by the time the commit actually runs. `@State`
    /// storage is not re-captured this way: it is the same persistent cell on
    /// every render, so mirroring the parameter into it here and reading the
    /// mirror from the `.task` gives the commit the true latest value.
    @State private var latestHomeSlotFrame: CGRect?

    private var plan: RequestCreationContinuityMotionPlan {
        RequestCreationContinuityMotionPlan.plan(reduceMotion: reduceMotion, isFirstRequest: isFirstRequest)
    }

    var body: some View {
        GeometryReader { geometry in
            let containerSize = geometry.size
            let containerFrame = geometry.frame(in: .global)
            ZStack {
                // Opaque for the whole Success phase — the Request Food
                // screen's own removal happens underneath it, so the
                // requester never sees a replacement — then crossfaded out to
                // reveal Home before the card finishes landing.
                CommonPlateStyle.Color.baseCanvas
                    .ignoresSafeArea()
                    .opacity(phase == .landing ? 0 : 1)
                    // W4-D2 physical-device FIX: the Home reveal is staged
                    // ahead of the travel rather than sharing the travel's own
                    // curve and full duration — see
                    // `RequestCreationContinuityMotionPlan.chromeRevealSeconds`.
                    .animation(chromeRevealAnimation, value: phase)

                VStack(spacing: CommonPlateStyle.Spacing.l) {
                    card(containerSize: containerSize, containerFrame: containerFrame)

                    VStack(spacing: CommonPlateStyle.Spacing.xs) {
                        Text(Self.successMessage)
                            .font(.title3.weight(.bold))
                        if isFirstRequest {
                            Text(Self.successGuidance)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: CommonPlateStyle.Metrics.stateContentWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(phase == .landing ? 0 : 1)
                    .animation(chromeRevealAnimation, value: phase)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("request-success-message")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The approved composition sits a little above the geometric
                // centre, matching the Posting state it replaces in place.
                .padding(.bottom, 60)
            }
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("request-creation-continuity")
        .onPreferenceChange(ContinuityCardFrameKey.self) { frame in
            settledCardFrame = frame
        }
        // W4-D2 physical-device FIX: keeps `latestHomeSlotFrame` current for
        // this presentation's whole lifetime, including the very first value
        // delivered before this view's first render (`initial: true`) — see
        // `latestHomeSlotFrame`'s own doc comment for why the long-running
        // `.task` below must read this mirror rather than `homeSlotFrame`
        // directly.
        .onChange(of: homeSlotFrame, initial: true) { _, newValue in
            latestHomeSlotFrame = newValue
        }
        .task {
            guard !hasAcknowledged else { return }
            hasAcknowledged = true
            // One semantic success haptic and one announcement of the visible
            // message, at first appearance only — never again for the landing.
            CommonPlateHaptics.success()
            UIAccessibility.post(
                notification: .announcement,
                argument: isFirstRequest ? Self.successAnnouncement : Self.successMessage
            )
            withAnimation(entranceAnimation) {
                phase = .settled
            }
            do {
                try await Task.sleep(for: plan.settleDwell)
            } catch {
                return
            }
            // W4-D2 physical-device FIX: commit the two real measured
            // endpoints before starting the travel, so the motion that runs
            // next has one fixed destination for its whole duration. A missing
            // endpoint is captured as missing, so the fallback cannot later
            // turn into travel (W4-D2 rereview FIX).
            settledCardCapture.commit(settledCardFrame)
            homeSlotCapture.commit(latestHomeSlotFrame)
            withAnimation(landingAnimation) {
                phase = .landing
            }
            do {
                try await Task.sleep(for: plan.landingDuration)
            } catch {
                return
            }
            onFinished(continuity.id)
        }
        // Covers both endings: the completed sequence (already retired above,
        // so this is a no-op) and a presentation that went away first —
        // cancellation, supersession, or the scene tearing it down — which
        // must never leave a continuity behind for a later create to inherit.
        .onDisappear {
            onFinished(continuity.id)
        }
    }

    /// The actual newly created requester-owned Home card — the same
    /// `RequestCardView` Home renders, in the same `.own` treatment, at the
    /// width measured from Home's own slot. Only offset, scale, and opacity
    /// animate around it, so its text can never reflow, resize, or rewrap
    /// during the sequence.
    private func card(containerSize: CGSize, containerFrame: CGRect) -> some View {
        // W4-D2 physical-device FIX: both the width rule and the landing
        // geometry read the same stable measurement, so a relayout arriving
        // mid-flight can neither retarget the travel nor resize the card.
        // Reads the mirrored `latestHomeSlotFrame`, not `homeSlotFrame`
        // directly, so this always agrees with what the landing commit itself
        // will read — see `latestHomeSlotFrame`'s doc comment.
        let measuredHomeSlot = RequestCreationContinuityLayout.stableFrame(
            phase: phase,
            live: latestHomeSlotFrame,
            capture: homeSlotCapture
        )
        // W4-D2 coordinate-system FIX: containment is evaluated against this
        // presentation's own real measured frame, not an assumed zero-origin
        // rect — see `RequestCreationContinuityLayout.landingSlot`.
        let landingSlot = RequestCreationContinuityLayout.landingSlot(
            homeSlot: measuredHomeSlot,
            containerFrame: containerFrame
        )
        return ZStack {
            RequestCardView(
                request: continuity.request,
                kind: .own,
                showsOwnershipEyebrow: false,
                ownerPhase: ownerPhase,
                isHomePresentation: true
            )
            .scaleEffect(cardScale)
            .offset(cardOffset(landingSlot: landingSlot))
            .opacity(cardOpacity(landingSlot: landingSlot))
            // W4-D2 final geometry-fallback card handoff: the in-place
            // crossfade's fade-out runs on the identical animation Home's
            // real card fades in on (see `HomeExchangeView`), rather than on
            // the landing's travel curve. Keyed only on this branch, so the
            // valid-target branches never observe a change here and keep
            // their existing landing animation untouched.
            .animation(
                plan.handoffCrossfadeAnimation,
                value: isInPlaceCrossfading(landingSlot: landingSlot)
            )
        }
        .frame(width: RequestCreationContinuityLayout.cardWidth(
            containerWidth: containerSize.width,
            homeSlot: measuredHomeSlot
        ))
        // Measured on this un-offset layout slot rather than on the moving
        // card, so the landing translation is computed from where the card
        // *settled*, not from wherever it currently is mid-animation.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: ContinuityCardFrameKey.self,
                        // W4-D2 coordinate-system FIX: `.global` is the one
                        // coordinate system genuinely shared with Home's own
                        // published slot frame (see `HomeExchangeView.
                        // firstOwnedSlotFrameReporter`) — a named space
                        // declared above this presentation does not resolve
                        // across `NavigationStack`'s own hosting boundary, so
                        // Home's slot and this card's frame were being
                        // subtracted across two different origins.
                        value: proxy.frame(in: .global)
                    )
                    // W4-D2 Reduce Motion rereview FIX: the crossfade handoff
                    // signal — see `RequestCreationContinuityHandoffKey`.
                    .preference(
                        key: RequestCreationContinuityHandoffKey.self,
                        value: RequestCreationContinuityLayout.isHomeCardRevealed(
                            phase: phase,
                            reduceMotion: reduceMotion,
                            hasLandingDestination: landingSlot != nil
                        )
                    )
            }
        )
        .accessibilityIdentifier("request-success-card")
    }

    private func cardOffset(landingSlot: CGRect?) -> CGSize {
        switch phase {
        case .entering:
            return CGSize(width: 0, height: plan.entranceRise)
        case .settled:
            return .zero
        case .landing:
            // Standard motion performs the exact measured landing — the full
            // delta to Home's real slot, unchanged by W4-D2. Reduce Motion
            // performs only a bounded portion of that same delta; the
            // remaining distance is covered by `cardOpacity`'s crossfade
            // instead of full travel.
            // W4-D2 physical-device FIX: the settled endpoint is held stable
            // for the whole travel for the same reason the destination is —
            // see `RequestCreationContinuityLayout.stableFrame(phase:live:capture:)`.
            let settled = RequestCreationContinuityLayout.stableFrame(
                phase: phase,
                live: settledCardFrame,
                capture: settledCardCapture
            )
            if reduceMotion {
                return RequestCreationContinuityLayout.reducedMotionLandingTranslation(
                    from: settled,
                    to: landingSlot
                )
            }
            return RequestCreationContinuityLayout.landingTranslation(
                from: settled,
                to: landingSlot
            )
        }
    }

    /// W4-D2 Reduce Motion FIX: standard motion's own precise landing already
    /// ends exactly on Home's real slot, so its card stays fully opaque
    /// through the landing — there is no gap to hide. Reduce Motion's bounded
    /// travel does not reach that slot, so its card crossfades out over the
    /// same landing duration instead, and Home's real card (already mounted
    /// invisibly in that slot — see `HomeExchangeView.isLandingContinuityCard`)
    /// is what the requester actually sees settle into place.
    ///
    /// W4-D2 final geometry-fallback card handoff: with no usable destination
    /// (`landingSlot == nil`), either motion preference, the card does not
    /// move but fades out where it settled while Home's real card fades in
    /// at its actual slot — see `RequestCreationContinuityLayout.LandingHandoff`.
    private func cardOpacity(landingSlot: CGRect?) -> Double {
        RequestCreationContinuityLayout.isOverlayCardVisible(
            phase: phase,
            reduceMotion: reduceMotion,
            hasLandingDestination: landingSlot != nil
        ) ? 1 : 0
    }

    private func isInPlaceCrossfading(landingSlot: CGRect?) -> Bool {
        phase == .landing
            && RequestCreationContinuityLayout.landingHandoff(
                reduceMotion: reduceMotion,
                hasLandingDestination: landingSlot != nil
            ) == .inPlaceCrossfade
    }

    private var cardScale: CGFloat {
        // Layout width never changes; only this scale does, and only for the
        // restrained entrance grow.
        phase == .entering ? plan.entranceScale : 1
    }

    private var entranceAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.25)
            : .spring(response: 0.45, dampingFraction: 0.82)
    }

    private var landingAnimation: Animation {
        if reduceMotion {
            // W4-D2 Reduce Motion rereview FIX: reads the same
            // `landingSeconds` the crossfade handoff is timed against —
            // see `RequestCreationContinuityMotionPlan.landingSeconds`.
            // Unchanged by the physical-device FIX: Reduce Motion performs a
            // bounded 24pt displacement, for which this ease is already
            // correct, and Faith verified it on device. (Expressed through
            // `handoffCrossfadeAnimation`, which is this identical
            // `.easeInOut(duration: plan.landingSeconds)`.)
            return plan.handoffCrossfadeAnimation
        }
        // W4-D2 physical-device FIX: built from the same control points the
        // `landingTravelProgress(atDurationFraction:)` contract is proved
        // against, replacing the micro-settle curve this travel had inherited
        // — see `RequestCreationContinuityLayout.standardLandingCurve`. The
        // duration is also read from the plan rather than restated, so it
        // cannot drift from the phase it is timed against.
        let curve = RequestCreationContinuityLayout.standardLandingCurve
        return .timingCurve(curve.x1, curve.y1, curve.x2, curve.y2, duration: plan.landingSeconds)
    }

    /// The Home reveal's own animation, deliberately separate from the card
    /// travel's — see `RequestCreationContinuityMotionPlan.chromeRevealSeconds`.
    private var chromeRevealAnimation: Animation {
        .easeOut(duration: plan.chromeRevealSeconds)
    }

    static let successMessage = "Request posted!"
    /// First post only (CP2, Faith 2026-10-25); later posts show just
    /// `successMessage`.
    static let successGuidance =
        "We'll let you know when a student places your order."
    static let successAnnouncement = "\(successMessage) \(successGuidance)"
}

/// The continuity card's own measured layout frame, in `.global` — the same
/// real coordinate system `HomeOwnedRequestSlotFrameKey` is measured in, so
/// the two are directly comparable. File-scope (not `private` to
/// `RequestCreationContinuityView`, matching `HomeOwnedRequestSlotFrameKey`
/// and `RequestCreationContinuityHandoffKey` above) so hosted geometry tests
/// can observe the actual rendered card frame directly rather than
/// reconstructing it from the view's own internal state.
struct ContinuityCardFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() {
            value = next
        }
    }
}
