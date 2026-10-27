//
//  NYUCampusTime.swift
//  CommonPlateios
//

import Foundation

/// The canonical product timezone, on the iOS side.
///
/// A request time means NYU campus time, wherever the device happens to be.
/// Everything the requester picks and everything either side reads is
/// interpreted and displayed here, so a phone left on Pacific time shows the
/// same New York wall clock a phone in Manhattan does.
///
/// The identifier matches `NYU_TIME_ZONE` in `src/utils/date.ts`, which the
/// backend uses to format the window text this app renders. It is an IANA
/// identifier, never a fixed offset, so every conversion stays DST-correct on
/// its own — `Calendar` and `TimeZone` do the work rather than hour arithmetic.
///
/// This is presentation and local input validation only. Lifecycle truth —
/// whether a request is visible, claimable, or expired — is decided by the
/// backend from absolute instants, and nothing here recomputes it.
enum NYUCampusTime {
    static let identifier = "America/New_York"

    /// Force-unwrapped deliberately: a missing `America/New_York` means a
    /// broken timezone database, which is a packaging failure rather than a
    /// runtime condition any screen could present. Silently falling back to
    /// the device timezone would be worse — it would produce a wrong time that
    /// looks right.
    static let timeZone = TimeZone(identifier: identifier)!

    /// The device's calendar, moved onto campus time. The calendar identifier
    /// and locale stay the user's, so only the zone is overridden.
    static var calendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        return calendar
    }
}
