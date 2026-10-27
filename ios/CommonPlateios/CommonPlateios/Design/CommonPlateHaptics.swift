//
//  CommonPlateHaptics.swift
//  CommonPlateios
//
// W4-M1's "selective, semantic haptics" direction. W4-R2 call sites: one
// success haptic at authoritative request creation, one error haptic at an
// authoritative definitive non-create. Nothing else in the requester journey
// — including any screenshot proposal state, D1 checking/ambiguity, or
// ordinary local validation — may trigger either. W4-H1 adds exactly one
// success call site: the helper success presentation's resolve after
// authoritative placement (never on submit, ambiguity, failure, or relaunch).
import UIKit

@MainActor
enum CommonPlateHaptics {
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
