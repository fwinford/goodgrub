//
//  RequestCreationContinuityFallbackCrossfadeTests.swift
//  CommonPlateiosTests
//
// Focused coverage for the W4-D2 final geometry-fallback card handoff: when
// the committed landing has no usable real Home target, the continuity card
// stays spatially fixed and fades out while Home's real card for the same
// request fades in at its actual slot, as one coordinated crossfade inside
// the existing landing window — regardless of motion preference — while both
// valid-target branches stay exactly as accepted.
//
// Scope honesty (`docs/testing.md`): this repository has no UI-test target, so
// these cases exercise the production policy, geometry, and motion values
// directly — the same pure functions and constants the views call — plus
// bounded source assertions for the wiring facts that have no non-UI seam.
// They do NOT prove rendered opacity curves, frame-level simultaneity of the
// two fades on screen, or the absence of a visible hard swap on a device;
// that remains physical-device evidence.
import CoreGraphics
import Foundation
import SwiftUI
import XCTest
@testable import CommonPlateios

final class RequestCreationContinuityFallbackCrossfadeTests: XCTestCase {

    private typealias Layout = RequestCreationContinuityLayout
    private typealias Plan = RequestCreationContinuityMotionPlan

    private static let container = CGSize(width: 390, height: 844)
    private static let settledCard = CGRect(x: 24, y: 309, width: 342, height: 121)
    private static let visibleSlot = CGRect(x: 24, y: 164, width: 342, height: 121)
    /// The no-usable-target captures: nothing measured, and a real slot that
    /// is off-screen (above and below the presentation's bounds).
    private static let unusableCaptures: [CGRect?] = [
        nil,
        CGRect(x: 24, y: -40, width: 342, height: 121),
        CGRect(x: 24, y: 900, width: 342, height: 121)
    ]

    /// One landing frame, composed from exactly the production functions
    /// `RequestCreationContinuityView.card(...)`, `cardOffset`, and
    /// `cardOpacity` call, in the same order, plus Home's own opacity rule.
    private struct Frame: Equatable {
        let handoff: Layout.LandingHandoff
        let translation: CGSize
        let overlayOpacity: Double
        let homeCardOpacity: Double
        let cardWidth: CGFloat
    }

    private func frame(
        phase: RequestCreationContinuityView.Phase,
        reduceMotion: Bool,
        homeSlotCapture: Layout.EndpointCapture,
        liveHomeSlot: CGRect? = nil
    ) -> Frame {
        let measured = Layout.stableFrame(phase: phase, live: liveHomeSlot, capture: homeSlotCapture)
        let landingSlot = Layout.landingSlot(homeSlot: measured, containerFrame: CGRect(origin: .zero, size: Self.container))
        let settled = Layout.stableFrame(
            phase: phase,
            live: Self.settledCard,
            capture: .captured(Self.settledCard)
        )
        let translation: CGSize
        if phase == .landing {
            translation = reduceMotion
                ? Layout.reducedMotionLandingTranslation(from: settled, to: landingSlot)
                : Layout.landingTranslation(from: settled, to: landingSlot)
        } else {
            translation = .zero
        }
        let hasDestination = landingSlot != nil
        return Frame(
            handoff: Layout.landingHandoff(reduceMotion: reduceMotion, hasLandingDestination: hasDestination),
            translation: translation,
            overlayOpacity: Layout.isOverlayCardVisible(
                phase: phase,
                reduceMotion: reduceMotion,
                hasLandingDestination: hasDestination
            ) ? 1 : 0,
            homeCardOpacity: HomeExchangeView.landingContinuityCardOpacity(
                isContinuityCard: true,
                isRevealing: Layout.isHomeCardRevealed(
                    phase: phase,
                    reduceMotion: reduceMotion,
                    hasLandingDestination: hasDestination
                )
            ),
            cardWidth: Layout.cardWidth(containerWidth: Self.container.width, homeSlot: measured)
        )
    }

    // MARK: - (1) Standard + no target, (2) Reduce Motion + no target

    /// Settled → landing with no usable target, both motion preferences: the
    /// overlay card goes from visible to hidden and Home's real card from
    /// hidden to visible across the same phase transition, with zero
    /// translation throughout — the in-place crossfade, not bounded travel
    /// and not an opaque card awaiting a retirement swap.
    func testNoTargetLandingIsAZeroTravelCardToCardCrossfadeForBothMotionPreferences() {
        for reduceMotion in [false, true] {
            for capture in Self.unusableCaptures {
                let label = "reduceMotion \(reduceMotion) capture \(String(describing: capture))"
                let settled = frame(phase: .settled, reduceMotion: reduceMotion, homeSlotCapture: .pending, liveHomeSlot: capture)
                let landing = frame(phase: .landing, reduceMotion: reduceMotion, homeSlotCapture: .captured(capture))

                XCTAssertEqual(landing.handoff, .inPlaceCrossfade, label)

                XCTAssertEqual(settled.translation, .zero, label)
                XCTAssertEqual(landing.translation, .zero, label)

                XCTAssertEqual(settled.overlayOpacity, 1, label)
                XCTAssertEqual(landing.overlayOpacity, 0, label)

                XCTAssertEqual(settled.homeCardOpacity, 0, label)
                XCTAssertEqual(landing.homeCardOpacity, 1, label)
            }
        }
    }

    /// Reduce Motion with no target must not fall into its bounded-travel
    /// branch: its translation is exactly zero, not a capped measured delta
    /// toward an off-screen slot.
    func testReduceMotionNoTargetDoesNotSwitchIntoBoundedTravel() {
        for capture in Self.unusableCaptures {
            let landing = frame(phase: .landing, reduceMotion: true, homeSlotCapture: .captured(capture))
            XCTAssertNotEqual(landing.handoff, .reducedMotionBoundedCrossfade)
            XCTAssertEqual(landing.translation, .zero, "capture \(String(describing: capture))")
        }
    }

    // MARK: - (3) No both-hidden state; Home revealed by retirement

    /// During the landing the two target opacities are exactly
    /// complementary for every branch, and the fallback never has both
    /// hidden. Because both sides then animate toward those targets on the
    /// one identical `handoffCrossfadeAnimation` (see timing below), their
    /// rendered opacities stay complementary for the whole landing window.
    func testFallbackLandingNeverTargetsBothCardsHidden() {
        for reduceMotion in [false, true] {
            for capture in Self.unusableCaptures {
                let landing = frame(phase: .landing, reduceMotion: reduceMotion, homeSlotCapture: .captured(capture))
                XCTAssertEqual(landing.overlayOpacity + landing.homeCardOpacity, 1)
                XCTAssertFalse(landing.overlayOpacity == 0 && landing.homeCardOpacity == 0)
            }
        }
    }

    /// Retirement is not the Home card's first appearance: the landing phase
    /// — which runs for the whole `landingDuration` before `onFinished`
    /// retires the presentation — already targets Home's card visible.
    func testFallbackHomeCardIsRevealedBeforeRetirement() throws {
        for reduceMotion in [false, true] {
            let landing = frame(phase: .landing, reduceMotion: reduceMotion, homeSlotCapture: .captured(nil))
            XCTAssertEqual(landing.homeCardOpacity, 1, "reduceMotion \(reduceMotion)")
        }
        // And the view retires only after sleeping the full landing duration
        // that follows the `.landing` commit.
        let source = Self.normalized(try continuitySource())
        XCTAssertTrue(source.contains(
            "withAnimation(landingAnimation) { phase = .landing } do { try await Task.sleep(for: plan.landingDuration) } catch { return } onFinished(continuity.id)"
        ))
    }

    /// Only the exact created request's own Home card participates: any other
    /// owned card is unaffected by the handoff signal in either state, so no
    /// older request can fade in as a destination substitute.
    func testOnlyTheExactContinuityRequestCardParticipatesInTheHandoff() throws {
        for isRevealing in [false, true] {
            XCTAssertEqual(
                HomeExchangeView.landingContinuityCardOpacity(isContinuityCard: false, isRevealing: isRevealing),
                1
            )
        }
        XCTAssertEqual(HomeExchangeView.landingContinuityCardOpacity(isContinuityCard: true, isRevealing: false), 0)
        XCTAssertEqual(HomeExchangeView.landingContinuityCardOpacity(isContinuityCard: true, isRevealing: true), 1)

        // "Is the continuity card" is decided by request identity against the
        // live, operation-scoped continuity — never by list position.
        let home = Self.normalized(try homeSource())
        XCTAssertTrue(home.contains(
            "private func isLandingContinuityCard(_ request: FoodRequest) -> Bool { store.createdRequestContinuity?.request.id == request.id }"
        ))
        XCTAssertTrue(home.contains(
            "isContinuityCard: isLandingContinuityCard(request), isRevealing: isRevealingLandingContinuityCard"
        ))
    }

    // MARK: - (4) Valid-target standard, (5) valid-target Reduce Motion

    /// Standard motion with a usable target is unchanged: the full measured
    /// delta, overlay opaque through the landing, Home's card not revealed
    /// early (the existing instant swap at retirement).
    func testValidTargetStandardLandingIsUnchanged() {
        let landing = frame(phase: .landing, reduceMotion: false, homeSlotCapture: .captured(Self.visibleSlot))
        XCTAssertEqual(landing.handoff, .measuredTravel)
        XCTAssertEqual(landing.translation, CGSize(width: 0, height: Self.visibleSlot.minY - Self.settledCard.minY))
        XCTAssertEqual(landing.overlayOpacity, 1)
        XCTAssertEqual(landing.homeCardOpacity, 0)
        XCTAssertEqual(landing.cardWidth, Self.visibleSlot.width)
    }

    /// Reduce Motion with a usable target is unchanged: the 24pt-capped
    /// measured-direction travel plus the existing crossfade.
    func testValidTargetReduceMotionLandingIsUnchanged() {
        let landing = frame(phase: .landing, reduceMotion: true, homeSlotCapture: .captured(Self.visibleSlot))
        XCTAssertEqual(landing.handoff, .reducedMotionBoundedCrossfade)
        XCTAssertEqual(
            (landing.translation.width * landing.translation.width
                + landing.translation.height * landing.translation.height).squareRoot(),
            Layout.reducedMotionMaximumLandingDisplacement,
            accuracy: 0.0001
        )
        XCTAssertLessThan(landing.translation.height, 0)
        XCTAssertEqual(landing.overlayOpacity, 0)
        XCTAssertEqual(landing.homeCardOpacity, 1)
    }

    /// The fallback's own animation override is keyed only on the fallback
    /// branch, so the valid-target branches never observe a changed value and
    /// keep their existing landing animation (standard: the proven travel
    /// curve; Reduce Motion: the same ease it always used).
    func testFallbackAnimationOverrideIsScopedToTheFallbackBranch() throws {
        let source = Self.normalized(try continuitySource())
        XCTAssertTrue(source.contains(
            ".animation( plan.handoffCrossfadeAnimation, value: isInPlaceCrossfading(landingSlot: landingSlot) )"
        ))
        XCTAssertTrue(source.contains(
            "phase == .landing && RequestCreationContinuityLayout.landingHandoff( reduceMotion: reduceMotion, hasLandingDestination: landingSlot != nil ) == .inPlaceCrossfade"
        ))
        XCTAssertTrue(source.contains(
            ".timingCurve(curve.x1, curve.y1, curve.x2, curve.y2, duration: plan.landingSeconds)"
        ))
    }

    // MARK: - (6) Timing

    /// One timing authority: both halves of the crossfade use the plan's
    /// `handoffCrossfadeAnimation`, which spans exactly the existing landing
    /// duration — no new constant, no post-landing wait, and the accepted
    /// 1.6s Success dwell is unchanged for both motion preferences.
    func testCrossfadeFitsTheExistingLandingWindowAndDwellIsUnchanged() throws {
        for plan in [Plan.standard, Plan.reducedMotion] {
            XCTAssertEqual(plan.landingDuration, .milliseconds(500))
            XCTAssertEqual(plan.settleDwell, .milliseconds(1100))
            XCTAssertEqual(plan.totalDuration, Plan.successDwellDuration)
            XCTAssertEqual(plan.handoffCrossfadeAnimation, Animation.easeInOut(duration: plan.landingSeconds))
        }
        XCTAssertEqual(Plan.successDwellDuration, .milliseconds(1600))
        XCTAssertEqual(Plan.standard.handoffCrossfadeAnimation, Plan.reducedMotion.handoffCrossfadeAnimation)

        // Home's fade-in reads that same animation for the active plan, keyed
        // on the one relayed handoff signal.
        let home = Self.normalized(try homeSource())
        XCTAssertTrue(home.contains(
            ".animation( RequestCreationContinuityMotionPlan .plan(reduceMotion: reduceMotion) .handoffCrossfadeAnimation, value: isRevealingLandingContinuityCard )"
        ))
        // And the signal is relayed from the overlay's own preference, never
        // re-derived on a second timeline.
        let contentView = Self.normalized(try String(
            contentsOf: repositoryFile("ios/CommonPlateios/CommonPlateios/ContentView.swift"),
            encoding: .utf8
        ))
        XCTAssertTrue(contentView.contains(
            ".onPreferenceChange(RequestCreationContinuityHandoffKey.self) { isRevealing in isRevealingLandingContinuityCard = isRevealing }"
        ))
        XCTAssertTrue(contentView.contains(
            "isRevealingLandingContinuityCard: isRevealingLandingContinuityCard,"
        ))
    }

    // MARK: - (7) Geometry

    /// The crossfade needs no target and invents none: a captured-nil stays
    /// nil for the whole landing even when Home later publishes a real
    /// visible slot, and the fallback's frame does not change because of it.
    func testFallbackNeitherRequiresNorFabricatesATarget() {
        XCTAssertNil(Layout.stableFrame(phase: .landing, live: Self.visibleSlot, capture: .captured(nil)))
        XCTAssertNil(Layout.landingSlot(homeSlot: nil, containerFrame: CGRect(origin: .zero, size: Self.container)))

        for reduceMotion in [false, true] {
            let atCommit = frame(phase: .landing, reduceMotion: reduceMotion, homeSlotCapture: .captured(nil))
            let afterHomePublishes = frame(
                phase: .landing,
                reduceMotion: reduceMotion,
                homeSlotCapture: .captured(nil),
                liveHomeSlot: Self.visibleSlot
            )
            XCTAssertEqual(afterHomePublishes, atCommit, "reduceMotion \(reduceMotion)")
            XCTAssertEqual(
                atCommit.cardWidth,
                HomeExchangeView.contentCardWidth(containerWidth: Self.container.width)
            )
        }
    }

    // MARK: - (8) Home layout

    /// The destination card stays mounted in Home's layout while hidden: its
    /// visibility is opacity only, applied to the always-rendered card, never
    /// a conditional that removes it — so the handoff cannot reflow Home or
    /// move the measured slot.
    func testDestinationCardStaysMountedWhileHidden() throws {
        let home = Self.normalized(try homeSource())
        XCTAssertTrue(home.contains(
            "RequestCardView( request: request, kind: .own, showsOwnershipEyebrow: false, ownerPhase: pickupExit?.request.id == request.id ? pickupExit?.ownerPhase : ownerPhase(for: request), placedOrderNeedsPickupConfirmation: pickupExit?.request.id == request.id ? pickupExit?.needsPickupConfirmation : store.placedOrder(requestID: request.id)?.shouldConfirmPickup(), isHomePresentation: true ) } .buttonStyle(.plain)"
        ))
        XCTAssertTrue(home.contains(".opacity(landingContinuityCardOpacity(request))"))
        XCTAssertFalse(home.contains("if !isLandingContinuityCard(request)"))
        XCTAssertFalse(home.contains("if isLandingContinuityCard(request)"))
    }

    // MARK: - Helpers

    private static func normalized(_ source: String) -> String {
        source
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

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
