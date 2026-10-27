import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

final class UI1WelcomeMotionTests: XCTestCase {
    func testScrollCueIsAConfidentDownwardDoubleBounceAndDisabledForReduceMotion() {
        let travel = OnboardingMotion.scrollCueTravel
        XCTAssertGreaterThanOrEqual(travel, 6, "The bounce should be clearly noticeable.")
        XCTAssertLessThanOrEqual(travel, 10, "The bounce should not be distracting.")
        XCTAssertGreaterThan(OnboardingMotion.scrollCueDuration, 0)
        XCTAssertLessThanOrEqual(OnboardingMotion.scrollCueDuration, 4)

        let hop = OnboardingMotion.scrollCueBounceFraction
        func offset(_ progress: Double) -> CGFloat {
            OnboardingMotion.scrollCueOffset(progress: progress, reduceMotion: false)
        }
        XCTAssertEqual(offset(0), 0, accuracy: 0.001)
        XCTAssertEqual(offset(1), 0, accuracy: 0.001, "The repeating cycle has no seam.")
        XCTAssertEqual(offset(hop / 2), travel, accuracy: 0.001, "First hop reaches full travel.")
        XCTAssertEqual(offset(hop * 1.5), travel * OnboardingMotion.scrollCueSecondBounceRatio, accuracy: 0.001,
                       "Second hop is smaller.")
        XCTAssertLessThan(offset(hop * 1.5), offset(hop / 2))
        XCTAssertEqual(offset(hop), 0, accuracy: 0.001, "The cue touches rest between hops.")
        XCTAssertEqual(offset(min(hop * 2 + 0.05, 1)), 0, accuracy: 0.001, "The cycle ends with a rest.")

        for step in 0...100 {
            let progress = Double(step) / 100
            XCTAssertGreaterThanOrEqual(offset(progress), -0.001, "The cue must never rise toward its label.")
            XCTAssertLessThanOrEqual(offset(progress), travel + 0.001)
            XCTAssertEqual(
                OnboardingMotion.scrollCueOffset(progress: progress, reduceMotion: true), 0,
                "Reduce Motion keeps the cue still."
            )
        }
    }

    func testStoryCardsRevealOnceWhenVisibleAndImmediatelyForAccessibility() {
        XCTAssertGreaterThan(OnboardingMotion.storyCardRevealOffset, 0)
        XCTAssertLessThanOrEqual(OnboardingMotion.storyCardRevealOffset, 16)
        XCTAssertGreaterThan(OnboardingMotion.storyCardRevealDuration, 0)
        XCTAssertLessThanOrEqual(OnboardingMotion.storyCardRevealDuration, 1)
        XCTAssertGreaterThan(OnboardingMotion.storyCardVisibilityThreshold, 0)
        XCTAssertLessThanOrEqual(OnboardingMotion.storyCardVisibilityThreshold, 1)

        let firstReveal = OnboardingMotion.addingVisibleStoryCards([2], to: [0])
        XCTAssertEqual(firstReveal, [0, 2])
        XCTAssertEqual(OnboardingMotion.addingVisibleStoryCards([], to: firstReveal), firstReveal)
        XCTAssertFalse(OnboardingMotion.isStoryCardRevealed(
            index: 3,
            revealedCards: firstReveal,
            reduceMotion: false
        ))
        XCTAssertTrue(OnboardingMotion.isStoryCardRevealed(
            index: 3,
            revealedCards: firstReveal,
            reduceMotion: true
        ))

        XCTAssertFalse(OnboardingMotion.shouldRevealImmediately(reduceMotion: false, voiceOverEnabled: false))
        XCTAssertTrue(OnboardingMotion.shouldRevealImmediately(reduceMotion: true, voiceOverEnabled: false))
        XCTAssertTrue(OnboardingMotion.shouldRevealImmediately(reduceMotion: false, voiceOverEnabled: true))
    }

    func testStoryCardVisibilityUsesTheConfiguredVisibleAreaThreshold() {
        let card = CGRect(x: 0, y: 0, width: 100, height: 100)
        let visibleHeightAtThreshold = card.height * OnboardingMotion.storyCardVisibilityThreshold
        XCTAssertTrue(OnboardingMotion.isStoryCardVisible(
            card,
            within: CGRect(x: 0, y: 0, width: card.width, height: visibleHeightAtThreshold)
        ))
        XCTAssertFalse(OnboardingMotion.isStoryCardVisible(
            card,
            within: CGRect(x: 0, y: 0, width: card.width, height: max(0, visibleHeightAtThreshold - 0.01))
        ))
        XCTAssertFalse(OnboardingMotion.isStoryCardVisible(
            card,
            within: CGRect(x: 0, y: card.maxY + 1, width: card.width, height: card.height)
        ))
    }

    @MainActor
    func testStoryCardWrapsAtCompactWidthAndAccessibilityTextSize() {
        let step = OnboardingCopy.story[1]
        let constraints = CGSize(width: 244, height: 2_000)
        let standardCard = UIHostingController(
            rootView: OnboardingStoryCard(step: step, iconName: "fork.knife", isIndented: false)
        )
        let accessibilityCard = UIHostingController(
            rootView: OnboardingStoryCard(step: step, iconName: "fork.knife", isIndented: false)
                .dynamicTypeSize(.accessibility3)
        )

        let standardSize = standardCard.sizeThatFits(in: constraints)
        let accessibilitySize = accessibilityCard.sizeThatFits(in: constraints)

        XCTAssertGreaterThan(standardSize.width, 0)
        XCTAssertLessThanOrEqual(accessibilitySize.width, constraints.width)
        XCTAssertGreaterThan(
            accessibilitySize.height,
            standardSize.height,
            "Story text should wrap and remain readable at accessibility text sizes."
        )
    }
}
