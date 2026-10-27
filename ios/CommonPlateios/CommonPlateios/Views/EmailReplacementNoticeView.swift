//
//  EmailReplacementNoticeView.swift
//  CommonPlateios
//
// W4-B1: the centered notice shown when Change Email is refused because the
// student still has unfinished requester or helper activity, or when that
// could not be checked. It follows the approved P2 account-deletion blocker
// layout (Figma 1151:7644 / 1151:7716 / 1151:7788): title, one explanation,
// a full-width primary action, a quiet dismiss, and the shared close control.
// Navigation only — nothing here withdraws, cancels, or stops anything.
import SwiftUI

struct EmailReplacementNoticeContent: Equatable {
    let title: String
    let message: String
    let primaryActionTitle: String
    /// True only for the failed eligibility read, where the primary action
    /// re-runs that read-only check instead of navigating.
    var isRetry = false
    var dismissTitle = EmailReplacementNoticeContent.dismissTitle

    static let dismissTitle = "Keep My Email"

    /// Sign Out reuses the same notice when it is not safe to sign out.
    static let signOutDismissTitle = "Stay Signed In"
    static let signOutHelping = EmailReplacementNoticeContent(
        title: "Currently helping",
        message: "Finish or release your reservation before signing out.",
        primaryActionTitle: "View Helping",
        dismissTitle: signOutDismissTitle
    )
    static let signOutRequestUnconfirmed = EmailReplacementNoticeContent(
        title: "Request still being confirmed",
        message: "Wait until your request is confirmed before signing out.",
        primaryActionTitle: "View Request",
        dismissTitle: signOutDismissTitle
    )
    static let signOutUnchecked = EmailReplacementNoticeContent(
        title: "Couldn’t check your activity",
        message: "We couldn’t check whether you can sign out. You’re still signed in.",
        primaryActionTitle: "Try Again",
        isRetry: true,
        dismissTitle: signOutDismissTitle
    )

    static func content(for block: EmailReplacementBlock) -> EmailReplacementNoticeContent {
        let blockers = block.blockers
        if blockers == [.ownRequestOpen] {
            return EmailReplacementNoticeContent(
                title: "Open request",
                message: "Finish or withdraw it before changing your email.",
                primaryActionTitle: "View Request"
            )
        }
        if blockers == [.helping] {
            return EmailReplacementNoticeContent(
                title: "Currently helping",
                message: "Finish or stop helping before changing your email.",
                primaryActionTitle: "View Helping"
            )
        }
        if blockers == [.ownRequestHelped] {
            return EmailReplacementNoticeContent(
                title: "Someone is helping with your request",
                message: "Wait until your request is finished before changing your email.",
                primaryActionTitle: "View Request"
            )
        }
        let hasRequester = blockers.contains(.ownRequestOpen) || blockers.contains(.ownRequestHelped)
        if hasRequester && blockers.contains(.helping) {
            return EmailReplacementNoticeContent(
                title: "Finish your requests and helping",
                message: "Finish your open requests and helping before changing your email.",
                primaryActionTitle: "View Activity"
            )
        }
        // A blocking condition this app cannot name: neutral, no category implied.
        return EmailReplacementNoticeContent(
            title: "Can’t change your email yet",
            message: "Something on your account is still unfinished. Your current email hasn’t changed.",
            primaryActionTitle: "View Activity"
        )
    }

    static let unavailable = EmailReplacementNoticeContent(
        title: "Couldn’t check your activity",
        message: "We couldn’t check whether you can change your email. Your current email hasn’t changed.",
        primaryActionTitle: "Try Again",
        isRetry: true
    )
}

struct EmailReplacementNoticeView: View {
    let content: EmailReplacementNoticeContent
    let onPrimary: () -> Void
    let onDismiss: () -> Void
    var identifier = "settings-email-replacement-notice"

    @State private var headerHeight: CGFloat = 0
    @State private var bodyHeight: CGFloat = 0
    /// Cap height of the `title2` heading at the current text size.
    @ScaledMetric(relativeTo: .title2) private var capHeight: CGFloat = 15.7

    var body: some View {
        GeometryReader { screen in
            ZStack {
                Color.black.opacity(0.34)
                    .accessibilityHidden(true)

                card(maxHeight: screen.size.height - 96)
                    .frame(width: 314)
                    .background(
                        CommonPlateStyle.Color.baseCanvas,
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: Color.black.opacity(0.12), radius: 18, y: 8)
                    .padding(.horizontal, CommonPlateStyle.Spacing.l)
                    .accessibilityIdentifier(identifier)
                    .accessibilityAddTraits(.isModal)
            }
            .frame(width: screen.size.width, height: screen.size.height)
        }
        .ignoresSafeArea()
    }

    /// The heading and close control form a fixed header that never scrolls or
    /// clips; only the explanation and actions scroll beneath it, and only
    /// when the card reaches the screen-based height cap (large Dynamic Type).
    private func card(maxHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            header
                .background(measure(NoticeHeaderHeightKey.self))
            ScrollView {
                bodyContent
                    .background(measure(NoticeContentHeightKey.self))
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.visible)
            .frame(height: bodyHeight > 0 ? min(bodyHeight, max(maxHeight - headerHeight, 120)) : nil)
        }
        .onPreferenceChange(NoticeHeaderHeightKey.self) { headerHeight = $0 }
        .onPreferenceChange(NoticeContentHeightKey.self) { bodyHeight = $0 }
    }

    private func measure<K: PreferenceKey>(_ key: K.Type) -> some View where K.Value == CGFloat {
        GeometryReader { proxy in
            Color.clear.preference(key: key, value: proxy.size.height)
        }
    }

    /// The close control's center sits on the center of the title's first line
    /// however many lines the title wraps to.
    private var header: some View {
        HStack(alignment: .noticeFirstLineCenter, spacing: CommonPlateStyle.Spacing.s) {
            Text(content.title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .alignmentGuide(.noticeFirstLineCenter) { $0[.firstTextBaseline] - capHeight / 2 }
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("settings-email-replacement-notice-title")

            CommonPlateScreenCloseControl(
                accessibilityLabel: "Close",
                accessibilityIdentifier: "settings-email-replacement-notice-close",
                action: onDismiss
            )
            .accessibilitySortPriority(1)
        }
        .padding(.horizontal, CommonPlateStyle.Spacing.l)
        .padding(.top, CommonPlateStyle.Spacing.l)
        .padding(.bottom, CommonPlateStyle.Spacing.m)
    }

    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
            Text(content.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(content.primaryActionTitle, action: onPrimary)
                .commonPlatePrimaryAction()
                .accessibilityIdentifier("settings-email-replacement-notice-primary")

            Button(content.dismissTitle, action: onDismiss)
                .commonPlateSecondaryAction()
                .accessibilityIdentifier("settings-email-replacement-notice-dismiss")
        }
        .padding(.horizontal, CommonPlateStyle.Spacing.l)
        .padding(.bottom, CommonPlateStyle.Spacing.l)
    }
}

private extension VerticalAlignment {
    private enum NoticeFirstLineCenter: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }
    static let noticeFirstLineCenter = VerticalAlignment(NoticeFirstLineCenter.self)
}

private struct NoticeHeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct NoticeContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Where the blocked-notice primary action goes. Navigation only. A specific
/// destination is chosen only when exactly one blocker kind is known and the
/// store already holds that exact request; anything ambiguous or not loaded
/// goes Home, where `Your Requests` and Helping both live. The destination
/// screen re-checks authorization itself, so nothing is exposed here.
enum EmailReplacementNavigation {
    static func path(
        for block: EmailReplacementBlock,
        activeClaim: ActiveClaimPresentation?,
        ownerRequests: [OwnerRequest]
    ) -> [AppRoute] {
        switch block.blockers {
        case [.helping]:
            if let activeClaim { return [.fulfillment(activeClaim.request)] }
        case [.ownRequestOpen], [.ownRequestHelped]:
            let helped = block.blockers == [.ownRequestHelped]
            let matches = ownerRequests.filter { ($0.phase == .reserved) == helped }
            if matches.count == 1, let only = matches.first { return [.ownerRequest(only)] }
        default:
            break
        }
        return []
    }
}
