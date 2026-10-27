//
//  AlertSignupView.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
// The email half of "Notify me". This screen is email-only on purpose: it
// shows no channel picker, no disabled control, and no "coming soon" row,
// because a control that cannot be used is not information. The Home entry
// above it stays broad, so another channel can be added behind it later
// without moving or renaming anything the person already knows.
import SwiftUI

struct AlertSignupView: View {
    // MARK: - Copy

    static let title = "Get email alerts"
    static let explanation =
        "Enter your NYU email to receive alerts when new meal requests are posted. You’ll need to confirm your email before alerts begin."
    static let fieldLabel = "NYU email address"
    static let continueButtonTitle = "Continue"
    static let submittingLabel = "Sending…"

    /// The accepted-state copy. Every sentence here is true of all four
    /// subscriber states the identical 202 covers — new, pending, confirmed,
    /// and unsubscribed — because the response cannot distinguish them and the
    /// app must not pretend otherwise. Nothing here claims that a subscription
    /// exists, that alerts are on, or that an email was sent.
    static let checkEmailTitle = "Check your email"
    static let checkEmailBody =
        "Check your NYU email for a message from CommonPlate. Follow the confirmation step if one is needed. If you already confirmed this address, there may be nothing else to do."
    static let useDifferentEmailTitle = "Use a different email"
    static let doneTitle = "Done"

    static func message(for failure: AlertSignupFailure) -> String {
        switch failure {
        case .paused:
            // Deliberately says nothing about the address: it was never the
            // problem, and blaming it would send someone off to retype a
            // perfectly good email.
            return "Email alerts aren’t open for signup right now. Try again later."
        case .rateLimited:
            return "Too many attempts from this device. Wait a minute, then try again."
        case .ambiguousOutcome:
            return "We couldn’t confirm whether your signup was received. Check your email before trying again."
        case .unknown:
            return "Something went wrong. Try again in a moment."
        }
    }

    /// Continue stays available for any non-empty entry so a rejected address
    /// can say why beside its own field. Local validation still decides whether
    /// anything is actually sent, so an unusable address never becomes a
    /// request.
    static func isSubmissionEnabled(email: String, phase: AlertSignupPhase) -> Bool {
        phase == .editing && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static let turnOffEmailAlertsButtonTitle = "Turn off email alerts"
    static let emailAlertsOffTitle = "Email alerts are off"
    static let emailAlertsOffBody =
        "You won’t receive CommonPlate alert or digest emails unless you sign up and confirm again."

    static func unsubscribeMessage(for failure: ParticipantEmailUnsubscribeFailure) -> String {
        switch failure {
        case .verificationRequired, .authorityInvalid:
            return "Verify your NYU email to turn off email alerts from here."
        case .paused:
            return "This isn’t available right now. Try again later."
        case .rateLimited:
            return "Too many attempts from this device. Wait a minute, then try again."
        case .unavailable:
            return "We couldn’t reach the server just now. Try again in a moment."
        }
    }

    // MARK: - View

    @ObservedObject var store: AlertSubscriptionStore
    /// Push keeps its own state owner and its own small section below the
    /// email form (Week 3 Day 6 Slice 6A.2). It shares no state with `store`:
    /// email and push are independent controls.
    @ObservedObject var pushStore: PushSubscriptionStore
    /// The participant-authorized "Turn off email alerts" action (W3-N2).
    /// Its own state owner, sharing nothing with `store`: signup presentation
    /// history establishes no Subscriber truth, and this action's Off result
    /// establishes no future On.
    @ObservedObject var unsubscribeStore: ParticipantEmailUnsubscribeStore
    /// Read only for its current authority credential at the moment of the
    /// tap — this view holds no identity state of its own.
    @ObservedObject var identityStore: ParticipantIdentityStore
    /// Overrides the accepted-state `Done` action. Defaults to `nil`, which
    /// falls back to `dismiss()` — the existing behavior for both of this
    /// view's current presentations (the `.alerts` push destination and the
    /// Home/Settings Request Alerts overlay).
    var onDone: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isEmailFocused: Bool

    /// The field reads and writes the store's address. Keeping a second copy in
    /// `@State` would let the screen and its one state owner disagree about
    /// what is being submitted.
    private var emailBinding: Binding<String> {
        Binding(
            get: { store.email },
            set: { store.updateEmail($0) }
        )
    }

    var body: some View {
        PushNotificationSection(store: pushStore)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Self.title)
                .font(.title2)
                .fontWeight(.semibold)

            Text(Self.explanation)
                .foregroundStyle(.secondary)

            expandedEntry
        }
    }

    private var expandedEntry: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.fieldLabel)
                    .font(.subheadline)
                    .fontWeight(.medium)

                TextField("name@nyu.edu", text: emailBinding)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(store.isSubmitting)
                    .focused($isEmailFocused)

                if store.fieldError == .invalidNYUEmail {
                    Text(AlertSignupEmailValidator.invalidEmailMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if let failure = store.failure {
                Text(Self.message(for: failure))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            Button {
                isEmailFocused = false
                Task { await store.submit(email: store.email) }
            } label: {
                if store.isSubmitting {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(Self.submittingLabel)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text(Self.continueButtonTitle)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!Self.isSubmissionEnabled(email: store.email, phase: store.phase))
        }
    }

    /// The approved Figma's Check Email step replaces a plain emoji envelope
    /// with a simple purple outlined envelope — the app's native `envelope`
    /// glyph reads as that same quiet outlined line-art `CommonPlateStyle`
    /// already uses for every other icon (`gearshape`, `checkmark.circle.fill`,
    /// `xmark`), so no new asset is needed. Shown only for the Check Email
    /// step, not the Email Alerts Off step, matching the approved design.
    private var checkEmailIcon: some View {
        Image(systemName: "envelope")
            .font(.system(size: 26, weight: .regular))
            .foregroundStyle(CommonPlateStyle.Color.brandText)
            .accessibilityHidden(true)
    }

    private var acceptedState: some View {
        VStack(alignment: .leading, spacing: 16) {
            if unsubscribeStore.emailAlertsOff {
                Text(Self.emailAlertsOffTitle)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(Self.emailAlertsOffBody)
                    .foregroundStyle(.secondary)
            } else {
                checkEmailIcon

                Text(Self.checkEmailTitle)
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(Self.checkEmailBody)
                    .foregroundStyle(.secondary)

                if let failure = unsubscribeStore.failure {
                    Text(Self.unsubscribeMessage(for: failure))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button(Self.turnOffEmailAlertsButtonTitle) {
                    Task {
                        await unsubscribeStore.turnOffEmailAlerts(
                            authority: identityStore.currentAuthority()
                        )
                    }
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .disabled(unsubscribeStore.isUnsubscribing)
            }

            Button(Self.useDifferentEmailTitle) {
                store.useDifferentEmail()
                // The screen is moving on to a different signup: a stale
                // in-session Off (or failure message) from the address just
                // left behind must not be shown for whatever comes next.
                unsubscribeStore.reset()
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)

            Button(Self.doneTitle) {
                if let onDone {
                    onDone()
                } else {
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
    }
}
