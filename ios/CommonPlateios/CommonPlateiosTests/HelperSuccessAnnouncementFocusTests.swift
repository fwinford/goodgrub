//
//  HelperSuccessAnnouncementFocusTests.swift
//  CommonPlateiosTests
//
// Focused W4-U1.1 proof of the VoiceOver focus-overlap correction. A physical
// device run showed that exposing the combined success element while the
// explicit announcement was still speaking made VoiceOver move focus onto it,
// which cut the announcement short (`wasSuccessful == false`) and spent the one
// allowed repost. While the announcement is pending the combined element must
// therefore stay out of the accessibility tree, and it must come back once the
// wait ends — never be removed for good — with no timing, repost, haptic, or
// Home change.
//
// Deterministic: VoiceOver state, the finish-notification center, and active
// time are injected. The hosted test reads the real view's accessibility tree
// in the simulator. Neither is evidence of what VoiceOver actually moves focus
// to or speaks on a device; that remains physical-device proof.
import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

@MainActor
final class HelperSuccessAnnouncementFocusTests: XCTestCase {
    private let plan = HelperSuccessMotionPlan.standard

    private final class Effects {
        var voiceOverRunning: Bool
        var resolves: [UUID] = []
        var reposts: [UUID] = []
        var homes: [UUID] = []

        init(voiceOverRunning: Bool) {
            self.voiceOverRunning = voiceOverRunning
        }
    }

    @MainActor
    private struct Rig {
        let coordinator: HelperSuccessPresentationCoordinator
        let center: NotificationCenter
        let effects: Effects
        let confirmation: FulfillmentConfirmation

        var phase: HelperSuccessProgression.Phase {
            coordinator.progression?.phase ?? .ticket
        }

        var isPending: Bool {
            coordinator.isAnnouncementPending(for: confirmation.id)
        }

        /// What `ContentView` hands the view, run through the view's own rule.
        var isHiddenFromAccessibility: Bool {
            HelperSuccessView.hidesSuccessContentFromAccessibility(
                phase: phase,
                isAnnouncementPending: isPending
            )
        }

        func advance(_ duration: Duration) {
            coordinator.advance(by: duration)
        }

        func finish(wasSuccessful: Bool) {
            center.post(
                name: UIAccessibility.announcementDidFinishNotification,
                object: nil,
                userInfo: [
                    UIAccessibility.announcementStringValueUserInfoKey:
                        HelperSuccessCopy.accessibilityAnnouncement(
                            for: confirmation.kind,
                            messageSuppressed: confirmation.messageSuppressed
                        ),
                    UIAccessibility.announcementWasSuccessfulUserInfoKey: wasSuccessful,
                ]
            )
        }
    }

    private func makeRig(
        voiceOverRunning: Bool,
        messageSuppressed: Bool = true
    ) -> Rig {
        let effects = Effects(voiceOverRunning: voiceOverRunning)
        let center = NotificationCenter()
        let plan = plan
        let coordinator = HelperSuccessPresentationCoordinator(
            performResolve: { effects.resolves.append($0.id) },
            planProvider: { _ in plan },
            drivesAutomatically: false,
            repostAnnouncement: { effects.reposts.append($0.id) },
            isVoiceOverRunning: { effects.voiceOverRunning },
            notificationCenter: center
        )
        coordinator.returnHome = { effects.homes.append($0.id) }
        coordinator.updateSceneActivity(isActive: true)

        let confirmation = FulfillmentConfirmation(
            id: UUID(),
            requestID: "success-target",
            vendor: "Crave NYU",
            foodDescription: "Rice bowl",
            kind: .notificationSent,
            messageSuppressed: messageSuppressed
        )
        coordinator.update(confirmation: confirmation, reduceMotion: false)
        return Rig(
            coordinator: coordinator,
            center: center,
            effects: effects,
            confirmation: confirmation
        )
    }

    private func advanceToResolve(_ rig: Rig, extra: Duration = .zero) {
        rig.advance(plan.ticketHold + plan.transformDuration + extra)
    }

    // MARK: - 1. Pending announcement hides the combined element

    func testSuccessContentIsHiddenBeforeResolveAndWhileTheAnnouncementIsPending() {
        let rig = makeRig(voiceOverRunning: true)
        XCTAssertEqual(rig.phase, .ticket)
        XCTAssertTrue(rig.isHiddenFromAccessibility)
        XCTAssertFalse(rig.isPending, "no announcement exists before the resolve")

        rig.advance(plan.ticketHold)
        XCTAssertEqual(rig.phase, .transforming)
        XCTAssertTrue(rig.isHiddenFromAccessibility)
        XCTAssertFalse(rig.isPending)

        rig.advance(plan.transformDuration)
        XCTAssertEqual(rig.phase, .dwelling)
        XCTAssertEqual(rig.effects.resolves, [rig.confirmation.id], "one haptic + announcement")
        XCTAssertNotNil(rig.coordinator.progression?.announcement, "the completion gate is installed")
        XCTAssertTrue(rig.isPending)
        XCTAssertTrue(
            rig.isHiddenFromAccessibility,
            "resolved visually, but the announcement is still pending: not a competing focus target"
        )

        rig.advance(plan.readableDwell)
        XCTAssertTrue(rig.isPending, "the dwell elapsing does not release the accessibility gate")
        XCTAssertTrue(rig.isHiddenFromAccessibility)
        XCTAssertTrue(rig.effects.homes.isEmpty)
    }

    // MARK: - 2 + 6. Successful completion restores it; Home timing unchanged

    func testFastSuccessfulCompletionExposesTheContentForTheRemainingDwellOnly() {
        let rig = makeRig(voiceOverRunning: true)
        advanceToResolve(rig)
        rig.advance(.milliseconds(300))
        XCTAssertTrue(rig.isHiddenFromAccessibility)

        rig.finish(wasSuccessful: true)
        XCTAssertFalse(rig.isPending)
        XCTAssertFalse(rig.isHiddenFromAccessibility, "restored, not permanently hidden")
        XCTAssertTrue(rig.effects.homes.isEmpty, "completion alone never beats the readable dwell")

        rig.advance(plan.readableDwell - .milliseconds(300) - .milliseconds(1))
        XCTAssertTrue(rig.effects.homes.isEmpty)
        XCTAssertFalse(rig.isHiddenFromAccessibility)

        rig.advance(.milliseconds(1))
        XCTAssertEqual(rig.effects.homes, [rig.confirmation.id])
        XCTAssertEqual(rig.phase, .finished)
        XCTAssertFalse(rig.isHiddenFromAccessibility)
        XCTAssertEqual(rig.effects.resolves, [rig.confirmation.id])
        XCTAssertTrue(rig.effects.reposts.isEmpty)
    }

    // MARK: - 7. Slow completion after the dwell

    func testSlowCompletionKeepsTheContentHiddenUntilTheEventAndHomeFollowsOnce() {
        let rig = makeRig(voiceOverRunning: true)
        advanceToResolve(rig, extra: plan.readableDwell + .seconds(1))
        XCTAssertTrue(rig.isHiddenFromAccessibility)
        rig.advance(.seconds(3))
        XCTAssertTrue(rig.isHiddenFromAccessibility)
        XCTAssertTrue(rig.effects.homes.isEmpty)

        rig.finish(wasSuccessful: true)
        XCTAssertEqual(rig.effects.homes, [rig.confirmation.id], "Home follows the completion event itself")
        XCTAssertFalse(rig.isHiddenFromAccessibility)

        rig.finish(wasSuccessful: true)
        rig.advance(.seconds(60))
        XCTAssertEqual(rig.effects.homes, [rig.confirmation.id], "no second Home")
        XCTAssertEqual(rig.effects.resolves, [rig.confirmation.id])
    }

    // MARK: - 3. Failed initial announcement and the one repost

    func testTheContentStaysHiddenAcrossAFailedAnnouncementAndItsRepost() {
        let rig = makeRig(voiceOverRunning: true)
        advanceToResolve(rig)
        rig.advance(.milliseconds(800))
        XCTAssertTrue(rig.isHiddenFromAccessibility)

        rig.finish(wasSuccessful: false)
        XCTAssertEqual(rig.effects.reposts, [rig.confirmation.id], "the one allowed repost")
        XCTAssertTrue(rig.isPending, "a failed first announcement is not a completed one")
        XCTAssertTrue(rig.isHiddenFromAccessibility, "no re-exposure between the failure and the repost")

        rig.advance(.seconds(1))
        XCTAssertTrue(rig.isHiddenFromAccessibility)
        XCTAssertTrue(rig.effects.homes.isEmpty)

        rig.finish(wasSuccessful: true)
        XCTAssertFalse(rig.isPending)
        XCTAssertFalse(rig.isHiddenFromAccessibility)
        XCTAssertEqual(rig.effects.resolves, [rig.confirmation.id], "no second haptic")
        XCTAssertEqual(rig.effects.reposts.count, 1)

        rig.advance(.seconds(30))
        XCTAssertEqual(rig.effects.homes, [rig.confirmation.id])
    }

    func testAnInterruptionKeepsTheContentHiddenUntilTheRepostCompletes() {
        let rig = makeRig(voiceOverRunning: true)
        advanceToResolve(rig)
        rig.advance(.milliseconds(500))

        rig.coordinator.updateSceneActivity(isActive: false)
        XCTAssertTrue(rig.isPending)
        XCTAssertTrue(rig.isHiddenFromAccessibility)

        rig.coordinator.updateSceneActivity(isActive: true)
        XCTAssertEqual(rig.effects.reposts, [rig.confirmation.id])
        XCTAssertTrue(rig.isHiddenFromAccessibility)

        rig.finish(wasSuccessful: true)
        XCTAssertFalse(rig.isHiddenFromAccessibility)
        XCTAssertEqual(rig.effects.resolves, [rig.confirmation.id])
    }

    // MARK: - 4. Fallback ceiling

    func testTheCeilingReleasesTheGateWithTheTerminalProgressionAndHomeStaysOnce() {
        let rig = makeRig(voiceOverRunning: true)
        advanceToResolve(rig)
        rig.finish(wasSuccessful: false)
        XCTAssertEqual(rig.effects.reposts, [rig.confirmation.id])
        rig.finish(wasSuccessful: false)
        XCTAssertEqual(rig.effects.reposts.count, 1, "the repost is spent")

        rig.advance(plan.announcementCeiling - .milliseconds(1))
        XCTAssertTrue(rig.isHiddenFromAccessibility)
        XCTAssertTrue(rig.effects.homes.isEmpty)

        rig.advance(.milliseconds(1))
        XCTAssertEqual(rig.phase, .finished)
        XCTAssertFalse(rig.isPending)
        XCTAssertFalse(rig.isHiddenFromAccessibility, "released with the terminal progression")
        XCTAssertEqual(rig.effects.homes, [rig.confirmation.id])

        rig.advance(.seconds(60))
        XCTAssertEqual(rig.effects.homes, [rig.confirmation.id])
        XCTAssertEqual(rig.effects.resolves, [rig.confirmation.id])
    }

    // MARK: - 5. VoiceOver off

    func testWithoutVoiceOverTheExposureIsExactlyTheOrdinaryResolveRule() {
        let rig = makeRig(voiceOverRunning: false)
        XCTAssertTrue(rig.isHiddenFromAccessibility)

        rig.advance(plan.ticketHold)
        XCTAssertTrue(rig.isHiddenFromAccessibility)

        rig.advance(plan.transformDuration)
        XCTAssertEqual(rig.phase, .dwelling)
        XCTAssertNil(rig.coordinator.progression?.announcement)
        XCTAssertFalse(rig.isPending)
        XCTAssertFalse(rig.isHiddenFromAccessibility, "exposed at the resolve, as before U1.1")

        // Finish notifications are irrelevant without VoiceOver.
        rig.finish(wasSuccessful: false)
        rig.finish(wasSuccessful: true)
        XCTAssertFalse(rig.isHiddenFromAccessibility)

        rig.advance(plan.readableDwell - .milliseconds(1))
        XCTAssertTrue(rig.effects.homes.isEmpty)
        rig.advance(.milliseconds(1))
        XCTAssertEqual(rig.effects.homes, [rig.confirmation.id], "the ordinary 2000 ms dwell")
        XCTAssertTrue(rig.effects.reposts.isEmpty)
    }

    // MARK: - The rule itself and its scoping

    func testHiddenRuleIsPendingOrUnresolvedAcrossEveryPhase() {
        let phases: [HelperSuccessProgression.Phase] = [.ticket, .transforming, .dwelling, .finished]
        for phase in phases {
            for pending in [false, true] {
                let resolved = phase == .dwelling || phase == .finished
                XCTAssertEqual(
                    HelperSuccessView.hidesSuccessContentFromAccessibility(
                        phase: phase,
                        isAnnouncementPending: pending
                    ),
                    !resolved || pending,
                    "\(phase) pending=\(pending)"
                )
            }
        }
    }

    func testPendingIsScopedToTheCurrentConfirmationAndEndsWithThePresentation() {
        let rig = makeRig(voiceOverRunning: true)
        advanceToResolve(rig)
        XCTAssertTrue(rig.coordinator.isAnnouncementPending(for: rig.confirmation.id))
        XCTAssertFalse(rig.coordinator.isAnnouncementPending(for: UUID()))

        rig.coordinator.update(confirmation: nil, reduceMotion: false)
        XCTAssertFalse(rig.coordinator.isAnnouncementPending(for: rig.confirmation.id))
    }

    func testContentViewPassesTheCoordinatorsPendingStateToTheView() throws {
        let contentView = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("CommonPlateios/ContentView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            contentView.contains(".isAnnouncementPending(for: confirmation.id)"),
            "verified by source inspection only"
        )
    }

    // MARK: - Hosted: the real view's accessibility tree

    /// Hosts the real `HelperSuccessView` and reads its accessibility tree, so
    /// the pending state is proven to remove the combined element from it and
    /// to restore it afterwards. The positive case is the control: a failure to
    /// see the element when it should be exposed is an environment problem and
    /// fails the test rather than letting the hidden case pass vacuously.
    func testHostedViewRemovesTheCombinedElementWhilePendingAndRestoresIt() throws {
        let confirmation = FulfillmentConfirmation(
            id: UUID(),
            requestID: "success-target",
            vendor: "Crave NYU",
            foodDescription: "Rice bowl",
            kind: .notificationSent,
            messageSuppressed: true
        )
        func view(
            phase: HelperSuccessProgression.Phase,
            pending: Bool
        ) -> HelperSuccessView {
            HelperSuccessView(
                confirmation: confirmation,
                phase: phase,
                reduceMotion: false,
                isAnnouncementPending: pending
            )
        }

        Self.enableAccessibilityTree()
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: view(phase: .dwelling, pending: false))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func settle(_ seconds: TimeInterval = 0.8) {
            let end = Date().addingTimeInterval(seconds)
            repeat {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                window.layoutIfNeeded()
            } while Date() < end
        }
        func successLabels() -> [String] {
            Self.labels(in: controller.view).filter { $0.contains("Thanks for helping someone out") }
        }

        settle()
        XCTAssertFalse(
            successLabels().isEmpty,
            "control: the resolved, non-pending success element must be in the accessibility tree"
        )

        controller.rootView = view(phase: .dwelling, pending: true)
        settle()
        XCTAssertTrue(
            successLabels().isEmpty,
            "pending announcement: the element is not a focus target. Saw: \(successLabels())"
        )

        controller.rootView = view(phase: .dwelling, pending: false)
        settle()
        XCTAssertFalse(successLabels().isEmpty, "restored once the wait ends, not permanently hidden")

        controller.rootView = view(phase: .ticket, pending: false)
        settle()
        XCTAssertTrue(successLabels().isEmpty, "still hidden before the resolve")
    }

    private static func enableAccessibilityTree() {
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let symbol = dlsym(handle, "_AXSSetAutomationEnabled") else { return }
        typealias SetAutomationEnabled = @convention(c) (Bool) -> Void
        unsafeBitCast(symbol, to: SetAutomationEnabled.self)(true)
    }

    private static func labels(in root: NSObject) -> [String] {
        var result: [String] = []
        func walk(_ node: NSObject, _ depth: Int) {
            guard depth < 60 else { return }
            if node.isAccessibilityElement,
               node.responds(to: NSSelectorFromString("accessibilityLabel")),
               let label = node.accessibilityLabel, !label.isEmpty {
                result.append(label)
            }
            if let view = node as? UIView { view.subviews.forEach { walk($0, depth + 1) } }
            if let elements = node.accessibilityElements {
                for element in elements {
                    if let element = element as? NSObject { walk(element, depth + 1) }
                }
            } else {
                let count = node.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for index in 0..<count {
                        if let element = node.accessibilityElement(at: index) as? NSObject {
                            walk(element, depth + 1)
                        }
                    }
                }
            }
        }
        walk(root, 0)
        return result
    }
}
