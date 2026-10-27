//
//  BlockedStudent.swift
//  CommonPlateios
//

import Foundation

/// One block the current participant owns, described only by the interaction
/// context they were already shown (W4-U1.3): the other student's role, the
/// dining location, and when the request was made.
///
/// There is no name, address, or identifier of the other participant here, and
/// no field a later change could quietly fill with one. `id` identifies this
/// block row for Unblock and nothing else.
struct BlockedStudent: Identifiable, Equatable {
    enum Role: Equatable {
        /// The blocked student posted the request the owner helped with or
        /// viewed.
        case requester
        /// The blocked student helped with the owner's request.
        case helper
    }

    let id: String
    let role: Role
    let diningLocation: String
    let interactionAt: Date
}

enum BlockedStudentPresentation {
    /// Muted, non-interactive role metadata.
    static func roleTitle(for student: BlockedStudent) -> String {
        switch student.role {
        case .requester: return "REQUESTER"
        case .helper: return "HELPER"
        }
    }

    /// e.g. `Oct 7 · 6:15 PM`, on NYU campus time like every other request time
    /// in the product, unless a test supplies a zone.
    static func timestamp(
        for student: BlockedStudent,
        timeZone: TimeZone = NYUCampusTime.timeZone,
        locale: Locale = Locale(identifier: "en_US")
    ) -> String {
        let day = DateFormatter()
        day.locale = locale
        day.timeZone = timeZone
        day.setLocalizedDateFormatFromTemplate("MMMd")
        let time = DateFormatter()
        time.locale = locale
        time.timeZone = timeZone
        time.setLocalizedDateFormatFromTemplate("jmm")
        return "\(day.string(from: student.interactionAt)) · \(time.string(from: student.interactionAt))"
    }

    /// The normal one-line form: `Palladium · Oct 7 · 6:15 PM`.
    static func singleLine(
        for student: BlockedStudent,
        timeZone: TimeZone = NYUCampusTime.timeZone,
        locale: Locale = Locale(identifier: "en_US")
    ) -> String {
        "\(student.diningLocation) · \(timestamp(for: student, timeZone: timeZone, locale: locale))"
    }
}
