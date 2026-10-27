//
//  MessagingDTOs.swift
//  CommonPlateios
//
// W4-MSG1 CP3 (dormant). Strict wire types for the CP1 HTTP messaging
// endpoints and the CP2 content-free WebSocket frames. Nothing here is reached
// from the running app. Decoding is deliberately strict: an unexpected key,
// type or range is a decoding failure, never a best-effort partial message.
import Foundation

// MARK: - Strict decoding helpers

nonisolated private struct StrictKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

nonisolated private func strictContainer(
    _ decoder: Decoder,
    exactKeys: Set<String>
) throws -> KeyedDecodingContainer<StrictKey> {
    let container = try decoder.container(keyedBy: StrictKey.self)
    guard Set(container.allKeys.map(\.stringValue)) == exactKeys else {
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Unexpected message shape")
        )
    }
    return container
}

nonisolated private func corrupted(_ decoder: Decoder) -> DecodingError {
    DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Invalid message value")
    )
}

nonisolated enum MessagingWire {
    /// Mirrors the backend's 24-hex object identifiers.
    static func isObjectID(_ value: String) -> Bool {
        value.utf8.count == 24 && value.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
        }
    }

    /// The backend only accepts lowercase canonical UUIDv4 strings.
    static func isUUIDv4(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else { return false }
        let characters = Array(value)
        return characters[14] == "4" && "89ab".contains(characters[19])
    }

    static let maxPageSize = 100
    static let historyPageSize = 50
    static let maxSequence = 9_007_199_254_740_991
    static let maxFrameBytes = 1024
    static let maxTextUTF16Units = 2000
    static let maxTextBytes = 8000

    /// Mirrors the server's `validateMessage`, only to avoid pointless sends.
    /// The server remains authoritative and the text is never altered.
    static func isSendableText(_ text: String) -> Bool {
        !text.isEmpty
            && text.utf16.count <= maxTextUTF16Units
            && text.utf8.count <= maxTextBytes
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - HTTP shapes

/// The open response. `openingSnapshotSequence` is the conversation's sequence
/// when the server marked the recipient's earlier incoming messages read; `0`
/// (an empty conversation) and `MessagingWire.maxSequence` are both valid.
nonisolated struct ConversationOpenDTO: Decodable, Equatable {
    let conversationId: String
    let openingSnapshotSequence: Int

    init(conversationId: String, openingSnapshotSequence: Int) {
        self.conversationId = conversationId
        self.openingSnapshotSequence = openingSnapshotSequence
    }

    init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, exactKeys: ["conversationId", "openingSnapshotSequence"])
        let id = try container.decode(String.self, forKey: StrictKey(stringValue: "conversationId")!)
        let snapshot = try container.decode(Int.self, forKey: StrictKey(stringValue: "openingSnapshotSequence")!)
        guard MessagingWire.isObjectID(id), (0...MessagingWire.maxSequence).contains(snapshot) else {
            throw corrupted(decoder)
        }
        self.init(conversationId: id, openingSnapshotSequence: snapshot)
    }
}

/// `POST .../:conversationId/read` result. It names the conversation and the
/// number of messages newly marked read; it carries no message or read state.
nonisolated struct ConversationReadAckDTO: Decodable, Equatable {
    let conversationId: String
    let acknowledgedCount: Int

    init(conversationId: String, acknowledgedCount: Int) {
        self.conversationId = conversationId
        self.acknowledgedCount = acknowledgedCount
    }

    init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, exactKeys: ["conversationId", "acknowledgedCount"])
        let id = try container.decode(String.self, forKey: StrictKey(stringValue: "conversationId")!)
        let count = try container.decode(Int.self, forKey: StrictKey(stringValue: "acknowledgedCount")!)
        guard MessagingWire.isObjectID(id), (0...MessagingWire.maxPageSize).contains(count) else {
            throw corrupted(decoder)
        }
        self.init(conversationId: id, acknowledgedCount: count)
    }
}

/// One conversation's unread count. The server only lists non-zero counts.
nonisolated struct ConversationUnreadEntryDTO: Decodable, Equatable {
    let requestId: String
    let conversationId: String
    let unreadCount: Int

    init(requestId: String, conversationId: String, unreadCount: Int) {
        self.requestId = requestId
        self.conversationId = conversationId
        self.unreadCount = unreadCount
    }

    init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, exactKeys: ["requestId", "conversationId", "unreadCount"])
        func key(_ name: String) -> StrictKey { StrictKey(stringValue: name)! }
        let requestId = try container.decode(String.self, forKey: key("requestId"))
        let conversationId = try container.decode(String.self, forKey: key("conversationId"))
        let count = try container.decode(Int.self, forKey: key("unreadCount"))
        guard MessagingWire.isObjectID(requestId), MessagingWire.isObjectID(conversationId),
              (1...MessagingWire.maxSequence).contains(count) else {
            throw corrupted(decoder)
        }
        self.init(requestId: requestId, conversationId: conversationId, unreadCount: count)
    }
}

/// `GET /api/participant/messaging/unread-count`. Accepted only when internally
/// consistent: bounded, no repeated conversation, and a total equal to the sum.
nonisolated struct MessagingUnreadSummaryDTO: Decodable, Equatable {
    static let maxConversations = 100

    let unreadCount: Int
    let conversations: [ConversationUnreadEntryDTO]

    init(unreadCount: Int, conversations: [ConversationUnreadEntryDTO]) {
        self.unreadCount = unreadCount
        self.conversations = conversations
    }

    init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, exactKeys: ["unreadCount", "conversations"])
        let total = try container.decode(Int.self, forKey: StrictKey(stringValue: "unreadCount")!)
        let entries = try container.decode([ConversationUnreadEntryDTO].self, forKey: StrictKey(stringValue: "conversations")!)
        guard entries.count <= Self.maxConversations,
              Set(entries.map(\.conversationId)).count == entries.count else { throw corrupted(decoder) }
        var sum = 0
        for entry in entries {
            let (next, overflow) = sum.addingReportingOverflow(entry.unreadCount)
            guard !overflow, next <= MessagingWire.maxSequence else { throw corrupted(decoder) }
            sum = next
        }
        guard total == sum else { throw corrupted(decoder) }
        self.init(unreadCount: total, conversations: entries)
    }
}

nonisolated enum ChatMessageSender: String, Decodable, Equatable {
    case own
    case other
}

nonisolated struct ChatMessage: Decodable, Equatable, Identifiable {
    let clientMessageId: String
    let sequence: Int
    let sender: ChatMessageSender
    let text: String
    let createdAt: Date

    var id: String { clientMessageId }

    init(clientMessageId: String, sequence: Int, sender: ChatMessageSender, text: String, createdAt: Date) {
        self.clientMessageId = clientMessageId
        self.sequence = sequence
        self.sender = sender
        self.text = text
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try strictContainer(
            decoder,
            exactKeys: ["clientMessageId", "sequence", "sender", "text", "createdAt"]
        )
        func key(_ name: String) -> StrictKey { StrictKey(stringValue: name)! }
        let clientMessageId = try container.decode(String.self, forKey: key("clientMessageId"))
        let sequence = try container.decode(Int.self, forKey: key("sequence"))
        let sender = try container.decode(ChatMessageSender.self, forKey: key("sender"))
        let text = try container.decode(String.self, forKey: key("text"))
        let createdAt = try container.decode(Date.self, forKey: key("createdAt"))
        guard MessagingWire.isUUIDv4(clientMessageId), sequence >= 1,
              sequence <= MessagingWire.maxSequence, !text.isEmpty else {
            throw corrupted(decoder)
        }
        self.init(
            clientMessageId: clientMessageId,
            sequence: sequence,
            sender: sender,
            text: text,
            createdAt: createdAt
        )
    }
}

/// `GET .../messages?after=&limit=`
nonisolated struct ChatMessagePageDTO: Decodable, Equatable {
    let messages: [ChatMessage]
    let nextAfter: Int

    init(messages: [ChatMessage], nextAfter: Int) {
        self.messages = messages
        self.nextAfter = nextAfter
    }

    init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, exactKeys: ["messages", "nextAfter"])
        let messages = try container.decode([ChatMessage].self, forKey: StrictKey(stringValue: "messages")!)
        let nextAfter = try container.decode(Int.self, forKey: StrictKey(stringValue: "nextAfter")!)
        guard messages.count <= MessagingWire.maxPageSize, nextAfter >= 0,
              nextAfter <= MessagingWire.maxSequence else {
            throw corrupted(decoder)
        }
        self.init(messages: messages, nextAfter: nextAfter)
    }
}

/// CP4 backward pages have a separate shape and never carry a forward cursor.
nonisolated struct ChatMessageHistoryDTO: Decodable, Equatable {
    let messages: [ChatMessage]
    let hasOlder: Bool
    let nextBefore: Int?
    let newestSequence: Int

    init(messages: [ChatMessage], hasOlder: Bool, nextBefore: Int?, newestSequence: Int) {
        self.messages = messages
        self.hasOlder = hasOlder
        self.nextBefore = nextBefore
        self.newestSequence = newestSequence
    }

    func isValid(before: Int?, limit: Int) -> Bool {
        guard hasValidContents(limit: limit),
              before.map({ (1...MessagingWire.maxSequence).contains($0) }) ?? true,
              messages.allSatisfy({ message in before.map { message.sequence < $0 } ?? true }) else { return false }
        // A latest page cannot omit the snapshot head. An empty older page can.
        return before != nil || (messages.last?.sequence ?? 0) == newestSequence
    }

    private func hasValidContents(limit: Int) -> Bool {
        guard (1...MessagingWire.maxPageSize).contains(limit), messages.count <= limit,
              (0...MessagingWire.maxSequence).contains(newestSequence),
              nextBefore == messages.first?.sequence,
              !hasOlder || !messages.isEmpty else { return false }
        var previous = 0
        var ids = Set<String>()
        for message in messages {
            guard message.sequence > previous, message.sequence <= newestSequence,
                  ids.insert(message.id).inserted else { return false }
            previous = message.sequence
        }
        return true
    }

    init(from decoder: Decoder) throws {
        let container = try strictContainer(
            decoder, exactKeys: ["messages", "hasOlder", "nextBefore", "newestSequence"]
        )
        func key(_ name: String) -> StrictKey { StrictKey(stringValue: name)! }
        messages = try container.decode([ChatMessage].self, forKey: key("messages"))
        hasOlder = try container.decode(Bool.self, forKey: key("hasOlder"))
        nextBefore = try container.decode(Int?.self, forKey: key("nextBefore"))
        newestSequence = try container.decode(Int.self, forKey: key("newestSequence"))
        // Request-relative checks run before application; an older head may exceed its rows.
        guard hasValidContents(limit: MessagingWire.maxPageSize) else { throw corrupted(decoder) }
    }
}

/// `POST .../messages` (200 replay or 201 created)
nonisolated struct ChatMessageEnvelopeDTO: Decodable, Equatable {
    let message: ChatMessage

    init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, exactKeys: ["message"])
        message = try container.decode(ChatMessage.self, forKey: StrictKey(stringValue: "message")!)
    }
}

/// `GET .../messages/:clientMessageId` — `message` is `null` when absent.
nonisolated struct ChatMessageReconciliationDTO: Decodable, Equatable {
    let message: ChatMessage?

    init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, exactKeys: ["message"])
        message = try container.decode(ChatMessage?.self, forKey: StrictKey(stringValue: "message")!)
    }
}

nonisolated struct ConversationReadPayload: Encodable, Equatable {
    let displayedSequences: [Int]
}

nonisolated struct ChatSendPayload: Encodable, Equatable {
    let clientMessageId: String
    let text: String
}

// MARK: - WebSocket frames (CP2)

nonisolated enum ConversationSocketInbound: Equatable {
    case text(String)
    case binary(Data)
}

/// Content-free frames the server may send. Anything else is rejected.
nonisolated enum ConversationSocketFrame: Equatable {
    case subscribed(reference: String)
    case changed(reference: String)

    static func decode(_ inbound: ConversationSocketInbound) -> ConversationSocketFrame? {
        guard case .text(let text) = inbound,
              text.utf8.count <= MessagingWire.maxFrameBytes,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              Set(object.keys) == ["type", "subscription"],
              let type = object["type"] as? String,
              let reference = object["subscription"] as? String,
              MessagingWire.isUUIDv4(reference)
        else { return nil }
        switch type {
        case "subscribed": return .subscribed(reference: reference)
        case "changed": return .changed(reference: reference)
        default: return nil
        }
    }
}

/// The only frame the client ever sends. It names the conversation and
/// carries no message content and no credential.
nonisolated enum ConversationSubscribeFrame {
    static func encode(requestId: String, conversationId: String) -> String {
        let object: [String: String] = [
            "type": "subscribe",
            "requestId": requestId,
            "conversationId": conversationId,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
