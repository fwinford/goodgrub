//
//  ConversationHTTPClient.swift
//  CommonPlateios
//
// W4-MSG1 CP3 (dormant). Authenticated HTTP messaging client over the existing
// `APIClient`. It performs the four CP1 operations and classifies every result
// into a small closed set so the coordinator never inspects raw errors.
//
// Classification rules (W4-MSG1 CP3 contract):
//   * `404 CONVERSATION_UNAVAILABLE` is the only proof a conversation is closed.
//   * `PARTICIPANT_AUTHORITY_INVALID` is the only proof a credential is invalid.
//   * `503 MESSAGING_UNAVAILABLE`, transport errors, timeouts, unknown statuses
//     and undecodable bodies are *unknown*: they prove nothing either way.
// The credential travels only in the header and never appears in an outcome,
// error, log or URL.
import Foundation

nonisolated enum ConversationRefusal: Equatable {
    case textNotAllowed
    case invalidMessage
    case identityConflict
}

nonisolated enum ConversationHTTPOutcome<Value> {
    case success(Value)
    /// `404 CONVERSATION_UNAVAILABLE`: authoritative closure.
    case unavailable
    /// `PARTICIPANT_AUTHORITY_INVALID`: the presented credential is rejected.
    case identityInvalid
    /// No credential, or `PARTICIPANT_VERIFICATION_REQUIRED`. Nothing was processed.
    case authorityRequired
    /// A definitive refusal of this message; never automatically retried.
    case refused(ConversationRefusal)
    /// Outcome not established (transport, timeout, 5xx, malformed body, 503).
    case unknown
}

extension ConversationHTTPOutcome: Equatable where Value: Equatable {}

nonisolated protocol ConversationHTTPServing: Sendable {
    func open(authority: String, requestId: String) async -> ConversationHTTPOutcome<ConversationOpenDTO>
    func readPage(
        authority: String, requestId: String, conversationId: String, after: Int, limit: Int
    ) async -> ConversationHTTPOutcome<ChatMessagePageDTO>
    func readHistory(
        authority: String, requestId: String, conversationId: String, before: Int?, limit: Int
    ) async -> ConversationHTTPOutcome<ChatMessageHistoryDTO>
    func send(
        authority: String, requestId: String, conversationId: String, clientMessageId: String, text: String
    ) async -> ConversationHTTPOutcome<ChatMessage>
    func reconcile(
        authority: String, requestId: String, conversationId: String, clientMessageId: String
    ) async -> ConversationHTTPOutcome<ChatMessage?>
    /// Acknowledges messages the recipient has actually displayed. `.refused`
    /// (`INVALID_MESSAGE`) rejects the whole batch and proves nothing else.
    func acknowledge(
        authority: String, requestId: String, conversationId: String, displayedSequences: [Int]
    ) async -> ConversationHTTPOutcome<ConversationReadAckDTO>
    /// The recipient's own unread projection. A `404` here carries no
    /// per-conversation closure meaning (the server also uses it when the
    /// projection is unavailable), so callers must treat `.unavailable` as unknown.
    func unreadSummary(authority: String) async -> ConversationHTTPOutcome<MessagingUnreadSummaryDTO>
}

nonisolated enum ConversationErrorCode {
    static let unavailable = "CONVERSATION_UNAVAILABLE"
    static let messagingUnavailable = "MESSAGING_UNAVAILABLE"
    static let invalidMessage = "INVALID_MESSAGE"
    static let identityConflict = "MESSAGE_IDENTITY_CONFLICT"
    static let textNotAllowed = "MESSAGE_TEXT_NOT_ALLOWED"
}

nonisolated struct ConversationHTTPClient: ConversationHTTPServing, @unchecked Sendable {
    /// Same header `RequestService` uses; must match the backend gate.
    static let participantAuthorityHeader = "x-commonplate-participant"
    static let sendTimeout: TimeInterval = 15

    private let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    // MARK: Operations

    func open(authority: String, requestId: String) async -> ConversationHTTPOutcome<ConversationOpenDTO> {
        guard let base = Self.requestPath(requestId) else { return .unknown }
        return await perform(authority: authority) { headers in
            try await client.send(path: base, method: .get, headers: headers)
        }
    }

    func readPage(
        authority: String, requestId: String, conversationId: String, after: Int, limit: Int
    ) async -> ConversationHTTPOutcome<ChatMessagePageDTO> {
        guard let base = Self.messagesPath(requestId, conversationId), after >= 0, limit >= 1 else { return .unknown }
        return await perform(authority: authority) { headers in
            try await client.send(path: "\(base)?after=\(after)&limit=\(limit)", method: .get, headers: headers)
        }
    }

    func readHistory(
        authority: String, requestId: String, conversationId: String, before: Int?, limit: Int
    ) async -> ConversationHTTPOutcome<ChatMessageHistoryDTO> {
        guard let base = Self.messagesPath(requestId, conversationId),
              (1...MessagingWire.maxPageSize).contains(limit),
              before.map({ (1...MessagingWire.maxSequence).contains($0) }) ?? true else { return .unknown }
        let bound = before.map { "&before=\($0)" } ?? ""
        let outcome: ConversationHTTPOutcome<ChatMessageHistoryDTO> = await perform(authority: authority) { headers in
            try await client.send(
                path: "\(base)?direction=backward&limit=\(limit)\(bound)", method: .get, headers: headers
            )
        }
        if case .success(let page) = outcome, !page.isValid(before: before, limit: limit) { return .unknown }
        return outcome
    }

    func send(
        authority: String, requestId: String, conversationId: String, clientMessageId: String, text: String
    ) async -> ConversationHTTPOutcome<ChatMessage> {
        guard let path = Self.messagesPath(requestId, conversationId) else { return .unknown }
        let outcome: ConversationHTTPOutcome<ChatMessageEnvelopeDTO> = await perform(authority: authority) { headers in
            try await client.send(
                path: path,
                method: .post,
                body: ChatSendPayload(clientMessageId: clientMessageId, text: text),
                headers: headers,
                timeoutInterval: Self.sendTimeout
            )
        }
        return outcome.mapValue(\.message)
    }

    func reconcile(
        authority: String, requestId: String, conversationId: String, clientMessageId: String
    ) async -> ConversationHTTPOutcome<ChatMessage?> {
        guard let base = Self.messagesPath(requestId, conversationId),
              MessagingWire.isUUIDv4(clientMessageId) else { return .unknown }
        let identity = clientMessageId
        let outcome: ConversationHTTPOutcome<ChatMessageReconciliationDTO> = await perform(authority: authority) { headers in
            try await client.send(path: "\(base)/\(identity)", method: .get, headers: headers)
        }
        return outcome.mapValue(\.message)
    }

    func acknowledge(
        authority: String, requestId: String, conversationId: String, displayedSequences: [Int]
    ) async -> ConversationHTTPOutcome<ConversationReadAckDTO> {
        guard let base = Self.requestPath(requestId), MessagingWire.isObjectID(conversationId),
              (1...MessagingWire.maxPageSize).contains(displayedSequences.count),
              Set(displayedSequences).count == displayedSequences.count,
              displayedSequences.allSatisfy({ (1...MessagingWire.maxSequence).contains($0) }) else { return .unknown }
        let outcome: ConversationHTTPOutcome<ConversationReadAckDTO> = await perform(authority: authority) { headers in
            try await client.send(
                path: "\(base)/\(conversationId)/read",
                method: .post,
                body: ConversationReadPayload(displayedSequences: displayedSequences),
                headers: headers
            )
        }
        // A result for another conversation, or one that claims more messages
        // than were submitted, is not an acknowledgement of this batch.
        if case .success(let result) = outcome,
           result.conversationId != conversationId || result.acknowledgedCount > displayedSequences.count {
            return .unknown
        }
        return outcome
    }

    func unreadSummary(authority: String) async -> ConversationHTTPOutcome<MessagingUnreadSummaryDTO> {
        await perform(authority: authority) { headers in
            try await client.send(path: Self.unreadSummaryPath, method: .get, headers: headers)
        }
    }

    // MARK: Classification

    private func perform<Value>(
        authority: String,
        _ call: ([String: String]) async throws -> Value
    ) async -> ConversationHTTPOutcome<Value> {
        guard !authority.isEmpty else { return .authorityRequired }
        do {
            return .success(try await call([Self.participantAuthorityHeader: authority]))
        } catch {
            return Self.classify(error)
        }
    }

    static func classify<Value>(_ error: Error) -> ConversationHTTPOutcome<Value> {
        guard let apiError = error as? APIClientError else { return .unknown }
        switch apiError {
        case .apiError(let code, _):
            switch code {
            case ConversationErrorCode.unavailable: return .unavailable
            case ParticipantErrorCode.authorityInvalid: return .identityInvalid
            case ParticipantErrorCode.verificationRequired: return .authorityRequired
            case ConversationErrorCode.textNotAllowed: return .refused(.textNotAllowed)
            case ConversationErrorCode.invalidMessage: return .refused(.invalidMessage)
            case ConversationErrorCode.identityConflict: return .refused(.identityConflict)
            default: return .unknown
            }
        case .invalidURL, .transport, .unexpectedStatus, .encoding, .decoding:
            return .unknown
        }
    }

    // MARK: Paths

    static let unreadSummaryPath = "/api/participant/messaging/unread-count"

    private static func requestPath(_ requestId: String) -> String? {
        guard MessagingWire.isObjectID(requestId) else { return nil }
        return "/api/request/\(requestId)/conversation"
    }

    private static func messagesPath(_ requestId: String, _ conversationId: String) -> String? {
        guard let request = requestPath(requestId), MessagingWire.isObjectID(conversationId) else { return nil }
        let conversation = conversationId
        return "\(request)/\(conversation)/messages"
    }
}

extension ConversationHTTPOutcome {
    nonisolated func mapValue<T>(_ transform: (Value) -> T) -> ConversationHTTPOutcome<T> {
        switch self {
        case .success(let value): return .success(transform(value))
        case .unavailable: return .unavailable
        case .identityInvalid: return .identityInvalid
        case .authorityRequired: return .authorityRequired
        case .refused(let refusal): return .refused(refusal)
        case .unknown: return .unknown
        }
    }
}
