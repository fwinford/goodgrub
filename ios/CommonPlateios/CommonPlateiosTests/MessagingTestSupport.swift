import Foundation
import Darwin
import XCTest
@testable import CommonPlateios

/// Same simulator-only automation prerequisite as RequesterFormHostedHarness;
/// focused Messaging runs must not depend on another class enabling the tree.
func enableMessagingAccessibilityTree() throws {
    let handle = try XCTUnwrap(dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW))
    defer { dlclose(handle) }
    let symbol = try XCTUnwrap(dlsym(handle, "_AXSSetAutomationEnabled"))
    typealias SetAutomationEnabled = @convention(c) (Bool) -> Void
    unsafeBitCast(symbol, to: SetAutomationEnabled.self)(true)
}

// W4-MSG1 CP3 shared test doubles: scripted HTTP, manual scheduler, fake socket.
// All are deterministic; nothing touches the network, disk or real time.

enum MsgFixture {
    static let requestId = "64c0000000000000000000a1"
    static let conversationId = "64c0000000000000000000c1"
    static let otherConversationId = "64c0000000000000000000c2"
    static let authority = "64c0000000000000000000a1.1.credential"
    static let otherAuthority = "64c0000000000000000000b2.1.credential"
    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    static func identity(_ n: Int) -> String { uuid(n).uuidString.lowercased() }

    static func message(_ seq: Int, sender: ChatMessageSender = .other, text: String? = nil, identity n: Int? = nil) -> ChatMessage {
        ChatMessage(
            clientMessageId: identity(n ?? (1000 + seq)),
            sequence: seq,
            sender: sender,
            text: text ?? "message \(seq)",
            createdAt: epoch.addingTimeInterval(Double(seq))
        )
    }

    static func page(_ messages: [ChatMessage], after: Int) -> ChatMessagePageDTO {
        ChatMessagePageDTO(messages: messages, nextAfter: messages.last?.sequence ?? after)
    }

    static func history(_ messages: [ChatMessage], hasOlder: Bool = false, head: Int? = nil) -> ChatMessageHistoryDTO {
        ChatMessageHistoryDTO(
            messages: messages, hasOlder: hasOlder,
            nextBefore: messages.first?.sequence, newestSequence: head ?? messages.last?.sequence ?? 0
        )
    }

    static func historyPage(total: Int, before: Int? = nil, limit: Int = 50) -> ChatMessageHistoryDTO {
        let end = min(total, (before ?? (total + 1)) - 1)
        let start = max(1, end - limit + 1)
        let messages = end >= start ? (start...end).map { message($0) } : []
        return history(messages, hasOlder: start > 1, head: total)
    }
}

/// Suspends a scripted response until the test releases it.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened { lock.unlock(); c.resume() } else { continuation = c; lock.unlock() }
        }
    }

    func open() {
        lock.lock()
        opened = true
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}

final class ScriptedHTTP: ConversationHTTPServing, @unchecked Sendable {
    struct HistoryCall: Equatable { let authority: String; let conversationId: String; let before: Int?; let limit: Int }
    struct ReadCall: Equatable { let authority: String; let conversationId: String; let after: Int; let limit: Int }
    struct SendCall: Equatable { let authority: String; let conversationId: String; let clientMessageId: String; let text: String }
    struct ReconcileCall: Equatable { let conversationId: String; let clientMessageId: String }

    typealias Open = @Sendable () async -> ConversationHTTPOutcome<ConversationOpenDTO>
    typealias Read = @Sendable (ReadCall) async -> ConversationHTTPOutcome<ChatMessagePageDTO>
    typealias History = @Sendable (HistoryCall) async -> ConversationHTTPOutcome<ChatMessageHistoryDTO>
    typealias Send = @Sendable (SendCall) async -> ConversationHTTPOutcome<ChatMessage>
    typealias Reconcile = @Sendable (ReconcileCall) async -> ConversationHTTPOutcome<ChatMessage?>

    private let lock = NSLock()
    private var _opens = 0
    private var _reads: [ReadCall] = []
    private var _history: [HistoryCall] = []
    private var historyQueue: [History] = []
    private var _sends: [SendCall] = []
    private var _reconciles: [ReconcileCall] = []
    private var openQueue: [Open] = []
    private var readQueue: [Read] = []
    private var sendQueue: [Send] = []
    private var reconcileQueue: [Reconcile] = []

    var defaultConversationId = MsgFixture.conversationId
    var defaultOpeningSnapshot = 0
    var defaultRead: Read = { call in .success(ChatMessagePageDTO(messages: [], nextAfter: call.after)) }
    var defaultHistory: History = { _ in .success(ChatMessageHistoryDTO(messages: [], hasOlder: false, nextBefore: nil, newestSequence: 0)) }
    var defaultSend: Send = { _ in .unknown }
    var defaultReconcile: Reconcile = { _ in .unknown }

    var opens: Int { lock.withLock { _opens } }
    var reads: [ReadCall] { lock.withLock { _reads } }
    var history: [HistoryCall] { lock.withLock { _history } }
    var sends: [SendCall] { lock.withLock { _sends } }
    var reconciles: [ReconcileCall] { lock.withLock { _reconciles } }

    func enqueueOpen(_ r: @escaping Open) { lock.withLock { openQueue.append(r) } }
    func enqueueRead(_ r: @escaping Read) { lock.withLock { readQueue.append(r) } }
    func enqueueHistory(_ r: @escaping History) { lock.withLock { historyQueue.append(r) } }

    func readHistory(authority: String, requestId: String, conversationId: String, before: Int?, limit: Int) async -> ConversationHTTPOutcome<ChatMessageHistoryDTO> {
        let call = HistoryCall(authority: authority, conversationId: conversationId, before: before, limit: limit)
        let next: History = lock.withLock { _history.append(call); return historyQueue.isEmpty ? defaultHistory : historyQueue.removeFirst() }
        return await next(call)
    }
    func enqueueSend(_ r: @escaping Send) { lock.withLock { sendQueue.append(r) } }
    func enqueueReconcile(_ r: @escaping Reconcile) { lock.withLock { reconcileQueue.append(r) } }

    func open(authority: String, requestId: String) async -> ConversationHTTPOutcome<ConversationOpenDTO> {
        let next: Open? = lock.withLock { _opens += 1; return openQueue.isEmpty ? nil : openQueue.removeFirst() }
        if let next { return await next() }
        return .success(try! JSONDecoder().decode(ConversationOpenDTO.self, from: Data(#"{"conversationId":"\#(defaultConversationId)","openingSnapshotSequence":\#(defaultOpeningSnapshot)}"#.utf8)))
    }

    func readPage(authority: String, requestId: String, conversationId: String, after: Int, limit: Int) async -> ConversationHTTPOutcome<ChatMessagePageDTO> {
        let call = ReadCall(authority: authority, conversationId: conversationId, after: after, limit: limit)
        let next: Read = lock.withLock { _reads.append(call); return readQueue.isEmpty ? defaultRead : readQueue.removeFirst() }
        return await next(call)
    }

    func send(authority: String, requestId: String, conversationId: String, clientMessageId: String, text: String) async -> ConversationHTTPOutcome<ChatMessage> {
        let call = SendCall(authority: authority, conversationId: conversationId, clientMessageId: clientMessageId, text: text)
        let next: Send = lock.withLock { _sends.append(call); return sendQueue.isEmpty ? defaultSend : sendQueue.removeFirst() }
        return await next(call)
    }

    func reconcile(authority: String, requestId: String, conversationId: String, clientMessageId: String) async -> ConversationHTTPOutcome<ChatMessage?> {
        let call = ReconcileCall(conversationId: conversationId, clientMessageId: clientMessageId)
        let next: Reconcile = lock.withLock { _reconciles.append(call); return reconcileQueue.isEmpty ? defaultReconcile : reconcileQueue.removeFirst() }
        return await next(call)
    }

    struct AckCall: Equatable { let authority: String; let requestId: String; let conversationId: String; let displayedSequences: [Int] }
    typealias Ack = @Sendable (AckCall) async -> ConversationHTTPOutcome<ConversationReadAckDTO>
    typealias Unread = @Sendable (String) async -> ConversationHTTPOutcome<MessagingUnreadSummaryDTO>
    private var _acks: [AckCall] = []
    private var _unreadCalls: [String] = []
    private var ackQueue: [Ack] = []
    private var unreadQueue: [Unread] = []
    var defaultAck: Ack = { call in .success(ConversationReadAckDTO(conversationId: call.conversationId, acknowledgedCount: call.displayedSequences.count)) }
    var defaultUnread: Unread = { _ in .success(MessagingUnreadSummaryDTO(unreadCount: 0, conversations: [])) }
    var acks: [AckCall] { lock.withLock { _acks } }
    var unreadCalls: [String] { lock.withLock { _unreadCalls } }
    func enqueueAck(_ r: @escaping Ack) { lock.withLock { ackQueue.append(r) } }
    func enqueueUnread(_ r: @escaping Unread) { lock.withLock { unreadQueue.append(r) } }

    func acknowledge(authority: String, requestId: String, conversationId: String, displayedSequences: [Int]) async -> ConversationHTTPOutcome<ConversationReadAckDTO> {
        let call = AckCall(authority: authority, requestId: requestId, conversationId: conversationId, displayedSequences: displayedSequences)
        let next: Ack = lock.withLock { _acks.append(call); return ackQueue.isEmpty ? defaultAck : ackQueue.removeFirst() }
        return await next(call)
    }

    func unreadSummary(authority: String) async -> ConversationHTTPOutcome<MessagingUnreadSummaryDTO> {
        let next: Unread = lock.withLock { _unreadCalls.append(authority); return unreadQueue.isEmpty ? defaultUnread : unreadQueue.removeFirst() }
        return await next(authority)
    }
}

final class ManualScheduler: ConversationScheduling, @unchecked Sendable {
    private struct Sleeper { let id: Int; let deadline: Date; let continuation: CheckedContinuation<Void, Error> }
    private let lock = NSLock()
    private var current = MsgFixture.epoch
    private var sleepers: [Sleeper] = []
    private var nextID = 0
    private(set) var requestedSleeps: [TimeInterval] = []

    var now: Date { lock.withLock { current } }
    var pendingSleeps: Int { lock.withLock { sleepers.count } }
    var sleepRequests: [TimeInterval] { lock.withLock { requestedSleeps } }

    func sleep(seconds: TimeInterval) async throws {
        let id: Int = lock.withLock { nextID += 1; requestedSleeps.append(seconds); return nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled { lock.unlock(); c.resume(throwing: CancellationError()); return }
                sleepers.append(Sleeper(id: id, deadline: current.addingTimeInterval(seconds), continuation: c))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let s = sleepers.first { $0.id == id }
            sleepers.removeAll { $0.id == id }
            lock.unlock()
            s?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        let due = sleepers.filter { $0.deadline <= current }
        sleepers.removeAll { s in due.contains { $0.id == s.id } }
        lock.unlock()
        for s in due { s.continuation.resume() }
    }
}

final class FakeSocketConnection: ConversationSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [String] = []
    private var _cancelCount = 0
    private var cancelled = false
    private var queue: [Result<ConversationSocketInbound, Error>] = []
    private var waiter: CheckedContinuation<ConversationSocketInbound, Error>?
    let authority: String

    init(authority: String) { self.authority = authority }

    var sent: [String] { lock.withLock { _sent } }
    var cancelCount: Int { lock.withLock { _cancelCount } }
    var isReceiving: Bool { lock.withLock { waiter != nil } }

    func send(text: String) async throws {
        try lock.withLock { if cancelled { throw ConversationSocketFailure.failed }; _sent.append(text) }
    }

    func receive() async throws -> ConversationSocketInbound {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<ConversationSocketInbound, Error>) in
            lock.lock()
            if cancelled { lock.unlock(); c.resume(throwing: ConversationSocketFailure.failed); return }
            if !queue.isEmpty {
                let item = queue.removeFirst(); lock.unlock(); c.resume(with: item); return
            }
            waiter = c
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        _cancelCount += 1
        cancelled = true
        let w = waiter; waiter = nil
        lock.unlock()
        w?.resume(throwing: ConversationSocketFailure.failed)
    }

    func push(_ text: String) { deliver(.success(.text(text))) }
    func pushBinary() { deliver(.success(.binary(Data([1, 2, 3])))) }
    func fail(_ error: Error = ConversationSocketFailure.closed(code: 1006)) { deliver(.failure(error)) }

    private func deliver(_ item: Result<ConversationSocketInbound, Error>) {
        lock.lock()
        if let w = waiter { waiter = nil; lock.unlock(); w.resume(with: item) }
        else { queue.append(item); lock.unlock() }
    }

    static func subscribedFrame(_ reference: String) -> String { #"{"type":"subscribed","subscription":"\#(reference)"}"# }
    static func changedFrame(_ reference: String) -> String { #"{"type":"changed","subscription":"\#(reference)"}"# }
}

final class FakeSocketTransport: ConversationSocketTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var _connections: [FakeSocketConnection] = []
    var connections: [FakeSocketConnection] { lock.withLock { _connections } }
    var last: FakeSocketConnection? { connections.last }

    func connect(authority: String) -> ConversationSocketConnection {
        let c = FakeSocketConnection(authority: authority)
        lock.withLock { _connections.append(c) }
        return c
    }
}

@MainActor
final class MsgAuthorityBox {
    var value: String?
    var rejectedCount = 0
    init(_ value: String? = MsgFixture.authority) { self.value = value }
}

@MainActor
struct CoordinatorHarness {
    let coordinator: ConversationCoordinator
    let http: ScriptedHTTP
    let socket: FakeSocketTransport
    let scheduler: ManualScheduler
    let authority: MsgAuthorityBox

    static let subscription = MsgFixture.identity(9001)

    static func make(
        http: ScriptedHTTP = ScriptedHTTP(),
        withSocket: Bool = true,
        authority: MsgAuthorityBox? = nil,
        random: @escaping () -> Double = { 0.5 },
        configuration: ConversationConfiguration = ConversationConfiguration(),
        unread: MessagingUnreadStore? = nil
    ) -> CoordinatorHarness {
        let authority = authority ?? MsgAuthorityBox()
        let socket = FakeSocketTransport()
        let scheduler = ManualScheduler()
        var counter = 0
        let coordinator = ConversationCoordinator(
            requestId: MsgFixture.requestId,
            http: http,
            socketTransport: withSocket ? socket : nil,
            authorityProvider: { authority.value },
            participantAuthorityRejected: { authority.rejectedCount += 1 },
            scheduler: scheduler,
            random: random,
            makeIdentity: { counter += 1; return MsgFixture.uuid(counter) },
            configuration: configuration,
            unread: unread
        )
        return CoordinatorHarness(coordinator: coordinator, http: http, socket: socket, scheduler: scheduler, authority: authority)
    }
}

/// Polls until `condition` holds (or fails the test after a bounded wait).
@MainActor
func eventually(
    _ description: String = "condition",
    timeout: TimeInterval = 3,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { XCTFail("Timed out waiting for \(description)", file: file, line: line); return }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

/// Lets already-runnable asynchronous work finish so negative assertions are meaningful.
@MainActor
func settle() async {
    for _ in 0..<25 {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

extension CoordinatorHarness {
    static var ref: String { subscription }

    /// Opens, catches up and (with a socket) subscribes. Leaves the coordinator live.
    func boot() async {
        coordinator.start()
        if socket.connections.isEmpty && http.opens >= 0 {
            await eventually("catch-up applied") { coordinator.hasLoaded }
        }
        if let first = await firstSocket() {
            await eventually("subscribe frame") { first.sent.count == 1 }
            first.push(FakeSocketConnection.subscribedFrame(Self.ref))
            await eventually("live") { coordinator.connectionStatus == .live }
        }
        await settle()
    }

    private func firstSocket() async -> FakeSocketConnection? {
        for _ in 0..<200 {
            if let c = socket.connections.first { return c }
            try? await Task.sleep(nanoseconds: 2_000_000)
            if coordinator.phase == .active && coordinator.hasLoaded && socket.connections.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        return nil
    }
}

extension ScriptedHTTP {
    func readReturning(_ messages: [ChatMessage]) {
        enqueueRead { call in .success(ChatMessagePageDTO(messages: messages, nextAfter: messages.last?.sequence ?? call.after)) }
    }
}
