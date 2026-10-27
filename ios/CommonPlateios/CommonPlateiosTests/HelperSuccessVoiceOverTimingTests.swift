//
//  HelperSuccessVoiceOverTimingTests.swift
//  CommonPlateiosTests
//
// Focused W4-U1.1 proof of the 2026-10-10 VoiceOver success-timing contract:
// when VoiceOver is running at the resolve, the one automatic Home return waits
// for the matching announcement's completion (never before the 2000 ms active
// readable dwell, and bounded by an active-time ceiling), re-posts the complete
// announcement at most once with no second haptic, and still returns Home
// exactly once. VoiceOver state is read once, at the resolve.
//
// Deterministic: VoiceOver state, the announcement-finish notification center,
// and active time are all injected. This is unit proof of the gate, not
// evidence of what VoiceOver actually speaks, how long that takes, or how
// UIKit reports interruption on a device.
import Foundation
import UIKit
import XCTest
@testable import CommonPlateios

/// A private notification center that counts observer registrations, so tests
/// can prove nothing is left observing.
private final class CountingNotificationCenter: NotificationCenter {
    private let lock = NSLock()
    private var added = 0
    private var removed = 0

    var addedCount: Int { lock.withLock { added } }
    var removedCount: Int { lock.withLock { removed } }
    var liveObserverCount: Int { lock.withLock { added - removed } }

    override func addObserver(
        forName name: NSNotification.Name?,
        object obj: Any?,
        queue: OperationQueue?,
        using block: @escaping @Sendable (Notification) -> Void
    ) -> NSObjectProtocol {
        lock.withLock { added += 1 }
        return super.addObserver(forName: name, object: obj, queue: queue, using: block)
    }

    override func removeObserver(_ observer: Any) {
        lock.withLock { removed += 1 }
        super.removeObserver(observer)
    }
}

@MainActor
private final class VoiceOverTimingHarness {
    let center: CountingNotificationCenter
    let coordinator: HelperSuccessPresentationCoordinator
    var voiceOverRunning: Bool
    private(set) var voiceOverReads = 0
    /// One entry per resolve effect: the haptic and the first announcement.
    private(set) var resolves: [UUID] = []
    /// Announcement-only re-posts. Never a haptic.
    private(set) var reposts: [UUID] = []
    private(set) var homes: [UUID] = []

    init(
        voiceOverRunning: Bool,
        plan: HelperSuccessMotionPlan = .standard,
        drivesAutomatically: Bool = false
    ) {
        let center = CountingNotificationCenter()
        self.center = center
        self.voiceOverRunning = voiceOverRunning
        var resolveSink: ((UUID) -> Void)?
        var repostSink: ((UUID) -> Void)?
        var readSink: (() -> Bool)?
        coordinator = HelperSuccessPresentationCoordinator(
            performResolve: { resolveSink?($0.id) },
            planProvider: { _ in plan },
            drivesAutomatically: drivesAutomatically,
            repostAnnouncement: { repostSink?($0.id) },
            isVoiceOverRunning: { readSink?() ?? false },
            notificationCenter: center
        )
        resolveSink = { [unowned self] in resolves.append($0) }
        repostSink = { [unowned self] in reposts.append($0) }
        readSink = { [unowned self] in
            // `self.`: the property, which tests toggle — not the init argument.
            voiceOverReads += 1
            return self.voiceOverRunning
        }
        coordinator.returnHome = { [unowned self] in homes.append($0.id) }
        coordinator.updateSceneActivity(isActive: true)
    }

    func present(_ confirmation: FulfillmentConfirmation) {
        coordinator.update(confirmation: confirmation, reduceMotion: false)
    }

    /// Active time straight to the resolve (haptic + first announcement).
    func advanceToResolve(
        plan: HelperSuccessMotionPlan = .standard,
        extra: Duration = .zero
    ) {
        coordinator.advance(by: plan.ticketHold + plan.transformDuration + extra)
    }

    func advance(_ duration: Duration) {
        coordinator.advance(by: duration)
    }

    /// Delivers `announcementDidFinishNotification` the way UIKit shapes it.
    func finish(_ announcement: String, wasSuccessful: Bool = true) {
        center.post(
            name: UIAccessibility.announcementDidFinishNotification,
            object: nil,
            userInfo: [
                UIAccessibility.announcementStringValueUserInfoKey: announcement,
                UIAccessibility.announcementWasSuccessfulUserInfoKey: wasSuccessful,
            ]
        )
    }

    func announcement(for confirmation: FulfillmentConfirmation) -> String {
        HelperSuccessCopy.accessibilityAnnouncement(
            for: confirmation.kind,
            messageSuppressed: confirmation.messageSuppressed
        )
    }
}

@MainActor
final class HelperSuccessVoiceOverTimingTests: XCTestCase {
    private let plan = HelperSuccessMotionPlan.standard

    // MARK: - 1. VoiceOver off: unchanged

    func testVoiceOverOffKeepsTheTwoSecondDwellAndIgnoresAccessibilityFinishes() {
        let harness = VoiceOverTimingHarness(voiceOverRunning: false)
        let confirmation = makeConfirmation(kind: .notificationSent)
        harness.present(confirmation)
        harness.advanceToResolve()

        XCTAssertEqual(harness.resolves, [confirmation.id])
        XCTAssertEqual(harness.center.addedCount, 0, "no observation is created when VoiceOver is off")

        // A finish notification, successful or not, is irrelevant.
        harness.finish(harness.announcement(for: confirmation), wasSuccessful: false)
        harness.finish(harness.announcement(for: confirmation), wasSuccessful: true)
        harness.advance(plan.readableDwell - .milliseconds(1))
        XCTAssertTrue(harness.homes.isEmpty)
        harness.advance(.milliseconds(1))

        XCTAssertEqual(harness.homes, [confirmation.id])
        XCTAssertTrue(harness.reposts.isEmpty)
        XCTAssertEqual(harness.voiceOverReads, 1)
        XCTAssertNil(harness.coordinator.progression?.announcement)

        harness.advance(.seconds(60))
        XCTAssertEqual(harness.homes, [confirmation.id])
    }

    // MARK: - 2. VoiceOver on, fast completion

    func testFastSuccessfulCompletionDoesNotReturnHomeBeforeTheReadableDwell() {
        let harness = VoiceOverTimingHarness(voiceOverRunning: true)
        let confirmation = makeConfirmation(kind: .notificationSent)
        harness.present(confirmation)
        harness.advanceToResolve()
        XCTAssertEqual(harness.center.liveObserverCount, 1)

        harness.advance(.milliseconds(300))
        harness.finish(harness.announcement(for: confirmation))
        XCTAssertTrue(harness.homes.isEmpty, "completion alone never beats the dwell")

        harness.advance(plan.readableDwell - .milliseconds(300) - .milliseconds(1))
        XCTAssertTrue(harness.homes.isEmpty)
        harness.advance(.milliseconds(1))

        XCTAssertEqual(harness.homes, [confirmation.id])
        XCTAssertEqual(harness.center.liveObserverCount, 0)
        XCTAssertEqual(harness.resolves, [confirmation.id])
        XCTAssertTrue(harness.reposts.isEmpty)
    }

    // MARK: - 3. VoiceOver on, slow completion

    func testSlowSuccessfulCompletionHoldsHomeUntilTheAnnouncementFinishes() {
        let harness = VoiceOverTimingHarness(voiceOverRunning: true)
        let confirmation = makeConfirmation(kind: .notificationFailed)
        harness.present(confirmation)
        harness.advanceToResolve()

        harness.advance(plan.readableDwell)
        XCTAssertTrue(harness.homes.isEmpty, "the dwell elapsing alone is not enough")
        harness.advance(.seconds(4))
        XCTAssertTrue(harness.homes.isEmpty)

        harness.finish(harness.announcement(for: confirmation))
        XCTAssertEqual(harness.homes, [confirmation.id], "Home follows the completion event itself")
        XCTAssertEqual(harness.center.liveObserverCount, 0)

        // A duplicate finish, or any later time, cannot return Home again.
        harness.finish(harness.announcement(for: confirmation))
        harness.advance(.seconds(60))
        XCTAssertEqual(harness.homes, [confirmation.id])
    }

    func testEveryOrdinarySuccessVariantWaitsForItsOwnCompleteAnnouncement() {
        for kind in [FulfillmentConfirmationKind.notificationSent, .notificationFailed, .emailStatusUnknown] {
            let harness = VoiceOverTimingHarness(voiceOverRunning: true)
            let confirmation = makeConfirmation(kind: kind)
            harness.present(confirmation)
            harness.advanceToResolve(extra: plan.readableDwell + .seconds(1))
            XCTAssertTrue(harness.homes.isEmpty, "\(kind)")

            harness.finish(harness.announcement(for: confirmation))
            XCTAssertEqual(harness.homes, [confirmation.id], "\(kind)")
        }
    }

    func testSuppressedSuccessWaitsForTheWholeThreePartAnnouncement() {
        let harness = VoiceOverTimingHarness(voiceOverRunning: true)
        let confirmation = makeConfirmation(kind: .notificationSent, messageSuppressed: true)
        let full = HelperSuccessCopy.accessibilityAnnouncement(
            for: .notificationSent,
            messageSuppressed: true
        )
        XCTAssertEqual(
            full,
            "Thanks for helping someone out. Message not sent Your message didn’t meet \(AppBrand.name)’s guidelines."
        )
        harness.present(confirmation)
        harness.advanceToResolve(extra: plan.readableDwell + .seconds(1))

        // The headline alone — what the physical device was cut off after —
        // does not release the gate.
        harness.finish(HelperSuccessCopy.messageSuppressedHeadline)
        harness.finish(HelperSuccessCopy.accessibilityAnnouncement(for: .notificationSent))
        XCTAssertTrue(harness.homes.isEmpty)

        harness.finish(full)
        XCTAssertEqual(harness.homes, [confirmation.id])
    }

    // MARK: - 4. Unrelated announcement

    func testUnrelatedOrMalformedFinishNeverReleasesTheGate() {
        let harness = VoiceOverTimingHarness(voiceOverRunning: true)
        let confirmation = makeConfirmation(kind: .notificationSent)
        harness.present(confirmation)
        harness.advanceToResolve(extra: plan.readableDwell + .seconds(1))

        harness.finish("Grubhub opened", wasSuccessful: true)
        harness.finish("", wasSuccessful: true)
        harness.finish(
            HelperSuccessCopy.accessibilityAnnouncement(for: .notificationFailed),
            wasSuccessful: true
        )
        // No string, or no success flag: not a usable matching notification.
        harness.center.post(
            name: UIAccessibility.announcementDidFinishNotification,
            object: nil,
            userInfo: [UIAccessibility.announcementWasSuccessfulUserInfoKey: true]
        )
        harness.center.post(
            name: UIAccessibility.announcementDidFinishNotification,
            object: nil,
            userInfo: [UIAccessibility.announcementStringValueUserInfoKey: harness.announcement(for: confirmation)]
        )
        harness.center.post(name: UIAccessibility.announcementDidFinishNotification, object: nil)
        XCTAssertTrue(harness.homes.isEmpty)
        XCTAssertTrue(harness.reposts.isEmpty, "an unrelated failure never triggers a repost either")

        harness.finish("Grubhub opened", wasSuccessful: false)
        XCTAssertTrue(harness.reposts.isEmpty)

        harness.finish(harness.announcement(for: confirmation))
        XCTAssertEqual(harness.homes, [confirmation.id])
    }

    // MARK: - 5/6. Failed announcement and failed retry

    func testFailedAnnouncementIsRepostedOnceWithoutASecondHaptic() {
        let harness = VoiceOverTimingHarness(voiceOverRunning: true)
        let confirmation = makeConfirmation(kind: .notificationSent)
        harness.present(confirmation)
        harness.advanceToResolve()
        harness.advance(.milliseconds(500))

        harness.finish(harness.announcement(for: confirmation), wasSuccessful: false)
        XCTAssertEqual(harness.reposts, [confirmation.id])
        XCTAssertEqual(harness.resolves, [confirmation.id], "the repost never replays the haptic")
        XCTAssertTrue(harness.homes.isEmpty)
        XCTAssertEqual(harness.center.liveObserverCount, 1, "still waiting on the retry")

        harness.advance(.milliseconds(500))
        harness.finish(harness.announcement(for: confirmation), wasSuccessful: true)
        // The dwell, counted from the resolve, is the remaining rule.
        harness.advance(plan.readableDwell - .seconds(1) - .milliseconds(1))
        XCTAssertTrue(harness.homes.isEmpty)
        harness.advance(.milliseconds(1))

        XCTAssertEqual(harness.homes, [confirmation.id])
        XCTAssertEqual(harness.reposts.count, 1)
        XCTAssertEqual(harness.resolves.count, 1)
    }

    func testFailedRetryIsNotRepostedAgainAndTheCeilingReturnsHomeOnce() {
        let harness = VoiceOverTimingHarness(voiceOverRunning: true)
        let confirmation = makeConfirmation(kind: .notificationSent)
        harness.present(confirmation)
        harness.advanceToResolve()

        harness.finish(harness.announcement(for: confirmation), wasSuccessful: false)
        XCTAssertEqual(harness.reposts.count, 1)
        harness.finish(harness.announcement(for: confirmation), wasSuccessful: false)
        harness.finish(harness.announcement(for: confirmation), wasSuccessful: false)
        XCTAssertEqual(harness.reposts.count, 1, "no third post, ever")
        XCTAssertTrue(harness.homes.isEmpty)

        // The ceiling restarted from the repost, which happened at the resolve.
        harness.advance(plan.announcementCeiling - .milliseconds(1))
        XCTAssertTrue(harness.homes.isEmpty)
        harness.advance(.milliseconds(1))

        XCTAssertEqual(harness.homes, [confirmation.id])
        XCTAssertEqual(harness.reposts.count, 1)
        XCTAssertEqual(harness.resolves.count, 1)
        XCTAssertEqual(harness.center.liveObserverCount, 0)
        harness.advance(.seconds(60))
        XCTAssertEqual(harness.homes.count, 1)
    }

    func testTheCeilingRestartsFromTheRepostNotFromTheFirstPost() {
        let harness = VoiceOverTimingHarness(voiceOverRunning: true)
        let confirmation = makeConfirmation(kind: .emailStatusUnknown)
        harness.present(confirmation)
        harness.advanceToResolve()

        harness.advance(.seconds(4))
        harness.finish(harness.announcement(for: confirmation), wasSuccessful: false)
        XCTAssertEqual(harness.reposts.count, 1)

        harness.advance(plan.announcementCeiling - .milliseconds(1))
        XCTAssertTrue(harness.homes.isEmpty, "measured from the repost, not the original post")
        harness.advance(.milliseconds(1))
        XCTAssertEqual(harness.homes, [confirmation.id])
    }

    // MARK: - 7. Scene inactive mid-announcement

    func testInterruptionMidAnnouncementRepostsOnceOnResumeWithoutASecondHaptic() {
        let harness = VoiceOverTimingHarness(voiceOverRunning: true)
        let confirmation = makeConfirmation(kind: .notificationSent)
        harness.present(confirmation)
        harness.advanceToResolve()
        harness.advance(.milliseconds(500))

        harness.coordinator.updateSceneActivity(isActive: false)
        XCTAssertTrue(harness.reposts.isEmpty, "nothing is posted while inactive")
        harness.advance(.seconds(30))
        XCTAssertTrue(harness.homes.isEmpty, "inactive time is never credited")

        // The system also reports the cut-off announcement as unsuccessful.
        harness.finish(harness.announcement(for: confirmation), wasSuccessful: false)
        XCTAssertTrue(harness.reposts.isEmpty)

        harness.coordinator.updateSceneActivity(isActive: true)
        XCTAssertEqual(harness.reposts, [confirmation.id], "one repost, on resume")
        XCTAssertEqual(harness.resolves, [confirmation.id], "no second haptic")

        // The readable dwell restarts in full on resume, as before.
        harness.advance(.seconds(1))
        harness.finish(harness.announcement(for: confirmation), wasSuccessful: true)
        harness.advance(plan.readableDwell - .seconds(1) - .milliseconds(1))
        XCTAssertTrue(harness.homes.isEmpty)
        harness.advance(.milliseconds(1))

        XCTAssertEqual(harness.homes, [confirmation.id])
        XCTAssertEqual(harness.reposts.count, 1)
    }

    func testRepeatedInterruptionNeverRepostsMoreThanOnce() {
        let harness = VoiceOverTimingHarness(voiceOverRunning: true)
        let confirmation = makeConfirmation(kind: .notificationSent)
        harness.present(confirmation)
        harness.advanceToResolve()

        for _ in 0..<4 {
            harness.coordinator.updateSceneActivity(isActive: false)
            harness.advance(.seconds(5))
            harness.finish(harness.announcement(for: confirmation), wasSuccessful: false)
            harness.coordinator.updateSceneActivity(isActive: true)
            harness.advance(.seconds(1))
        }
        XCTAssertEqual(harness.reposts.count, 1, "at most two posts in total")
        XCTAssertEqual(harness.resolves.count, 1)
        XCTAssertTrue(harness.homes.isEmpty)

        // Active time still reaches the ceiling and returns Home exactly once.
        harness.advance(plan.announcementCeiling)
        XCTAssertEqual(harness.homes, [confirmation.id])
        harness.advance(.seconds(60))
        XCTAssertEqual(harness.homes.count, 1)
    }

    func testInterruptionAfterSuccessfulCompletionNeverReposts() {
        let harness = VoiceOverTimingHarness(voiceOverRunning: true)
        let confirmation = makeConfirmation(kind: .notificationSent)
        harness.present(confirmation)
        harness.advanceToResolve()
        harness.advance(.milliseconds(500))
        harness.finish(harness.announcement(for: confirmation), wasSuccessful: true)

        harness.coordinator.updateSceneActivity(isActive: false)
        harness.coordinator.updateSceneActivity(isActive: true)
        XCTAssertTrue(harness.reposts.isEmpty)

        // The dwell restarts, exactly as the non-VoiceOver path does.
        harness.advance(plan.readableDwell - .milliseconds(1))
        XCTAssertTrue(harness.homes.isEmpty)
        harness.advance(.milliseconds(1))
        XCTAssertEqual(harness.homes, [confirmation.id])
        XCTAssertEqual(harness.resolves.count, 1)
    }

    // MARK: - 8. Fallback ceiling

    func testCeilingIsAtMostTenSecondsAndAfterTheDwell() {
        for plan in [HelperSuccessMotionPlan.standard, .reducedMotion] {
            XCTAssertLessThanOrEqual(plan.announcementCeiling, .seconds(10))
            XCTAssertGreaterThan(plan.announcementCeiling, plan.readableDwell)
        }
    }

    func testAbsentFinishReturnsHomeAtTheActiveTimeCeilingOnce() {
        let harness = VoiceOverTimingHarness(voiceOverRunning: true)
        let confirmation = makeConfirmation(kind: .notificationSent)
        harness.present(confirmation)
        harness.advanceToResolve()

        harness.advance(plan.readableDwell)
        harness.advance(plan.announcementCeiling - plan.readableDwell - .milliseconds(1))
        XCTAssertTrue(harness.homes.isEmpty)

        // Inactive time does not count toward the ceiling.
        harness.coordinator.updateSceneActivity(isActive: false)
        harness.advance(.seconds(60))
        XCTAssertTrue(harness.homes.isEmpty)
        harness.coordinator.updateSceneActivity(isActive: true)
        XCTAssertEqual(harness.reposts.count, 1, "the interruption's one repost restarts the ceiling")

        harness.advance(plan.announcementCeiling - .milliseconds(1))
        XCTAssertTrue(harness.homes.isEmpty)
        harness.advance(.milliseconds(1))
        XCTAssertEqual(harness.homes, [confirmation.id])
        harness.advance(.seconds(60))
        XCTAssertEqual(harness.homes.count, 1)
    }

    func testCeilingNeverReturnsHomeBeforeTheReadableDwell() {
        var shortCeiling = HelperSuccessMotionPlan.standard
        shortCeiling.announcementCeiling = .milliseconds(500)
        let harness = VoiceOverTimingHarness(voiceOverRunning: true, plan: shortCeiling)
        let confirmation = makeConfirmation(kind: .notificationSent)
        harness.present(confirmation)
        harness.advanceToResolve(plan: shortCeiling)

        harness.advance(.milliseconds(500))
        XCTAssertTrue(harness.homes.isEmpty, "the ceiling is not a dwell shortcut")
        harness.advance(shortCeiling.readableDwell - .milliseconds(500) - .milliseconds(1))
        XCTAssertTrue(harness.homes.isEmpty)
        harness.advance(.milliseconds(1))
        XCTAssertEqual(harness.homes, [confirmation.id])
    }

    // MARK: - 9. VoiceOver toggled after the resolve

    func testVoiceOverTurnedOffAfterResolveStillWaitsForTheAnnouncement() {
        let harness = VoiceOverTimingHarness(voiceOverRunning: true)
        let confirmation = makeConfirmation(kind: .notificationSent)
        harness.present(confirmation)
        harness.advanceToResolve()

        harness.voiceOverRunning = false
        harness.advance(plan.readableDwell + .seconds(2))
        XCTAssertTrue(harness.homes.isEmpty, "the state captured at resolve owns this confirmation")

        harness.finish(harness.announcement(for: confirmation))
        XCTAssertEqual(harness.homes, [confirmation.id])
        XCTAssertEqual(harness.voiceOverReads, 1)
    }

    func testVoiceOverTurnedOnAfterResolveDoesNotAddAWait() {
        let harness = VoiceOverTimingHarness(voiceOverRunning: false)
        let confirmation = makeConfirmation(kind: .notificationSent)
        harness.present(confirmation)
        harness.advanceToResolve()

        harness.voiceOverRunning = true
        harness.advance(plan.readableDwell - .milliseconds(1))
        XCTAssertTrue(harness.homes.isEmpty)
        harness.advance(.milliseconds(1))

        XCTAssertEqual(harness.homes, [confirmation.id])
        XCTAssertEqual(harness.voiceOverReads, 1)
        XCTAssertEqual(harness.center.addedCount, 0)
    }

    func testVoiceOverIsNotReadBeforeTheResolveOrAfterIt() {
        let harness = VoiceOverTimingHarness(voiceOverRunning: true)
        let confirmation = makeConfirmation(kind: .notificationSent)
        harness.present(confirmation)
        harness.advance(plan.ticketHold + plan.transformDuration - .milliseconds(1))
        XCTAssertEqual(harness.voiceOverReads, 0)
        harness.advance(.milliseconds(1))
        XCTAssertEqual(harness.voiceOverReads, 1)
        harness.advance(.seconds(30))
        harness.coordinator.updateSceneActivity(isActive: false)
        harness.coordinator.updateSceneActivity(isActive: true)
        harness.advance(.seconds(30))
        XCTAssertEqual(harness.voiceOverReads, 1)
    }

    // MARK: - 10. Cancellation and stale notifications

    func testRetiredConfirmationLeavesNoObserverAndItsFinishIsInert() {
        let harness = VoiceOverTimingHarness(voiceOverRunning: true)
        let first = makeConfirmation(kind: .notificationSent)
        harness.present(first)
        harness.advanceToResolve()
        XCTAssertEqual(harness.center.liveObserverCount, 1)

        harness.coordinator.update(confirmation: nil, reduceMotion: false)
        XCTAssertEqual(harness.center.liveObserverCount, 0)

        harness.finish(harness.announcement(for: first))
        harness.advance(.seconds(60))
        XCTAssertTrue(harness.homes.isEmpty, "a retired confirmation never returns Home")
        XCTAssertTrue(harness.reposts.isEmpty)
    }

    func testStaleFinishFromAnEarlierConfirmationCannotReleaseALaterOne() {
        let harness = VoiceOverTimingHarness(voiceOverRunning: true)
        let first = makeConfirmation(kind: .notificationSent)
        let second = makeConfirmation(kind: .notificationFailed)
        harness.present(first)
        harness.advanceToResolve()
        let firstAnnouncement = harness.announcement(for: first)

        // The first is replaced while still waiting; the second runs its own.
        harness.present(second)
        XCTAssertEqual(harness.center.liveObserverCount, 0, "the first wait was retired")
        harness.finish(firstAnnouncement)
        harness.advanceToResolve(extra: plan.readableDwell + .seconds(1))
        XCTAssertEqual(harness.center.liveObserverCount, 1)
        XCTAssertTrue(harness.homes.isEmpty)

        // A late finish carrying the first confirmation's string is not the
        // second's announcement.
        harness.finish(firstAnnouncement)
        XCTAssertTrue(harness.homes.isEmpty)

        harness.finish(harness.announcement(for: second))
        XCTAssertEqual(harness.homes, [second.id])
        XCTAssertEqual(harness.resolves, [first.id, second.id])
        XCTAssertEqual(harness.center.liveObserverCount, 0)
    }

    func testEachConfirmationReadsVoiceOverOnceAndKeepsItsOwnGate() {
        let harness = VoiceOverTimingHarness(voiceOverRunning: true)
        let first = makeConfirmation(kind: .notificationSent)
        harness.present(first)
        harness.advanceToResolve()
        harness.finish(harness.announcement(for: first))
        harness.advance(plan.readableDwell)
        XCTAssertEqual(harness.homes, [first.id])

        harness.coordinator.update(confirmation: nil, reduceMotion: false)
        harness.voiceOverRunning = false
        let second = makeConfirmation(kind: .notificationSent)
        harness.present(second)
        harness.advanceToResolve()
        harness.advance(plan.readableDwell)

        XCTAssertEqual(harness.homes, [first.id, second.id], "its own capture: off, so no wait")
        XCTAssertEqual(harness.voiceOverReads, 2)
        XCTAssertEqual(harness.center.liveObserverCount, 0)
    }

    func testAReappearingResolvedConfirmationIsNeitherReadNorGatedAgain() {
        let harness = VoiceOverTimingHarness(voiceOverRunning: true)
        let confirmation = makeConfirmation(kind: .notificationSent)
        harness.present(confirmation)
        harness.advanceToResolve()
        harness.finish(harness.announcement(for: confirmation))
        harness.advance(plan.readableDwell)
        XCTAssertEqual(harness.homes, [confirmation.id])

        harness.coordinator.update(confirmation: nil, reduceMotion: false)
        harness.present(confirmation)
        harness.advance(plan.totalDuration + .seconds(60))

        XCTAssertEqual(harness.voiceOverReads, 1)
        XCTAssertEqual(harness.resolves, [confirmation.id])
        XCTAssertEqual(harness.homes, [confirmation.id])
        XCTAssertEqual(harness.center.liveObserverCount, 0)
    }

    func testFinishPostedOffTheMainThreadIsHandledOnTheMainActor() async throws {
        let harness = VoiceOverTimingHarness(voiceOverRunning: true)
        let confirmation = makeConfirmation(kind: .notificationSent)
        harness.present(confirmation)
        harness.advanceToResolve(extra: plan.readableDwell + .seconds(1))
        XCTAssertTrue(harness.homes.isEmpty)

        let center = harness.center
        let announcement = harness.announcement(for: confirmation)
        await Task.detached {
            center.post(
                name: UIAccessibility.announcementDidFinishNotification,
                object: nil,
                userInfo: [
                    UIAccessibility.announcementStringValueUserInfoKey: announcement,
                    UIAccessibility.announcementWasSuccessfulUserInfoKey: true,
                ]
            )
        }.value
        let deadline = Date().addingTimeInterval(3)
        while harness.homes.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(harness.homes, [confirmation.id])
    }

    // MARK: - Pure gate

    func testProgressionReadsVoiceOverOnlyAtTheResolveAndGatesOnlyTheHomeReturn() {
        var reads = 0
        var progression = HelperSuccessProgression(confirmationID: UUID(), plan: plan)
        XCTAssertEqual(
            progression.advance(by: plan.ticketHold) { reads += 1; return true },
            [.beginTransform]
        )
        XCTAssertEqual(reads, 0)
        XCTAssertNil(progression.announcement)

        XCTAssertEqual(
            progression.advance(by: plan.transformDuration + plan.readableDwell) { reads += 1; return true },
            [.resolve],
            "the dwell elapsed, but the announcement still holds Home"
        )
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(progression.isAwaitingAnnouncement)
        XCTAssertEqual(progression.phase, .dwelling)
        XCTAssertEqual(
            progression.timeUntilNextMilestone,
            plan.announcementCeiling - plan.readableDwell
        )

        progression.announcementDidFinish(wasSuccessful: true)
        XCTAssertFalse(progression.isAwaitingAnnouncement)
        XCTAssertEqual(progression.advance(by: .zero), [.returnHome])
        XCTAssertEqual(progression.phase, .finished)
        XCTAssertEqual(reads, 1)

        // A presentation released by the ceiling is no longer waiting, and
        // can no longer re-post.
        var capped = HelperSuccessProgression(confirmationID: UUID(), plan: plan)
        XCTAssertEqual(
            capped.advance(by: plan.ticketHold + plan.transformDuration) { true },
            [.beginTransform, .resolve]
        )
        XCTAssertTrue(capped.isAwaitingAnnouncement)
        capped.announcementDidFinish(wasSuccessful: false)
        XCTAssertEqual(capped.advance(by: plan.announcementCeiling), [.returnHome])
        XCTAssertFalse(capped.isAwaitingAnnouncement)
        XCTAssertFalse(capped.takeAnnouncementRepost())
    }

    func testGateBoundsRepostsAtOneAndNeverRepostsACompletedAnnouncement() {
        var gate = HelperSuccessAnnouncementGate(elapsed: .zero)
        XCTAssertFalse(gate.takeRepost(), "nothing is due")

        gate.finished(wasSuccessful: false)
        XCTAssertTrue(gate.repostIsDue)
        gate.credit(.seconds(3))
        XCTAssertTrue(gate.takeRepost())
        XCTAssertEqual(gate.elapsed, .zero, "the ceiling clock restarts from the repost")
        XCTAssertFalse(gate.takeRepost())

        gate.finished(wasSuccessful: false)
        gate.interrupted()
        XCTAssertFalse(gate.repostIsDue, "the one repost is spent")
        XCTAssertFalse(gate.takeRepost())

        var completed = HelperSuccessAnnouncementGate(elapsed: .zero)
        completed.finished(wasSuccessful: true)
        completed.interrupted()
        completed.finished(wasSuccessful: false)
        XCTAssertTrue(completed.isCompleted)
        XCTAssertFalse(completed.repostIsDue)
        XCTAssertFalse(completed.takeRepost())
    }

    // MARK: - Real driver

    /// The real driver, with tiny timings: completion releases Home at the
    /// dwell — long before the ceiling — and absence waits for the ceiling.
    func testAutomaticDriverIsEventBasedAndFallsBackAtTheCeiling() async throws {
        var tiny = HelperSuccessMotionPlan(
            ticketHold: .milliseconds(20),
            transformDuration: .milliseconds(20),
            readableDwell: .milliseconds(40),
            ticketEndScale: 1,
            mealStartScale: 1,
            copyRise: 0
        )
        tiny.announcementCeiling = .milliseconds(1_500)

        // Completion arrives promptly: Home near the dwell, far before the ceiling.
        let completed = VoiceOverTimingHarness(
            voiceOverRunning: true,
            plan: tiny,
            drivesAutomatically: true
        )
        let first = makeConfirmation(kind: .notificationSent)
        let clock = ContinuousClock()
        completed.present(first)
        let start = clock.now
        try await waitUntil { !completed.resolves.isEmpty }
        completed.finish(completed.announcement(for: first))
        try await waitUntil { !completed.homes.isEmpty }
        XCTAssertEqual(completed.homes, [first.id])
        XCTAssertLessThan(clock.now - start, .milliseconds(1_000), "event-based, not the ceiling")
        XCTAssertEqual(completed.center.liveObserverCount, 0)

        // No finish: the ceiling, and no sooner.
        let silent = VoiceOverTimingHarness(
            voiceOverRunning: true,
            plan: tiny,
            drivesAutomatically: true
        )
        let second = makeConfirmation(kind: .notificationSent)
        silent.present(second)
        let silentStart = clock.now
        try await waitUntil { !silent.resolves.isEmpty }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(silent.homes.isEmpty, "still waiting on the announcement")
        try await waitUntil { !silent.homes.isEmpty }
        XCTAssertEqual(silent.homes, [second.id])
        XCTAssertGreaterThanOrEqual(clock.now - silentStart, .milliseconds(1_450))
        XCTAssertEqual(silent.center.liveObserverCount, 0)
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeConfirmation(
        kind: FulfillmentConfirmationKind,
        messageSuppressed: Bool = false
    ) -> FulfillmentConfirmation {
        FulfillmentConfirmation(
            id: UUID(),
            requestID: "success-target",
            vendor: "Crave NYU",
            foodDescription: "Rice bowl",
            kind: kind,
            messageSuppressed: messageSuppressed
        )
    }
}
