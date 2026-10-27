//
//  CommonPlateStatus.swift
//  CommonPlateios
//
// Shared semantic-state presentation (W4-F1). Normal content and disabled
// controls already have a native answer (ordinary content; `.disabled()`)
// and are not represented here. This covers the remaining states later
// slices need a consistent, truthful way to present: empty, loading,
// temporarily unavailable, ordinary error, conflict/no-longer-available,
// mutation-outcome-uncertain, expiration/warning, and success.
//
// Every case pairs a distinct SF Symbol with its text, so meaning never rests
// on color alone. This is presentation only: it decides how a state looks,
// never what state a screen is in — callers remain responsible for mapping
// their own truthful backend/store outcome onto one case.
import SwiftUI

enum CommonPlateStatusKind: CaseIterable {
    case loading
    case empty
    case unavailable
    case error
    case conflict
    case uncertain
    case warning
    case success

    var symbolName: String {
        switch self {
        case .loading: return "arrow.triangle.2.circlepath"
        case .empty: return "tray"
        case .unavailable: return "nosign"
        case .error: return "exclamationmark.circle"
        case .conflict: return "person.crop.circle.badge.xmark"
        case .uncertain: return "questionmark.circle"
        case .warning: return "clock.badge.exclamationmark"
        case .success: return "checkmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .loading: return .secondary
        case .empty: return .secondary
        case .unavailable: return .secondary
        case .error: return .red
        case .conflict: return .orange
        // Deliberately off the orange/red spectrum: an uncertain mutation
        // outcome (e.g. an unresolved W3-D1 create) must never read as a
        // failure or a warning at a glance. A calm blue-gray, distinct from
        // every other kind's tint, keeps "we don't know yet" visually
        // distinct from "something is wrong" while the icon/copy still carry
        // the meaning for anyone who can't perceive the color difference.
        case .uncertain: return Color("CommonPlateUncertainTint")
        case .warning: return .orange
        case .success: return .green
        }
    }

    /// A spoken-word cue so VoiceOver conveys the same distinction sighted
    /// users get from the icon, not only from color.
    var accessibilityPrefix: String {
        switch self {
        case .loading: return "Loading."
        case .empty: return "Nothing here yet."
        case .unavailable: return "Temporarily unavailable."
        case .error: return "Error."
        case .conflict: return "No longer available."
        case .uncertain: return "Outcome uncertain."
        case .warning: return "Warning."
        case .success: return "Success."
        }
    }
}

/// A shared inline status presentation. `ProgressView` replaces the static
/// icon for `.loading`, since a spinner is the native, immediately legible
/// way to show in-progress work.
struct CommonPlateInlineStatus: View {
    let kind: CommonPlateStatusKind
    let message: String

    var body: some View {
        Label {
            Text(message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            if kind == .loading {
                ProgressView()
            } else {
                Image(systemName: kind.symbolName)
            }
        }
        .foregroundStyle(kind.tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(kind: kind, message: message))
    }

    /// Extracted as a pure function so the spoken-label composition itself —
    /// not just `CommonPlateStatusKind.accessibilityPrefix` in isolation — is
    /// directly testable without instantiating SwiftUI view hierarchy.
    static func accessibilityLabel(kind: CommonPlateStatusKind, message: String) -> String {
        "\(kind.accessibilityPrefix) \(message)"
    }
}
