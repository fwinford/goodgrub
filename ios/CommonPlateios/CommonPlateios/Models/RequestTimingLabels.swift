//
//  RequestTimingLabels.swift
//  CommonPlateios
//
//  W4-B1 — Faith-selected request timing labels. Presentation only: every
//  value derives from the backend's `windowStart` / `expiresAt` in campus
//  time; `timingDescription` and the backend's `pickupWindowText` are
//  unchanged. "Available until" describes availability to helpers and is
//  never a pickup deadline after placement.
//

import Foundation

enum RequestTimingLabels {
    static let asapCard = "ASAP"
    static let asapDetail = "Requested: ASAP"

    static func clockText(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, timeZone: NYUCampusTime.timeZone)
        )
    }

    /// `Today · 6:30 PM`. A start on another campus day names its date so the
    /// label is never a wrong "Today".
    static func scheduledCard(start: Date, now: Date = Date()) -> String {
        let calendar = NYUCampusTime.calendar
        if calendar.isDate(start, inSameDayAs: now) {
            return "Today · \(clockText(start))"
        }
        let day = start.formatted(
            Date.FormatStyle(timeZone: NYUCampusTime.timeZone).month(.abbreviated).day()
        )
        return "\(day) · \(clockText(start))"
    }

    static func scheduledDetail(start: Date) -> String {
        "Starts at \(clockText(start))"
    }

    static func availableUntil(_ expiresAt: Date) -> String {
        "Available until \(clockText(expiresAt))"
    }

    /// Public Request Detail's single quiet timing line (W4-N1, Faith).
    static func requestExpiresAt(_ expiresAt: Date) -> String {
        "Request expires at \(clockText(expiresAt))"
    }
}

extension FoodRequest {
    /// Home-card timing: `ASAP`, or `Today · 6:30 PM`. Falls back to the
    /// backend's own text when no start time is available.
    func cardTimingLabel(now: Date = Date()) -> String {
        guard timing == .later, let start = windowStart else {
            return timing == .asap ? RequestTimingLabels.asapCard : pickupWindowText
        }
        return RequestTimingLabels.scheduledCard(start: start, now: now)
    }

    /// Detail timing: `Requested: ASAP` or `Starts at 6:30 PM`.
    var detailTimingLabel: String {
        guard timing == .later, let start = windowStart else {
            return timing == .asap ? RequestTimingLabels.asapDetail : pickupWindowText
        }
        return RequestTimingLabels.scheduledDetail(start: start)
    }

    var availableUntilLabel: String {
        RequestTimingLabels.availableUntil(expiresAt)
    }

    var requestExpiresAtLabel: String {
        RequestTimingLabels.requestExpiresAt(expiresAt)
    }
}
