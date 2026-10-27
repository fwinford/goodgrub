//
//  MessagingUnreadStore.swift
//  CommonPlateios
//
// W4-MSG1 CP7-B (dormant). The in-memory, MSG1-owned client view of the
// recipient's CP7-A unread projection. It is never persisted, holds no message
// content, and the server projection stays the only authority.
//
// Invariants:
//   * Entries are keyed by the exact (request, conversation) the server named.
//   * Unknown is never zero. A failed, undecodable, unavailable or unauthorized
//     fetch never produces a count and never claims success.
//   * After a temporary failure a last-known count is retained only while the
//     same participant authority still holds, and is reported as stale.
//   * Opening, acknowledging, closure, Block, relationship change, participant
//     change and sign-out invalidate immediately. A response that began before
//     an invalidation is dropped for the invalidated scope; a response for a
//     previous authority generation is dropped entirely.
//   * The raw credential is read through the injected provider, never stored,
//     logged or used as a key; only a one-way fingerprint is compared.
import Foundation
import Combine
import CryptoKit
import SwiftUI

nonisolated enum RequestUnreadState: Equatable {
    case unknown
    /// `isStale` means the count survived a failed refresh and is not verified current.
    case known(count: Int, isStale: Bool)

    /// What a surface may show: a positive count, otherwise nothing.
    var displayableCount: Int? {
        if case .known(let count, _) = self, count > 0 { return count }
        return nil
    }
}

@MainActor
final class MessagingUnreadStore: ObservableObject {
    private struct Key: Hashable {
        let requestId: String
        let conversationId: String
    }

    /// Bumped on every observable change so views re-read `state(forRequest:)`.
    @Published private(set) var revision = 0

    private let http: ConversationHTTPServing
    private let authorityProvider: () -> String?

    private var entries: [Key: Int] = [:]
    /// Requests whose count was invalidated and not yet resolved by a later fetch.
    private var unknownRequests = Set<String>()
    private var invalidatedAt: [String: Int] = [:]
    private var clock = 0
    private var generation = 0
    private var boundFingerprint: Data?
    private var hasSnapshot = false
    /// Set the first time a different or missing credential is observed. Sticky
    /// until `clearAll`, so an A -> B -> A switch cannot resurrect A's entries.
    private var authorityLost = false
    private var isStale = false
    private var fetchSerial = 0
    private var appliedSerial = 0
    private var startClocks: [Int: Int] = [:]
    private var tasks: [Int: Task<Void, Never>] = [:]

    init(http: ConversationHTTPServing, authorityProvider: @escaping () -> String?) {
        self.http = http
        self.authorityProvider = authorityProvider
    }

    deinit {
        for task in tasks.values { task.cancel() }
    }

    // MARK: - Read-only lookup

    /// The count for one request, or unknown. Pure: it never mutates state.
    /// More than one entry for the same request is ambiguous and so unknown.
    func state(forRequest requestId: String) -> RequestUnreadState {
        guard authorityMatches, !authorityLost, !unknownRequests.contains(requestId) else { return .unknown }
        let matching = entries.filter { $0.key.requestId == requestId }
        switch matching.count {
        case 0:
            // Absence means zero only in a current snapshot; never from a stale one.
            return hasSnapshot && !isStale ? .known(count: 0, isStale: false) : .unknown
        case 1:
            return .known(count: matching.first!.value, isStale: isStale)
        default:
            return .unknown
        }
    }

    // MARK: - Refresh

    /// Fetches the projection. No polling: callers invoke this on authorized
    /// events (scene active, entry appearance, return from a conversation, ack).
    func refresh() {
        guard validateAuthority(), let authority = authorityProvider(), !authority.isEmpty else { return }
        // An identical fetch already started and nothing was invalidated since.
        if startClocks.values.contains(clock) { return }
        fetchSerial += 1
        let serial = fetchSerial
        let startClock = clock
        let startGeneration = generation
        let fingerprint = boundFingerprint
        startClocks[serial] = startClock
        let http = http
        tasks[serial] = Task { [weak self] in
            let outcome = await http.unreadSummary(authority: authority)
            guard let self, !Task.isCancelled else { return }
            self.finish(
                outcome, serial: serial, startClock: startClock,
                generation: startGeneration, fingerprint: fingerprint
            )
        }
    }

    private func finish(
        _ outcome: ConversationHTTPOutcome<MessagingUnreadSummaryDTO>,
        serial: Int,
        startClock: Int,
        generation startGeneration: Int,
        fingerprint: Data?
    ) {
        tasks[serial] = nil
        startClocks[serial] = nil
        guard startGeneration == generation, validateAuthority(), fingerprint == boundFingerprint,
              serial > appliedSerial else { return }
        appliedSerial = serial
        switch outcome {
        case .success(let summary):
            merge(summary, startClock: startClock)
        case .identityInvalid, .authorityRequired:
            clearAll()
        case .unavailable, .refused, .unknown:
            // Includes the server's fail-closed cap: nothing is learned.
            if !isStale { isStale = true; touch() }
        }
    }

    private func merge(_ summary: MessagingUnreadSummaryDTO, startClock: Int) {
        func invalidatedSinceStart(_ requestId: String) -> Bool { (invalidatedAt[requestId] ?? 0) > startClock }
        entries = entries.filter { invalidatedSinceStart($0.key.requestId) }
        for entry in summary.conversations where !invalidatedSinceStart(entry.requestId) {
            entries[Key(requestId: entry.requestId, conversationId: entry.conversationId)] = entry.unreadCount
        }
        unknownRequests = unknownRequests.filter { invalidatedSinceStart($0) }
        hasSnapshot = true
        isStale = false
        touch()
    }

    // MARK: - Invalidation

    /// Drops this request's count to unknown (never zero) until a later fetch
    /// that started after this call resolves it.
    func invalidate(requestId: String) {
        clock += 1
        invalidatedAt[requestId] = clock
        unknownRequests.insert(requestId)
        entries = entries.filter { $0.key.requestId != requestId }
        touch()
    }

    /// The server confirmed newly acknowledged messages: the count changed, so
    /// it is unknown until the next authoritative fetch, which is requested now.
    func acknowledgementSucceeded(requestId: String) {
        invalidate(requestId: requestId)
        refresh()
    }

    /// Authoritative closure of one conversation, or loss of the relationship.
    func conversationClosed(requestId: String) {
        invalidate(requestId: requestId)
    }

    /// The host detected a possible participant change. A different or missing
    /// credential clears every entry and discards in-flight responses.
    func authorityMayHaveChanged() {
        _ = validateAuthority()
    }

    /// Sign-out, authority rejection or any revocation that removes authority.
    func clearAll() {
        generation += 1
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        startClocks.removeAll()
        entries = [:]
        unknownRequests = []
        invalidatedAt = [:]
        hasSnapshot = false
        isStale = false
        authorityLost = false
        appliedSerial = fetchSerial
        boundFingerprint = currentFingerprint
        touch()
    }

    // MARK: - Authority

    private var currentFingerprint: Data? {
        guard let authority = authorityProvider(), !authority.isEmpty else { return nil }
        return Data(SHA256.hash(data: Data(authority.utf8)))
    }

    private var authorityMatches: Bool {
        let matches = boundFingerprint != nil && boundFingerprint == currentFingerprint
        if boundFingerprint != nil && !matches { authorityLost = true }
        return matches
    }

    /// Binds to the current participant, clearing everything when it differs
    /// from the one the held entries belong to.
    @discardableResult
    private func validateAuthority() -> Bool {
        let current = currentFingerprint
        if current != boundFingerprint || authorityLost { clearAll() }
        return current != nil
    }

    private func touch() { revision &+= 1 }
}

// MARK: - Environment (read-only handoff for later Home-card integration)

/// The read-only lookup a later UI1 Home card consumes. It exposes only
/// "request id → unknown or known(count, isStale)". It cannot refresh,
/// invalidate or acknowledge, and a dormant composition yields `unknown`.
@MainActor
struct RequestUnreadLookup {
    fileprivate let store: MessagingUnreadStore?

    func state(for requestID: String) -> RequestUnreadState {
        store?.state(forRequest: requestID) ?? .unknown
    }
}

/// Re-renders its content whenever the unread projection changes, so a surface
/// does not need to observe the store itself.
struct RequestUnreadReader<Content: View>: View {
    let requestID: String
    @ViewBuilder let content: (RequestUnreadState) -> Content
    @Environment(\.requestMessaging) private var messaging

    var body: some View {
        if let store = messaging.unread {
            Observed(store: store, requestID: requestID, content: content)
        } else {
            content(.unknown)
        }
    }

    private struct Observed: View {
        @ObservedObject var store: MessagingUnreadStore
        let requestID: String
        let content: (RequestUnreadState) -> Content

        var body: some View { content(store.state(forRequest: requestID)) }
    }
}

extension EnvironmentValues {
    var requestUnreadLookup: RequestUnreadLookup {
        RequestUnreadLookup(store: requestMessaging.unread)
    }
}
