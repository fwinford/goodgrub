//
//  RequestCardViewTests.swift
//  CommonPlateiosTests
//
// Focused W4-H2 coverage for `RequestCardView`'s pure presentation helpers.
import Foundation
import XCTest
@testable import CommonPlateios

final class RequestCardViewTests: XCTestCase {
    func testMealSwipesTextIsSingularForOne() {
        XCTAssertEqual(RequestCardView.mealSwipesText(1), "1 meal swipe")
    }

    func testMealSwipesTextIsPluralForOtherCounts() {
        XCTAssertEqual(RequestCardView.mealSwipesText(2), "2 meal swipes")
        XCTAssertEqual(RequestCardView.mealSwipesText(5), "5 meal swipes")
    }

    func testRemainingTimeRoundsUpToTheNextWholeMinute() {
        let now = Date()
        let text = RequestCardView.remainingTimeText(
            until: now.addingTimeInterval(10 * 60 + 1),
            now: now
        )
        XCTAssertEqual(text, "11 min left")
    }

    func testRemainingTimeIsSingularForOneMinute() {
        let now = Date()
        let text = RequestCardView.remainingTimeText(
            until: now.addingTimeInterval(45),
            now: now
        )
        XCTAssertEqual(text, "1 min left")
    }

    /// A reservation at or past its deadline is reconciled by the existing
    /// accepted reservation lifecycle elsewhere — this label never reads as
    /// a negative or zero countdown.
    func testRemainingTimeFloorsAtReservedRatherThanGoingNegative() {
        let now = Date()
        XCTAssertEqual(
            RequestCardView.remainingTimeText(until: now, now: now),
            "Reserved"
        )
        XCTAssertEqual(
            RequestCardView.remainingTimeText(until: now.addingTimeInterval(-30), now: now),
            "Reserved"
        )
    }
}
