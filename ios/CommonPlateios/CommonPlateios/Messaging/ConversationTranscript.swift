//
//  ConversationTranscript.swift
//  CommonPlateios
//
// W4-MSG1 CP3 (dormant). Pure value reducer for one conversation's local
// state: authoritative messages, the HTTP cursor, and local (sending/failed)
// outgoing items. It has no I/O and no notion of identity; the coordinator
// owns every fence and discards the whole value on purge.
import Foundation

nonisolated enum LocalSendFailure: Equatable {
    /// Reconciliation proved the message is not on the server.
    case notDelivered
    /// Reconciliation could not be completed; outcome not established.
    case unconfirmed
    case refused(ConversationRefusal)

    /// A definitive server refusal is never retried with identical content.
    var isRetryable: Bool {
        if case .refused = self { return false }
        return true
    }

    /// Only an established non-delivery may be removed locally. `unconfirmed`
    /// may already exist on the server, so it stays until reconciled.
    var isDefinitelyUnsent: Bool {
        if case .unconfirmed = self { return false }
        return true
    }
}

nonisolated enum LocalSendState: Equatable {
    case sending
    case failed(LocalSendFailure)
}

/// An outgoing message the server has not yet confirmed. The identity, text
/// and conversation are fixed at creation and never edited, so a manual retry
/// is byte-identical to the original attempt.
nonisolated struct LocalOutgoingMessage: Equatable, Identifiable {
    let clientMessageId: String
    let conversationId: String
    let text: String
    let createdAt: Date
    var state: LocalSendState

    var id: String { clientMessageId }
}

nonisolated enum ConversationItem: Equatable, Identifiable {
    case message(ChatMessage)
    case local(LocalOutgoingMessage)

    var id: String {
        switch self {
        case .message(let message): return message.clientMessageId
        case .local(let local): return local.clientMessageId
        }
    }
}

nonisolated struct ConversationTranscript: Equatable {
    private(set) var messages: [ChatMessage] = []
    private(set) var locals: [LocalOutgoingMessage] = []
    /// Advanced only by an applied HTTP page. Never by a hint or a POST result.
    private(set) var cursor: Int = 0
    private(set) var historyInitialized = false
    private(set) var hasOlder = false
    private(set) var nextBefore: Int?

    private var sequences: [Int: ChatMessage] = [:]
    private var identities: [String: ChatMessage] = [:]

    var isEmpty: Bool { messages.isEmpty && locals.isEmpty }

    var items: [ConversationItem] {
        messages.map(ConversationItem.message) + locals.map(ConversationItem.local)
    }

    /// Applies one page read after `requestedAfter`. A malformed page (out of
    /// order, at or before the requested cursor, or a `nextAfter` that does not
    /// agree with its contents) is rejected whole and changes nothing.
    @discardableResult
    mutating func applyPage(_ page: ChatMessagePageDTO, requestedAfter: Int) -> Bool {
        guard requestedAfter == cursor,
              page.nextAfter >= requestedAfter,
              page.nextAfter <= MessagingWire.maxSequence,
              page.messages.count <= MessagingWire.maxPageSize else { return false }
        var previous = requestedAfter
        for message in page.messages {
            guard message.sequence > previous else { return false }
            previous = message.sequence
        }
        guard page.nextAfter == (page.messages.last?.sequence ?? requestedAfter) else { return false }
        guard canMerge(page.messages) else { return false }
        for message in page.messages { insert(message) }
        cursor = page.nextAfter
        return true
    }

    /// A POST result is a confirmed message; it never moves the cursor.
    @discardableResult
    mutating func applySent(_ message: ChatMessage) -> Bool {
        guard canMerge([message]) else { return false }
        insert(message)
        return true
    }

    @discardableResult
    mutating func applyHistory(_ page: ChatMessageHistoryDTO, before: Int?, limit: Int = MessagingWire.historyPageSize) -> Bool {
        guard page.isValid(before: before, limit: limit),
              (!historyInitialized && before == nil)
                || (historyInitialized && hasOlder && before == nextBefore && before != nil),
              canMerge(page.messages) else { return false }
        for message in page.messages { insert(message) }
        if !historyInitialized { cursor = page.newestSequence }
        historyInitialized = true
        hasOlder = page.hasOlder
        nextBefore = page.nextBefore
        return true
    }

    mutating func addLocal(_ local: LocalOutgoingMessage) {
        guard identities[local.clientMessageId] == nil,
              !locals.contains(where: { $0.clientMessageId == local.clientMessageId }) else { return }
        locals.append(local)
    }

    @discardableResult
    mutating func setState(_ state: LocalSendState, for clientMessageId: String) -> Bool {
        guard let index = locals.firstIndex(where: { $0.clientMessageId == clientMessageId }) else { return false }
        locals[index].state = state
        return true
    }

    func local(_ clientMessageId: String) -> LocalOutgoingMessage? {
        locals.first { $0.clientMessageId == clientMessageId }
    }

    @discardableResult
    mutating func removeLocal(_ clientMessageId: String) -> Bool {
        guard let index = locals.firstIndex(where: { $0.clientMessageId == clientMessageId }) else { return false }
        locals.remove(at: index)
        return true
    }

    func contains(clientMessageId: String) -> Bool {
        identities[clientMessageId] != nil
    }

    private func canMerge(_ incoming: [ChatMessage]) -> Bool {
        var pageSequences: [Int: ChatMessage] = [:]
        var pageIdentities: [String: ChatMessage] = [:]
        for message in incoming {
            guard (1...MessagingWire.maxSequence).contains(message.sequence) else { return false }
            if let existing = sequences[message.sequence], existing != message { return false }
            if let existing = identities[message.id], existing != message { return false }
            if let existing = pageSequences[message.sequence], existing != message { return false }
            if let existing = pageIdentities[message.id], existing != message { return false }
            if let local = local(message.id), message.sender != .own || message.text != local.text { return false }
            pageSequences[message.sequence] = message
            pageIdentities[message.id] = message
        }
        return true
    }

    private mutating func insert(_ message: ChatMessage) {
        locals.removeAll { $0.clientMessageId == message.clientMessageId }
        guard identities[message.id] == nil else { return }
        sequences[message.sequence] = message
        identities[message.id] = message
        let index = messages.firstIndex { $0.sequence > message.sequence } ?? messages.endIndex
        messages.insert(message, at: index)
    }
}
