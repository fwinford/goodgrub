//
//  MessagingPreviewComposition.swift
//  CommonPlateios
//
// DEVELOPMENT-ONLY (W4-MSG1 CP6 UI preview). An in-memory test double behind
// the real `ConversationCoordinator`, so the real message list, composer,
// send/retry and history UI run unchanged against fictional data. It opens no
// connection of any kind, persists nothing, and holds no credential. A
// "successful send" here only means this process appended a line to its own
// array; it says nothing about the real backend or WebSocket.
#if DEBUG
import Foundation

actor PreviewConversationHTTP: ConversationHTTPServing {
    private let scenario: MessagingPreviewScenario
    private let requestID: String
    private var messages: [ChatMessage]
    private var failedOnce = Set<String>()
    private let sendDelay: Duration
    private let now: @Sendable () -> Date
    private let ledger: PreviewUnreadLedger?

    init(
        scenario: MessagingPreviewScenario,
        role: RequestConversationRole,
        requestID: String,
        anchor: Date = Date(),
        sendDelay: Duration = .milliseconds(350),
        now: @escaping @Sendable () -> Date = { Date() },
        ledger: PreviewUnreadLedger? = nil
    ) {
        self.ledger = ledger
        self.scenario = scenario
        self.requestID = requestID
        self.messages = MessagingPreviewFixtures.messages(for: scenario, role: role, anchor: anchor)
        self.sendDelay = sendDelay
        self.now = now
    }

    func open(authority: String, requestId: String) async -> ConversationHTTPOutcome<ConversationOpenDTO> {
        switch scenario {
        case .closed:
            return .unavailable
        case .loading:
            // Cancellation (leaving the screen) ends the wait; it proves nothing.
            try? await Task.sleep(for: .seconds(3600))
            return .unknown
        default:
            // Like the server, opening reads everything that exists at that moment.
            let snapshot = messages.last?.sequence ?? 0
            await ledger?.markRead(requestID)
            let body = Data(#"{"conversationId":"\#(requestID)","openingSnapshotSequence":\#(snapshot)}"#.utf8)
            guard let dto = try? JSONDecoder().decode(ConversationOpenDTO.self, from: body) else { return .unknown }
            return .success(dto)
        }
    }

    func readPage(
        authority: String, requestId: String, conversationId: String, after: Int, limit: Int
    ) async -> ConversationHTTPOutcome<ChatMessagePageDTO> {
        let page = Array(messages.filter { $0.sequence > after }.prefix(limit))
        return .success(ChatMessagePageDTO(messages: page, nextAfter: page.last?.sequence ?? after))
    }

    func readHistory(
        authority: String, requestId: String, conversationId: String, before: Int?, limit: Int
    ) async -> ConversationHTTPOutcome<ChatMessageHistoryDTO> {
        let eligible = messages.filter { before == nil || $0.sequence < before! }
        let page = Array(eligible.suffix(limit))
        return .success(ChatMessageHistoryDTO(
            messages: page,
            hasOlder: eligible.count > page.count,
            nextBefore: page.first?.sequence,
            newestSequence: messages.last?.sequence ?? 0
        ))
    }

    func send(
        authority: String, requestId: String, conversationId: String, clientMessageId: String, text: String
    ) async -> ConversationHTTPOutcome<ChatMessage> {
        try? await Task.sleep(for: sendDelay)
        if scenario == .sendFailure, failedOnce.insert(clientMessageId).inserted {
            return .unknown
        }
        if let existing = messages.first(where: { $0.clientMessageId == clientMessageId }) {
            return .success(existing)
        }
        let message = ChatMessage(
            clientMessageId: clientMessageId,
            sequence: (messages.last?.sequence ?? 0) + 1,
            sender: .own,
            text: text,
            createdAt: now()
        )
        messages.append(message)
        return .success(message)
    }

    func reconcile(
        authority: String, requestId: String, conversationId: String, clientMessageId: String
    ) async -> ConversationHTTPOutcome<ChatMessage?> {
        .success(messages.first { $0.clientMessageId == clientMessageId })
    }

    func acknowledge(
        authority: String, requestId: String, conversationId: String, displayedSequences: [Int]
    ) async -> ConversationHTTPOutcome<ConversationReadAckDTO> {
        .success(ConversationReadAckDTO(conversationId: conversationId, acknowledgedCount: 0))
    }

    func unreadSummary(authority: String) async -> ConversationHTTPOutcome<MessagingUnreadSummaryDTO> {
        await ledger?.unreadSummary(authority: authority) ?? .unknown
    }
}

/// Preview-only stand-in for the server's unread projection. Fictional counts
/// per preview request; opening a conversation zeroes it, as the real server
/// reads everything that exists at open. Holds no credential and no network.
actor PreviewUnreadLedger: ConversationHTTPServing {
    private var counts: [String: Int] = [:]

    init() {
        for scenario in MessagingPreviewScenario.allCases where scenario != .closed {
            for role in [RequestConversationRole.requester, .helper] {
                let incoming = MessagingPreviewFixtures
                    .messages(for: scenario, role: role, anchor: Date())
                    .filter { $0.sender == .other }
                    .count
                if incoming > 0 { counts[MessagingPreviewFixtures.requestID(scenario, role)] = incoming }
            }
        }
    }

    func markRead(_ requestID: String) { counts[requestID] = nil }

    func unreadSummary(authority: String) async -> ConversationHTTPOutcome<MessagingUnreadSummaryDTO> {
        let entries = counts.sorted { $0.key < $1.key }.map {
            ConversationUnreadEntryDTO(requestId: $0.key, conversationId: $0.key, unreadCount: $0.value)
        }
        return .success(MessagingUnreadSummaryDTO(unreadCount: entries.reduce(0) { $0 + $1.unreadCount }, conversations: entries))
    }

    func open(authority: String, requestId: String) async -> ConversationHTTPOutcome<ConversationOpenDTO> { .unknown }
    func readPage(authority: String, requestId: String, conversationId: String, after: Int, limit: Int) async -> ConversationHTTPOutcome<ChatMessagePageDTO> { .unknown }
    func readHistory(authority: String, requestId: String, conversationId: String, before: Int?, limit: Int) async -> ConversationHTTPOutcome<ChatMessageHistoryDTO> { .unknown }
    func send(authority: String, requestId: String, conversationId: String, clientMessageId: String, text: String) async -> ConversationHTTPOutcome<ChatMessage> { .unknown }
    func reconcile(authority: String, requestId: String, conversationId: String, clientMessageId: String) async -> ConversationHTTPOutcome<ChatMessage?> { .unknown }
    func acknowledge(authority: String, requestId: String, conversationId: String, displayedSequences: [Int]) async -> ConversationHTTPOutcome<ConversationReadAckDTO> { .unknown }
}

nonisolated enum MessagingPreviewComposition {
    /// A well-formed but fictional string that is not a participant credential.
    static let fictionalAuthority = "preview-fictional-authority"

    /// Enabled composition used only by the preview root. Each call to the
    /// factory builds a fresh coordinator over a fresh in-memory double, so no
    /// transcript, draft or failure state survives from one entry to the next.
    /// A request id the preview did not mint resolves to a closed conversation.
    @MainActor
    static func make(
        anchor: @escaping () -> Date = { Date() }
    ) -> RequestMessagingComposition {
        let ledger = PreviewUnreadLedger()
        let unread = MessagingUnreadStore(http: ledger, authorityProvider: { fictionalAuthority })
        return .enabled(unread: unread) { requestID, _, rejected in
            let resolved = MessagingPreviewFixtures.resolve(requestID: requestID)
            return ConversationCoordinator(
                requestId: requestID,
                http: PreviewConversationHTTP(
                    scenario: resolved?.0 ?? .closed,
                    role: resolved?.1 ?? .requester,
                    requestID: requestID,
                    anchor: anchor(),
                    ledger: ledger
                ),
                socketTransport: nil,
                authorityProvider: { fictionalAuthority },
                participantAuthorityRejected: rejected,
                unread: unread
            )
        }
    }
}

/// Preview-only stand-in for the entry verifier. It never reads or changes any
/// real request, claim or store state.
@MainActor
final class PreviewConversationVerifier: ConversationEntryVerifying {
    func verify(requestID: String, role: RequestConversationRole) async -> RequestConversationEligibility {
        guard MessagingPreviewFixtures.resolve(requestID: requestID) != nil else { return .ineligible }
        return .eligible
    }

    func isLocallyDenied(requestID: String, role: RequestConversationRole) -> Bool {
        MessagingPreviewFixtures.resolve(requestID: requestID)?.1 != role
    }

    func availableActions(requestID: String, role: RequestConversationRole) -> ConversationActionAvailability {
        guard !isLocallyDenied(requestID: requestID, role: role) else { return .none }
        return ConversationActionAvailability(
            report: true,
            block: role == .requester ? .viewedRequest : .helpingReservation
        )
    }
}
#endif
