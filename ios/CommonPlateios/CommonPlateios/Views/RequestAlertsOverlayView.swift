//
//  RequestAlertsOverlayView.swift
//  CommonPlateios
//
// W4-H2 Request Alerts quick entry (Section 12): a focused centered overlay
// presented directly over Home from Empty Exchange — never a navigation push
// through Settings, never a bottom sheet.
//
// H2 owns only this contextual entry, its centered presentation, the
// verified/unverified branching, navigation into verification, and
// continuation back to the attempted alert setup. It deliberately embeds the
// existing, already-accepted N1 runtime controls (`AlertSignupView`'s email
// flow and `PushNotificationSection`) rather than inventing new toggle-based
// Email/Push semantics: the real runtime for Email is a confirm-by-link
// signup flow and Push is a multi-state permission flow, neither of which is
// a simple on/off toggle a caller-relative "own request" style signal could
// safely fabricate. See docs/week-4-ios-testflight-spec.md W4-H2 Section 12
// ("H2 does NOT own... actual Email/Push subscription behavior").
import SwiftUI

struct RequestAlertsOverlayView: View {
    @ObservedObject var identityStore: ParticipantIdentityStore
    @ObservedObject var alertSubscriptionStore: AlertSubscriptionStore
    @ObservedObject var pushSubscriptionStore: PushSubscriptionStore
    @ObservedObject var unsubscribeStore: ParticipantEmailUnsubscribeStore
    let onDismiss: () -> Void

    /// Sticky once verification is ever seen true this presentation, matching
    /// `RequestFoodEntryView.hasEnteredForm`'s exact precedent: a later
    /// authority loss must not eject the student back to a verification
    /// gate they already passed for this same alert-setup attempt.
    @State private var hasEnteredChannelSetup = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()

            card
                .frame(maxWidth: 340)
                .background(
                    CommonPlateStyle.Color.baseCanvas,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
                .padding(CommonPlateStyle.Spacing.l)
        }
        .accessibilityIdentifier("request-alerts-overlay")
        .sheet(isPresented: isPresentingVerification) {
            ParticipantVerificationView(store: identityStore, cancel: cancelVerification)
        }
        .onAppear {
            guard !hasEnteredChannelSetup else { return }
            identityStore.beginVerificationIfNeeded()
        }
        .onChange(of: identityStore.isVerified, initial: true) { _, isVerified in
            hasEnteredChannelSetup = hasEnteredChannelSetup || isVerified
        }
    }

    @ViewBuilder
    private var card: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
            closeRow

            if hasEnteredChannelSetup || identityStore.isVerified {
                channelSetup
            } else {
                unverifiedNotice
            }
        }
        .padding(CommonPlateStyle.Spacing.l)
    }

    private var closeRow: some View {
        HStack {
            Text(Self.title)
                .font(.headline)
            Spacer()
            CommonPlateCloseControl(action: dismiss)
                .accessibilityIdentifier("request-alerts-overlay-close")
        }
    }

    /// Shown behind the verification sheet while it opens/is dismissed, so
    /// the overlay never renders a blank card. Cancelling from the sheet
    /// leaves this exact copy on screen for a moment before `onDismiss`
    /// closes the whole overlay.
    private var unverifiedNotice: some View {
        Text(Self.unverifiedNoticeText)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    /// The existing accepted N1 controls, embedded rather than reimplemented.
    /// `AlertSignupView` already renders the email form/accepted state and
    /// (via `PushNotificationSection`) the push control; this card adds only
    /// the H2 close affordance around it.
    ///
    /// Review triage (finding 7): `onDone` must be this overlay's own
    /// `dismiss()`, not left `nil`. This overlay is a plain `ZStack` layer
    /// (Section 12: "never a navigation push through Settings"), not a
    /// `.sheet`/`.navigationDestination` of its own, so `AlertSignupView`'s
    /// fallback `@Environment(\.dismiss)` would bubble to whatever ambient
    /// presentation actually owns this screen — Settings' own push, when
    /// reached from there — and pop that instead of closing only this card.
    private var channelSetup: some View {
        AlertSignupView(
            store: alertSubscriptionStore,
            pushStore: pushSubscriptionStore,
            unsubscribeStore: unsubscribeStore,
            identityStore: identityStore,
            onDone: dismiss
        )
    }

    private var isPresentingVerification: Binding<Bool> {
        Binding(
            get: {
                !hasEnteredChannelSetup
                    && !identityStore.isVerified
                    && identityStore.flow?.purpose == .firstVerification
            },
            set: { isPresented in
                if !isPresented { identityStore.cancelVerification() }
            }
        )
    }

    private func cancelVerification() {
        identityStore.cancelVerification()
        dismiss()
    }

    private func dismiss() {
        onDismiss()
    }

    static let title = "Request Alerts"
    static let unverifiedNoticeText =
        "Verify your NYU email to turn on Request Alerts."
}
