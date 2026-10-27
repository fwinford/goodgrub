import XCTest
@testable import CommonPlateios

/// W4-N1 walkthrough (Faith): Home's helping badge must not lag the
/// Helping screen / 5-minute warning. It redraws on whole-minute boundaries
/// of the reservation deadline, still in whole minutes only.
final class HomeHelpingBadgeRefreshTests: XCTestCase {
    func testScheduleStartIsInThePastAndAlignedToTheDeadline() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        for offset in [1.0, 59, 60, 61, 299, 300, 301, 437, 900] {
            let deadline = now.addingTimeInterval(offset)
            let start = RequestCardView.minuteAlignedStart(for: deadline, now: now)
            XCTAssertLessThanOrEqual(start, now)
            let gap = deadline.timeIntervalSince(start)
            XCTAssertEqual(gap.truncatingRemainder(dividingBy: 60), 0, accuracy: 0.0001)
        }
    }

    func testReadingAtEachScheduledTickMatchesTheRemainingMinutes() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let deadline = now.addingTimeInterval(7 * 60 - 20)
        let start = RequestCardView.minuteAlignedStart(for: deadline, now: now)
        var tick = start
        while tick <= now { tick.addTimeInterval(60) }
        XCTAssertEqual(RequestCardView.remainingTimeText(until: deadline, now: now), "7 min left")
        XCTAssertEqual(RequestCardView.remainingTimeText(until: deadline, now: tick), "6 min left")
        XCTAssertEqual(
            RequestCardView.remainingTimeText(until: deadline, now: tick.addingTimeInterval(2 * 60)),
            "4 min left"
        )
        XCTAssertEqual(RequestCardView.remainingTimeText(until: deadline, now: deadline), "Reserved")
    }

    func testHelpingBadgeIsDrivenByAPeriodicTimeline() throws {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        url.appendPathComponent("CommonPlateios/Views/RequestCardView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("TimelineView(.periodic(from: Self.minuteAlignedStart(for: claimExpiresAt), by: 60))"))
        XCTAssertTrue(source.contains("remainingTimeText(until: claimExpiresAt, now: context.date)"))
    }
}
