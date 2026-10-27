//
//  ConversationPresentation.swift
//  CommonPlateios
//
// W4-MSG1 CP3 (dormant). Pure presentation model for the request-linked chat:
// approved copy, timestamp grouping and accessibility text. Wording marked
// PROVISIONAL is not an accepted product decision; final closed/offline/failed
// copy remains a Faith/design item for the later integration pass.
//
// Nothing here names a relationship state (Block, release, replacement,
// pickup, expiry, moderation) and nothing distinguishes helper from requester:
// a message is only ever "own" or "other".
import Foundation

nonisolated enum ConversationCopy {
    // Figma 1449:6880 / 1473:6915 (UX proposal).
    static let title = "Chat"
    static let emptyLine = "For questions or updates about the order."
    static let composerPlaceholder = "Message…"
    static let failedSheetTitle = "Message not sent"
    static let notSent = "Not sent"
    static let deliveryUnconfirmed = "Delivery unconfirmed"
    static let tapToRetry = "Tap to retry"
    static let tapForDetails = "Tap for details"
    static let removeMessage = "Remove message"
    static let tryAgain = "Try again"
    static let cancel = "Cancel"
    static let sendLabel = "Send message"

    // PROVISIONAL (not in the approved frames).
    static let unavailableTitle = "This conversation is unavailable."
    static let unavailableDetail = "You can no longer send or read messages here."
    static let authorityRequiredLine = "Verify your account to use chat."
    static let loading = "Loading messages…"
    static let loadingOlder = "Earlier messages"
    static let historyFailed = "Couldn't load earlier messages."
    static let retryOlder = "Retry loading earlier messages"
    static let loadOlder = "Load earlier messages"
    static let offlineBanner = "You're offline. Messages may be delayed."
    static let reconnecting = "Reconnecting…"
    static let openFailed = "Couldn't open this chat."
    static let retry = "Retry"
    static let reviseMessage = "Please revise your message."
    static let sending = "Sending"
    static let capacityNotice = "Too many unsent messages. Resolve them to send more."

    /// Derived from the failure class only, never from relationship state.
    static func failureExplanation(_ failure: LocalSendFailure) -> String {
        switch failure {
        case .unconfirmed: return "You're offline. Reconnect before trying again." // Figma 1473:6946
        case .notDelivered: return "Your message wasn't sent. Try again."
        case .refused(.textNotAllowed): return reviseMessage
        case .refused(.invalidMessage), .refused(.identityConflict): return "This message can't be sent."
        }
    }
}

/// The chat-entry unread capsule's wording. Only the recipient's own count is
/// ever shown; nothing here describes the other party's reading.
nonisolated enum ConversationUnreadPresentation {
    static let displayCap = 99

    /// Nil (no capsule) for zero, negative or unknown counts.
    static func badgeText(for count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return count > displayCap ? "\(displayCap)+" : String(count)
    }

    static func accessibilityLabel(for count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        if count > displayCap { return "More than \(displayCap) unread messages" }
        return count == 1 ? "1 unread message" : "\(count) unread messages"
    }
}

nonisolated enum ConversationLayout {
    /// Minimum interactive target, in points.
    static let minimumTarget: CGFloat = 44
    static let bubbleCornerRadius: CGFloat = 18
    static let timestampGroupGap: TimeInterval = 60 * 60
}

nonisolated struct ChatBubbleModel: Equatable, Identifiable {
    enum Kind: Equatable {
        case outgoing
        case incoming
        case sending
        case failed(LocalSendFailure)
    }

    let id: String
    let text: String
    let kind: Kind
    let accessibilityLabel: String
    let accessibilityHint: String?
}

nonisolated enum ConversationRow: Equatable, Identifiable {
    case timestamp(id: String, label: String)
    case bubble(ChatBubbleModel)

    var id: String {
        switch self {
        case .timestamp(let id, _): return "t-\(id)"
        case .bubble(let model): return model.id
        }
    }
}

nonisolated enum ConversationPresentation {
    static func rows(
        for items: [ConversationItem],
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [ConversationRow] {
        var rows: [ConversationRow] = []
        var lastGroupTime: Date?
        for item in items {
            let date: Date
            let model: ChatBubbleModel
            switch item {
            case .message(let message):
                date = message.createdAt
                model = bubble(for: message, calendar: calendar, locale: locale)
            case .local(let local):
                date = local.createdAt
                model = bubble(for: local)
            }
            if lastGroupTime == nil || date.timeIntervalSince(lastGroupTime!) >= ConversationLayout.timestampGroupGap {
                rows.append(.timestamp(
                    id: model.id,
                    label: timestampLabel(for: date, now: now, calendar: calendar, locale: locale)
                ))
                lastGroupTime = date
            }
            rows.append(.bubble(model))
        }
        return rows
    }

    static func bubble(for message: ChatMessage, calendar: Calendar = .current, locale: Locale = .current) -> ChatBubbleModel {
        let time = timeLabel(for: message.createdAt, calendar: calendar, locale: locale)
        switch message.sender {
        case .own:
            return ChatBubbleModel(
                id: message.clientMessageId, text: message.text, kind: .outgoing,
                accessibilityLabel: "You, \(time): \(message.text)", accessibilityHint: nil
            )
        case .other:
            return ChatBubbleModel(
                id: message.clientMessageId, text: message.text, kind: .incoming,
                accessibilityLabel: "Other person, \(time): \(message.text)", accessibilityHint: nil
            )
        }
    }

    static func bubble(for local: LocalOutgoingMessage) -> ChatBubbleModel {
        switch local.state {
        case .sending:
            return ChatBubbleModel(
                id: local.clientMessageId, text: local.text, kind: .sending,
                accessibilityLabel: "You, \(ConversationCopy.sending): \(local.text)", accessibilityHint: nil
            )
        case .failed(let failure):
            return ChatBubbleModel(
                id: local.clientMessageId, text: local.text, kind: .failed(failure),
                accessibilityLabel: "You, \(failure == .unconfirmed ? ConversationCopy.deliveryUnconfirmed : ConversationCopy.failedSheetTitle): \(local.text)",
                accessibilityHint: nil
            )
        }
    }

    static func timeLabel(for date: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    /// "Today · 12:04 PM" (Figma example), "Yesterday · …", otherwise a date.
    static func timestampLabel(for date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let time = timeLabel(for: date, calendar: calendar, locale: locale)
        if calendar.isDate(date, inSameDayAs: now) { return "Today · \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday · \(time)"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return "\(formatter.string(from: date)) · \(time)"
    }
}
