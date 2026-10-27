//
//  RequestConversationEntryRow.swift
//  CommonPlateios
//
// W4-MSG1 CP6 (iOS, dormant). The only way into chat: a row on a request
// screen the caller already has an authorized relationship with. Renders
// nothing unless messaging is composed in (never in the shipping app).
import SwiftUI

struct RequestConversationEntryRow: View {
    let requestID: String
    let role: RequestConversationRole
    /// A Blocked/restricted relationship shows no entry at all.
    var isSuppressed = false
    @Binding var path: [AppRoute]
    @Environment(\.requestMessaging) private var messaging

    var body: some View {
        if messaging.isEnabled && !isSuppressed {
            if let unread = messaging.unread {
                ObservedEntry(
                    requestID: requestID, role: role, store: unread, path: $path
                )
            } else {
                EntryButton(requestID: requestID, role: role, unreadCount: nil, path: $path)
            }
        }
    }

    /// Refreshes only on authorized events: appearance (which includes returning
    /// from the conversation) and the scene becoming active. No polling.
    private struct ObservedEntry: View {
        let requestID: String
        let role: RequestConversationRole
        @ObservedObject var store: MessagingUnreadStore
        @Binding var path: [AppRoute]
        @Environment(\.scenePhase) private var scenePhase

        var body: some View {
            EntryButton(
                requestID: requestID, role: role,
                unreadCount: store.state(forRequest: requestID).displayableCount, path: $path
            )
            .onAppear { store.refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { store.refresh() }
            }
        }
    }

    private struct EntryButton: View {
        let requestID: String
        let role: RequestConversationRole
        let unreadCount: Int?
        @Binding var path: [AppRoute]

        private var title: String { role == .requester ? "Message helper" : "Message requester" }

        var body: some View {
            Button {
                path = AppRoute.appending(
                    .requestConversation(requestID: requestID, role: role),
                    to: path
                )
            } label: {
                HStack(spacing: CommonPlateStyle.Spacing.m) {
                    Image(systemName: "message")
                        .foregroundStyle(CommonPlateStyle.Color.brandText)
                    Text(title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: CommonPlateStyle.Spacing.s)
                    if let text = ConversationUnreadPresentation.badgeText(for: unreadCount) {
                        Text(text)
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, CommonPlateStyle.Spacing.s)
                            .padding(.vertical, CommonPlateStyle.Spacing.xs)
                            .frame(minWidth: 28)
                            .background(Capsule().fill(CommonPlateStyle.Color.brandFill))
                            .accessibilityHidden(true)
                            .accessibilityIdentifier("request-conversation-unread")
                    }
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: ConversationLayout.minimumTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                ConversationUnreadPresentation.accessibilityLabel(for: unreadCount)
                    .map { "\(title), \($0)" } ?? title
            )
            .accessibilityIdentifier("request-conversation-entry")
        }
    }
}
