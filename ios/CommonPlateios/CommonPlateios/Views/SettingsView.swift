//
//  SettingsView.swift
//  CommonPlateios
//
// W4-H2's one shared secondary utility route (Section 11), reached from
// Home's gear. Presentation architecture only: identity, Request Alerts, and
// About & Help behavior are all unchanged accepted runtime, relocated here
// from R1's Home-inline utility group rather than reimplemented.
import SwiftUI

struct SettingsView: View {
    @ObservedObject var requestStore: RequestStore
    @ObservedObject var participantIdentityStore: ParticipantIdentityStore
    @ObservedObject var pushSubscriptionStore: PushSubscriptionStore
    /// W4-S1's app-level AI Assistance Settings control. Off prevents any
    /// screenshot selection from starting a new transfer, and cancels/fences
    /// a pending one that has not yet actually begun transfer; it cannot
    /// recall bytes a transfer had already genuinely started sending, but
    /// generation/cancellation fencing guarantees that transfer's response
    /// is never applied. On only restores availability for a later
    /// selection — the separate first-use disclosure gate is unaffected by
    /// this toggle and still governs every actual transfer.
    @ObservedObject var screenshotProposalStore: ScreenshotProposalStore
    /// W4-B1: the blocked Change Email notice's primary action. Navigation
    /// only; the caller picks the destination.
    let onViewActivity: (EmailReplacementBlock) -> Void

    /// W3-I4: open only between tapping Remove Email and the mutation
    /// actually running. Cancel (or dismissing any other way) leaves
    /// `participantIdentityStore` untouched — the confirmation dialog itself
    /// has no side effect, only its destructive button does. Relocated
    /// verbatim from `ContentView`, which owned this identically before H2.
    @State private var isPresentingRemoveEmailConfirmation = false

    /// The popup shown when Sign Out is tapped while it is not safe. Sign Out
    /// itself stays fail closed: the confirmation opens only when every
    /// existing readiness/authority check passes.
    @State private var signOutNotice: EmailReplacementNoticeContent?

    /// Only the existing identity-verification sheet, never an alerts-management popup.
    @State private var isPresentingRequestAlerts = false


    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xl) {
                    identitySection
                    requestAlertsSection
                    aboutAndHelpSection
                    foodResourcesSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, CommonPlateStyle.Metrics.settingsPageInset)
                .padding(.vertical, CommonPlateStyle.Spacing.l)
            }
            .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: participantIdentityStore.identity) { _, _ in
                if participantIdentityStore.isVerified { isPresentingRequestAlerts = false }
                Task { await pushSubscriptionStore.refreshAuthorizationStatus() }
            }


            if let notice = emailReplacementNoticeContent {
                EmailReplacementNoticeView(
                    content: notice,
                    onPrimary: {
                        if notice.isRetry {
                            // Closes the notice, then runs a fresh read-only
                            // eligibility check; it never touches the identity
                            // or any request. One press per notice, like Sign Out.
                            participantIdentityStore.dismissReplacementNotice()
                            Task { await participantIdentityStore.startEmailReplacement() }
                            return
                        }
                        let block = participantIdentityStore.replacementBlock
                        participantIdentityStore.dismissReplacementNotice()
                        if let block { onViewActivity(block) }
                    },
                    onDismiss: { participantIdentityStore.dismissReplacementNotice() }
                )
                .zIndex(3)
            }

            if let notice = signOutNotice {
                EmailReplacementNoticeView(
                    content: notice,
                    onPrimary: {
                        if notice.isRetry {
                            signOutNotice = nil
                            Task { _ = try? await requestStore.continueActiveReservationIfNeeded() }
                            return
                        }
                        signOutNotice = nil
                        onViewActivity(
                            EmailReplacementBlock(
                                blockers: notice == .signOutHelping ? [.helping] : [.ownRequestOpen]
                            )
                        )
                    },
                    onDismiss: { signOutNotice = nil },
                    identifier: "settings-sign-out-notice"
                )
                .zIndex(3)
            }

        }
        .animation(.easeInOut(duration: 0.18), value: isPresentingRequestAlerts)
        .sheet(isPresented: $isPresentingRequestAlerts) {
            ParticipantVerificationView(store: participantIdentityStore) {
                participantIdentityStore.cancelVerification()
                isPresentingRequestAlerts = false
            }
        }
    }

    // MARK: - Identity

    @ViewBuilder
    private var identitySection: some View {
        if let identity = participantIdentityStore.identity {
            VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
                sectionHeading("IDENTITY")

                // Figma's approved compact identity treatment sits flat on
                // the page, not inside a grouped warm-surface card — see
                // the warm-surface token's own documented intent in
                // CommonPlateStyle.swift ("native identity/settings
                // sections intentionally do not use this treatment").
                VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
                    verifiedIdentityRow(masked: identity.masked)
                        .padding(.horizontal, CommonPlateStyle.Metrics.settingsRowInset)
                        .padding(.bottom, CommonPlateStyle.Spacing.xs)

                    // Full card width: the outer edges align with the Request
                    // Alerts and About & Help card boundaries.
                    ViewThatFits(in: .horizontal) {
                        identityActions(axis: .horizontal)
                        identityActions(axis: .vertical)
                    }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Faith-selected V1 identity row: the masked address with a small
    /// campus-purple check at the far trailing edge, shown only for an
    /// authoritatively verified identity. The check is decorative; VoiceOver
    /// reads one element carrying the verification meaning.
    private func verifiedIdentityRow(masked: String) -> some View {
        let isVerified = participantIdentityStore.isVerified
        return HStack {
            Text(masked)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: CommonPlateStyle.Spacing.s)
            if isVerified {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(CommonPlateStyle.Color.campusQualifierCampus)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isVerified ? "\(Self.verifiedNYUEmailLabel), \(masked)" : masked)
        .accessibilityIdentifier("settings-verified-identity")
    }

    @ViewBuilder
    private func identityActions(axis: Axis) -> some View {
        if axis == .horizontal {
            HStack(spacing: CommonPlateStyle.Spacing.m) {
                signOutButton.frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: CommonPlateStyle.Spacing.s) {
                signOutButton.frame(maxWidth: .infinity)
            }
        }
    }

    private var emailReplacementNoticeContent: EmailReplacementNoticeContent? {
        if let block = participantIdentityStore.replacementBlock {
            return EmailReplacementNoticeContent.content(for: block)
        }
        return participantIdentityStore.replacementCheckFailed
            ? EmailReplacementNoticeContent.unavailable
            : nil
    }

    private var signOutButton: some View {
        Button(Self.signOutTitle) {
            if let notice = signOutBlockedNotice {
                signOutNotice = notice
            } else {
                isPresentingRemoveEmailConfirmation = true
            }
        }
        .commonPlateDestructiveAction()
        // Attached here so the system dialog anchors to the Sign Out button
        // rather than the whole screen. W3-I4: Cancel is the dialog's implicit
        // dismissal path too; only the destructive button has any effect on
        // `participantIdentityStore`.
        .confirmationDialog(
            Self.signOutConfirmationTitle,
            isPresented: $isPresentingRemoveEmailConfirmation,
            titleVisibility: .visible
        ) {
            Button(Self.signOutTitle, role: .destructive) {
                Task {
                    await participantIdentityStore.removeIdentity(ifSafe: { !isRemoveEmailBlocked })
                    if participantIdentityStore.removalFailed { signOutNotice = .signOutUnchecked }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.signOutConfirmationMessage)
        }
        .accessibilityHint(Self.signOutAccessibilityHint)
        .accessibilityIdentifier("settings-sign-out")
        .disabled(participantIdentityStore.isRemovingIdentity)
    }

    static let verifiedNYUEmailLabel = "Verified NYU email"
    /// The visible label for the existing local identity-clearing action
    /// (formerly "Remove Email"). It signs this installation out only: no
    /// server account, request, or history is deleted.
    static let signOutTitle = "Sign Out"
    static let signOutConfirmationTitle = "Sign out of \(AppBrand.name)?"
    static let signOutConfirmationMessage =
        "You’ll need to verify an NYU email again to post or help. Your requests and help history aren’t deleted."
    static let signOutAccessibilityHint =
        "Signs out on this device. You’ll need to verify an NYU email again."

    /// Identical precedence to `ContentView`'s pre-H2 implementation (W3-I4):
    /// the cold/relaunch readiness check first, then an active
    /// reservation/in-progress request, then an unresolved create.
    private var isRemoveEmailBlocked: Bool {
        !requestStore.hasEstablishedRemovalSafety
            || requestStore.activeClaim != nil
            || requestStore.hasUnresolvedCreateAmbiguity
            // W4-D2 FIX (2026-09-18, independent-review MUST FIX): an issued
            // create's outcome may still be unknown while `isCreating` is
            // true — its operation is intentionally excluded from
            // `hasUnresolvedCreateAmbiguity`'s projection until the create
            // call itself resolves. Remove Email must stay fail-closed for
            // that window too, not only once ambiguity is armed.
            || requestStore.isCreating
            // Fail closed: with no credential the removal-safety read cannot
            // have asked the backend anything, so it proves nothing.
            || participantIdentityStore.currentAuthority() == nil
    }

    /// `nil` only when every existing safety/authority check passes. Anything
    /// else (including an unproven or unavailable check) maps to a notice, so
    /// an unavailable check can never authorize Sign Out.
    private var signOutBlockedNotice: EmailReplacementNoticeContent? {
        guard isRemoveEmailBlocked else { return nil }
        if !requestStore.hasEstablishedRemovalSafety
            || participantIdentityStore.currentAuthority() == nil {
            return .signOutUnchecked
        }
        if requestStore.activeClaim != nil { return .signOutHelping }
        return .signOutRequestUnconfirmed
    }

    // MARK: - Request Alerts

    private var requestAlertsSection: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
            sectionHeading("REQUEST ALERTS")

            if participantIdentityStore.isVerified {
                PushNotificationSection(store: pushSubscriptionStore)
                .padding(.horizontal, CommonPlateStyle.Metrics.settingsRowInset)
                .padding(.vertical, CommonPlateStyle.Spacing.s)
                .background(
                    CommonPlateStyle.Color.requestCardSurface,
                    in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                )
            } else {
                requestAlertsVerificationPrompt
            }
        }
    }

    private var requestAlertsVerificationPrompt: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.s) {
            Text(Self.requestAlertsVerificationPromptText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                participantIdentityStore.beginVerificationIfNeeded()
                isPresentingRequestAlerts = true
            } label: {
                Text(Self.verifyNYUEmailActionTitle)
            }
            .commonPlateSecondaryAction()
            .accessibilityIdentifier("settings-request-alerts-verify-action")
        }
        .padding(.horizontal, CommonPlateStyle.Metrics.settingsRowInset)
    }

    static let requestAlertsVerificationPromptText = "Required to manage request alerts."
    static let verifyNYUEmailActionTitle = "Verify NYU email"

    /// Faith's resolution for W4-N0 Unknown Email truth (final H2 visual
    /// alignment FIX, item 1): a disabled — never interactive — Off-looking
    /// toggle is not itself enough, because a viewer cannot distinguish "not
    /// yet established" from a truth claim of confirmed Off. This inline
    /// status, shown only while `emailAlertStateStore.state == .unknown`,
    /// makes that distinction explicit without inventing a third toggle
    /// visual state — the toggle itself stays the same approved binary
    /// Off/On glyph, just disabled. Copy distinguishes *why* truth is
    /// unavailable: a read still in flight reads as "Checking…", while a
    /// failed/unresolved read (including an unusable credential) reads as
    /// "unavailable" — reusing `CommonPlateStatusKind.loading`/`.uncertain`,
    /// the same accepted status vocabulary `removeEmailBlockedStatusKind`
    /// already uses elsewhere in this screen. Once N0 establishes `.active`
    /// or `.inactive`, this disappears and the toggle becomes the ordinary
    /// interactive On/Off control.
    /// Extracted as a pure, directly testable mapping — see
    /// `SettingsRequestAlertsToggleTests`.
    static func emailUnknownStatusMessage(state: EmailAlertState, isRefreshing: Bool) -> String? {
        guard state == .unknown else { return nil }
        return isRefreshing ? Self.emailAlertsCheckingStatus : Self.emailAlertsUnavailableStatus
    }

    /// Extracted as a pure, directly testable mapping — see
    /// `SettingsRequestAlertsToggleTests`.
    static func isEmailToggleInteractive(_ state: EmailAlertState) -> Bool {
        state != .unknown
    }

    static let emailAlertsCheckingStatus = "Checking your email alert status…"
    static let emailAlertsUnavailableStatus = "Email alert status unavailable."

    private func requestAlertsToggleRow(
        title: String,
        isOn: Binding<Bool>,
        isEnabled: Bool,
        accessibilityIdentifier: String
    ) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .tint(Color.accentColor)
                .disabled(!isEnabled)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
        .frame(minHeight: CommonPlateStyle.Control.minimumHeight)
        .padding(.horizontal, CommonPlateStyle.Metrics.settingsRowInset)
    }

    /// Approved Figma `Control / Toggle` behavior, exactly: "Binary
    /// CommonPlate settings toggle. Visual states are Off and On
    /// only—there is intentionally no pending/halfway toggle state. Email
    /// Off→On may open a setup/confirmation flow, but the toggle remains
    /// visually Off until the existing Email subscription truth confirms it
    /// is actually enabled." The read side therefore consumes only the W4-N0
    /// authoritative `.active` truth — never `alertSubscriptionStore.phase`,
    /// Check Email presentation history, or a remembered signup submission —
    /// so `.unknown` (not yet read, unreadable, or a superseded identity) and
    /// `.inactive` both render identically Off, and never fabricate On.
    ///
    /// Turning the toggle On does not itself assert Email On: it opens the
    /// focused Request Alerts presentation, which owns the real signup/
    /// confirmation lifecycle unchanged. The toggle only reads On again once
    /// a later `emailAlertStateStore.refresh()` (this screen's own `.task`,
    /// or the overlay's own lifecycle) observes confirmed truth.
    ///
    /// Turning the toggle Off runs the existing accepted participant-
    /// authorized unsubscribe mutation (W3-N2) — the same action the
    /// focused overlay's "Turn off email alerts" button already performs —
    /// then reconciles N0 truth with a fresh `refresh()` so the toggle
    /// reflects the newly confirmed Off state rather than assuming it.
    /// Extracted as a pure, directly testable mapping — see
    /// `SettingsViewToggleSourceTests` — rather than only asserting on the
    /// view body.
    static func isEmailToggleOn(_ state: EmailAlertState) -> Bool {
        state == .active
    }

    /// Extracted as a pure, directly testable mapping — see
    /// `SettingsViewToggleSourceTests`.
    static func isPushToggleOn(_ state: PushPreferenceState) -> Bool {
        state == .on
    }

    /// Reads only the existing accepted authoritative Push truth
    /// (`PushSubscriptionStore.state == .on`); every other state
    /// (`.off`, `.settingUp`, `.denied`, `.failed`, `.ambiguous`) renders
    /// Off, matching the approved toggle's "Push appearance must likewise
    /// reflect the existing authoritative Push state rather than a local
    /// visual boolean." Turning the toggle On opens the same focused Request
    /// Alerts presentation, which already embeds the existing accepted Push
    /// explanation/permission/recovery flow (`PushNotificationSection`) —
    /// this row invents no separate setup path. Turning it Off from a
    /// confirmed On runs the existing accepted `disable()` mutation exactly
    /// as the overlay's own "Turn off" control already does.
    // MARK: - About & Help

    /// The approved Figma's About & Help rows sit almost flush with the
    /// page — a near-canvas background separated only by hairline dividers
    /// — not a strongly tinted grouped card. `baseCanvas` (already the
    /// page's own background token) reads as that same quiet, neutral
    /// treatment without introducing a new color; the divider reuses
    /// `requestCardBorder`, which already matches the approved Figma's
    /// divider tone exactly.
    private var aboutAndHelpSection: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
            sectionHeading("ABOUT & HELP")

            VStack(spacing: 0) {
                NavigationLink(value: AppRoute.howCommonPlateWorks) {
                    SettingsRow(title: "How \(AppBrand.name) Works")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-how-commonplate-works")

                aboutAndHelpDivider

                NavigationLink(value: AppRoute.privacySafety) {
                    SettingsRow(title: "Privacy & Safety")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-privacy-safety")

                aboutAndHelpDivider

                NavigationLink(value: AppRoute.support) {
                    SettingsRow(title: "Support")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-support")
            }
            .background(
                CommonPlateStyle.Color.settingsGroupSurface,
                in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
            )
        }
    }

    // MARK: - Food Resources

    /// R5's established inline resource links, shown directly in Settings.
    /// The first two destinations are the existing Support/Privacy ones.
    static let foodResources: [(title: String, url: URL)] = [
        ("NYU Food Accessibility Assistance",
         URL(string: "https://www.nyu.edu/students/student-information-and-resources/courtesy-meals.html")!),
        ("NYU Nutritional Support Initiatives",
         URL(string: "https://www.nyu.edu/students/student-information-and-resources/housing-and-dining/dining/nutritional-support-initiatives.html")!),
        ("Food Help NYC", URL(string: "https://finder.nyc.gov/foodhelp/")!),
    ]

    private var foodResourcesSection: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
            sectionHeading("FOOD RESOURCES")

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.foodResources, id: \.title) { resource in
                    Link(destination: resource.url) {
                        HStack {
                            Text(resource.title)
                                .font(.subheadline.weight(.semibold))
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: CommonPlateStyle.Spacing.s)
                            Image(systemName: "arrow.up.right")
                                .font(.footnote.weight(.semibold))
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(CommonPlateStyle.Color.brandText)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .accessibilityHint("Opens in your browser")
                }
            }
            .padding(.horizontal, CommonPlateStyle.Metrics.settingsRowInset)
        }
    }

    private var aboutAndHelpDivider: some View {
        Rectangle()
            .fill(CommonPlateStyle.Color.settingsGroupDivider)
            .frame(height: 1)
            .padding(.horizontal, CommonPlateStyle.Metrics.settingsRowInset)
    }

    private func sectionHeading(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    /// The approved Figma's About & Help rows carry no subtitle; `subtitle`
    /// stays optional so Request Alerts (which does) and About & Help (which
    /// no longer does) share one row component.
    private struct SettingsRow: View {
        let title: String
        var subtitle: String?

        var body: some View {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: CommonPlateStyle.Spacing.s)
                CommonPlateDisclosureIndicator()
            }
            .frame(minHeight: CommonPlateStyle.Control.minimumHeight)
            .padding(.horizontal, CommonPlateStyle.Metrics.settingsRowInset)
            .padding(.vertical, CommonPlateStyle.Spacing.xs)
            .contentShape(Rectangle())
        }
    }
}
