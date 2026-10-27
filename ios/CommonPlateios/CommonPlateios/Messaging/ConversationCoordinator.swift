//
//  ConversationCoordinator.swift
//  CommonPlateios
//
// W4-MSG1 CP3 (dormant). The single owner of one private conversation's local
// state. It is bound at creation to one participant credential and one request,
// resolves its conversation exactly once, and is never re-pointed: a different
// participant, request or conversation needs a new coordinator.
//
// Invariants (see docs/planning/slices/W4-MSG1.md, CP3):
//   * HTTP is the only message authority. Socket frames are content-free hints;
//     a hint never inserts a message and never moves the cursor.
//   * Every asynchronous completion re-checks identity, conversation, and (for
//     the socket) connection generation and is dropped if stale.
//   * `404 CONVERSATION_UNAVAILABLE` purges everything and is terminal; a closed
//     conversation is never reopened by foreground, reconnect, retry or cache.
//   * Transport errors, timeouts, 503 and socket failures prove neither closure
//     nor credential invalidity. Only an HTTP `PARTICIPANT_AUTHORITY_INVALID`
//     reaches the injected rejection closure.
//   * Reading (CP7-B): only the server's open acknowledgement (messages at or
//     below `openingSnapshotSequence`) and an explicit acknowledgement of
//     server-confirmed incoming messages the screen reports as actually
//     displayed mark anything read. Own, local, fetched-but-undisplayed and
//     other conversations' messages are never submitted. A failed or ambiguous
//     acknowledgement is dropped, never recorded as read, and never retried by
//     a timer; only a new display event, a foreground return with the same
//     still-visible messages, or the next open can send it again.
//   * An ambiguous send is reconciled read-only by exact clientMessageId and is
//     otherwise re-sent only by an explicit user "Try again" with the same
//     identity, conversation and payload. Nothing here persists to disk.
import Foundation
import Combine

nonisolated protocol ConversationScheduling: Sendable {
    var now: Date { get }
    func sleep(seconds: TimeInterval) async throws
}

nonisolated struct SystemConversationScheduler: ConversationScheduling {
    var now: Date { Date() }
    func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

nonisolated struct ConversationConfiguration: Equatable {
    var pageLimit = MessagingWire.maxPageSize
    var periodicInterval: TimeInterval = 30
    /// In-flight + ambiguous + failed local messages: 10 x <=2,000 UTF-16 units
    /// bounds retained unsent payload to ~40 KB while leaving room for a normal
    /// burst of retries. Sending is disabled (never discarded) at the limit.
    var maxOutstandingLocal = 10
    var reconnectBase: TimeInterval = 1
    var reconnectCap: TimeInterval = 60
    var reconnectJitter = 0.2
    var upgradesPerWindow = 30
    var upgradeWindow: TimeInterval = 60
    /// A connection that stayed subscribed this long resets the backoff.
    var stableConnection: TimeInterval = 30
}

/// Cancels its socket when released, so a discarded coordinator cannot leak a
/// connection whose receive loop only holds the socket weakly-owned by nothing else.
nonisolated private final class ConnectionHandle: @unchecked Sendable {
    let socket: ConversationSocketConnection
    init(_ socket: ConversationSocketConnection) { self.socket = socket }
    deinit { socket.cancel() }
}

nonisolated enum ConversationNotice: Equatable {
    case reviseMessage
}

@MainActor
final class ConversationCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case opening
        /// Opening failed with an unknown outcome; nothing was resolved.
        case openFailed
        case active
        /// Authoritative closure. Terminal.
        case unavailable
        /// No usable participant credential. Nothing is sent. Terminal.
        case authorityRequired
        /// Identity replaced/removed/rejected, or the host closed it. Terminal.
        case ended
    }

    enum ConnectionStatus: Equatable {
        case idle
        case connecting
        case live
        case disconnected
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var items: [ConversationItem] = []
    @Published private(set) var connectionStatus: ConnectionStatus = .idle
    /// True once one HTTP catch-up has been applied.
    @Published private(set) var hasLoaded = false
    /// The last HTTP catch-up ended with an unknown outcome.
    @Published private(set) var isOffline = false
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var historyFailed = false
    @Published private(set) var hasOlder = false
    @Published private(set) var failedSheetTarget: String?
    @Published private(set) var notice: ConversationNotice?
    @Published var draft = ""

    private struct Fence: Equatable {
        let identity: Int
        let conversation: Int
    }

    private enum CatchUpResult { case complete, failed, fenced }

    private let requestId: String
    private let http: ConversationHTTPServing
    private let socketTransport: ConversationSocketTransporting?
    private let authorityProvider: () -> String?
    private let participantAuthorityRejected: () -> Void
    private let scheduler: ConversationScheduling
    private let random: () -> Double
    private let makeIdentity: () -> UUID
    private let configuration: ConversationConfiguration
    private let boundAuthority: String?
    private let unread: MessagingUnreadStore?

    private var transcript = ConversationTranscript()
    private var conversationId: String?
    private var foreground = true

    private var identityGeneration = 0
    private var conversationGeneration = 0
    private var connectionGeneration = 0
    private var fetchEpoch = 0
    private var historyEpoch = 0
    private var periodicToken = 0
    private var reconnectToken = 0

    private var openTask: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var dirty = false
    private var connectAfterCatchUp = false
    private var periodicTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var socketTask: Task<Void, Never>?
    private var connection: ConnectionHandle?
    private var subscribedReference: String?
    private var subscribedAt: Date?
    private var consecutiveFailures = 0
    private var upgradeTimes: [Date] = []
    private var sendTasks: [String: Task<Void, Never>] = [:]

    private var openingSnapshotSequence: Int?
    /// Messages the latest screen report says are on screen right now.
    private var displayedIDs = Set<String>()
    /// Server-confirmed acknowledged sequences. A failed acknowledgement is never added.
    private var acknowledgedSequences = Set<Int>()
    private var pendingAcknowledgement = Set<Int>()
    private var inFlightAcknowledgement = Set<Int>()
    private var acknowledgementTask: Task<Void, Never>?

    init(
        requestId: String,
        http: ConversationHTTPServing,
        socketTransport: ConversationSocketTransporting?,
        authorityProvider: @escaping () -> String?,
        participantAuthorityRejected: @escaping () -> Void,
        scheduler: ConversationScheduling = SystemConversationScheduler(),
        random: @escaping () -> Double = { Double.random(in: 0..<1) },
        makeIdentity: @escaping () -> UUID = { UUID() },
        configuration: ConversationConfiguration = ConversationConfiguration(),
        unread: MessagingUnreadStore? = nil
    ) {
        self.requestId = requestId
        self.http = http
        self.socketTransport = socketTransport
        self.authorityProvider = authorityProvider
        self.participantAuthorityRejected = participantAuthorityRejected
        self.scheduler = scheduler
        self.random = random
        self.makeIdentity = makeIdentity
        self.configuration = configuration
        self.boundAuthority = authorityProvider()
        self.unread = unread
    }

    deinit {
        // Releasing the coordinator cancels every task it owns. In-flight sends
        // are left to settle: cancelling an HTTP call proves nothing about the
        // server, and their results are discarded (nothing persists).
        openTask?.cancel()
        fetchTask?.cancel()
        historyTask?.cancel()
        periodicTask?.cancel()
        reconnectTask?.cancel()
        socketTask?.cancel()
        connection?.socket.cancel()
        acknowledgementTask?.cancel()
    }

    // MARK: - Presentation inputs

    /// Unresolved (sending, ambiguous or failed) local messages.
    var outstandingLocalCount: Int { transcript.locals.count }

    var isAtLocalCapacity: Bool { outstandingLocalCount >= configuration.maxOutstandingLocal }

    var canSend: Bool {
        phase == .active && !isAtLocalCapacity && MessagingWire.isSendableText(draft)
    }

    var isLoadingInitialMessages: Bool {
        (phase == .opening) || (phase == .active && !hasLoaded && !isOffline)
    }

    var failedSheetMessage: LocalOutgoingMessage? {
        guard let id = failedSheetTarget, let local = transcript.local(id), case .failed = local.state else { return nil }
        return local
    }

    // MARK: - Host entry points

    /// Resolves the conversation once. Allowed only before a conversation has
    /// been resolved (first call, or after an unknown open failure).
    func start(isForeground: Bool = true) {
        guard identityIsCurrent(), phase == .idle || phase == .openFailed else { return }
        foreground = isForeground
        guard let authority = boundAuthority, !authority.isEmpty else {
            endAuthorityRequired()
            return
        }
        phase = .opening
        let fence = currentFence
        let requestId = requestId
        let http = http
        openTask = Task { [weak self] in
            let outcome = await http.open(authority: authority, requestId: requestId)
            guard let self, !Task.isCancelled, self.isCurrent(fence) else { return }
            self.openTask = nil
            switch outcome {
            case .success(let opened):
                self.conversationId = opened.conversationId
                self.openingSnapshotSequence = opened.openingSnapshotSequence
                // Opening changed the server's unread state; unknown, never zero.
                self.unread?.invalidate(requestId: requestId)
                self.phase = .active
                if self.foreground { self.requestHistory() }
            case .unavailable: self.closeConversation()
            case .identityInvalid: self.authorityRejected(presented: authority)
            case .authorityRequired: self.endAuthorityRequired()
            case .refused, .unknown: self.phase = .openFailed
            }
        }
    }

    func sceneDidBecomeActive() {
        guard identityIsCurrent() else { return }
        foreground = true
        switch phase {
        case .active:
            if hasLoaded { requestCatchUp(connectAfter: true) }
            else { requestHistory() }
            acknowledgeDisplayedMessages()
        default: break
        }
    }

    func sceneDidEnterBackground() {
        guard identityIsCurrent() else { return }
        foreground = false
        pendingAcknowledgement.removeAll()
        cancelForegroundWork()
    }

    // MARK: - Display acknowledgement

    /// The screen's current set of fully presented message rows. Only the
    /// server-confirmed incoming messages among them, above the opening
    /// snapshot and not yet acknowledged, are ever submitted.
    func messagesDidDisplay(_ ids: Set<String>) {
        displayedIDs = ids
        acknowledgeDisplayedMessages()
    }

    private func acknowledgeDisplayedMessages() {
        guard identityIsCurrent(), phase == .active, foreground, conversationId != nil,
              let snapshot = openingSnapshotSequence, !displayedIDs.isEmpty else { return }
        for message in transcript.messages
        where message.sender == .other
            && message.sequence > snapshot
            && displayedIDs.contains(message.clientMessageId)
            && !acknowledgedSequences.contains(message.sequence)
            && !inFlightAcknowledgement.contains(message.sequence) {
            pendingAcknowledgement.insert(message.sequence)
        }
        sendNextAcknowledgement()
    }

    private func sendNextAcknowledgement() {
        guard acknowledgementTask == nil, foreground, phase == .active, !pendingAcknowledgement.isEmpty,
              let authority = boundAuthority, let conversationId else { return }
        let batch = Array(pendingAcknowledgement.sorted().prefix(MessagingWire.maxPageSize))
        pendingAcknowledgement.subtract(batch)
        inFlightAcknowledgement = Set(batch)
        let fence = currentFence
        let requestId = requestId
        let http = http
        acknowledgementTask = Task { [weak self] in
            let outcome = await http.acknowledge(
                authority: authority, requestId: requestId,
                conversationId: conversationId, displayedSequences: batch
            )
            self?.finishAcknowledgement(batch, outcome, fence: fence, authority: authority)
        }
    }

    private func finishAcknowledgement(
        _ batch: [Int],
        _ outcome: ConversationHTTPOutcome<ConversationReadAckDTO>,
        fence: Fence,
        authority: String
    ) {
        guard isCurrent(fence) else { return }
        acknowledgementTask = nil
        inFlightAcknowledgement.removeAll()
        switch outcome {
        case .success:
            acknowledgedSequences.formUnion(batch)
            unread?.acknowledgementSucceeded(requestId: requestId)
        case .unavailable:
            closeConversation()
            return
        case .identityInvalid:
            authorityRejected(presented: authority)
            return
        case .authorityRequired:
            endAuthorityRequired()
            return
        case .refused, .unknown:
            // Dropped without inference: nothing is treated as read.
            break
        }
        sendNextAcknowledgement()
    }

    /// Host hook after any credential change. The coordinator also re-checks
    /// the credential on every entry point and completion.
    func identityDidChange() {
        _ = identityIsCurrent()
    }

    /// Non-destructive retry for the offline / open-failed states.
    func retryConnection() {
        guard identityIsCurrent() else { return }
        switch phase {
        case .openFailed: start(isForeground: foreground)
        case .active:
            if hasLoaded { if foreground { requestCatchUp(connectAfter: true) } }
            else { requestHistory() }
        default: break
        }
    }

    /// Called once per user upward reach, not by row appearance or a paging loop.
    func loadOlderMessages() {
        guard hasLoaded, hasOlder, !historyFailed else { return }
        requestHistory()
    }

    func retryHistory() {
        guard historyFailed else { return }
        requestHistory()
    }

    private func requestHistory() {
        guard identityIsCurrent(), phase == .active, foreground,
              historyTask == nil, let authority = boundAuthority, let conversationId,
              !hasLoaded || transcript.hasOlder else { return }
        let before = hasLoaded ? transcript.nextBefore : nil
        let fence = currentFence
        historyEpoch += 1
        let epoch = historyEpoch
        let http = http
        let requestId = requestId
        isLoadingHistory = true
        historyFailed = false
        historyTask = Task { [weak self] in
            let outcome = await http.readHistory(
                authority: authority, requestId: requestId, conversationId: conversationId,
                before: before, limit: MessagingWire.historyPageSize
            )
            guard let self, !Task.isCancelled, self.historyEpoch == epoch,
                  self.foreground, self.isCurrent(fence) else { return }
            self.historyTask = nil
            self.isLoadingHistory = false
            switch outcome {
            case .success(let page):
                guard self.transcript.applyHistory(page, before: before) else {
                    self.historyFailed = true
                    if !self.hasLoaded { self.isOffline = true }
                    return
                }
                let opening = !self.hasLoaded
                self.hasLoaded = true
                self.hasOlder = self.transcript.hasOlder
                self.historyFailed = false
                self.publish()
                if opening {
                    self.isOffline = false
                    self.requestCatchUp(connectAfter: true)
                }
            case .unavailable: self.closeConversation()
            case .identityInvalid: self.authorityRejected(presented: authority)
            case .authorityRequired: self.endAuthorityRequired()
            case .refused, .unknown:
                self.historyFailed = true
                if !self.hasLoaded { self.isOffline = true }
            }
        }
    }

    /// The host dismissed the screen. Local state is purged; nothing persists.
    func dismiss() {
        guard phase != .ended else { return }
        purge()
        phase = .ended
    }

    // MARK: - Sending

    func sendDraft() {
        guard identityIsCurrent(), phase == .active, let conversationId else { return }
        let text = draft
        guard !isAtLocalCapacity, MessagingWire.isSendableText(text) else { return }
        let identity = makeIdentity().uuidString.lowercased()
        draft = ""
        notice = nil
        transcript.addLocal(LocalOutgoingMessage(
            clientMessageId: identity,
            conversationId: conversationId,
            text: text,
            createdAt: scheduler.now,
            state: .sending
        ))
        publish()
        startSend(identity)
    }

    func presentFailedSheet(for clientMessageId: String) {
        // Recoverable failures retry inline; the sheet is only for refusals.
        guard identityIsCurrent(), phase == .active,
              let local = transcript.local(clientMessageId),
              case .failed(let failure) = local.state,
              !failure.isRetryable else { return }
        failedSheetTarget = clientMessageId
    }

    func dismissFailedSheet() {
        failedSheetTarget = nil
    }

    /// "Try again": the identical conversation, payload and clientMessageId.
    func retryFailed(_ clientMessageId: String) {
        guard identityIsCurrent(), phase == .active,
              let local = transcript.local(clientMessageId),
              case .failed(let failure) = local.state,
              failure.isRetryable,
              local.conversationId == conversationId,
              sendTasks[clientMessageId] == nil else { return }
        failedSheetTarget = nil
        transcript.setState(.sending, for: clientMessageId)
        publish()
        startSend(clientMessageId)
    }

    /// "Cancel": discards only that failed local message.
    func cancelFailed(_ clientMessageId: String) {
        guard identityIsCurrent(),
              let local = transcript.local(clientMessageId),
              case .failed(let failure) = local.state,
              failure.isDefinitelyUnsent else { return }
        transcript.removeLocal(clientMessageId)
        if failedSheetTarget == clientMessageId { failedSheetTarget = nil }
        publish()
    }

    private func startSend(_ identity: String) {
        guard let local = transcript.local(identity), let authority = boundAuthority else { return }
        let fence = currentFence
        let requestId = requestId
        let http = http
        sendTasks[identity] = Task { [weak self] in
            let outcome = await http.send(
                authority: authority,
                requestId: requestId,
                conversationId: local.conversationId,
                clientMessageId: identity,
                text: local.text
            )
            self?.finishSend(identity, outcome, fence: fence, authority: authority)
        }
    }

    private func finishSend(
        _ identity: String,
        _ outcome: ConversationHTTPOutcome<ChatMessage>,
        fence: Fence,
        authority: String
    ) {
        guard isCurrent(fence) else { return }
        sendTasks[identity] = nil
        switch outcome {
        case .success(let message) where message.clientMessageId == identity && message.sender == .own:
            if transcript.applySent(message) { publish() }
            else { reconcile(identity, fence: fence, authority: authority) }
        case .unavailable: closeConversation()
        case .identityInvalid: authorityRejected(presented: authority)
        case .authorityRequired: endAuthorityRequired()
        case .refused(let refusal):
            transcript.setState(.failed(.refused(refusal)), for: identity)
            if refusal == .textNotAllowed { notice = .reviseMessage }
            publish()
        case .success, .unknown:
            reconcile(identity, fence: fence, authority: authority)
        }
    }

    private func reconcile(_ identity: String, fence: Fence, authority: String) {
        guard let local = transcript.local(identity) else { return }
        let requestId = requestId
        let http = http
        sendTasks[identity] = Task { [weak self] in
            let outcome = await http.reconcile(
                authority: authority,
                requestId: requestId,
                conversationId: local.conversationId,
                clientMessageId: identity
            )
            self?.finishReconcile(identity, outcome, fence: fence, authority: authority)
        }
    }

    private func finishReconcile(
        _ identity: String,
        _ outcome: ConversationHTTPOutcome<ChatMessage?>,
        fence: Fence,
        authority: String
    ) {
        guard isCurrent(fence) else { return }
        sendTasks[identity] = nil
        switch outcome {
        case .success(let message?) where message.clientMessageId == identity && message.sender == .own:
            if !transcript.applySent(message) {
                transcript.setState(.failed(.unconfirmed), for: identity)
            }
        case .success(nil):
            transcript.setState(.failed(.notDelivered), for: identity)
        case .unavailable: closeConversation(); return
        case .identityInvalid: authorityRejected(presented: authority); return
        case .authorityRequired: endAuthorityRequired(); return
        case .success, .refused, .unknown:
            transcript.setState(.failed(.unconfirmed), for: identity)
        }
        publish()
    }

    // MARK: - Catch-up (serialized, dirty-bit)

    private enum PageStep { case more, complete, failed, fenced }

    private struct PageRequest {
        let authority: String
        let conversationId: String
        let after: Int
    }

    private func requestCatchUp(connectAfter: Bool = false) {
        guard identityIsCurrent(), phase == .active, foreground, hasLoaded, conversationId != nil else { return }
        if connectAfter { connectAfterCatchUp = true }
        if fetchTask != nil {
            dirty = true
            return
        }
        let fence = currentFence
        let epoch = fetchEpoch
        let http = http
        let requestId = requestId
        let limit = configuration.pageLimit
        // The task never holds the coordinator across an await: every hop back
        // re-resolves a weak reference, so releasing the coordinator releases
        // (and the deinit cancels) an in-flight catch-up.
        fetchTask = Task { [weak self] in
            var again = true
            while again {
                guard self?.beginCycle(fence, epoch) == true else { return }
                var result = CatchUpResult.complete
                while true {
                    guard let request = self?.nextPageRequest(fence, epoch) else { result = .fenced; break }
                    let outcome = await http.readPage(
                        authority: request.authority,
                        requestId: requestId,
                        conversationId: request.conversationId,
                        after: request.after,
                        limit: limit
                    )
                    guard let step = self?.applyPageOutcome(outcome, request, fence, epoch) else { return }
                    if step == .more { await Task.yield(); continue }
                    result = step == .complete ? .complete : (step == .failed ? .failed : .fenced)
                    break
                }
                guard let next = self?.endCycle(result, fence, epoch) else { return }
                again = next
            }
        }
    }

    private func catchUpIsCurrent(_ fence: Fence, _ epoch: Int) -> Bool {
        !Task.isCancelled && epoch == fetchEpoch && isCurrent(fence)
    }

    private func beginCycle(_ fence: Fence, _ epoch: Int) -> Bool {
        guard catchUpIsCurrent(fence, epoch) else { return false }
        dirty = false
        return true
    }

    private func nextPageRequest(_ fence: Fence, _ epoch: Int) -> PageRequest? {
        guard catchUpIsCurrent(fence, epoch), let authority = boundAuthority, let conversationId else { return nil }
        return PageRequest(authority: authority, conversationId: conversationId, after: transcript.cursor)
    }

    /// No page cap: authorized history is never silently truncated. Each
    /// applied page must advance the cursor, so catch-up always terminates.
    private func applyPageOutcome(
        _ outcome: ConversationHTTPOutcome<ChatMessagePageDTO>,
        _ request: PageRequest,
        _ fence: Fence,
        _ epoch: Int
    ) -> PageStep {
        guard catchUpIsCurrent(fence, epoch) else { return .fenced }
        switch outcome {
        case .success(let page):
            guard transcript.applyPage(page, requestedAfter: request.after) else { return .failed }
            publish()
            return page.messages.count < configuration.pageLimit ? .complete : .more
        case .unavailable:
            closeConversation()
            return .fenced
        case .identityInvalid:
            authorityRejected(presented: request.authority)
            return .fenced
        case .authorityRequired:
            endAuthorityRequired()
            return .fenced
        case .refused, .unknown:
            return .failed
        }
    }

    /// Returns whether another cycle (a hint arrived mid-fetch) must run.
    private func endCycle(_ result: CatchUpResult, _ fence: Fence, _ epoch: Int) -> Bool {
        guard catchUpIsCurrent(fence, epoch) else { return false }
        switch result {
        case .complete:
            isOffline = false
        case .failed:
            isOffline = true
        case .fenced:
            return false
        }
        if dirty && result == .complete { return true }
        dirty = false
        fetchTask = nil
        if connectAfterCatchUp {
            connectAfterCatchUp = false
            connectSocket()
            startPeriodic()
        }
        return false
    }

    private func startPeriodic() {
        guard periodicTask == nil, phase == .active, foreground else { return }
        periodicToken += 1
        let token = periodicToken
        let interval = configuration.periodicInterval
        let scheduler = scheduler
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await scheduler.sleep(seconds: interval) } catch { return }
                guard let self, token == self.periodicToken, self.foreground, self.phase == .active else { return }
                self.requestCatchUp()
            }
        }
    }

    // MARK: - Socket (content-free hints only)

    private func connectSocket() {
        guard let socketTransport, let authority = boundAuthority, let conversationId,
              phase == .active, foreground, connection == nil, reconnectTask == nil,
              identityIsCurrent() else { return }
        let now = scheduler.now
        upgradeTimes.removeAll { now.timeIntervalSince($0) >= configuration.upgradeWindow }
        if upgradeTimes.count >= configuration.upgradesPerWindow, let oldest = upgradeTimes.first {
            scheduleReconnect(minimumDelay: oldest.addingTimeInterval(configuration.upgradeWindow).timeIntervalSince(now))
            return
        }
        upgradeTimes.append(now)

        connectionGeneration += 1
        let generation = connectionGeneration
        let fence = currentFence
        let socket = socketTransport.connect(authority: authority)
        connection = ConnectionHandle(socket)
        connectionStatus = .connecting
        subscribedReference = nil
        subscribedAt = nil
        let subscribe = ConversationSubscribeFrame.encode(requestId: requestId, conversationId: conversationId)
        socketTask = Task { [weak self] in
            do {
                try await socket.send(text: subscribe)
                while !Task.isCancelled {
                    let inbound = try await socket.receive()
                    guard let self, self.socketIsCurrent(generation, fence) else {
                        socket.cancel()
                        return
                    }
                    self.handleInbound(inbound)
                }
            } catch {
                self?.socketEnded(generation: generation, fence: fence, error: error)
            }
        }
    }

    private func socketIsCurrent(_ generation: Int, _ fence: Fence) -> Bool {
        !Task.isCancelled && generation == connectionGeneration && isCurrent(fence)
    }

    private func handleInbound(_ inbound: ConversationSocketInbound) {
        // Malformed, unknown, binary or oversized frames change nothing.
        guard let frame = ConversationSocketFrame.decode(inbound) else { return }
        switch frame {
        case .subscribed(let reference):
            guard subscribedReference == nil else { return }
            subscribedReference = reference
            subscribedAt = scheduler.now
            connectionStatus = .live
            requestCatchUp()
        case .changed(let reference):
            guard reference == subscribedReference else { return }
            requestCatchUp()
        }
    }

    private func socketEnded(generation: Int, fence: Fence, error: Error) {
        guard generation == connectionGeneration, isCurrent(fence), !Task.isCancelled else { return }
        let lived = subscribedAt.map { scheduler.now.timeIntervalSince($0) } ?? 0
        consecutiveFailures = lived >= configuration.stableConnection ? 1 : consecutiveFailures + 1
        teardownSocket()
        connectionStatus = .disconnected
        // A refusal is only a reason to ask HTTP; it is never proof of closure
        // or of an invalid credential.
        if let failure = error as? ConversationSocketFailure, case .closed(let code) = failure, code == 1008 {
            requestCatchUp()
        }
        guard phase == .active, foreground else { return }
        scheduleReconnect(minimumDelay: 0)
    }

    private func scheduleReconnect(minimumDelay: TimeInterval) {
        reconnectToken += 1
        let token = reconnectToken
        let exponent = max(0, min(consecutiveFailures - 1, 16))
        let base = min(configuration.reconnectCap, configuration.reconnectBase * pow(2, Double(exponent)))
        let jitter = 1 + (random() * 2 - 1) * configuration.reconnectJitter
        let delay = max(minimumDelay, min(configuration.reconnectCap, base * jitter))
        let scheduler = scheduler
        reconnectTask = Task { [weak self] in
            do { try await scheduler.sleep(seconds: delay) } catch { return }
            guard let self, token == self.reconnectToken else { return }
            self.reconnectTask = nil
            self.connectSocket()
        }
    }

    private func teardownSocket() {
        connectionGeneration += 1
        socketTask?.cancel()
        socketTask = nil
        connection?.socket.cancel()
        connection = nil
        subscribedReference = nil
        subscribedAt = nil
    }

    // MARK: - Fencing, purge and terminal transitions

    private var currentFence: Fence {
        Fence(identity: identityGeneration, conversation: conversationGeneration)
    }

    private func isCurrent(_ fence: Fence) -> Bool {
        identityIsCurrent() && fence == currentFence
    }

    /// The coordinator is bound to the credential it was created with. Any
    /// replacement or removal ends it and purges every transcript and payload.
    private func identityIsCurrent() -> Bool {
        if phase == .ended { return false }
        guard authorityProvider() == boundAuthority else {
            purge()
            phase = .ended
            unread?.authorityMayHaveChanged()
            return false
        }
        return true
    }

    private func cancelForegroundWork() {
        historyEpoch += 1
        historyTask?.cancel()
        historyTask = nil
        isLoadingHistory = false
        fetchEpoch += 1
        fetchTask?.cancel()
        fetchTask = nil
        dirty = false
        connectAfterCatchUp = false
        periodicToken += 1
        periodicTask?.cancel()
        periodicTask = nil
        reconnectToken += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        teardownSocket()
        if connectionStatus != .idle { connectionStatus = .disconnected }
    }

    private func purge() {
        identityGeneration += 1
        conversationGeneration += 1
        openTask?.cancel()
        openTask = nil
        acknowledgementTask?.cancel()
        acknowledgementTask = nil
        openingSnapshotSequence = nil
        displayedIDs.removeAll()
        acknowledgedSequences.removeAll()
        pendingAcknowledgement.removeAll()
        inFlightAcknowledgement.removeAll()
        for task in sendTasks.values { task.cancel() }
        sendTasks.removeAll()
        cancelForegroundWork()
        transcript = ConversationTranscript()
        conversationId = nil
        consecutiveFailures = 0
        upgradeTimes.removeAll()
        draft = ""
        notice = nil
        failedSheetTarget = nil
        items = []
        hasLoaded = false
        hasOlder = false
        historyFailed = false
        isOffline = false
        connectionStatus = .idle
    }

    private func closeConversation() {
        purge()
        phase = .unavailable
        unread?.conversationClosed(requestId: requestId)
    }

    private func endAuthorityRequired() {
        purge()
        phase = .authorityRequired
        unread?.clearAll()
    }

    private func authorityRejected(presented: String) {
        if authorityProvider() == presented { participantAuthorityRejected() }
        purge()
        phase = .ended
        unread?.clearAll()
    }

    private func publish() {
        items = transcript.items
    }
}
