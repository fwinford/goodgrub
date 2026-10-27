import XCTest
@testable import CommonPlateios

final class RequestTimingLabelsTests: XCTestCase {
    private func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ") }

    private var calendar: Calendar { NYUCampusTime.calendar }

    private func date(_ d: Int, _ h: Int, _ m: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!
    }

    func testAsapLabelsAreSelectedCopy() {
        XCTAssertEqual(RequestTimingLabels.asapCard, "ASAP")
        XCTAssertEqual(RequestTimingLabels.asapDetail, "Requested: ASAP")
    }

    func testScheduledLabelsUseAuthoritativeCampusTimes() {
        let now = date(14, 12, 0)
        XCTAssertEqual(plain(RequestTimingLabels.scheduledCard(start: date(14, 18, 30), now: now)), "Today · 6:30 PM")
        XCTAssertEqual(plain(RequestTimingLabels.scheduledDetail(start: date(14, 18, 30))), "Starts at 6:30 PM")
        XCTAssertEqual(plain(RequestTimingLabels.availableUntil(date(14, 21, 30))), "Available until 9:30 PM")
        XCTAssertEqual(plain(RequestTimingLabels.requestExpiresAt(date(14, 21, 16))), "Request expires at 9:16 PM")
    }

    func testAStartOnAnotherCampusDayNeverClaimsToday() {
        let label = plain(RequestTimingLabels.scheduledCard(start: date(15, 9, 0), now: date(14, 12, 0)))
        XCTAssertFalse(label.hasPrefix("Today"))
        XCTAssertTrue(label.hasSuffix("9:00 AM"))
    }

    func testAvailableUntilIsNotAPickupDeadlineOnPlacedSurfaces() throws {
        let fulfill = try String(contentsOfFile: #filePath
            .replacingOccurrences(of: "CommonPlateiosTests/RequestTimingLabelsTests.swift",
                                  with: "CommonPlateios/Views/FulfillRequestView.swift"), encoding: .utf8)
        XCTAssertFalse(fulfill.contains("availableUntil"))
        let placed = try String(contentsOfFile: #filePath
            .replacingOccurrences(of: "CommonPlateiosTests/RequestTimingLabelsTests.swift",
                                  with: "CommonPlateios/Views/PlacedOrderDetailView.swift"), encoding: .utf8)
        XCTAssertFalse(placed.contains("availableUntil"))
    }
}
