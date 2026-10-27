//
//  RequestMessagingAvailability.swift
//  CommonPlateios
//
// W4-MSG1 CP6 (iOS, dormant). Whether request-linked chat can be entered at
// all. The shipping composition is dormant: the SwiftUI environment default is
// `.dormant`, `ContentView` never injects anything else, and so no entry row,
// route destination or Report disclosure appears in production. Tests (and,
// later, an explicitly authorized INF1/release change) inject `.enabled`.
//
// This type carries no reservation, helper or conversation identity. The only
// binding is the request id plus the participant authority supplied at the
// moment a coordinator is created.
import SwiftUI

nonisolated enum RequestConversationRole: Hashable {
    case requester
    case helper
}

struct RequestMessagingComposition {
    typealias CoordinatorFactory = @MainActor (
        _ requestID: String,
        _ authorityProvider: @escaping () -> String?,
        _ authorityRejected: @escaping () -> Void
    ) -> ConversationCoordinator

    let makeCoordinator: CoordinatorFactory?
    /// The recipient unread projection. Absent when dormant, and optional for
    /// an enabled composition that does not model unread counts.
    let unread: MessagingUnreadStore?

    var isEnabled: Bool { makeCoordinator != nil }

    init(makeCoordinator: CoordinatorFactory?, unread: MessagingUnreadStore? = nil) {
        self.makeCoordinator = makeCoordinator
        self.unread = makeCoordinator == nil ? nil : unread
    }

    static let dormant = RequestMessagingComposition(makeCoordinator: nil)

    /// What the shipping app composes. Deliberately equal to `.dormant`.
    static let shipping = RequestMessagingComposition.dormant

    static func enabled(
        unread: MessagingUnreadStore? = nil,
        _ factory: @escaping CoordinatorFactory
    ) -> RequestMessagingComposition {
        RequestMessagingComposition(makeCoordinator: factory, unread: unread)
    }

    /// The real HTTP/socket wiring. Not referenced by the shipping app until a
    /// separately authorized activation (P2 + INF1 + integrated proof).
    @MainActor
    static func live(
        configuration: APIConfiguration,
        authorityProvider: @escaping () -> String?
    ) -> RequestMessagingComposition {
        let http = ConversationHTTPClient(client: APIClient(configuration: configuration))
        let unread = MessagingUnreadStore(http: http, authorityProvider: authorityProvider)
        return enabled(unread: unread) { requestID, authority, rejected in
            ConversationCoordinator(
                requestId: requestID,
                http: http,
                socketTransport: URLSessionConversationSocketTransport(
                    baseURL: configuration.baseURL
                ),
                authorityProvider: authority,
                participantAuthorityRejected: rejected,
                unread: unread
            )
        }
    }
}

private struct RequestMessagingKey: EnvironmentKey {
    static let defaultValue = RequestMessagingComposition.shipping
}

extension EnvironmentValues {
    var requestMessaging: RequestMessagingComposition {
        get { self[RequestMessagingKey.self] }
        set { self[RequestMessagingKey.self] = newValue }
    }
}
