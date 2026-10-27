//
//  HelperSuccessView.swift
//  CommonPlateios
//
// W4-H1 helper success: the brief ticket → meal presentation shown only after
// authoritative placement, followed by one automatic Home return. It is
// presentation, never lifecycle authority — `RequestStore` already ended the
// helper's active reservation before this presentation can exist, and nothing
// here (its dwell, its motion, its pauses, or its removal) decides what the
// helper may do next.
//
// Progression is active-scene aware. Only time spent while CommonPlate's scene
// is active advances the presentation, so the success haptic, the VoiceOver
// announcement, the readable dwell, and the Home return are never consumed
// while the helper cannot perceive them.
//
// W4-U1.1 (2026-10-10 VoiceOver success-timing contract): when VoiceOver is
// running at the resolve — read once per confirmation — the Home return also
// waits for the matching announcement to finish (never before the readable
// dwell, bounded by an active-time ceiling), with at most one announcement
// repost and no second haptic. Without VoiceOver the timing is unchanged. While
// that announcement is pending the combined success element stays out of the
// accessibility tree, so VoiceOver focus cannot cut the announcement short; it
// is exposed once the wait ends.
import Combine
import SwiftUI
import UIKit

/// The exact H1 success copy, keyed by the authoritative email outcome.
enum HelperSuccessCopy {
    static let headline = "Thanks for helping."

    /// Decorative gratitude line from the selected Figma motion. It carries no
    /// claim about the outcome, so it is not part of the spoken announcement.
    static let tagline = "A little good goes a long way."

    /// W4-U1.1 (2026-10-08) headline for the Message-suppressed variant only.
    static let messageSuppressedHeadline = "Thanks for helping someone out."

    /// `nil` when the email outcome is unknown: that state has a headline
    /// only. `requester` is the intentional noun for this surface.
    static func secondaryLine(for kind: FulfillmentConfirmationKind) -> String? {
        switch kind {
        case .notificationSent, .emailStatusUnknown:
            return nil
        case .notificationFailed:
            return "We couldn't email the requester."
        }
    }

    /// W4-U1.1 (2026-10-08) approved suppression card copy, shown only when the
    /// backend established that placement committed but the helper's optional
    /// Message was suppressed. The card is subordinate to the success headline.
    static let messageSuppressedCardTitle = "Message not sent"
    static let messageSuppressedCardBody =
        "Your message didn’t meet \(AppBrand.name)’s guidelines."
    /// The approved visual line break (after `meet`). Display only; the spoken
    /// and tested sentence is `messageSuppressedCardBody`.
    static let messageSuppressedCardBodyDisplay =
        "Your message didn’t meet\n\(AppBrand.name)’s guidelines."

    static func headline(messageSuppressed: Bool) -> String {
        messageSuppressed ? messageSuppressedHeadline : headline
    }

    /// The lines under the headline. In the suppression variant the moderation
    /// card is the secondary content, so there is no requester-email-status
    /// line (suppression-only; ordinary variants are exactly `secondaryLine`).
    static func supportingLines(
        for kind: FulfillmentConfirmationKind,
        messageSuppressed: Bool
    ) -> [String] {
        if messageSuppressed {
            return []
        }
        return [secondaryLine(for: kind)].compactMap { $0 }
    }

    /// One concise, truthful VoiceOver announcement: exactly the visible copy.
    static func accessibilityAnnouncement(
        for kind: FulfillmentConfirmationKind,
        messageSuppressed: Bool = false
    ) -> String {
        if messageSuppressed {
            return [
                messageSuppressedHeadline,
                messageSuppressedCardTitle,
                messageSuppressedCardBody,
            ].joined(separator: " ")
        }
        return ([headline] + supportingLines(for: kind, messageSuppressed: false))
            .joined(separator: " ")
    }
}

/// Per-process bookkeeping that makes each success presentation's two side
/// effects happen at most once per confirmation, whatever else happens to the
/// presentation. It holds no lifecycle authority and is never persisted, so a
/// relaunch can never replay a haptic or a Home return.
struct HelperSuccessPresentationLedger: Equatable {
    private(set) var successHapticConfirmationIDs: Set<UUID> = []
    private(set) var homeReturnConfirmationIDs: Set<UUID> = []

    /// `true` exactly once per confirmation: the caller fires the one
    /// semantic success haptic and announcement only when this returns `true`.
    mutating func claimSuccessHaptic(for confirmationID: UUID) -> Bool {
        successHapticConfirmationIDs.insert(confirmationID).inserted
    }

    /// `true` exactly once per confirmation: the caller applies the one
    /// automatic Home return only when this returns `true`.
    mutating func claimHomeReturn(for confirmationID: UUID) -> Bool {
        homeReturnConfirmationIDs.insert(confirmationID).inserted
    }

    func hasResolved(_ confirmationID: UUID) -> Bool {
        successHapticConfirmationIDs.contains(confirmationID)
    }
}

/// SwiftUI timing for the Faith-selected "Tiny standing ovation" (Figma
/// `1596:7322`, native 4.5 s Motion). `transformDuration` runs to the meal's
/// landing, where the single success haptic and announcement fire; the
/// headline and tagline finish entering inside the readable dwell. Offsets in
/// `HelperSuccessCelebration` are seconds from the start of the transform.
struct HelperSuccessMotionPlan: Equatable {
    /// Active time the meal-swipe ticket is shown before it transforms.
    let ticketHold: Duration
    /// The swipe-to-meal transition, ending at the primary visual resolve.
    let transformDuration: Duration
    /// Continuous active readable time after the resolve before the
    /// automatic Home return.
    let readableDwell: Duration
    let ticketEndScale: CGFloat
    let mealStartScale: CGFloat
    let copyRise: CGFloat
    /// W4-U1.1 VoiceOver success-timing contract (2026-10-10): the safety
    /// ceiling on the wait for the spoken announcement to finish, measured in
    /// active time from the announcement's post. It applies only when
    /// VoiceOver was running at the resolve and is never the normal timing
    /// mechanism — Home follows the announcement's own completion event.
    ///
    /// 9 s: the longest announcement (the suppression variant, 14 words) is
    /// estimated at roughly 6 s at VoiceOver's default speech rate, so 9 s
    /// leaves about 1.5x headroom while staying inside the accepted 10 s cap.
    /// An estimate, not a measurement: physical-device proof must record the
    /// real completion time at the normal rate against this value.
    var announcementCeiling: Duration = .seconds(9)

    static let standard = HelperSuccessMotionPlan(
        ticketHold: .milliseconds(350),
        transformDuration: .milliseconds(1000),
        readableDwell: .milliseconds(2400),
        ticketEndScale: 0.65,
        mealStartScale: 0.65,
        copyRise: 6
    )

    /// Reduce Motion: materially lower displacement — no travel, curve, or
    /// rotation — while still crossfading the ticket into the meal, so the
    /// swipe → meal meaning is preserved.
    static let reducedMotion = HelperSuccessMotionPlan(
        ticketHold: .milliseconds(350),
        transformDuration: .milliseconds(400),
        readableDwell: .milliseconds(2000),
        ticketEndScale: 1,
        mealStartScale: 1,
        copyRise: 0
    )

    static func plan(reduceMotion: Bool) -> HelperSuccessMotionPlan {
        reduceMotion ? .reducedMotion : .standard
    }

    var totalDuration: Duration {
        ticketHold + transformDuration + readableDwell
    }

    var transformSeconds: Double {
        let components = transformDuration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// W4-U1.1: the VoiceOver half of the Home gate for one confirmation. It exists
/// only when VoiceOver was running at the resolve, and then holds the Home
/// return until the spoken announcement has finished — or, as a bounded
/// fallback, until the active-time ceiling since its post. Pure: it learns of
/// the announcement's end only through `finished(wasSuccessful:)`.
struct HelperSuccessAnnouncementGate: Equatable {
    /// The complete announcement is re-posted at most once, so it is posted
    /// at most twice in total.
    static let maximumReposts = 1

    private(set) var isCompleted = false
    private(set) var repostsUsed = 0
    /// A failed or interrupted announcement is waiting for an active scene to
    /// be re-posted. Never set once the one repost has been used.
    private(set) var repostIsDue = false
    /// Active time since the announcement was last posted.
    private(set) var elapsed: Duration

    init(elapsed: Duration) {
        self.elapsed = elapsed
    }

    mutating func credit(_ activeElapsed: Duration) {
        elapsed += activeElapsed
    }

    /// The matching announcement finished. Success completes the gate; a
    /// failure makes the one repost due, if it is still unused. A failure
    /// after the repost is spent changes nothing: the ceiling decides.
    mutating func finished(wasSuccessful: Bool) {
        guard !isCompleted else { return }
        if wasSuccessful {
            isCompleted = true
            repostIsDue = false
        } else if repostsUsed < Self.maximumReposts {
            repostIsDue = true
        }
    }

    /// The scene became inactive while the announcement was still pending.
    mutating func interrupted() {
        guard !isCompleted, repostsUsed < Self.maximumReposts else { return }
        repostIsDue = true
    }

    /// `true` at most `maximumReposts` times, and only while pending and due:
    /// the caller re-posts the announcement only — never the haptic — and the
    /// ceiling clock restarts from this post.
    mutating func takeRepost() -> Bool {
        guard !isCompleted, repostIsDue, repostsUsed < Self.maximumReposts else {
            return false
        }
        repostIsDue = false
        repostsUsed += 1
        elapsed = .zero
        return true
    }

    func isReleased(ceiling: Duration) -> Bool {
        isCompleted || elapsed >= ceiling
    }
}

/// The success presentation's active-time state machine for one confirmation.
/// Pure and deterministic: it only moves when told how much *active* time has
/// passed, and it never moves backwards past the resolve.
struct HelperSuccessProgression: Equatable {
    enum Phase: Equatable {
        /// The meal-swipe ticket, before the transform.
        case ticket
        /// The swipe-to-meal transition is running.
        case transforming
        /// Resolved meal and copy; the readable dwell is running.
        case dwelling
        /// The readable dwell completed while active.
        case finished
    }

    /// Effects that become due as active time crosses each boundary.
    enum Milestone: Equatable {
        case beginTransform
        /// The primary visual resolve: the one haptic and announcement.
        case resolve
        /// The one automatic Home return.
        case returnHome
    }

    let confirmationID: UUID
    let plan: HelperSuccessMotionPlan
    private(set) var phase: Phase = .ticket
    /// Active time accumulated in the current phase.
    private(set) var phaseElapsed: Duration = .zero
    /// W4-U1.1: `nil` unless VoiceOver was running at the resolve, which is
    /// read exactly once per confirmation. When set, it alone holds the Home
    /// return beyond the readable dwell; the phases and visuals are unchanged.
    private(set) var announcement: HelperSuccessAnnouncementGate?

    init(confirmationID: UUID, plan: HelperSuccessMotionPlan) {
        self.confirmationID = confirmationID
        self.plan = plan
    }

    var hasResolved: Bool {
        phase == .dwelling || phase == .finished
    }

    /// The Home return is still waiting on the spoken announcement. `false`
    /// once the presentation has finished, by completion or by the ceiling.
    var isAwaitingAnnouncement: Bool {
        guard phase != .finished, let announcement else { return false }
        return !announcement.isCompleted
    }

    private var isAnnouncementReleased: Bool {
        announcement?.isReleased(ceiling: plan.announcementCeiling) ?? true
    }

    /// Active time remaining until the next time-driven milestone, or `nil`
    /// once finished. While an announcement is pending the Home return can
    /// also come sooner, from the announcement's completion event.
    var timeUntilNextMilestone: Duration? {
        switch phase {
        case .ticket:
            return max(.zero, plan.ticketHold - phaseElapsed)
        case .transforming:
            return max(.zero, plan.transformDuration - phaseElapsed)
        case .dwelling:
            let dwellRemaining = max(.zero, plan.readableDwell - phaseElapsed)
            guard let announcement, !announcement.isCompleted else {
                return dwellRemaining
            }
            // Never before the dwell, and otherwise at the ceiling.
            return max(
                dwellRemaining,
                max(.zero, plan.announcementCeiling - announcement.elapsed)
            )
        case .finished:
            return nil
        }
    }

    /// Credits `activeElapsed` of foreground time and returns every milestone
    /// crossed, in order. Callers only pass time that was actually active.
    ///
    /// `voiceOverRunningAtResolve` is evaluated at most once, at the moment the
    /// resolve is crossed; its answer owns this confirmation's Home timing
    /// until the presentation finishes.
    mutating func advance(
        by activeElapsed: Duration,
        voiceOverRunningAtResolve: () -> Bool = { false }
    ) -> [Milestone] {
        guard phase != .finished, activeElapsed >= .zero else { return [] }
        phaseElapsed += activeElapsed
        announcement?.credit(activeElapsed)
        var milestones: [Milestone] = []
        while true {
            switch phase {
            case .ticket where phaseElapsed >= plan.ticketHold:
                phaseElapsed -= plan.ticketHold
                phase = .transforming
                milestones.append(.beginTransform)
            case .transforming where phaseElapsed >= plan.transformDuration:
                phaseElapsed -= plan.transformDuration
                phase = .dwelling
                milestones.append(.resolve)
                if voiceOverRunningAtResolve() {
                    // Time already past the resolve counts from the post.
                    announcement = HelperSuccessAnnouncementGate(elapsed: phaseElapsed)
                }
            case .dwelling where phaseElapsed >= plan.readableDwell && isAnnouncementReleased:
                phaseElapsed = .zero
                phase = .finished
                milestones.append(.returnHome)
                return milestones
            default:
                return milestones
            }
        }
    }

    /// The matching announcement reported its end. A no-op when VoiceOver was
    /// not running at the resolve.
    mutating func announcementDidFinish(wasSuccessful: Bool) {
        announcement?.finished(wasSuccessful: wasSuccessful)
    }

    /// `true` when a failed or interrupted announcement may be re-posted now.
    /// At most once per confirmation; the caller never replays the haptic.
    mutating func takeAnnouncementRepost() -> Bool {
        guard phase != .finished else { return false }
        return announcement?.takeRepost() ?? false
    }

    /// The scene stopped being active. Nothing already perceived is undone,
    /// but nothing unperceived is kept: before the resolve the ticket and
    /// transition start over, and during the dwell the readable time starts
    /// over, so the helper always gets a complete foreground presentation.
    mutating func interrupt() {
        switch phase {
        case .ticket, .transforming:
            phase = .ticket
            phaseElapsed = .zero
        case .dwelling:
            phaseElapsed = .zero
            announcement?.interrupted()
        case .finished:
            break
        }
    }
}

/// One live `UIAccessibility.announcementDidFinishNotification` observation.
/// Owned by the coordinator for exactly as long as a confirmation is waiting
/// on its spoken announcement; invalidated explicitly when that wait ends and
/// again, as a backstop, when it is released.
private final class HelperSuccessAnnouncementObservation {
    private let center: NotificationCenter
    private var token: NSObjectProtocol?

    /// `handler` receives the finished announcement's string and whether it
    /// completed, on whichever thread the notification was posted from.
    init(
        center: NotificationCenter,
        handler: @escaping (_ announcement: String?, _ wasSuccessful: Bool?) -> Void
    ) {
        self.center = center
        token = center.addObserver(
            forName: UIAccessibility.announcementDidFinishNotification,
            object: nil,
            queue: nil
        ) { notification in
            handler(
                notification.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String,
                notification.userInfo?[UIAccessibility.announcementWasSuccessfulUserInfoKey] as? Bool
            )
        }
    }

    func invalidate() {
        if let token {
            center.removeObserver(token)
        }
        token = nil
    }

    deinit {
        invalidate()
    }
}

/// Owns the one success progression for the current confirmation, outside any
/// view, so SwiftUI view recreation and repeated store publications can
/// neither restart it nor duplicate its effects. Presentation only: it never
/// reads or writes claim, reservation, or fulfillment truth.
@MainActor
final class HelperSuccessPresentationCoordinator: ObservableObject {
    @Published private(set) var progression: HelperSuccessProgression?
    private(set) var isSceneActive = false

    /// The one automatic Home return. Installed by the view that owns
    /// navigation; retired with the presentation it performs.
    var returnHome: ((FulfillmentConfirmation) -> Void)?

    private var confirmation: FulfillmentConfirmation?
    private var ledger = HelperSuccessPresentationLedger()
    private let performResolve: (FulfillmentConfirmation) -> Void
    private let planProvider: (Bool) -> HelperSuccessMotionPlan
    private let drivesAutomatically: Bool
    private let repostAnnouncement: (FulfillmentConfirmation) -> Void
    private let isVoiceOverRunning: () -> Bool
    private let notificationCenter: NotificationCenter
    private let clock = ContinuousClock()
    private var lastTick: ContinuousClock.Instant?
    private var driver: Task<Void, Never>?
    /// Live only while the current confirmation is waiting on its spoken
    /// announcement; retired the moment that wait ends, however it ends.
    private var announcementObservation: HelperSuccessAnnouncementObservation?

    /// `drivesAutomatically: false` lets tests step active time explicitly
    /// through `advance(by:)`.
    ///
    /// W4-U1.1 seams: `isVoiceOverRunning` is read once per confirmation, at
    /// the resolve; `repostAnnouncement` posts the announcement alone (never
    /// the haptic); `notificationCenter` carries
    /// `announcementDidFinishNotification`.
    init(
        performResolve: @escaping (FulfillmentConfirmation) -> Void = HelperSuccessPresentationCoordinator.productionResolve,
        planProvider: @escaping (Bool) -> HelperSuccessMotionPlan = HelperSuccessMotionPlan.plan(reduceMotion:),
        drivesAutomatically: Bool = true,
        repostAnnouncement: @escaping (FulfillmentConfirmation) -> Void = HelperSuccessPresentationCoordinator.productionAnnounce,
        isVoiceOverRunning: @escaping () -> Bool = { UIAccessibility.isVoiceOverRunning },
        notificationCenter: NotificationCenter = .default
    ) {
        self.performResolve = performResolve
        self.planProvider = planProvider
        self.drivesAutomatically = drivesAutomatically
        self.repostAnnouncement = repostAnnouncement
        self.isVoiceOverRunning = isVoiceOverRunning
        self.notificationCenter = notificationCenter
    }

    /// The exactly-once resolve effects: one semantic success haptic and one
    /// concise VoiceOver announcement.
    static func productionResolve(_ confirmation: FulfillmentConfirmation) {
        CommonPlateHaptics.success()
        productionAnnounce(confirmation)
    }

    /// The complete announcement alone. The only VoiceOver post of this
    /// presentation; also what a bounded repost sends.
    static func productionAnnounce(_ confirmation: FulfillmentConfirmation) {
        UIAccessibility.post(
            notification: .announcement,
            argument: HelperSuccessCopy.accessibilityAnnouncement(
                for: confirmation.kind,
                messageSuppressed: confirmation.messageSuppressed
            )
        )
    }

    /// W4-U1.1: `true` while `confirmationID`'s explicit VoiceOver
    /// announcement is still pending — from the resolve until the matching
    /// announcement completes or the presentation finishes (including the
    /// ceiling). Always `false` when VoiceOver was not running at the resolve
    /// and for any other confirmation. The view uses it to keep the combined
    /// success element from becoming a competing focus target meanwhile.
    func isAnnouncementPending(for confirmationID: UUID) -> Bool {
        guard let progression, progression.confirmationID == confirmationID else {
            return false
        }
        return progression.isAwaitingAnnouncement
    }

    /// Mirrors the store's current confirmation. Idempotent for the same
    /// confirmation, so repeated publications never restart the sequence; a
    /// different confirmation starts its own; `nil` retires the presentation.
    func update(confirmation newConfirmation: FulfillmentConfirmation?, reduceMotion: Bool) {
        guard let newConfirmation else {
            confirmation = nil
            progression = nil
            endAnnouncementObservation()
            stopDriver()
            return
        }
        guard newConfirmation.id != confirmation?.id else { return }
        // A previous confirmation's wait can never be observed by this one.
        endAnnouncementObservation()
        confirmation = newConfirmation
        progression = HelperSuccessProgression(
            confirmationID: newConfirmation.id,
            plan: planProvider(reduceMotion)
        )
        restartDriver()
    }

    /// Scene activity is the only thing that lets active time count. Becoming
    /// inactive interrupts the progression before any time can be credited;
    /// becoming active starts counting from that moment, never from before.
    func updateSceneActivity(isActive: Bool) {
        guard isActive != isSceneActive else { return }
        isSceneActive = isActive
        if isActive {
            // An announcement the interruption cut short is re-posted once,
            // before the active-time wait restarts from that post.
            postDueAnnouncementRepost()
            restartDriver()
        } else {
            stopDriver()
            progression?.interrupt()
        }
    }

    /// Credits active time and applies any due effects exactly once. Ignored
    /// while inactive.
    func advance(by activeElapsed: Duration) {
        guard isSceneActive,
              var current = progression,
              let confirmation,
              current.confirmationID == confirmation.id else {
            return
        }
        // VoiceOver is read once per confirmation, at the resolve; a
        // confirmation that already resolved is never read, or gated, again.
        let alreadyResolved = ledger.hasResolved(confirmation.id)
        let milestones = current.advance(by: activeElapsed) { [isVoiceOverRunning] in
            !alreadyResolved && isVoiceOverRunning()
        }
        progression = current
        for milestone in milestones {
            switch milestone {
            case .beginTransform:
                break
            case .resolve:
                if ledger.claimSuccessHaptic(for: confirmation.id) {
                    // Observe before posting, so no finish can be missed.
                    if current.isAwaitingAnnouncement {
                        observeAnnouncementFinish(for: confirmation)
                    }
                    performResolve(confirmation)
                }
            case .returnHome:
                endAnnouncementObservation()
                if let returnHome, ledger.claimHomeReturn(for: confirmation.id) {
                    returnHome(confirmation)
                }
            }
        }
        if progression?.phase == .finished {
            stopDriver()
        }
    }

    // MARK: - VoiceOver announcement completion (W4-U1.1)

    private func observeAnnouncementFinish(for confirmation: FulfillmentConfirmation) {
        endAnnouncementObservation()
        let confirmationID = confirmation.id
        let expected = HelperSuccessCopy.accessibilityAnnouncement(
            for: confirmation.kind,
            messageSuppressed: confirmation.messageSuppressed
        )
        announcementObservation = HelperSuccessAnnouncementObservation(
            center: notificationCenter
        ) { [weak self] announcement, wasSuccessful in
            // Only a finish for this confirmation's own announcement string
            // counts; any other announcement is ignored.
            guard announcement == expected, let wasSuccessful else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.announcementDidFinish(
                        confirmationID: confirmationID,
                        wasSuccessful: wasSuccessful
                    )
                }
            } else {
                Task { @MainActor in
                    self?.announcementDidFinish(
                        confirmationID: confirmationID,
                        wasSuccessful: wasSuccessful
                    )
                }
            }
        }
    }

    private func endAnnouncementObservation() {
        announcementObservation?.invalidate()
        announcementObservation = nil
    }

    private func announcementDidFinish(confirmationID: UUID, wasSuccessful: Bool) {
        guard announcementObservation != nil,
              confirmation?.id == confirmationID else {
            return
        }
        // Bring the active-time clocks current first, so a ceiling or dwell
        // that has already elapsed is honored before this event is applied.
        if drivesAutomatically, isSceneActive, lastTick != nil {
            tick()
        }
        guard var current = progression,
              current.confirmationID == confirmationID,
              current.isAwaitingAnnouncement else {
            return
        }
        current.announcementDidFinish(wasSuccessful: wasSuccessful)
        progression = current
        if wasSuccessful {
            endAnnouncementObservation()
            // Home now if the readable dwell is already complete; otherwise
            // at the dwell's end.
            advance(by: .zero)
        } else {
            postDueAnnouncementRepost()
        }
        if progression?.phase != .finished {
            restartDriver()
        }
    }

    /// Re-posts the complete announcement — never the haptic — when a failed
    /// or interrupted one is due and the scene is active. The progression
    /// allows this at most once per confirmation.
    private func postDueAnnouncementRepost() {
        guard isSceneActive,
              let confirmation,
              var current = progression,
              current.confirmationID == confirmation.id,
              current.takeAnnouncementRepost() else {
            return
        }
        progression = current
        repostAnnouncement(confirmation)
    }

    private func restartDriver() {
        stopDriver()
        guard drivesAutomatically,
              isSceneActive,
              let progression,
              progression.phase != .finished else {
            return
        }
        lastTick = clock.now
        driver = Task { [weak self] in
            while !Task.isCancelled {
                guard let wait = self?.progression?.timeUntilNextMilestone else { return }
                do {
                    try await Task.sleep(for: wait)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        let now = clock.now
        let elapsed = now - (lastTick ?? now)
        lastTick = now
        advance(by: elapsed)
    }

    private func stopDriver() {
        driver?.cancel()
        driver = nil
        lastTick = nil
    }
}

/// Renders a success progression. Holds no progression state of its own, so
/// recreating it can neither restart the sequence nor replay its effects.
struct HelperSuccessView: View {
    let confirmation: FulfillmentConfirmation
    let phase: HelperSuccessProgression.Phase
    let reduceMotion: Bool
    /// W4-U1.1: the explicit VoiceOver announcement is still pending. While it
    /// is, the combined success element stays out of the accessibility tree so
    /// VoiceOver cannot move focus onto it and cut the announcement short; it
    /// is exposed again once the wait ends. Never set without VoiceOver.
    var isAnnouncementPending: Bool = false

    @State private var isVisible = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var plan: HelperSuccessMotionPlan {
        HelperSuccessMotionPlan.plan(reduceMotion: reduceMotion)
    }

    private var isTransformed: Bool {
        phase != .ticket
    }

    private var hasResolved: Bool {
        phase == .dwelling || phase == .finished
    }

    /// The combined success element is unavailable to accessibility before the
    /// resolve and, with VoiceOver running, while the explicit announcement is
    /// pending (W4-U1.1). Temporary: the element is never removed for good.
    static func hidesSuccessContentFromAccessibility(
        phase: HelperSuccessProgression.Phase,
        isAnnouncementPending: Bool
    ) -> Bool {
        let resolved = phase == .dwelling || phase == .finished
        return !resolved || isAnnouncementPending
    }

    private var transformAnimation: Animation {
        .timingCurve(0.3, 0, 0.2, 1, duration: plan.transformSeconds)
    }

    /// Reduce Motion keeps the short crossfade and shows the copy with it.
    private var copyAnimation: Animation {
        reduceMotion
            ? transformAnimation
            : .timingCurve(0.16, 1, 0.3, 1, duration: HelperSuccessCelebration.copyDuration)
                .delay(HelperSuccessCelebration.copyDelay)
    }

    /// Suppression variant at an accessibility text size: the taller, wider
    /// card plus the full-size motif can exceed a short iPhone's height, so only
    /// decorative height gives way (full motif, then half size, then none).
    /// Text keeps its full Dynamic Type size and is never truncated.
    private var usesAccessibilitySuppressionLayout: Bool {
        confirmation.messageSuppressed && dynamicTypeSize.isAccessibilitySize
    }

    @ViewBuilder
    private var successContent: some View {
        if usesAccessibilitySuppressionLayout {
            ViewThatFits(in: .vertical) {
                successStack(motifSize: 96, spacing: 22, compact: false)
                successStack(motifSize: 48, spacing: 12, compact: false)
                successStack(motifSize: nil, spacing: 0, compact: true)
            }
        } else {
            successStack(motifSize: 96, spacing: 22, compact: false)
        }
    }

    @ViewBuilder
    private func successStack(motifSize: CGFloat?, spacing: CGFloat, compact: Bool) -> some View {
        VStack(spacing: spacing) {
            if let motifSize {
                motif
                    .scaleEffect(motifSize / 96)
                    .frame(width: motifSize, height: motifSize)
            }

            VStack(spacing: compact ? 4 : 10) {
                Text(HelperSuccessCopy.headline(messageSuppressed: confirmation.messageSuppressed))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    // Suppression variant only: the taller accessibility-size
                    // card must not squeeze the headline into an ellipsis.
                    .fixedSize(horizontal: false, vertical: confirmation.messageSuppressed)
                    .accessibilityIdentifier("helper-success-headline")

                if !confirmation.messageSuppressed {
                    Text(HelperSuccessCopy.tagline)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(CommonPlateStyle.Color.brandText)
                        .accessibilityHidden(true)
                        .accessibilityIdentifier("helper-success-tagline")
                }

                // Without suppression this is exactly the one existing
                // requester-email line (or nothing). With suppression the
                // subordinate moderation card replaces it. No control is
                // added and the automatic Home return is unchanged.
                if confirmation.messageSuppressed {
                    messageSuppressedCard(compact: compact)
                        .padding(.top, compact ? 0 : 6)
                } else {
                    ForEach(
                        Array(
                            HelperSuccessCopy.supportingLines(
                                for: confirmation.kind,
                                messageSuppressed: false
                            ).enumerated()
                        ),
                        id: \.offset
                    ) { _, line in
                        Text(line)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("helper-success-secondary")
                    }
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: CommonPlateStyle.Metrics.stateContentWidth)
            .opacity(isTransformed ? 1 : 0)
            .offset(y: isTransformed ? 0 : plan.copyRise)
            .animation(copyAnimation, value: isTransformed)
            .accessibilityElement(children: .combine)
            .accessibilityHidden(
                Self.hidesSuccessContentFromAccessibility(
                    phase: phase,
                    isAnnouncementPending: isAnnouncementPending
                )
            )
        }
    }

    var body: some View {
        ZStack {
            CommonPlateStyle.Color.baseCanvas
                .ignoresSafeArea()

            successContent
                .padding(.horizontal, CommonPlateStyle.Metrics.settingsPageInset)
                // The approved composition sits a little above the geometric center.
                // The taller accessibility-size suppression card needs that room back.
                .padding(
                    .bottom,
                    usesAccessibilitySuppressionLayout ? 0 : 60
                )
        }
        .opacity(isVisible ? 1 : 0)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("helper-success")
        .onAppear {
            // A focused Helping-page field must not leave its keyboard over
            // the presentation.
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
            withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.22)) {
                isVisible = true
            }
        }
    }

    /// Compact, centered, soft-red moderation card (Figma `885:5652`, card
    /// `1070:7082`): 272 pt wide, 12 pt horizontal / 10 pt vertical padding,
    /// 3 pt content gap, 13 pt corners, `#D64045` 1 pt border on a `#FFF7F7`
    /// surface; a 16 pt icon and 14 pt semibold title centered together (8 pt
    /// gap, 18 pt line), the 13 pt regular body centered beneath (18 pt line).
    /// Sizes scale with Dynamic Type from their Figma values at the default size.
    ///
    /// At accessibility text sizes the scaled icon and a single word of the
    /// title no longer fit together in the fixed 272 pt card, which ellipsized
    /// the title and broke the body mid-word. There the icon stacks above the
    /// title and the card takes the available content width instead of the
    /// fixed width; wrapping and height are free to differ from the default.
    private func messageSuppressedCard(compact: Bool) -> some View {
        // Last-resort short-screen variant: only the decorative icon is capped.
        let icon = compact ? min(iconSize, 24) : iconSize
        let accessibilityLayout = dynamicTypeSize.isAccessibilitySize
        let titleLayout = accessibilityLayout
            ? AnyLayout(VStackLayout(spacing: 3))
            : AnyLayout(HStackLayout(spacing: 8))
        return VStack(spacing: 3) {
            titleLayout {
                Image(systemName: "info.circle")
                    .font(.system(size: icon))
                    .frame(width: icon, height: icon)
                    .accessibilityHidden(true)
                Text(HelperSuccessCopy.messageSuppressedCardTitle)
                    .font(.system(size: titleSize, weight: .semibold))
                    .lineSpacing(titleLine - titleSize * Self.systemLineFactor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(HelperSuccessCopy.messageSuppressedCardBodyDisplay)
                .font(.system(size: bodySize))
                .lineSpacing(bodyLine - bodySize * Self.systemLineFactor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Self.moderationContent)
        .multilineTextAlignment(.center)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(width: accessibilityLayout ? nil : 272)
        .frame(maxWidth: accessibilityLayout ? .infinity : nil)
        .background(
            Self.moderationSurface,
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Self.moderationContent, lineWidth: 1)
        }
        .accessibilityIdentifier("helper-success-message-suppressed")
    }

    // Figma `#D64045` / `#FFF7F7`, with the same dark-mode counterparts as the
    // requester moderation notice.
    private static let moderationContent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 240 / 255, green: 130 / 255, blue: 135 / 255, alpha: 1)
            : UIColor(red: 214 / 255, green: 64 / 255, blue: 69 / 255, alpha: 1)
    })
    private static let moderationSurface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 214 / 255, green: 64 / 255, blue: 69 / 255, alpha: 0.16)
            : UIColor(red: 255 / 255, green: 247 / 255, blue: 247 / 255, alpha: 1)
    })
    /// Approximate natural line height of the system font as a multiple of its
    /// point size, used to reach the Figma 18 pt lines.
    private static let systemLineFactor: CGFloat = 1.19

    @ScaledMetric(relativeTo: .footnote) private var iconSize: CGFloat = 16
    @ScaledMetric(relativeTo: .footnote) private var titleSize: CGFloat = 14
    @ScaledMetric(relativeTo: .footnote) private var bodySize: CGFloat = 13
    @ScaledMetric(relativeTo: .footnote) private var titleLine: CGFloat = 18
    @ScaledMetric(relativeTo: .footnote) private var bodyLine: CGFloat = 18

    @ViewBuilder
    private var motif: some View {
        ZStack {
            HelperSuccessHalo(isTransformed: isTransformed, reduceMotion: reduceMotion)
            if !reduceMotion {
                HelperSuccessCelebrationDots(isTransformed: isTransformed)
            }

            ticket
                .scaleEffect(isTransformed ? plan.ticketEndScale : 1)
                .animation(
                    reduceMotion
                        ? transformAnimation
                        : .easeIn(duration: HelperSuccessCelebration.ticketShrink),
                    value: isTransformed
                )
                .opacity(isTransformed ? 0 : 1)
                .animation(
                    reduceMotion
                        ? transformAnimation
                        : .easeIn(duration: HelperSuccessCelebration.ticketFade)
                            .delay(HelperSuccessCelebration.ticketFadeDelay),
                    value: isTransformed
                )

            meal
                .scaleEffect(isTransformed ? 1 : plan.mealStartScale)
                .animation(
                    reduceMotion
                        ? transformAnimation
                        : .spring(duration: 0.4, bounce: 0.2)
                            .delay(HelperSuccessCelebration.mealDelay),
                    value: isTransformed
                )
                .opacity(isTransformed ? 1 : 0)
                .animation(
                    reduceMotion
                        ? transformAnimation
                        : .easeOut(duration: HelperSuccessCelebration.mealFade)
                            .delay(HelperSuccessCelebration.mealDelay),
                    value: isTransformed
                )
        }
    }

    /// Template-rendered so the adaptive `AccentColor` supplies the correct
    /// purple in light and dark appearance, exactly like the existing
    /// `TicketToMealMotif`. The Figma geometry is unchanged.
    private var ticket: some View {
        Image("HelperSuccessTicket")
            .renderingMode(.template)
            .foregroundStyle(Color.accentColor)
            .accessibilityHidden(true)
    }

    private var meal: some View {
        Image("HelperSuccessMeal")
            .renderingMode(.template)
            .foregroundStyle(Color.accentColor)
            .accessibilityHidden(true)
    }
}

/// Faith-selected "Tiny standing ovation" timings (Figma `1596:7322`), in
/// seconds from the start of the transform.
enum HelperSuccessCelebration {
    static let ticketShrink = 0.64
    static let ticketFadeDelay = 0.52
    static let ticketFade = 0.18
    static let mealDelay = 0.64
    static let mealFade = 0.22
    static let haloDelay = 0.65
    static let haloDuration = 1.05
    static let dotDelay = 0.8
    static let dotTravel = 0.6
    static let dotFadeOutDelay = 1.3
    static let dotFadeOut = 0.5
    static let copyDelay = 1.02
    static let copyDuration = 0.42

    static let warmGold = Color(red: 189 / 255, green: 141 / 255, blue: 70 / 255)
}

/// Quiet warm halo behind the ticket and meal.
private struct HelperSuccessHalo: View {
    let isTransformed: Bool
    let reduceMotion: Bool

    var body: some View {
        Circle()
            .fill(CommonPlateStyle.Color.brandFill.opacity(0.10))
            .frame(width: 143, height: 143)
            .opacity(isTransformed ? 1 : 0)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.4)
                    : .timingCurve(0.16, 1, 0.3, 1, duration: HelperSuccessCelebration.haloDuration)
                        .delay(HelperSuccessCelebration.haloDelay),
                value: isTransformed
            )
            .accessibilityHidden(true)
    }
}

/// Eight small warm dots and two sparkles that burst outward once as the meal
/// lands, then fade. Decorative, hidden from accessibility, and omitted under
/// Reduce Motion.
private struct HelperSuccessCelebrationDots: View {
    let isTransformed: Bool
    @State private var isOut = false
    @State private var isVisible = false

    private static let dots: [(CGSize, CGFloat)] = [
        (CGSize(width: -55, height: 58), 3), (CGSize(width: 5, height: 71), 4),
        (CGSize(width: 62, height: 54), 3), (CGSize(width: 87, height: 15), 4),
        (CGSize(width: 68, height: -25), 3), (CGSize(width: 14, height: -46), 4),
        (CGSize(width: -47, height: -37), 3), (CGSize(width: -84, height: -3), 4),
    ]

    var body: some View {
        ZStack {
            ForEach(Self.dots.indices, id: \.self) { index in
                Circle()
                    .fill(HelperSuccessCelebration.warmGold)
                    .frame(width: Self.dots[index].1, height: Self.dots[index].1)
                    .offset(isOut ? Self.dots[index].0 : .zero)
            }
            Text("✦").font(.system(size: 12, weight: .semibold))
                .offset(x: -78, y: -34)
                .scaleEffect(isOut ? 1 : 0.2)
            Text("✦").font(.system(size: 10, weight: .semibold))
                .offset(x: 90, y: -39)
                .scaleEffect(isOut ? 1 : 0.2)
        }
        .foregroundStyle(HelperSuccessCelebration.warmGold.opacity(0.78))
        .opacity(isVisible ? 0.65 : 0)
        .accessibilityHidden(true)
        .onChange(of: isTransformed) { _, transformed in
            guard transformed else { return }
            withAnimation(
                .timingCurve(0.16, 1, 0.3, 1, duration: HelperSuccessCelebration.dotTravel)
                    .delay(HelperSuccessCelebration.dotDelay)
            ) { isOut = true }
            withAnimation(.easeOut(duration: 0.13).delay(HelperSuccessCelebration.dotDelay)) {
                isVisible = true
            }
            withAnimation(
                .easeIn(duration: HelperSuccessCelebration.dotFadeOut)
                    .delay(HelperSuccessCelebration.dotFadeOutDelay)
            ) { isVisible = false }
        }
    }
}
