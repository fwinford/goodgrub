//
//  RequestCreationContinuityLandingTests.swift
//  CommonPlateiosTests
//
// Focused W4-D2 coverage for the two structural properties of the
// Success→Home handoff that a state-only test cannot reach: the card is the
// same width on Success and on Home, and its landing geometry comes from
// Home's *real* first requester-owned slot rather than a tuned offset.
//
// Scope honesty (`docs/testing.md`): this repository has no UI-test target, so
// these cases exercise the production layout and motion rules directly — the
// same pure functions and constants the views call — plus bounded source
// assertions for the two wiring facts that have no non-UI seam (Home
// publishing its slot frame, and the in-flight slot rendering invisibly rather
// than collapsing). They prove the rules and the wiring. They do not prove
// rendered geometry, smoothness, or the absence of a visible jump on a
// device; that remains physical-device evidence.
import CoreGraphics
import Foundation
import XCTest
@testable import CommonPlateios

final class RequestCreationContinuityLandingTests: XCTestCase {

    // MARK: - Width / no reflow (MUST FIX 1)

    /// The defect this replaces: the Success card applied Home's content
    /// inset and then received a further default `.padding()`, making it
    /// 32pt narrower overall than the Home card and re-wrapping its text at
    /// the handoff. The rule is now single-sourced — with no measured Home
    /// slot, the continuity card falls back to the exact same shared Home
    /// content-column width Home itself renders, for the same container.
    func testFallbackCardWidthIsExactlyTheSharedHomeContentColumnWidth() {
        for containerWidth in [320.0, 390.0, 402.0, 430.0] as [CGFloat] {
            XCTAssertEqual(
                RequestCreationContinuityLayout.cardWidth(
                    containerWidth: containerWidth,
                    homeSlot: nil
                ),
                HomeExchangeView.contentCardWidth(containerWidth: containerWidth),
                "container \(containerWidth)"
            )
        }
    }

    /// The shared rule is Home's own inset applied on both sides — one
    /// authority, not two values that can drift apart.
    func testSharedHomeContentColumnWidthIsTheHomeInsetOnBothSides() {
        XCTAssertEqual(
            HomeExchangeView.contentCardWidth(containerWidth: 390),
            390 - (CommonPlateStyle.Metrics.homeContentColumnInset * 2)
        )
        XCTAssertEqual(HomeExchangeView.contentCardWidth(containerWidth: 0), 0)
    }

    /// Whenever Home has actually laid out a first owned slot, the continuity
    /// card takes that slot's measured width verbatim — so the two widths are
    /// identical by construction even if Home's own column rule were later
    /// changed, and never by a compensating offset maintained in parallel.
    func testMeasuredHomeSlotWidthWinsOverTheFallbackRule() {
        let slot = CGRect(x: 24, y: 300, width: 331, height: 121)

        XCTAssertEqual(
            RequestCreationContinuityLayout.cardWidth(containerWidth: 390, homeSlot: slot),
            331
        )
        // A degenerate measurement is not a width: it falls back rather than
        // rendering a zero-width card.
        XCTAssertEqual(
            RequestCreationContinuityLayout.cardWidth(
                containerWidth: 390,
                homeSlot: CGRect(x: 24, y: 300, width: 0, height: 0)
            ),
            HomeExchangeView.contentCardWidth(containerWidth: 390)
        )
    }

    /// Home's ownership column and the continuity card must not acquire a
    /// second, outer inset again: the Success presentation applies the card
    /// width rule and no additional `.padding()` around the card itself.
    func testContinuityCardCarriesNoSecondOuterInset() throws {
        let source = try continuitySource()
        let cardDeclaration = try boundedSource(
            source,
            from: "private func card(containerSize: CGSize, containerFrame: CGRect) -> some View {",
            to: "private func cardOffset(landingSlot: CGRect?) -> CGSize {"
        )

        XCTAssertTrue(cardDeclaration.contains("RequestCreationContinuityLayout.cardWidth("))
        XCTAssertFalse(
            cardDeclaration.contains(".padding("),
            "the card's width comes from one layout rule, never from a further inset"
        )
    }

    // MARK: - Landing geometry (MUST FIX 2)

    /// The landing is a measured delta between two real frames in one shared
    /// coordinate space — the settled card's own frame and Home's actual
    /// first owned slot — not a fixed offset that happens to look right on
    /// one simulator.
    func testLandingTranslationIsTheMeasuredDeltaToHomesRealSlot() {
        let settled = CGRect(x: 24, y: 340, width: 342, height: 121)
        let homeSlot = CGRect(x: 24, y: 196, width: 342, height: 121)

        let translation = RequestCreationContinuityLayout.landingTranslation(
            from: settled,
            to: homeSlot
        )

        XCTAssertEqual(translation.width, 0)
        XCTAssertEqual(translation.height, -144)
    }

    /// A slot Home lays out at a different x (a different column inset, a
    /// different device) moves the card there too, because nothing about the
    /// destination is hardcoded.
    func testLandingTranslationFollowsHorizontalSlotPositionToo() {
        let translation = RequestCreationContinuityLayout.landingTranslation(
            from: CGRect(x: 24, y: 400, width: 342, height: 121),
            to: CGRect(x: 40, y: 150, width: 342, height: 121)
        )

        XCTAssertEqual(translation.width, 16)
        XCTAssertEqual(translation.height, -250)
    }

    /// Fail-closed geometry: with no real destination — Home renders no owned
    /// slot right now, or the card has not been measured yet — nothing is
    /// invented. The card stays exactly where it settled and the landing
    /// crossfades in place instead of jumping to a guessed position.
    func testNoMeasuredDestinationMeansNoTranslationAtAll() {
        let rect = CGRect(x: 24, y: 340, width: 342, height: 121)

        XCTAssertEqual(
            RequestCreationContinuityLayout.landingTranslation(from: rect, to: nil),
            .zero
        )
        XCTAssertEqual(
            RequestCreationContinuityLayout.landingTranslation(from: nil, to: rect),
            .zero
        )
        XCTAssertEqual(
            RequestCreationContinuityLayout.landingTranslation(
                from: rect,
                to: CGRect(x: 0, y: 0, width: 0, height: 0)
            ),
            .zero
        )
    }

    /// Home keeps its own scroll position, so its first owned slot can be
    /// off-screen when the requester returns to it. A destination that is not
    /// fully on screen is not travelled to — the landing crossfades in place
    /// rather than flying the card off the edge — while a fully visible slot
    /// is used exactly as measured.
    func testOnlyAFullyVisibleHomeSlotIsUsedAsALandingDestination() {
        let containerFrame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let visible = CGRect(x: 24, y: 196, width: 342, height: 121)

        XCTAssertEqual(
            RequestCreationContinuityLayout.landingSlot(homeSlot: visible, containerFrame: containerFrame),
            visible
        )
        // Scrolled above the top edge, and below the bottom edge.
        XCTAssertNil(RequestCreationContinuityLayout.landingSlot(
            homeSlot: CGRect(x: 24, y: -40, width: 342, height: 121),
            containerFrame: containerFrame
        ))
        XCTAssertNil(RequestCreationContinuityLayout.landingSlot(
            homeSlot: CGRect(x: 24, y: 800, width: 342, height: 121),
            containerFrame: containerFrame
        ))
        XCTAssertNil(RequestCreationContinuityLayout.landingSlot(
            homeSlot: nil,
            containerFrame: containerFrame
        ))
    }

    /// W4-D2 coordinate-system FIX: the overlay's own container is not
    /// guaranteed to sit at a coordinate system's origin (its measured
    /// `.global` frame reflects wherever the window/screen actually placed
    /// it). Containment must be evaluated against that real frame, not an
    /// assumed `CGRect(origin: .zero, size: containerSize)` — a slot near the
    /// container's actual top/bottom edge must resolve correctly regardless
    /// of where that edge sits in the shared coordinate system.
    func testLandingSlotContainmentUsesTheContainersRealNonZeroOrigin() {
        let containerFrame = CGRect(x: 12, y: 62, width: 390, height: 782)

        // Just inside the real top edge (y=62): usable.
        XCTAssertEqual(
            RequestCreationContinuityLayout.landingSlot(
                homeSlot: CGRect(x: 36, y: 70, width: 342, height: 121),
                containerFrame: containerFrame
            ),
            CGRect(x: 36, y: 70, width: 342, height: 121)
        )
        // Above the real top edge but below y=0: would have been wrongly
        // accepted by a zero-origin bounds check, and must be rejected here.
        XCTAssertNil(RequestCreationContinuityLayout.landingSlot(
            homeSlot: CGRect(x: 36, y: 20, width: 342, height: 121),
            containerFrame: containerFrame
        ))
        // Just inside the real bottom edge.
        XCTAssertEqual(
            RequestCreationContinuityLayout.landingSlot(
                homeSlot: CGRect(x: 36, y: 700, width: 342, height: 121),
                containerFrame: containerFrame
            ),
            CGRect(x: 36, y: 700, width: 342, height: 121)
        )
        // Past the real bottom edge.
        XCTAssertNil(RequestCreationContinuityLayout.landingSlot(
            homeSlot: CGRect(x: 36, y: 800, width: 342, height: 121),
            containerFrame: containerFrame
        ))
    }

    /// Home publishes its real first-slot frame, in the one shared continuity
    /// coordinate space, from the first owned slot only — and renders that
    /// slot's own card invisibly rather than omitting it while the same card
    /// is in flight above the stack, so the layout (and therefore every other
    /// card's position) is identical before, during, and after the landing.
    func testHomePublishesItsFirstOwnedSlotAndHoldsItsPlaceWhileTheCardIsInFlight() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("key: HomeOwnedRequestSlotFrameKey.self"))
        // W4-D2 coordinate-system FIX: `.global` is the one coordinate system
        // genuinely shared across the `NavigationStack` hosting boundary — a
        // space named on the app root does not resolve across it. See
        // `RequestCreationContinuityLayout.landingSlot`'s own doc comment.
        XCTAssertTrue(source.contains("proxy.frame(in: .global)"))
        XCTAssertFalse(
            source.contains(".named(RequestCreationContinuityLayout.coordinateSpaceName)"),
            "the invalid cross-NavigationStack named-space comparison must not return"
        )
        // W4-R3 urgency ordering: the landing slot is the continuity
        // request's own card by identity (first slot only without one).
        XCTAssertTrue(source.contains("isFirstSlot: Self.isContinuityLandingSlot("))
        XCTAssertTrue(source.contains(".opacity(landingContinuityCardOpacity(request))"))

        // The continuity overlay must read that same real coordinate system,
        // or the two measurements would not be comparable.
        let continuity = try continuitySource()
        XCTAssertTrue(continuity.contains("proxy.frame(in: .global)"))
        XCTAssertFalse(
            continuity.contains(".named(RequestCreationContinuityLayout.coordinateSpaceName)")
        )

        // The named coordinate space itself is dead architecture now — it
        // must not still be declared anywhere, including on the app
        // container that used to name it.
        XCTAssertFalse(continuity.contains("coordinateSpaceName"))
        let contentView = try String(
            contentsOf: repositoryFile("ios/CommonPlateios/CommonPlateios/ContentView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(contentView.contains("coordinateSpaceName"))
        XCTAssertFalse(contentView.contains(".coordinateSpace(name:"))
        XCTAssertTrue(contentView.contains(".onPreferenceChange(HomeOwnedRequestSlotFrameKey.self)"))
        XCTAssertTrue(contentView.contains("RequestCreationContinuityView("))
    }

    // MARK: - Motion contract

    /// The accepted total dwell is unchanged and is split inside itself;
    /// Reduce Motion keeps the identical timing and the identical
    /// destination, reducing displacement only.
    func testReduceMotionReducesDisplacementWithoutChangingTimingOrDestination() {
        let standard = RequestCreationContinuityMotionPlan.standard
        let reduced = RequestCreationContinuityMotionPlan.reducedMotion

        XCTAssertEqual(standard.totalDuration, .milliseconds(1600))
        XCTAssertEqual(reduced.totalDuration, standard.totalDuration)
        XCTAssertEqual(reduced.settleDwell, standard.settleDwell)
        XCTAssertEqual(reduced.landingDuration, standard.landingDuration)

        XCTAssertGreaterThan(standard.entranceRise, 0)
        XCTAssertEqual(reduced.entranceRise, 0)
        XCTAssertLessThan(standard.entranceScale, 1)
        XCTAssertEqual(reduced.entranceScale, 1)

        XCTAssertEqual(RequestCreationContinuityMotionPlan.plan(reduceMotion: false), standard)
        XCTAssertEqual(RequestCreationContinuityMotionPlan.plan(reduceMotion: true), reduced)

        // Standard motion's own measured-delta rule is unchanged: the full
        // travel to Home's real slot.
        let settled = CGRect(x: 24, y: 340, width: 342, height: 121)
        let slot = CGRect(x: 24, y: 196, width: 342, height: 121)
        XCTAssertEqual(
            RequestCreationContinuityLayout.landingTranslation(from: settled, to: slot),
            CGSize(width: 0, height: -144)
        )
    }

    /// W4-D2 Reduce Motion FIX (independent rereview MUST FIX): Reduce Motion
    /// must not perform the same full measured travel standard motion does.
    /// `reducedMotionLandingTranslation` follows the same real direction —
    /// nothing about the destination is invented — but its magnitude is
    /// capped far below the full delta.
    func testReducedMotionLandingTranslationIsSubstantiallySmallerThanTheFullMeasuredDelta() {
        let settled = CGRect(x: 24, y: 340, width: 342, height: 121)
        let farSlot = CGRect(x: 24, y: 196, width: 342, height: 121)

        let full = RequestCreationContinuityLayout.landingTranslation(from: settled, to: farSlot)
        let reduced = RequestCreationContinuityLayout.reducedMotionLandingTranslation(from: settled, to: farSlot)

        XCTAssertEqual(full, CGSize(width: 0, height: -144))
        XCTAssertLessThan(abs(reduced.height), abs(full.height))
        XCTAssertLessThanOrEqual(
            abs(reduced.height),
            RequestCreationContinuityLayout.reducedMotionMaximumLandingDisplacement
        )
        // Same direction as the full measured delta — this is bounded travel
        // toward the real destination, not a different destination.
        XCTAssertLessThan(reduced.height, 0)
    }

    /// A slot close enough that the full measured delta already sits under
    /// the Reduce Motion cap is not artificially inflated or redirected — it
    /// passes through unchanged, since there is nothing to bound.
    func testReducedMotionLandingTranslationPassesThroughAShortDeltaUnchanged() {
        let settled = CGRect(x: 24, y: 340, width: 342, height: 121)
        let nearSlot = CGRect(x: 24, y: 330, width: 342, height: 121)

        XCTAssertEqual(
            RequestCreationContinuityLayout.reducedMotionLandingTranslation(from: settled, to: nearSlot),
            RequestCreationContinuityLayout.landingTranslation(from: settled, to: nearSlot)
        )
    }

    /// The Reduce Motion rule shares the exact same fallback conditions as
    /// standard motion's own rule: no real destination produces no bounded
    /// travel either. This keeps Reduce Motion and the geometry fallback
    /// distinct branches — Reduce Motion never masquerades as the fallback,
    /// and the fallback is never affected by the Reduce Motion cap.
    func testReducedMotionLandingTranslationSharesTheSameFallbackAsStandardMotion() {
        let rect = CGRect(x: 24, y: 340, width: 342, height: 121)

        XCTAssertEqual(
            RequestCreationContinuityLayout.reducedMotionLandingTranslation(from: rect, to: nil),
            .zero
        )
        XCTAssertEqual(
            RequestCreationContinuityLayout.reducedMotionLandingTranslation(from: nil, to: rect),
            .zero
        )
        XCTAssertEqual(
            RequestCreationContinuityLayout.reducedMotionLandingTranslation(
                from: rect,
                to: CGRect(x: 0, y: 0, width: 0, height: 0)
            ),
            .zero
        )
    }

    // MARK: - Reduce Motion crossfade handoff (rereview MUST FIX)

    /// The root cause the rereview found: the overlay card's own fade-out
    /// used a hardcoded duration (0.4s) independent of the actual landing
    /// phase length (`landingDuration`, 500ms), leaving a ~0.1s window where
    /// the overlay card had already faded to invisible before Home's real
    /// card became visible at retirement. `landingSeconds` is now the one
    /// place that duration is read from, and the Reduce Motion landing plan
    /// must still total the accepted 1,600ms Success dwell.
    func testLandingSecondsMatchesTheActualLandingDurationForBothMotionPlans() {
        XCTAssertEqual(RequestCreationContinuityMotionPlan.standard.landingSeconds, 0.5, accuracy: 0.0001)
        XCTAssertEqual(RequestCreationContinuityMotionPlan.reducedMotion.landingSeconds, 0.5, accuracy: 0.0001)
        XCTAssertEqual(RequestCreationContinuityMotionPlan.reducedMotion.totalDuration, .milliseconds(1600))
    }

    /// The crossfade handoff's central invariant: during the landing phase —
    /// the one window where the base canvas has already faded away and Home
    /// is genuinely visible behind the overlay — the overlay card and Home's
    /// real card are never both invisible at once, for every combination of
    /// motion preference and destination availability. (Before landing, the
    /// opaque Success canvas still hides Home entirely, so neither card's
    /// visibility there is part of this invariant — see
    /// `RequestCreationContinuityView.body`'s `baseCanvas` opacity.) This is
    /// what actually proves "no empty-slot blink" — the defect the rereview
    /// found was exactly a case where both predicates below would have been
    /// false for a short window during landing.
    func testOverlayCardAndHomeCardAreNeverBothInvisibleDuringLanding() {
        for reduceMotion in [false, true] {
            for hasDestination in [false, true] {
                let overlayVisible = RequestCreationContinuityLayout.isOverlayCardVisible(
                    phase: .landing,
                    reduceMotion: reduceMotion,
                    hasLandingDestination: hasDestination
                )
                let homeRevealed = RequestCreationContinuityLayout.isHomeCardRevealed(
                    phase: .landing,
                    reduceMotion: reduceMotion,
                    hasLandingDestination: hasDestination
                )
                XCTAssertTrue(
                    overlayVisible || homeRevealed,
                    "reduceMotion \(reduceMotion), hasDestination \(hasDestination)"
                )
                // And never both targeted at once either: the two are
                // complementary, so one shared crossfade moves them together.
                XCTAssertNotEqual(
                    overlayVisible,
                    homeRevealed,
                    "reduceMotion \(reduceMotion), hasDestination \(hasDestination)"
                )
            }
        }
    }

    /// Home's real card is revealed early only during the landing, and only
    /// for the two crossfading branches: Reduce Motion with a real measured
    /// destination, and the no-usable-target in-place crossfade (either
    /// motion preference, W4-D2 final geometry-fallback card handoff).
    /// Standard motion with a real destination never reveals it early, and
    /// no branch reveals it before the landing is committed.
    func testHomeCardIsRevealedEarlyOnlyForTheCrossfadingLandingBranches() {
        XCTAssertTrue(
            RequestCreationContinuityLayout.isHomeCardRevealed(
                phase: .landing,
                reduceMotion: true,
                hasLandingDestination: true
            )
        )
        for reduceMotion in [false, true] {
            XCTAssertTrue(
                RequestCreationContinuityLayout.isHomeCardRevealed(
                    phase: .landing,
                    reduceMotion: reduceMotion,
                    hasLandingDestination: false
                ),
                "reduceMotion \(reduceMotion)"
            )
            for hasDestination in [false, true] {
                for phase: RequestCreationContinuityView.Phase in [.entering, .settled] {
                    XCTAssertFalse(
                        RequestCreationContinuityLayout.isHomeCardRevealed(
                            phase: phase,
                            reduceMotion: reduceMotion,
                            hasLandingDestination: hasDestination
                        ),
                        "\(phase) reduceMotion \(reduceMotion) hasDestination \(hasDestination)"
                    )
                }
            }
        }
        XCTAssertFalse(
            RequestCreationContinuityLayout.isHomeCardRevealed(
                phase: .landing,
                reduceMotion: false,
                hasLandingDestination: true
            )
        )
    }

    /// Standard motion with a real destination keeps its existing visibility
    /// policy exactly: invisible only while entering, fully visible for the
    /// rest of the presentation — the same instant, pixel-exact swap it
    /// always performed.
    func testStandardMotionValidTargetOverlayVisibilityIsUnchanged() {
        XCTAssertFalse(
            RequestCreationContinuityLayout.isOverlayCardVisible(
                phase: .entering,
                reduceMotion: false,
                hasLandingDestination: true
            )
        )
        for phase: RequestCreationContinuityView.Phase in [.settled, .landing] {
            XCTAssertTrue(
                RequestCreationContinuityLayout.isOverlayCardVisible(
                    phase: phase,
                    reduceMotion: false,
                    hasLandingDestination: true
                )
            )
        }
    }

    /// The geometry fallback (no real destination) is its own branch, not
    /// Reduce Motion's: regardless of motion preference it is the in-place
    /// crossfade, while the two valid-target branches stay exactly what they
    /// were.
    func testLandingHandoffBranchesStayDistinct() {
        XCTAssertEqual(
            RequestCreationContinuityLayout.landingHandoff(reduceMotion: false, hasLandingDestination: true),
            .measuredTravel
        )
        XCTAssertEqual(
            RequestCreationContinuityLayout.landingHandoff(reduceMotion: true, hasLandingDestination: true),
            .reducedMotionBoundedCrossfade
        )
        for reduceMotion in [false, true] {
            XCTAssertEqual(
                RequestCreationContinuityLayout.landingHandoff(
                    reduceMotion: reduceMotion,
                    hasLandingDestination: false
                ),
                .inPlaceCrossfade,
                "reduceMotion \(reduceMotion)"
            )
        }
    }

    /// Overlay retirement cannot cause a sudden first appearance of Home's
    /// card for any crossfading branch: by the exact phase (`.landing`) whose
    /// end triggers retirement, Home's card is already revealed — it does not
    /// first become visible only once continuity is gone.
    func testHomeCardIsAlreadyRevealedByTheLandingPhaseThatEndsInRetirement() {
        for (reduceMotion, hasDestination) in [(true, true), (false, false), (true, false)] {
            XCTAssertTrue(
                RequestCreationContinuityLayout.isHomeCardRevealed(
                    phase: .landing,
                    reduceMotion: reduceMotion,
                    hasLandingDestination: hasDestination
                ),
                "Home's card must already be revealed during the landing phase, not only after retirement (reduceMotion \(reduceMotion), hasDestination \(hasDestination))"
            )
        }
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

    private func boundedSource(_ source: String, from start: String, to end: String) throws -> String {
        guard let startRange = source.range(of: start) else {
            XCTFail("expected to find \(start)")
            return ""
        }
        guard let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            XCTFail("expected to find \(end) after \(start)")
            return ""
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    /// Matching `RequestCreationViewTests`' own repository-file resolution.
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
