//
//  ConversationSocketTransport.swift
//  CommonPlateios
//
// W4-MSG1 CP3 (dormant). Content-free WebSocket hint transport for the CP2
// server module. The socket carries no message content in either direction:
// the client sends exactly one `subscribe` frame per connection and the server
// only ever answers `subscribed` / `changed` hints. HTTP stays authoritative.
//
// A socket close, 1008, upgrade failure or timeout is reported only as a
// `ConversationSocketFailure`. It is never evidence of an invalid credential
// or a closed conversation; the coordinator verifies over HTTP.
import Foundation

nonisolated enum ConversationSocketFailure: Error, Equatable {
    /// Closed by either side. `code` is the WebSocket close code when known.
    case closed(code: Int?)
    case failed
    /// The peer sent something that is not a text frame within the size bound.
    case malformed
}

/// One live connection. `cancel()` must be idempotent and must end any
/// pending `receive()` by making it throw.
nonisolated protocol ConversationSocketConnection: AnyObject, Sendable {
    func send(text: String) async throws
    func receive() async throws -> ConversationSocketInbound
    func cancel()
}

nonisolated protocol ConversationSocketTransporting: Sendable {
    /// Opens a connection that presents `authority` in the participant header.
    func connect(authority: String) -> ConversationSocketConnection
}

nonisolated struct URLSessionConversationSocketTransport: ConversationSocketTransporting {
    static let path = "/api/messaging/socket"
    static let participantAuthorityHeader = "x-commonplate-participant"

    private let baseURL: URL
    private let autoResume: Bool

    init(baseURL: URL, autoResume: Bool = true) {
        self.baseURL = baseURL
        self.autoResume = autoResume
    }

    /// `http` → `ws`, `https` → `wss`. Any other scheme yields `nil`.
    static func socketURL(for baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else { return nil }
        switch components.scheme?.lowercased() {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        default: return nil
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }

    /// The credential is only ever a header: never in the URL, query,
    /// subprotocol or a frame.
    static func makeRequest(baseURL: URL, authority: String) -> URLRequest? {
        guard !authority.isEmpty, let url = socketURL(for: baseURL) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(authority, forHTTPHeaderField: participantAuthorityHeader)
        return request
    }

    func connect(authority: String) -> ConversationSocketConnection {
        guard let request = Self.makeRequest(baseURL: baseURL, authority: authority) else {
            return FailedConversationSocketConnection()
        }
        return URLSessionConversationSocketConnection(request: request, autoResume: autoResume)
    }
}

/// Returned when a connection cannot even be formed (bad scheme, no credential).
nonisolated final class FailedConversationSocketConnection: ConversationSocketConnection {
    func send(text: String) async throws { throw ConversationSocketFailure.failed }
    func receive() async throws -> ConversationSocketInbound { throw ConversationSocketFailure.failed }
    func cancel() {}
}

nonisolated final class URLSessionConversationSocketConnection: ConversationSocketConnection, @unchecked Sendable {
    private let session: URLSession
    let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var disposed = false

    init(request: URLRequest, autoResume: Bool = true) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
        task = session.webSocketTask(with: request)
        // Frames are at most 1 KiB; anything larger is a protocol violation.
        task.maximumMessageSize = MessagingWire.maxFrameBytes
        if autoResume { task.resume() }
    }

    func send(text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            throw failure(from: error)
        }
    }

    func receive() async throws -> ConversationSocketInbound {
        do {
            switch try await task.receive() {
            case .string(let text): return .text(text)
            case .data(let data): return .binary(data)
            @unknown default: throw ConversationSocketFailure.malformed
            }
        } catch {
            throw failure(from: error)
        }
    }

    func cancel() {
        lock.lock()
        let first = !disposed
        disposed = true
        lock.unlock()
        guard first else { return }
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    private func failure(from error: Error) -> ConversationSocketFailure {
        if let failure = error as? ConversationSocketFailure { return failure }
        let code = task.closeCode
        if code != .invalid { return .closed(code: code.rawValue) }
        return .failed
    }
}
