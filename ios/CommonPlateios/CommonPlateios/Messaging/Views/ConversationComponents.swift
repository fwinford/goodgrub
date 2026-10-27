//
//  ConversationComponents.swift
//  CommonPlateios
//
// W4-MSG1 CP3 (dormant). Leaf chat components. None is placed anywhere in the
// running app; each is driven by values and closures so it can be previewed
// and tested alone. Reads existing Design tokens without editing them.
import SwiftUI

struct ChatBubbleView: View {
    let model: ChatBubbleModel
    /// Retries a recoverable failure; opens details for a definitive refusal.
    var onFailedTap: () -> Void = {}
    var onDiscard: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch model.kind {
        case .outgoing, .sending: row(alignment: .trailing)
        case .incoming: row(alignment: .leading)
        case .failed: row(alignment: .trailing)
        }
    }

    private var isRetryableFailure: Bool {
        if case .failed(let failure) = model.kind { return failure.isRetryable }
        return false
    }

    private var isUnconfirmed: Bool {
        if case .failed(.unconfirmed) = model.kind { return true }
        return false
    }

    private var canRemove: Bool {
        if case .failed(let failure) = model.kind { return failure.isDefinitelyUnsent }
        return false
    }

    private var failureHeadline: String {
        isUnconfirmed ? ConversationCopy.deliveryUnconfirmed : ConversationCopy.notSent
    }

    private var failureActionText: String {
        "\(failureHeadline) · \(isRetryableFailure ? ConversationCopy.tapToRetry : ConversationCopy.tapForDetails)"
    }

    private var failureActionLabel: String {
        "\(failureHeadline). \(isRetryableFailure ? ConversationCopy.tapToRetry : ConversationCopy.tapForDetails)"
    }

    private func row(alignment: HorizontalAlignment) -> some View {
        let trailing = alignment == .trailing
        return VStack(alignment: trailing ? .trailing : .leading, spacing: 0) {
            HStack(alignment: .center, spacing: CommonPlateStyle.Spacing.s) {
                if trailing { Spacer(minLength: 48) }
                bubble
                if !trailing { Spacer(minLength: 48) }
            }
            if isFailed { failureAction }
        }
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }

    private var bubbleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ConversationLayout.bubbleCornerRadius, style: .continuous)
    }

    private var bubbleText: some View {
        Text(model.text)
            .font(.body)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(background, in: bubbleShape)
            .overlay(bubbleShape.strokeBorder(border, lineWidth: 1))
            .opacity(model.kind == .sending ? 0.7 : 1)
    }

    @ViewBuilder private var selectableBubbleText: some View {
        if isFailed { bubbleText } else { bubbleText.textSelection(.enabled) }
    }

    private var bubble: some View {
        accessibleBubble
    }

    @ViewBuilder private var accessibleBubble: some View {
        let base = selectableBubbleText
            .contextMenu {
                if canRemove {
                    Button(role: .destructive, action: onDiscard) {
                        Label(ConversationCopy.removeMessage, systemImage: "trash")
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.accessibilityLabel)
            .accessibilityHint(model.accessibilityHint ?? "")
        if canRemove {
            base.accessibilityAction(named: ConversationCopy.removeMessage, onDiscard)
        } else {
            base
        }
    }

    /// Sits directly under the failed bubble, so it reads as that message's
    /// status rather than a separate control.
    private var failureAction: some View {
        Button(action: onFailedTap) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                    .accessibilityHidden(true)
                Text(failureActionText)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(Self.failureRed)
            .frame(maxWidth: .infinity, minHeight: ConversationLayout.minimumTarget, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(failureActionLabel)
        .accessibilityIdentifier("chat.failedWarning")
    }

    private var isFailed: Bool {
        if case .failed = model.kind { return true }
        return false
    }

    private static let failureRed = Color(red: 0.74, green: 0.2, blue: 0.24)

    private var background: Color {
        switch model.kind {
        case .outgoing, .sending: return Color.accentColor.opacity(colorScheme == .dark ? 0.35 : 0.16)
        case .incoming: return CommonPlateStyle.Color.requestCardSurface
        case .failed: return Self.failureRed.opacity(0.14)
        }
    }

    private var border: Color {
        switch model.kind {
        case .outgoing, .sending: return Color.accentColor.opacity(0.25)
        case .incoming: return CommonPlateStyle.Color.requestCardBorder
        case .failed: return Self.failureRed.opacity(0.55)
        }
    }
}

struct ConversationTimestampView: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
    }
}

struct ConversationEmptyState: View {
    var body: some View {
        VStack(spacing: CommonPlateStyle.Spacing.m) {
            Image(systemName: "bubble.left")
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
                .frame(width: 68, height: 68)
                .background(Color.accentColor.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            Text(ConversationCopy.emptyLine)
                .font(.callout)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, CommonPlateStyle.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// One generic, non-relationship-revealing closed state. It never says why.
struct ConversationUnavailableState: View {
    var body: some View {
        VStack(spacing: CommonPlateStyle.Spacing.s) {
            Text(ConversationCopy.unavailableTitle)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(ConversationCopy.unavailableDetail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(CommonPlateStyle.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct ConversationStatusBanner: View {
    let text: String
    var actionTitle: String?
    var action: () -> Void = {}

    var body: some View {
        HStack(spacing: CommonPlateStyle.Spacing.s) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let actionTitle {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.footnote.weight(.semibold))
                        .frame(minWidth: ConversationLayout.minimumTarget, minHeight: ConversationLayout.minimumTarget)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, CommonPlateStyle.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CommonPlateStyle.Color.warmSurface)
    }
}

struct ConversationComposer: View {
    @Binding var text: String
    let canSend: Bool
    let onSend: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: CommonPlateStyle.Spacing.m) {
            TextField(ConversationCopy.composerPlaceholder, text: $text, axis: .vertical)
                .focused($isFocused)
                .lineLimit(1...5)
                .padding(.horizontal, CommonPlateStyle.Spacing.l)
                .padding(.vertical, CommonPlateStyle.Spacing.m)
                .frame(minHeight: ConversationLayout.minimumTarget)
                .background(CommonPlateStyle.Color.warmSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { isFocused = true }
                .accessibilityIdentifier("chat.composer")
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(canSend ? Color.accentColor : Color.gray.opacity(0.4), in: Circle())
                    .frame(
                        minWidth: ConversationLayout.minimumTarget,
                        minHeight: ConversationLayout.minimumTarget
                    )
                    .contentShape(Rectangle())
            }
            .disabled(!canSend)
            .accessibilityLabel(ConversationCopy.sendLabel)
            .accessibilityIdentifier("chat.send")
        }
        .padding(.horizontal, CommonPlateStyle.Spacing.l)
        .padding(.vertical, CommonPlateStyle.Spacing.s)
        .background(CommonPlateStyle.Color.baseCanvas)
    }
}

/// "Message not sent" bottom sheet content. The explanation is derived from
/// the failure class only.
struct FailedMessageSheet: View {
    let failure: LocalSendFailure
    let onTryAgain: () -> Void
    let onCancel: () -> Void

    var body: some View {
        // Scrolls when large Dynamic Type exceeds the sheet detent, so both
        // actions stay reachable at every supported detent.
        ScrollView {
            content
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var content: some View {
        VStack(spacing: CommonPlateStyle.Spacing.m) {
            Text(ConversationCopy.failedSheetTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(ConversationCopy.failureExplanation(failure))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if failure.isRetryable {
                Button(action: onTryAgain) {
                    Text(ConversationCopy.tryAgain).frame(maxWidth: .infinity)
                }
                .commonPlatePrimaryAction()
                .accessibilityIdentifier("chat.tryAgain")
            }
            Button(action: onCancel) {
                Text(ConversationCopy.cancel)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: ConversationLayout.minimumTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
                .accessibilityIdentifier("chat.cancelFailed")
        }
        .padding(CommonPlateStyle.Spacing.l)
        .frame(maxWidth: .infinity)
    }
}

/// Standalone entry rows for a later integration owner. Not placed anywhere;
/// each only invokes the host's closure and holds no conversation identity.
struct ConversationEntryRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: "bubble.left").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .frame(minHeight: ConversationLayout.minimumTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// PROVISIONAL titles; the final entry wording belongs to the integration pass.
struct ChatWithHelperRow: View {
    static let title = "Chat with helper"
    let action: () -> Void
    var body: some View { ConversationEntryRow(title: Self.title, action: action) }
}

struct ChatWithRequesterRow: View {
    static let title = "Chat with requester"
    let action: () -> Void
    var body: some View { ConversationEntryRow(title: Self.title, action: action) }
}
