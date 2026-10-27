//
//  HomeRefreshSettle.swift
//  CommonPlateios
//
// W4-H3 authored post-refresh settle (Decision 11). PRESENTATION ONLY.
//
// Native `.refreshable` remains the sole refresh gesture, trigger, spinner, and
// loading authority. After a *truthful successful* refresh, the native collapse
// would return the dynamic Home content to rest faster than the selected H3
// choreography (spinner → check with breathing room → content settles → check
// fades). This file authors only the *visual* return to rest of that content.
//
// How the handoff stays continuous (no visible bounce, by construction):
//
//   rendered displacement = native displacement + compensation
//   compensation          = max(0, hold − native displacement)
//   ⇒ rendered            = max(native, hold)
//
// `native` is the content's displacement below rest, read from passive layout
// geometry at render time. `hold` is an authored value that starts at the
// native displacement the settle took over from and eases to zero. Both terms
// only ever decrease while a settle runs, so their maximum can only decrease:
// content never moves away from rest, never jumps, and never overshoots.
// Wherever native motion is the larger of the two the compensation is zero and
// the native position is untouched. The hold changes no layout, no scroll range,
// no scroll position, and no inset — it is a render-time translation of one
// region.
//
// What the real refresh does, as measured on the Simulator (it is NOT a single
// clean "refresh closure returns, then the lane collapses"):
//   • The native refresh starts as soon as the pull crosses its threshold, while
//     the finger is still down, and it may end (the closure returns) before the
//     finger is released, or long after the native lane has already closed.
//   • While the native refresh is active, the displacement read from passive
//     layout geometry is one lane height (60 pt) *less* than the content's drawn
//     displacement, and it steps up by that amount when the refresh ends. The displacement stream is
//     therefore not a clean monotonic collapse: it holds, steps, and rises.
//   • The real collapse only runs after the refresh has ended and, if a finger
//     was down, after it lifts.
// So the settle never trusts a displacement read while the refresh may still be
// active, and a rise in displacement is not by itself a new pull. It waits for
// the step that marks the refresh having ended, hands off from the first
// reading after it (the first one that is real), and starts the check only once
// the collapse has actually carried the content back to the native
// indicator-clear depth.
//
// Nothing here triggers a refresh, decides success, delays or alters data, or
// drives header ownership; the stage, the hold, and the check are all derived
// from the single truthful-success decision the refresh closure already makes.
import SwiftUI

enum HomeRefreshSettle {
    // MARK: - Geometry (displacement is positive below rest)

    /// Native displacement (points below rest) at or below which the outgoing
    /// native refresh indicator is visually gone from the lane. Presentation
    /// sequencing only — it reads no UIKit state and decides no refresh. Provenance
    /// (Simulator only; re-check on a physical device): rendered frames from a
    /// real pull-to-refresh on the iPhone 17 Pro Simulator, iOS 26.5, showed the
    /// outgoing indicator still visibly present with ~11 pt of collapse
    /// remaining and gone by ~7 pt; 6 pt starts the check just after it has
    /// cleared.
    static let nativeIndicatorClearDepth: CGFloat = 6

    /// Measured on the Simulator (re-check on a physical device): the one-lane
    /// height by which the passive layout reading is lower than the content is
    /// drawn while the native refresh is active, and by which it steps up when
    /// the refresh ends. A single reading that rises by at least this much after
    /// the refresh closure has returned is the refresh having ended — a step, not
    /// motion — which is the first reading the settle may hand off from. Set well
    /// under the lane so a step that coincides with a fast collapse is still seen.
    static let refreshEndStepThreshold: CGFloat = 20

    /// How far displacement may rise above its lowest value since the check began
    /// before it is read as a new pull rather than the native collapse, which
    /// only ever decreases once it is running.
    static let takeoverTolerance: CGFloat = 2

    // MARK: - Plan

    /// One settle's authored parameters. Engineering-owned within the accepted
    /// character: restrained, one-way, continuous-looking, no spring.
    struct Plan: Equatable {
        /// The most the hold may start at. A pull held further than this still
        /// has native as the larger term, so native controls until it falls to
        /// the hold; the cap only keeps the authored lane from exceeding the
        /// native one.
        let startCap: CGFloat
        let delay: Double
        let duration: Double
        let isReduced: Bool
        /// How long after the check begins before it starts to fade out. The
        /// fade-in runs inside this window, so the fully-visible time is the hold
        /// less the fade-in.
        let checkHold: Duration

        /// Where the hold starts for a given native displacement: exactly that
        /// displacement (never negative, never above the cap), so the handoff is
        /// continuous.
        func holdStart(forDisplacement displacement: CGFloat) -> CGFloat {
            min(max(0, displacement), startCap)
        }

        /// Vertical center of the check below the band's bottom edge: the center
        /// of the held lane at its full authored size, fixed for the whole settle
        /// and for every path into it — never derived from whatever reading the
        /// hold happened to be armed from (a fast refresh can arm from a few
        /// points, which would crowd the check against the header). The check
        /// carries no positional animation.
        var laneCenter: CGFloat {
            startCap / 2
        }

        var animation: Animation {
            let curve: Animation = isReduced
                ? .easeOut(duration: duration)
                : .easeInOut(duration: duration)
            return delay > 0 ? curve.delay(delay) : curve
        }

        /// Upper bound on the eased settle once it has started; an unfinished
        /// settle is ended here.
        var endsAfter: Duration {
            .milliseconds(Int(((delay + duration) * 1000).rounded()) + 600)
        }
    }

    /// The smallest held lane that keeps the heading clear of the native spinner.
    /// The spinner stays drawn, centered ~30 pt below the band and ~26 pt across
    /// (to ~44 pt), until native displacement is back to ~11 pt, while the content
    /// holds at the authored lane; the first heading's text top sits ~16 pt below
    /// the band at rest plus the held displacement. A 24 pt lane put the heading in
    /// the spinner's row (measured on the Simulator); 36 pt leaves ~8 pt clear.
    /// Both motion modes use it. Provenance: Simulator, iPhone 17 Pro iOS 26.5;
    /// re-check on a physical device.
    static let heldLane: CGFloat = 36

    static let standardStartCap: CGFloat = heldLane
    static let standardDelay: Double = 0.35
    static let standardDuration: Double = 0.4
    /// From the check beginning to its fade-out starting; the 0.15 s fade-in runs
    /// inside it. Fixed by the geometry of the settle, not by taste: the first
    /// heading rises through the check's own lane as the content eases to rest, so
    /// the mark must be mostly gone when the heading's text reaches it. Measured on
    /// the Simulator, the check begins 0.10–0.16 s after the ease starts; 200 ms
    /// starts the fade-out as the still moment ends (~0.3–0.36 s in), the text
    /// reaches the check's bottom edge ~0.55 s in with the mark at most ~0.4 opaque,
    /// and the mark is gone by ~0.6 s. It stays readable (above half opacity)
    /// ~0.31 s — close to the Figma reference's ~0.38 s full/readable portion —
    /// before its ~0.25 s fade.
    static let standardCheckHold: Duration = .milliseconds(200)

    /// Reduce Motion: no sustained spatial drift. A static lane holds the check,
    /// then returns to rest with a brief ease. Truth, ordering, and the VoiceOver
    /// acknowledgment are identical to standard motion.
    /// Same lane as standard motion (the spinner-clearance minimum); what is reduced
    /// is the movement — a static hold (0.5 s), then one brief 0.2 s return — and
    /// the check hold is 200 ms so the mark is mostly gone as the heading arrives.
    static let reducedStartCap: CGFloat = heldLane
    static let reducedDelay: Double = 0.5
    static let reducedDuration: Double = 0.2
    static let reducedCheckHold: Duration = .milliseconds(200)

    /// Lets the un-animated hold commit for a frame before it eases, so the
    /// ease starts from the held value rather than being coalesced with it.
    static let commitInterval: Duration = .milliseconds(20)

    /// After the refresh closure returns the native refresh ends and, measured,
    /// the end-of-refresh step follows within ~0.05 s unless a finger is still
    /// holding the pull. If no step has been seen by this long after, the settle
    /// stops waiting for one: content already at rest has no collapse to wait for
    /// and, for a healthy → healthy refresh, the acknowledgment begins (a recovery
    /// ends with no check — Decision 12 Option B); content still displaced is
    /// handed off from as read. A fallback that keeps a truthful success from
    /// being dropped, not the path of a normal refresh.
    static let postEndGrace: Duration = .milliseconds(500)

    /// A settle whose native collapse never carries the content back to the
    /// indicator-clear depth (for example a pull that is simply held) is ended
    /// here with no acknowledgment, never shown late.
    static let maxWaitForNativeCollapse: Duration = .seconds(10)

    /// The value a retire drives the hold to. The settle's own ease already
    /// targets `0`, and SwiftUI retargets a running animation only when the state
    /// *changes*; assigning `0` again would silently leave the long ease running.
    /// A value just below zero is inert (`compensation` clamps it to no
    /// translation), so a retire retargets the ease from wherever it currently is
    /// and reaches "no translation" within its short duration.
    static let retiredHold: CGFloat = -1

    /// Decision 12 Option B: the narrow exceptional fallback for a successful
    /// recovery. True when an Unavailable → healthy recovery has its native
    /// reading effectively at rest (at or within `nativeIndicatorClearDepth`) and
    /// no authored hold armed. A recovery whose hold was armed has a genuine lane
    /// and is acknowledged normally.
    ///
    /// What the second input is in production: the only call site is the grace
    /// fallback, which runs only while no hold has been armed, so `isHoldArmed` is
    /// always false there. An unarmed hold is NOT evidence that no lane is open —
    /// a held native lane reads ~0 while it is genuinely open, and its hold arms
    /// only on the end-of-refresh step a few milliseconds later. In production the
    /// condition is therefore a proxy: "no step was seen within `postEndGrace`".
    /// A pull a finger still holds at roughly 66 pt of drawn displacement or less
    /// after the data returns reads the same way; that is the recorded open
    /// residual for Week HQ, not something this predicate resolves.
    /// Presentation only — it decides nothing about the refresh or its data.
    nonisolated static func isExceptionalNoLaneRecovery(
        isRecovery: Bool,
        nativeDisplacement: CGFloat,
        isHoldArmed: Bool
    ) -> Bool {
        isRecovery && !isHoldArmed && nativeDisplacement <= nativeIndicatorClearDepth
    }

    /// Builds the plan for a truthful successful refresh, or `nil` when the
    /// context-bound acknowledgment rule (Decision 9) is already failed at the
    /// start — in which case there is no settle, no check, and no `Updated`, and
    /// nothing is queued or replayed.
    static func plan(
        reduceMotion: Bool,
        isHomePresented: Bool,
        ownsBandHeader: Bool
    ) -> Plan? {
        guard HomeExchangeView.shouldBeginRefreshAcknowledgment(
            isHomePresented: isHomePresented,
            ownsBandHeader: ownsBandHeader
        ) else { return nil }
        return Plan(
            startCap: reduceMotion ? reducedStartCap : standardStartCap,
            delay: reduceMotion ? reducedDelay : standardDelay,
            duration: reduceMotion ? reducedDuration : standardDuration,
            isReduced: reduceMotion,
            checkHold: reduceMotion ? reducedCheckHold : standardCheckHold
        )
    }

    // MARK: - Render-time compensation

    /// The translation added on top of the native position so the rendered
    /// displacement is `max(native, hold)`. Never negative: the settle can hold
    /// content *at* its authored displacement but never pull it above it.
    nonisolated static func compensation(nativeDisplacement: CGFloat, hold: CGFloat) -> CGFloat {
        max(0, hold - max(0, nativeDisplacement))
    }

    nonisolated static func renderedDisplacement(nativeDisplacement: CGFloat, hold: CGFloat) -> CGFloat {
        max(0, nativeDisplacement) + compensation(nativeDisplacement: nativeDisplacement, hold: hold)
    }
}

/// Holds the dynamic Home region at the authored displacement while the native
/// collapse runs underneath, then lets it ease to rest. `hold` is the animatable
/// input (so a SwiftUI animation interpolates it per frame); the native
/// displacement is read inside `visualEffect`, which is evaluated at render
/// time — so there is no state round-trip and no frame of lag between the
/// scroll view's position and the compensation.
struct HomeRefreshSettleHold: ViewModifier, Animatable {
    var hold: CGFloat
    /// Global top of the dynamic region at rest (the bottom of the stationary
    /// band). Not animated.
    let restMinY: CGFloat

    var animatableData: CGFloat {
        get { hold }
        set { hold = newValue }
    }

    func body(content: Content) -> some View {
        content.visualEffect { effect, proxy in
            // At rest (no hold, or a retired one) nothing is added, and the
            // geometry is not even read: ordinary scrolling pays nothing.
            guard hold > 0 else { return effect.offset(y: 0) }
            let native = proxy.frame(in: .global).minY - restMinY
            return effect.offset(y: HomeRefreshSettle.compensation(nativeDisplacement: native, hold: hold))
        }
    }
}

/// The settle's per-sample state machine, as a pure reference type with no view,
/// store, or timer dependency: it consumes passive displacement samples and the
/// presentation context and says what the view should do. A reference type held
/// in `@State` so that per-frame samples invalidate nothing; only the effects the
/// view performs change published state.
///
/// Stages
///   • `awaitingNativeEnd` — the refresh closure has returned. No hold exists
///     yet: until the refresh has ended, readings are lane-biased (see the file
///     header), and a hold armed from one would draw the content further from
///     rest than native does, then hop back when the bias ended. The machine
///     waits for the end-of-refresh step.
///   • `collapsing` — the first reading after that step armed the hold; the
///     content is returning to rest. The hold's ease starts once native has
///     fallen to it (immediately if it is already there; later if a finger is
///     still holding the pull).
///   • `acknowledging` — native has carried the content back to the
///     indicator-clear depth, the spinner is gone, and the check has begun.
///
/// A rise in displacement is *not* treated as a new pull before the check has
/// begun: a held or still-moving pull and the end-of-refresh step both rise, and
/// a genuinely new pull supersedes the settle when its own refresh starts. Once
/// the check is visible, a rise above the lowest displacement reached since it
/// began is a pull that must retire it so it never stacks with a new indicator.
final class HomeRefreshSettleMachine {
    enum Stage: Equatable {
        case idle
        case awaitingNativeEnd
        case collapsing
        case acknowledging
    }

    enum Effect: Equatable {
        /// Arms the hold un-animated at `start`. The check's lane center is fixed
        /// by the plan, not by this value.
        case armHold(start: CGFloat)
        /// Begins easing the armed hold to zero.
        case startEase
        /// Shows the check and posts `Updated`, together.
        case beginAcknowledgment
        /// Ends the settle and any check entirely: a suppressed acknowledgment
        /// (context lost before it began), or a pull that rises while the check
        /// is showing.
        case retire
        /// Decision 12 Option B: a successful recovery at rest with no genuinely
        /// open lane. Ends the settle with no check and no `Updated`; the data
        /// was applied normally before the settle began and is untouched.
        case endWithoutAcknowledgment
        /// Context lost after the acknowledgment began. The contract adds no rule
        /// for a begun acknowledgment, so the check finishes its own fade; only
        /// the hold — which would otherwise strand a transform under a user who
        /// has scrolled away — is released.
        case releaseHold
    }

    private(set) var stage: Stage = .idle
    private(set) var plan: HomeRefreshSettle.Plan?
    private(set) var latestDisplacement: CGFloat = 0
    private var holdStart: CGFloat = 0
    private var easeStarted = false
    private var minimumSinceAcknowledging: CGFloat = 0
    private var isRecovery = false

    /// True while a settle is waiting on, or running, the native collapse and has
    /// not yet begun its acknowledgment.
    var isAwaitingCollapse: Bool {
        stage == .awaitingNativeEnd || stage == .collapsing
    }

    /// Starts one settle, at the moment the refresh closure returns. Nothing is
    /// armed from the reading seen now: the refresh may still be active, so it may
    /// be lane-biased.
    func begin(
        plan: HomeRefreshSettle.Plan,
        ownsBandHeader: Bool,
        isHomePresented: Bool,
        isRecovery: Bool = false
    ) -> [Effect] {
        self.plan = plan
        self.isRecovery = isRecovery
        stage = .awaitingNativeEnd
        holdStart = 0
        easeStarted = false
        minimumSinceAcknowledging = 0
        return []
    }

    /// One passive displacement sample.
    func observe(
        displacement: CGFloat,
        ownsBandHeader: Bool,
        isHomePresented: Bool
    ) -> [Effect] {
        let rise = displacement - latestDisplacement
        latestDisplacement = displacement
        return evaluate(rise: rise, ownsBandHeader: ownsBandHeader, isHomePresented: isHomePresented)
    }

    /// The post-refresh grace has elapsed with no end-of-refresh step seen, so the
    /// settle stops waiting for one (see `HomeRefreshSettle.postEndGrace`).
    /// Content already at rest has no collapse to wait for: a healthy → healthy
    /// refresh begins its acknowledgment (through the same context gate), while a
    /// recovery ends with no check and no `Updated` (Decision 12 Option B). Content
    /// still displaced is handed off from as read.
    func nativeEndGraceElapsed(ownsBandHeader: Bool, isHomePresented: Bool) -> [Effect] {
        guard stage == .awaitingNativeEnd else { return [] }
        guard HomeExchangeView.shouldBeginRefreshAcknowledgment(
            isHomePresented: isHomePresented,
            ownsBandHeader: ownsBandHeader
        ) else { return [.retire] }
        guard latestDisplacement <= HomeRefreshSettle.nativeIndicatorClearDepth else {
            return arm() + advanceCollapse()
        }
        // At rest, and no end-of-refresh step seen within the grace. No hold is
        // armed in this stage, which is not by itself evidence that no lane is open
        // (see `isExceptionalNoLaneRecovery`): this is the Decision 12 Option B
        // proxy. A recovery here gets no check and no `Updated`; any other success
        // keeps its acknowledgment.
        if HomeRefreshSettle.isExceptionalNoLaneRecovery(
            isRecovery: isRecovery,
            nativeDisplacement: latestDisplacement,
            isHoldArmed: stage != .awaitingNativeEnd
        ) {
            reset()
            return [.endWithoutAcknowledgment]
        }
        stage = .acknowledging
        minimumSinceAcknowledging = latestDisplacement
        return [.beginAcknowledgment]
    }

    /// Ends the settle's monitoring. Visual cleanup is the view's.
    func reset() {
        stage = .idle
        plan = nil
        isRecovery = false
        easeStarted = false
    }

    private func evaluate(rise: CGFloat, ownsBandHeader: Bool, isHomePresented: Bool) -> [Effect] {
        let inContext = HomeExchangeView.shouldBeginRefreshAcknowledgment(
            isHomePresented: isHomePresented,
            ownsBandHeader: ownsBandHeader
        )

        switch stage {
        case .idle:
            return []

        case .awaitingNativeEnd, .collapsing:
            // Decision 9: lost before the acknowledgment begins → suppressed,
            // never queued or replayed.
            guard inContext else { return [.retire] }

            var effects: [Effect] = []
            if stage == .awaitingNativeEnd {
                // Only the step that marks the refresh ending makes readings real.
                guard rise >= HomeRefreshSettle.refreshEndStepThreshold,
                      latestDisplacement > HomeRefreshSettle.nativeIndicatorClearDepth else { return [] }
                effects = arm()
            }
            return effects + advanceCollapse()

        case .acknowledging:
            minimumSinceAcknowledging = min(minimumSinceAcknowledging, latestDisplacement)
            // The one thing the contract retires a begun check for: a repeated pull.
            if latestDisplacement > minimumSinceAcknowledging + HomeRefreshSettle.takeoverTolerance { return [.retire] }
            // Already begun: the contract states no rule for leaving context now,
            // so none is invented — the check runs its own fade.
            return inContext ? [] : [.releaseHold]
        }
    }

    /// Arms the hold from the latest reading and enters the collapse.
    private func arm() -> [Effect] {
        guard let plan else { return [] }
        holdStart = plan.holdStart(forDisplacement: latestDisplacement)
        stage = .collapsing
        return [.armHold(start: holdStart)]
    }

    /// Starts the ease once native has fallen to the hold, and the check once
    /// native has carried the content back to the indicator-clear depth.
    private func advanceCollapse() -> [Effect] {
        guard stage == .collapsing else { return [] }
        var effects: [Effect] = []
        if !easeStarted, latestDisplacement <= holdStart {
            easeStarted = true
            effects.append(.startEase)
        }
        if latestDisplacement <= HomeRefreshSettle.nativeIndicatorClearDepth {
            stage = .acknowledging
            minimumSinceAcknowledging = latestDisplacement
            effects.append(.beginAcknowledgment)
        }
        return effects
    }
}
