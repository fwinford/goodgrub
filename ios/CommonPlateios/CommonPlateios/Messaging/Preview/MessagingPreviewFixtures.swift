//
//  MessagingPreviewFixtures.swift
//  CommonPlateios
//
// DEVELOPMENT-ONLY (W4-MSG1 CP6 UI preview). Compiled only into Debug builds:
// every file in `Messaging/Preview/` is wrapped in `#if DEBUG`, so Release,
// TestFlight and App Store binaries contain none of it. Everything here is
// synthetic: fictional participants, request ids and message text. Nothing
// here is a credential, an authorization decision, or a statement about real
// backend behavior.
#if DEBUG
import Foundation

nonisolated enum MessagingPreviewScenario: Int, CaseIterable, Identifiable {
    case reserved
    case long
    case empty
    case loading
    case sendFailure
    case closed

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .reserved: "Reserved, short conversation"
        case .long: "Long conversation (scrolling, history)"
        case .empty: "Empty (newly reserved)"
        case .loading: "Loading (never finishes)"
        case .sendFailure: "First send fails, retry works"
        case .closed: "Closed / unavailable"
        }
    }
}

/// One synthetic message, authored by a fixed fictional participant.
nonisolated struct MessagingPreviewLine: Equatable {
    let fromRequester: Bool
    let text: String
    let minutesBeforeAnchor: Int
}

nonisolated enum MessagingPreviewFixtures {
    static let requesterName = "Maya (fictional requester)"
    static let helperName = "Jordan (fictional helper)"
    static let mealTitle = "Burrito bowl and chips"
    static let venueName = "Fictional Burrito Co."

    /// A server-shaped fictional id. The scenario and role are encoded in the
    /// last four hex digits so the preview composition can resolve them; an id
    /// that does not decode resolves to nothing and fails closed.
    static func requestID(_ scenario: MessagingPreviewScenario, _ role: RequestConversationRole) -> String {
        "feedfeedfeedfeed0000" + String(format: "%02x", scenario.rawValue) + (role == .requester ? "01" : "02")
    }

    static func resolve(requestID: String) -> (MessagingPreviewScenario, RequestConversationRole)? {
        guard requestID.count == 24, requestID.hasPrefix("feedfeedfeedfeed0000"),
              let scenarioValue = Int(requestID.dropFirst(20).prefix(2), radix: 16),
              let scenario = MessagingPreviewScenario(rawValue: scenarioValue) else { return nil }
        switch requestID.suffix(2) {
        case "01": return (scenario, .requester)
        case "02": return (scenario, .helper)
        default: return nil
        }
    }

    static func lines(for scenario: MessagingPreviewScenario) -> [MessagingPreviewLine] {
        switch scenario {
        case .reserved, .sendFailure:
            return [
                .init(fromRequester: false, text: "Hi! I just reserved your request. I can order in about 20 minutes.", minutesBeforeAnchor: 42),
                .init(fromRequester: true, text: "Amazing, thank you!", minutesBeforeAnchor: 40),
                .init(fromRequester: true, text: "Could you add extra salsa if it is available?", minutesBeforeAnchor: 39),
                .init(fromRequester: false, text: "Sure, no problem.", minutesBeforeAnchor: 12),
                .init(fromRequester: false, text: "Ordering now. Where should we meet for pickup afterwards?", minutesBeforeAnchor: 11),
            ]
        case .long:
            return longLines
        case .empty, .loading, .closed:
            return []
        }
    }

    private static let longLines: [MessagingPreviewLine] = {
        let samples: [(Bool, String)] = [
            (false, "Hey, it's Jordan. I reserved your request."),
            (true, "Thanks so much!"),
            (true, "I'm in class until 2, is a later pickup okay?"),
            (false, "That works. I'll order around 1:30 so it's fresh."),
            (true, "Perfect."),
            (false, "Quick question: should the chips be separate from the bowl? The menu lists them as a side and the order notes don't say either way, so I want to get it right before checking out."),
            (true, "Separate is great, thank you for checking."),
            (false, "👍"),
            (true, "Also, no sour cream please."),
            (false, "Noted."),
        ]
        return (0..<70).map { index in
            let sample = samples[index % samples.count]
            return MessagingPreviewLine(
                fromRequester: sample.0,
                text: index % 11 == 5 ? "(\(index + 1)) " + sample.1 : sample.1,
                minutesBeforeAnchor: (70 - index) * 7
            )
        }
    }()

    static func uuid(_ sequence: Int) -> String {
        "00000000-0000-4000-8000-" + String(format: "%012d", sequence)
    }

    /// The messages as the given participant's own server would shape them:
    /// `own` is whatever this role authored.
    static func messages(
        for scenario: MessagingPreviewScenario,
        role: RequestConversationRole,
        anchor: Date
    ) -> [ChatMessage] {
        lines(for: scenario).enumerated().map { index, line in
            ChatMessage(
                clientMessageId: uuid(index + 1),
                sequence: index + 1,
                sender: line.fromRequester == (role == .requester) ? .own : .other,
                text: line.text,
                createdAt: anchor.addingTimeInterval(-Double(line.minutesBeforeAnchor) * 60)
            )
        }
    }
}
#endif
