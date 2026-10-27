//
//  RequestTimingContractTests.swift
//  CommonPlateiosTests
//
//  W3-R1: NYU campus time is the canonical product timezone, and request
//  timing is backend-authoritative. These cases pin the two halves of that on
//  the iOS side — that the app interprets and displays a requester's selection
//  in campus time no matter where the device is, and that it never restates
//  lifecycle rules the backend owns.
//

import XCTest
@testable import CommonPlateios

final class RequestTimingContractTests: XCTestCase {

    // MARK: - The canonical zone

    func testCampusTimeIsNewYorkNamedByIdentifierRatherThanOffset() {
        // An offset would be right for half the year and silently wrong for
        // the other half.
        XCTAssertEqual(NYUCampusTime.identifier, "America/New_York")
        XCTAssertEqual(NYUCampusTime.timeZone.identifier, "America/New_York")
        XCTAssertEqual(NYUCampusTime.calendar.timeZone, NYUCampusTime.timeZone)
    }

    /// The backend formats every window it sends in `America/New_York`
    /// (`NYU_TIME_ZONE` in `src/utils/date.ts`). If these two identifiers ever
    /// diverge, the app would interpret a selection in one zone while helpers
    /// read it in another.
    func testCampusTimeMatchesTheBackendIdentifier() throws {
        let backendSource = try String(
            contentsOf: repositoryFile("src/utils/date.ts"),
            encoding: .utf8
        )

        XCTAssertTrue(
            backendSource.contains("export const NYU_TIME_ZONE = 'America/New_York'"),
            "the backend's canonical timezone constant moved or was renamed"
        )
        XCTAssertTrue(backendSource.contains(NYUCampusTime.identifier))
    }

    // MARK: - Device timezone independence

    /// The property that matters for a student travelling, or for a phone left
    /// on another zone: the campus day boundary is a fact about New York, and
    /// is the same instant regardless of the device's own calendar.
    func testTheCampusDayBoundaryIsIndependentOfTheDeviceTimezone() throws {
        // 2026-07-28 20:00 UTC is 4:00 PM in New York and 1:00 PM in Los
        // Angeles, so a device-local boundary would land a different day's
        // midnight for one of them.
        let instant = try iso("2026-07-28T20:00:00.000Z")

        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))

        let campusDayEnd = try XCTUnwrap(
            RequestFoodView.endOfDay(containing: instant, calendar: NYUCampusTime.calendar)
        )

        // Midnight in New York on the 29th, which is 04:00 UTC.
        XCTAssertEqual(campusDayEnd, try iso("2026-07-29T04:00:00.000Z"))
        XCTAssertNotEqual(
            campusDayEnd,
            RequestFoodView.endOfDay(containing: instant, calendar: pacific)
        )
        XCTAssertNotEqual(
            campusDayEnd,
            RequestFoodView.endOfDay(containing: instant, calendar: tokyo)
        )
    }

    /// The same selection, read back in campus time, is the New York wall
    /// clock the requester intended — not the device's.
    func testASelectedInstantReadsAsNewYorkWallClockOnAPacificDevice() throws {
        let selected = try iso("2026-07-28T22:00:00.000Z")

        let campusFormatter = DateFormatter()
        campusFormatter.locale = Locale(identifier: "en_US_POSIX")
        campusFormatter.dateFormat = "h:mm a"
        campusFormatter.timeZone = NYUCampusTime.timeZone

        let pacificFormatter = DateFormatter()
        pacificFormatter.locale = Locale(identifier: "en_US_POSIX")
        pacificFormatter.dateFormat = "h:mm a"
        pacificFormatter.timeZone = try XCTUnwrap(
            TimeZone(identifier: "America/Los_Angeles")
        )

        XCTAssertEqual(campusFormatter.string(from: selected), "6:00 PM")
        // What the requester would have seen if the screen had used the device
        // zone: three hours off, and no indication anything was wrong.
        XCTAssertEqual(pacificFormatter.string(from: selected), "3:00 PM")
    }

    /// The screen must actually install campus time into the environment. A
    /// `DatePicker` renders in the environment's timezone, so without this the
    /// picker would offer device wall-clock times while the backend read the
    /// resulting instant as New York.
    func testRequestFormInstallsCampusTimeIntoTheEnvironment() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(#".environment(\.timeZone, NYUCampusTime.timeZone)"#))
        XCTAssertTrue(source.contains(#".environment(\.calendar, NYUCampusTime.calendar)"#))
        XCTAssertTrue(source.contains("NYUCampusTime.calendar"))
        XCTAssertFalse(
            source.contains("Calendar.current"),
            "the request form must not fall back to the device calendar"
        )
    }

    // MARK: - DST

    /// The campus day boundary is a calendar question, not 24 hours of
    /// arithmetic. On the two transition days a fixed-offset implementation is
    /// an hour wrong in each direction.
    func testTheCampusDayBoundaryIsCalendarDerivedAcrossDSTTransitions() throws {
        let calendar = NYUCampusTime.calendar

        // Spring forward: 2027-03-14 is a 23-hour local day.
        let springMorning = try iso("2027-03-14T12:00:00.000Z")
        let springStart = calendar.startOfDay(for: springMorning)
        let springEnd = try XCTUnwrap(
            RequestFoodView.endOfDay(containing: springMorning, calendar: calendar)
        )
        XCTAssertEqual(springEnd.timeIntervalSince(springStart), 23 * 3600)

        // Fall back: 2027-11-07 is a 25-hour local day.
        let fallMorning = try iso("2027-11-07T12:00:00.000Z")
        let fallStart = calendar.startOfDay(for: fallMorning)
        let fallEnd = try XCTUnwrap(
            RequestFoodView.endOfDay(containing: fallMorning, calendar: calendar)
        )
        XCTAssertEqual(fallEnd.timeIntervalSince(fallStart), 25 * 3600)

        // Both boundaries are still local midnight, which is the point: the
        // day changed length and the boundary did not move off midnight.
        for (day, end) in [(springMorning, springEnd), (fallMorning, fallEnd)] {
            _ = day
            let components = calendar.dateComponents([.hour, .minute], from: end)
            XCTAssertEqual(components.hour, 0)
            XCTAssertEqual(components.minute, 0)
        }
    }

    // MARK: - Near-now Later is never silently converted

    func testQuickTimesAreDerivedFromNowOnNearbyHalfHourBoundaries() throws {
        // 4:07 PM New York. The quick row begins at the next half-hour and
        // continues in 30-minute steps; no example clock values are constants.
        let now = try iso("2026-07-28T20:07:00.000Z")
        let choices = RequestFoodView.quickScheduledTimes(
            now: now,
            calendar: NYUCampusTime.calendar
        )

        XCTAssertEqual(
            choices,
            [
                try iso("2026-07-28T20:30:00.000Z"),
                try iso("2026-07-28T21:00:00.000Z"),
                try iso("2026-07-28T21:30:00.000Z")
            ]
        )
        XCTAssertTrue(choices.allSatisfy {
            RequestFoodView.isValidScheduledWindow(
                startingAt: $0,
                now: now,
                calendar: NYUCampusTime.calendar
            )
        })
    }

    func testQuickTimesStopAtTheAcceptedSameDaySchedulingCutoff() throws {
        // 10:47 PM New York: only 11:00 and 11:30 remain before the existing
        // 30-minutes-before-midnight latest-start boundary.
        let now = try iso("2026-07-29T02:47:00.000Z")
        XCTAssertEqual(
            RequestFoodView.quickScheduledTimes(
                now: now,
                calendar: NYUCampusTime.calendar
            ),
            [
                try iso("2026-07-29T03:00:00.000Z"),
                try iso("2026-07-29T03:30:00.000Z")
            ]
        )
    }

    func testQuickTimesAreEmptyWhenLaterIsUnavailable() throws {
        let now = try iso("2026-07-29T03:45:00.000Z")
        XCTAssertTrue(
            RequestFoodView.quickScheduledTimes(
                now: now,
                calendar: NYUCampusTime.calendar
            ).isEmpty
        )
    }

    /// The accepted recovery path. A `Later` selection that has slipped into
    /// the past is refused with an instruction, and is never quietly rewritten
    /// into an ASAP request the student did not ask for.
    func testALapsedLaterSelectionIsRefusedRatherThanConvertedToASAP() throws {
        let now = try iso("2026-07-28T20:00:00.000Z")
        let alreadyPassed = try iso("2026-07-28T19:59:00.000Z")

        XCTAssertThrowsError(
            try RequestFoodView.makePayload(
                draft: laterDraft(preferredPickupTime: alreadyPassed),
                now: now,
                calendar: NYUCampusTime.calendar
            )
        ) { error in
            XCTAssertEqual(error as? RequestFoodFormError, .invalidScheduledTime)
        }
    }

    /// Once no start remains in the campus day, the picker is withdrawn and the
    /// error names ASAP as the move — still a refusal the student acts on, not
    /// an automatic substitution.
    func testAnExpiredSchedulingDayKeepsTheExplicitRecoveryPath() throws {
        // 11:45 PM in New York: past the last selectable start.
        let lateNight = try iso("2026-07-29T03:45:00.000Z")

        XCTAssertFalse(
            RequestFoodView.isScheduledTimingAvailable(
                now: lateNight,
                calendar: NYUCampusTime.calendar
            )
        )
        XCTAssertEqual(
            RequestFoodView.availableTimingOptions(
                now: lateNight,
                calendar: NYUCampusTime.calendar
            ),
            [.asap]
        )
        XCTAssertEqual(
            RequestFoodFormError.scheduledTimingUnavailable.message,
            RequestFoodView.lapsedScheduledTimingNotice
        )
        XCTAssertTrue(
            RequestFoodView.lapsedScheduledTimingNotice.contains("Choose ASAP")
        )
    }

    /// A start selected for later today stays `scheduled` all the way to the
    /// payload. The one guarantee behind "must not silently become ASAP".
    func testANearFutureLaterSelectionStaysScheduled() throws {
        let now = try iso("2026-07-28T20:00:00.000Z")
        let inOneMinute = try iso("2026-07-28T20:01:00.000Z")

        let payload = try RequestFoodView.makePayload(
            draft: laterDraft(preferredPickupTime: inOneMinute),
            now: now,
            calendar: NYUCampusTime.calendar
        )

        XCTAssertEqual(payload.timing, .scheduled)
        XCTAssertEqual(payload.windowStart, inOneMinute)
    }

    /// A complete W4-R4 Meal Exchange `Later` draft. R4 preserves R2's
    /// accepted Timing behaviour unchanged; the structured entries simply
    /// travel with it.
    private func laterDraft(preferredPickupTime: Date) -> RequestFoodFormDraft {
        RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            menuPath: .mealExchange,
            timing: .later,
            preferredPickupTime: preferredPickupTime,
            mealSwipes: 2,
            mealEntries: ["Chicken bowl", "Side salad", "", "", ""]
        )
    }

    // MARK: - Lifecycle stays backend-owned

    /// Helper-facing timing text is the backend's `pickupWindowText`, which is
    /// already formatted in campus time. Requester and helper therefore read
    /// one value derived from one set of backend instants.
    func testHelperTimingTextIsRenderedFromTheBackendWindowText() throws {
        let backendText = "Jul 28, 6:00 PM – 9:00 PM"
        let request = FoodRequest(
            id: "scheduled",
            diningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            foodDescription: "Chicken bowl",
            pickupWindowText: backendText,
            mealSwipes: 2,
            windowStart: try iso("2026-07-28T22:00:00.000Z"),
            windowEnd: try iso("2026-07-29T01:00:00.000Z"),
            createdAt: try iso("2026-07-28T16:00:00.000Z"),
            expiresAt: try iso("2026-07-29T01:00:00.000Z"),
            status: .open
        )

        XCTAssertEqual(request.timingDescription, backendText)
        XCTAssertEqual(request.listTimingDescription, backendText)
    }

    /// A helper who opens a scheduled request before its start is told it has
    /// not begun — never that it is gone. The two are opposite situations and
    /// only one of them is worth coming back for.
    func testNotYetAvailableIsItsOwnClaimOutcome() {
        let mapped = ClaimPresentationError.map(
            RequestServiceError.serverError(
                code: ClaimErrorCode.requestNotYetAvailable,
                message: "This request is not available to help with yet."
            )
        )

        XCTAssertEqual(mapped, .notYetAvailable)
        XCTAssertNotEqual(mapped, .noLongerAvailable)
        XCTAssertEqual(mapped.message, RequestDetailView.notYetAvailableNotice)
        XCTAssertFalse(mapped.message.contains("no longer"))
        // The helper can still act once the start arrives, so the action stays.
        XCTAssertTrue(RequestDetailView.showsClaimAction(for: mapped))
    }

    // MARK: - Helpers

    private func iso(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try XCTUnwrap(formatter.date(from: value), "unparseable fixture \(value)")
    }

    /// Walks up from this file to the repository root, so the source-text
    /// assertions above read the real tracked files rather than a copy.
    private func repositoryFile(_ relativePath: String) throws -> URL {
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
