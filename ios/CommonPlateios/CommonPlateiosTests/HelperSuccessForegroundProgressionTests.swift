//
//  HelperSuccessForegroundProgressionTests.swift
//  CommonPlateiosTests
//
// Focused W4-H1 proof that the success presentation progresses only on
// active-scene time: the resolve effects (the one success haptic and the one
// VoiceOver announcement) and the one automatic Home return are never consumed
// while CommonPlate is inactive, survive interruption and resumption without
// duplication, and are not reconstructed by a relaunch.
//
// Deterministic: the coordinator's automatic driver is disabled and active time
// is stepped explicitly, except for one bounded driver smoke test. This is unit
// proof of the progression logic, not physical-device evidence of haptic feel,
// VoiceOver output, or real foreground/background behavior.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
private final class SuccessEffectRecorder {
    var resolved: [UUID] = []
    var announcements: [String] = []
    var homeReturns: [UUID] = []
}

@MainActor
final class HelperSuccessForegroundProgressionTests: XCTestCase {
    private let plan = HelperSuccessMotionPlan.standard

    override func tearDown() {
        HelperCompletionURLProtocol.reset()
        super.tearDown()
    }

    // 1. Authoritative confirmation arrives while inactive.
    func testConfirmationArrivingWhileInactiveWaitsForAFullActivePresentation() {
        let (coordinator, effects) = makeCoordinator()
        let confirmation = makeConfirmation(kind: .notificationSent)

        coordinator.update(confirmation: confirmation, reduceMotion: false)
        XCTAssertFalse(coordinator.isSceneActive)
        coordinator.advance(by: .seconds(60))

        XCTAssertEqual(coordinator.progression?.phase, .ticket)
        XCTAssertEqual(coordinator.progression?.phaseElapsed, .zero)
        assertNoEffects(effects)

        coordinator.updateSceneActivity(isActive: true)
        coordinator.advance(by: plan.ticketHold - .milliseconds(1))
        XCTAssertEqual(coordinator.progression?.phase, .ticket)
        coordinator.advance(by: .milliseconds(1))
        XCTAssertEqual(coordinator.progression?.phase, .transforming)
        coordinator.advance(by: plan.transformDuration - .milliseconds(1))
        XCTAssertTrue(effects.resolved.isEmpty, "no resolve before the active visual resolve")
        coordinator.advance(by: .milliseconds(1))
        XCTAssertEqual(coordinator.progression?.phase, .dwelling)
        XCTAssertEqual(effects.resolved, [confirmation.id])
        XCTAssertEqual(effects.announcements, ["Thanks for helping."])

        coordinator.advance(by: plan.readableDwell - .milliseconds(1))
        XCTAssertTrue(effects.homeReturns.isEmpty)
        coordinator.advance(by: .milliseconds(1))
        XCTAssertEqual(coordinator.progression?.phase, .finished)
        XCTAssertEqual(effects.homeReturns, [confirmation.id])
    }

    // 2. Backgrounding before the primary visual resolve.
    func testBackgroundingBeforeResolveRestartsTheTransitionAndConsumesNothing() {
        let (coordinator, effects) = makeCoordinator()
        let confirmation = makeConfirmation(kind: .notificationFailed)
        coordinator.updateSceneActivity(isActive: true)
        coordinator.update(confirmation: confirmation, reduceMotion: false)

        coordinator.advance(by: plan.ticketHold + plan.transformDuration - .milliseconds(50))
        XCTAssertEqual(coordinator.progression?.phase, .transforming)

        coordinator.updateSceneActivity(isActive: false)
        XCTAssertEqual(coordinator.progression?.phase, .ticket, "the unperceived transition starts over")
        coordinator.advance(by: .seconds(30))
        assertNoEffects(effects)

        coordinator.updateSceneActivity(isActive: true)
        coordinator.advance(by: plan.ticketHold + plan.transformDuration - .milliseconds(1))
        XCTAssertTrue(effects.resolved.isEmpty, "time before the interruption is not credited")
        coordinator.advance(by: .milliseconds(1))
        XCTAssertEqual(effects.resolved, [confirmation.id])
        XCTAssertEqual(effects.announcements, ["Thanks for helping. We couldn't email the requester."])
        XCTAssertTrue(effects.homeReturns.isEmpty)
    }

    // 3. Backgrounding after resolve, during the readable dwell.
    func testBackgroundingDuringDwellNeverReplaysResolveAndRestartsTheReadableDwell() {
        let (coordinator, effects) = makeCoordinator()
        let confirmation = makeConfirmation(kind: .emailStatusUnknown)
        coordinator.updateSceneActivity(isActive: true)
        coordinator.update(confirmation: confirmation, reduceMotion: false)
        coordinator.advance(by: plan.ticketHold + plan.transformDuration)
        XCTAssertEqual(effects.resolved, [confirmation.id])
        coordinator.advance(by: plan.readableDwell - .milliseconds(100))

        coordinator.updateSceneActivity(isActive: false)
        XCTAssertEqual(coordinator.progression?.phase, .dwelling, "a perceived resolve is never undone")
        coordinator.advance(by: .seconds(30))
        XCTAssertTrue(effects.homeReturns.isEmpty, "inactive time never counts toward the dwell")

        coordinator.updateSceneActivity(isActive: true)
        coordinator.advance(by: plan.readableDwell - .milliseconds(1))
        XCTAssertTrue(effects.homeReturns.isEmpty, "a complete readable dwell is required after resuming")
        coordinator.advance(by: .milliseconds(1))
        XCTAssertEqual(effects.homeReturns, [confirmation.id])
        XCTAssertEqual(effects.resolved, [confirmation.id])
        XCTAssertEqual(effects.announcements, ["Thanks for helping."])
    }

    // 4. Repeated active/inactive transitions.
    func testRepeatedSceneTransitionsProduceExactlyOneOfEachEffect() {
        let (coordinator, effects) = makeCoordinator()
        let confirmation = makeConfirmation(kind: .notificationSent)
        coordinator.update(confirmation: confirmation, reduceMotion: false)

        // Interrupted repeatedly before the resolve.
        for _ in 0..<5 {
            coordinator.updateSceneActivity(isActive: true)
            coordinator.advance(by: plan.ticketHold + plan.transformDuration - .milliseconds(10))
            coordinator.updateSceneActivity(isActive: false)
            coordinator.advance(by: .seconds(5))
        }
        assertNoEffects(effects)

        coordinator.updateSceneActivity(isActive: true)
        coordinator.advance(by: plan.ticketHold + plan.transformDuration)
        XCTAssertEqual(effects.resolved.count, 1)

        // Interrupted repeatedly during the dwell.
        for _ in 0..<5 {
            coordinator.advance(by: plan.readableDwell - .milliseconds(10))
            coordinator.updateSceneActivity(isActive: false)
            coordinator.advance(by: .seconds(5))
            coordinator.updateSceneActivity(isActive: true)
        }
        XCTAssertTrue(effects.homeReturns.isEmpty)

        // Redundant same-state notifications do not interrupt anything.
        coordinator.advance(by: plan.readableDwell - .milliseconds(10))
        coordinator.updateSceneActivity(isActive: true)
        coordinator.advance(by: .milliseconds(10))

        XCTAssertEqual(effects.resolved, [confirmation.id])
        XCTAssertEqual(effects.announcements.count, 1)
        XCTAssertEqual(effects.homeReturns, [confirmation.id])
    }

    // 5. View recreation and repeated publisher/state updates.
    func testRepeatedPublicationsAndViewRecreationNeitherRestartNorDuplicate() {
        let (coordinator, effects) = makeCoordinator()
        let confirmation = makeConfirmation(kind: .notificationSent)
        coordinator.updateSceneActivity(isActive: true)
        coordinator.update(confirmation: confirmation, reduceMotion: false)
        coordinator.advance(by: plan.ticketHold + plan.transformDuration + .milliseconds(500))
        let snapshot = coordinator.progression

        // The store republishing the same confirmation, and a view rebuilt
        // from the coordinator, leave the progression exactly where it was.
        for _ in 0..<3 {
            coordinator.update(confirmation: confirmation, reduceMotion: false)
            coordinator.update(confirmation: confirmation, reduceMotion: true)
            let rebuilt = HelperSuccessView(
                confirmation: confirmation,
                phase: coordinator.progression?.phase ?? .ticket,
                reduceMotion: false
            )
            XCTAssertEqual(rebuilt.phase, .dwelling)
        }
        XCTAssertEqual(coordinator.progression, snapshot)
        XCTAssertEqual(effects.resolved, [confirmation.id])

        coordinator.advance(by: plan.readableDwell - .milliseconds(500))
        XCTAssertEqual(effects.homeReturns, [confirmation.id])
    }

    // 6–9. Exactly one resolve (haptic + announcement) and Home return, with
    // nothing more after finishing or resuming.
    func testNoDuplicateEffectsAfterFinishingOrResuming() {
        let (coordinator, effects) = makeCoordinator()
        let confirmation = makeConfirmation(kind: .notificationSent)
        coordinator.updateSceneActivity(isActive: true)
        coordinator.update(confirmation: confirmation, reduceMotion: false)
        coordinator.advance(by: plan.totalDuration)
        XCTAssertEqual(coordinator.progression?.phase, .finished)

        for _ in 0..<3 {
            coordinator.updateSceneActivity(isActive: false)
            coordinator.updateSceneActivity(isActive: true)
            coordinator.advance(by: .seconds(10))
        }
        XCTAssertEqual(coordinator.progression?.phase, .finished)

        // Even the same confirmation somehow reappearing cannot replay effects.
        coordinator.update(confirmation: nil, reduceMotion: false)
        XCTAssertNil(coordinator.progression)
        coordinator.update(confirmation: confirmation, reduceMotion: false)
        coordinator.advance(by: plan.totalDuration)

        XCTAssertEqual(effects.resolved, [confirmation.id])
        XCTAssertEqual(effects.announcements.count, 1)
        XCTAssertEqual(effects.homeReturns, [confirmation.id])
    }

    /// A distinct later confirmation gets its own single set of effects.
    func testEachConfirmationGetsItsOwnSingleSetOfEffects() {
        let (coordinator, effects) = makeCoordinator()
        let first = makeConfirmation(kind: .notificationSent)
        let second = makeConfirmation(kind: .notificationFailed)
        coordinator.updateSceneActivity(isActive: true)

        coordinator.update(confirmation: first, reduceMotion: false)
        coordinator.advance(by: plan.totalDuration)
        coordinator.update(confirmation: nil, reduceMotion: false)
        coordinator.update(confirmation: second, reduceMotion: true)
        XCTAssertEqual(coordinator.progression?.plan, .reducedMotion)
        coordinator.advance(by: HelperSuccessMotionPlan.reducedMotion.totalDuration)

        XCTAssertEqual(effects.resolved, [first.id, second.id])
        XCTAssertEqual(effects.homeReturns, [first.id, second.id])
    }

    /// The pure progression never moves backwards past the resolve and never
    /// credits time it was not given.
    func testProgressionStateMachineBoundaries() {
        var progression = HelperSuccessProgression(confirmationID: UUID(), plan: plan)
        XCTAssertEqual(progression.timeUntilNextMilestone, plan.ticketHold)
        XCTAssertEqual(progression.advance(by: plan.totalDuration), [.beginTransform, .resolve, .returnHome])
        XCTAssertNil(progression.timeUntilNextMilestone)
        XCTAssertEqual(progression.advance(by: .seconds(10)), [])
        progression.interrupt()
        XCTAssertEqual(progression.phase, .finished)

        var interrupted = HelperSuccessProgression(confirmationID: UUID(), plan: plan)
        XCTAssertEqual(interrupted.advance(by: plan.ticketHold + plan.transformDuration), [.beginTransform, .resolve])
        interrupted.interrupt()
        XCTAssertTrue(interrupted.hasResolved)
        XCTAssertEqual(interrupted.timeUntilNextMilestone, plan.readableDwell)
    }

    // 10. No success reconstruction on a later relaunch.
    func testRelaunchAfterConfirmedPlacementReconstructsNoPresentationOrEffects() async throws {
        let store = makeStore()
        HelperCompletionURLProtocol.enqueue(.response(data: Data("""
        {
          "reservation": null,
          "placement": {
            "request": {
              "id": "relaunch-placed",
              "vendor": "Crave NYU",
              "food": "Rice bowl",
              "pickupWindowText": "ASAP",
              "mealSwipes": 2,
              "menuPath": "meal-exchange",
              "mealItems": ["Meal 1", "Meal 2"],
              "orderDetails": null,
              "estimatedDiningDollarsCents": null,
              "windowStart": null,
              "windowEnd": null,
              "status": "placed",
              "createdAt": "2026-08-10T15:00:00.000Z",
              "expiresAt": "2026-08-10T20:00:00.000Z"
            },
            "orderNumber": "70154321",
            "etaText": "15 minutes",
            "notification": { "status": "sent" }
          }
        }
        """.utf8)))
        _ = try await store.continueActiveReservationIfNeeded()

        // A relaunched process: a fresh coordinator mirroring the store.
        let (coordinator, effects) = makeCoordinator()
        coordinator.updateSceneActivity(isActive: true)
        coordinator.update(confirmation: store.fulfillmentConfirmation, reduceMotion: false)
        coordinator.advance(by: .seconds(60))

        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertNil(coordinator.progression)
        assertNoEffects(effects)
    }

    /// The real driver, with tiny timings: inactive time never advances it,
    /// and an active scene carries it to exactly one of each effect.
    func testAutomaticDriverRespectsSceneActivity() async throws {
        let tiny = HelperSuccessMotionPlan(
            ticketHold: .milliseconds(20),
            transformDuration: .milliseconds(20),
            readableDwell: .milliseconds(40),
            ticketEndScale: 1,
            mealStartScale: 1,
            copyRise: 0
        )
        let effects = SuccessEffectRecorder()
        let coordinator = HelperSuccessPresentationCoordinator(
            performResolve: { effects.resolved.append($0.id) },
            planProvider: { _ in tiny },
            drivesAutomatically: true,
            isVoiceOverRunning: { false }
        )
        coordinator.returnHome = { effects.homeReturns.append($0.id) }
        let confirmation = makeConfirmation(kind: .notificationSent)

        coordinator.update(confirmation: confirmation, reduceMotion: false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(coordinator.progression?.phase, .ticket, "no progress while inactive")
        XCTAssertTrue(effects.resolved.isEmpty)

        coordinator.updateSceneActivity(isActive: true)
        let deadline = Date().addingTimeInterval(3)
        while effects.homeReturns.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(effects.resolved, [confirmation.id])
        XCTAssertEqual(effects.homeReturns, [confirmation.id])
        XCTAssertEqual(coordinator.progression?.phase, .finished)
    }

    // MARK: - Helpers

    private func makeCoordinator() -> (HelperSuccessPresentationCoordinator, SuccessEffectRecorder) {
        let effects = SuccessEffectRecorder()
        let coordinator = HelperSuccessPresentationCoordinator(
            performResolve: { confirmation in
                effects.resolved.append(confirmation.id)
                effects.announcements.append(
                    HelperSuccessCopy.accessibilityAnnouncement(for: confirmation.kind)
                )
            },
            drivesAutomatically: false,
            isVoiceOverRunning: { false }
        )
        coordinator.returnHome = { effects.homeReturns.append($0.id) }
        return (coordinator, effects)
    }

    private func assertNoEffects(
        _ effects: SuccessEffectRecorder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(effects.resolved.isEmpty, "no haptic", file: file, line: line)
        XCTAssertTrue(effects.announcements.isEmpty, "no announcement", file: file, line: line)
        XCTAssertTrue(effects.homeReturns.isEmpty, "no Home return", file: file, line: line)
    }

    private func makeConfirmation(kind: FulfillmentConfirmationKind) -> FulfillmentConfirmation {
        FulfillmentConfirmation(
            id: UUID(),
            requestID: "success-target",
            vendor: "Crave NYU",
            foodDescription: "Rice bowl",
            kind: kind
        )
    }

    private func makeStore() -> RequestStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HelperCompletionURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
        return RequestStore(
            service: RequestService(client: client),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { "64c0000000000000000000a1.1.credential" },
            participantAuthorityRejected: {}
        )
    }
}
