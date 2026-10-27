//
//  ParticipantVerificationView.swift
//  CommonPlateios
//
// The one screen that establishes participant identity (W3-I1). It owns the
// address and code the student is typing and nothing else: the flow itself,
// the credential, and every decision about what is verified belong to
// `ParticipantIdentityStore`, and the backend remains authoritative over both.
import SwiftUI

struct ParticipantVerificationView: View {
    @ObservedObject var store: ParticipantIdentityStore
    private let cancel: () -> Void
    /// The root gate (W4-B1) has nowhere to cancel to: verification is the
    /// entry itself, so it offers no dismissal control.
    private let isRootGate: Bool
    private let supportContact: SupportContact

    init(
        store: ParticipantIdentityStore,
        isRootGate: Bool = false,
        supportContact: SupportContact = SupportContact(),
        cancel: (() -> Void)? = nil
    ) {
        self.store = store
        self.isRootGate = isRootGate
        self.supportContact = supportContact
        self.cancel = cancel ?? store.cancelVerification
    }

    /// Local input only. Deliberately not seeded from a remembered identity,
    /// even during Change Email: prefilling the address being replaced would
    /// invite verifying the one already held.
    @State private var email = ""
    @State private var code = ""
    /// Set only by the explicit "Not at NYU?" path. Typed ineligible addresses
    /// remain on this editable form and receive inline validation instead.
    @State private var unsupportedAddress: String?
    @State private var localEmailError: String?
    @State private var wantsEmailFocus = false
    @State private var lastCodeActionWasResend = false
    @FocusState private var focusedField: Field?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private enum Field: Hashable {
        case email
        case code
    }

    static let title = "Verify your NYU email"
    static let replacementTitle = "Change your NYU email"

    static let brandContext = AppBrand.nameWithCampus
    static let emailPlaceholder = "you@nyu.edu"
    static let emailFieldLabel = "NYU email address"
    static let continueTitle = "Continue"
    static let useDifferentEmailTitle = "Use a different email"
    static let notAtNYUTitle = "Not at NYU?"

    static func codeSentNotice(email: String) -> String {
        "Code sent to \(email)."
    }

    private var isEnteringCode: Bool {
        if case .awaitingCode? = store.flow?.stage { return true }
        return false
    }

    var body: some View {
        if unsupportedAddress != nil {
            UnsupportedSchoolView(
                contact: supportContact,
                onHaveNYUEmail: returnToEmailEntry
            )
        } else {
            verificationEntry
        }
    }

    /// "I have an NYU email": back to the entry that opened this screen, with
    /// no draft or validation left over. Verifies nothing and opens no Home.
    private func returnToEmailEntry() {
        unsupportedAddress = nil
        email = ""
        localEmailError = nil
        wantsEmailFocus = true
    }

    /// The root gate already lives inside ContentView's NavigationStack(path:).
    /// A nested NavigationStack there crashes SwiftUI
    /// (AnyNavigationPath.Error.comparisonTypeMismatch) when the root swaps
    /// between Home and the gate while the outer path is non-empty, so only
    /// sheet presentations get their own stack.
    @ViewBuilder
    private var verificationEntry: some View {
        if isRootGate {
            verificationContent
        } else {
            NavigationStack {
                verificationContent
            }
        }
    }

    private var verificationContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xl) {
                if !isRootGate {
                    closeButton
                }

                verificationBrandHeader

                switch store.flow?.stage {
                case .enteringEmail, .none:
                    emailSection
                case .awaitingCode(let address, _, let resendAvailableAt):
                    codeSection(address: address, resendAvailableAt: resendAvailableAt)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CommonPlateStyle.Spacing.l)
            .padding(.vertical, CommonPlateStyle.Spacing.xl)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: store.verificationError) { _, error in
            guard let error else { return }
            AccessibilityNotification.Announcement(error.message).post()
        }
        .onAppear {
            if let target = store.replacementRecoveryEmail { email = target }
        }
        .task(id: wantsEmailFocus) {
            guard wantsEmailFocus else { return }
            wantsEmailFocus = false
            await Task.yield()
            focusedField = .email
        }
        .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
        .toolbar(isRootGate ? .automatic : .hidden, for: .navigationBar)
    }

    /// Placed first in the scroll content (rather than in a toolbar) so
    /// VoiceOver reads the dismissal before the form, matching its visual
    /// position. The fixed circle owns the symbol geometry, so Dynamic Type
    /// cannot enlarge this quiet dismissal control while nearby text remains
    /// accessible.
    private var closeButton: some View {
        CommonPlateScreenCloseControl(
            accessibilityLabel: "Close email verification",
            accessibilityIdentifier: "participant-verification-cancel",
            action: cancel
        )
    }

    /// Verification is an approved, rare trust/entry moment for CommonPlate
    /// character. The brand/display type remains here; fields, controls, and
    /// explanatory copy below deliberately remain system typography.
    private var verificationBrandHeader: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
            (Text(AppBrand.name).foregroundStyle(.primary)
                + Text(" at \(AppBrand.campus)").foregroundStyle(CommonPlateStyle.Color.campusQualifierCampus))
                .font(.subheadline.weight(.medium))

            Text(
                store.flow?.purpose == .emailReplacement
                    ? Self.replacementTitle
                    : Self.title
            )
            .font(.commonPlateBrandDisplay(.title2, dynamicTypeSize: dynamicTypeSize))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)

            if store.flow?.purpose == .emailReplacement,
               let currentEmail = store.identity?.principal {
                Text("Current email: \(currentEmail)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Your current email stays active until the change completes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("participant-verification-brand-header")
    }

    @ViewBuilder
    private var emailSection: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
            Text(Self.codeLifetimeNotice)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("participant-verification-code-lifetime")

            if store.flow?.purpose == .emailReplacement {
                Text("New NYU email address")
                    .font(.subheadline.weight(.medium))
            }

            TextField(Self.emailPlaceholder, text: $email)
                .padding(.horizontal, CommonPlateStyle.Spacing.m)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                        .fill(CommonPlateStyle.Color.requestCardSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                        .strokeBorder(CommonPlateStyle.Color.secondaryActionBorder, lineWidth: 1)
                )
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .email)
                .onChange(of: email) { _, _ in localEmailError = nil }
                .accessibilityLabel(Self.emailFieldLabel)
                .accessibilityIdentifier("participant-verification-email")

            if let localEmailError {
                CommonPlateInlineStatus(kind: .error, message: localEmailError)
                    .accessibilityIdentifier("participant-verification-email-validation-error")
            } else {
                verificationError(isFieldError: true)
            }
            verificationError(isFieldError: false)

            Button {
                continueTapped()
            } label: {
                if store.isRequestingCode {
                    HStack {
                        Spacer()
                        ProgressView()
                        Text("Sending…")
                        Spacer()
                    }
                } else {
                    Text(Self.continueTitle)
                        .frame(maxWidth: .infinity)
                }
            }
            // Bordered-prominent + large control (W3-I3 physical-device
            // correction), now the shared primary-action convention (W4-F1):
            // the plain in-row button style this shared with every other row
            // read as one more line of text, not the screen's actual primary
            // action. Full-width for the same reason "Send code" needed a
            // stronger visual claim than its own label width gave it.
            .commonPlatePrimaryAction()
            .disabled(!Self.canSendCode(email: email, isRequesting: store.isRequestingCode))
            .accessibilityIdentifier("participant-verification-send")

            if isRootGate, store.flow?.purpose != .emailReplacement {
                Button(Self.notAtNYUTitle) { openUnsupportedWithoutEmail() }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                    .underline()
                    .foregroundStyle(CommonPlateStyle.Color.brandText)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("participant-verification-not-at-nyu")
            }
        }
    }

    private func codeSection(address: String, resendAvailableAt: Date) -> some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
            Text(Self.codeSentNotice(email: address))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("participant-code-sent-notice")

            TextField("6-digit code", text: $code)
                .padding(.horizontal, CommonPlateStyle.Spacing.m)
                .padding(.vertical, 12)
                .background(
                    CommonPlateStyle.Color.requestCardSurface,
                    in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                        .strokeBorder(
                            codeFieldError != nil
                                ? CommonPlateStyle.Color.destructiveBorder
                                : CommonPlateStyle.Color.secondaryActionBorder,
                            lineWidth: 1
                        )
                )
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .code)
                .accessibilityLabel("6-digit verification code")
                .accessibilityHint(codeFieldError?.message ?? "")
                .accessibilityIdentifier("participant-verification-code")

            if !lastCodeActionWasResend, let error = store.verificationError {
                codeErrorMessage(error)
                    .accessibilityIdentifier("participant-verification-error")
            }

            Button {
                lastCodeActionWasResend = false
                let submitted = code
                Task {
                    let verified = await store.submitCode(submitted)
                    if verified { code = "" }
                }
            } label: {
                if store.isSubmittingCode {
                    HStack {
                        Spacer()
                        ProgressView()
                        Text("Verifying…")
                        Spacer()
                    }
                } else {
                    Text("Verify")
                        .frame(maxWidth: .infinity)
                }
            }
            .commonPlatePrimaryAction()
            .disabled(
                !Self.canSubmitCode(
                    code: code,
                    isSubmitting: store.isSubmittingCode,
                    isRequesting: store.isRequestingCode
                )
            )
            .accessibilityIdentifier("participant-verification-submit")

            // Verify stays the only filled action. Send a new code is its
            // outlined secondary partner, and Use a different email is a quiet
            // text link set apart below so it never competes with resend.
            VStack(alignment: .center, spacing: CommonPlateStyle.Spacing.s) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Button(
                        Self.resendTitle(availableAt: resendAvailableAt, now: context.date)
                    ) {
                        lastCodeActionWasResend = true
                        Task { await store.resendCode() }
                    }
                    .commonPlateSecondaryAction()
                    .disabled(
                        !Self.canResend(
                            availableAt: resendAvailableAt,
                            now: context.date,
                            isRequesting: store.isRequestingCode,
                            isSubmitting: store.isSubmittingCode
                        )
                    )
                    .accessibilityIdentifier("participant-verification-resend")
                }

                if lastCodeActionWasResend, let error = store.verificationError {
                    codeErrorMessage(error)
                        .accessibilityIdentifier("participant-verification-resend-error")
                }

                Button(Self.useDifferentEmailTitle) {
                    code = ""
                    lastCodeActionWasResend = false
                    store.returnToEmailEntry()
                    wantsEmailFocus = true
                }
                .buttonStyle(CommonPlateFlatActionButtonStyle())
                .foregroundStyle(.secondary)
                .font(.footnote.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.top, CommonPlateStyle.Spacing.xs)
                .disabled(store.isRequestingCode || store.isSubmittingCode)
                .accessibilityIdentifier("participant-verification-change-email")
            }
        }
    }

    private var codeFieldError: ParticipantVerificationPresentationError? {
        guard !lastCodeActionWasResend, let error = store.verificationError,
              Self.isFieldError(error) else { return nil }
        return error
    }

    private func codeErrorMessage(_ error: ParticipantVerificationPresentationError) -> some View {
        Text(error.message)
            .font(.footnote)
            .foregroundStyle(CommonPlateStyle.Color.destructiveText)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func isFieldError(_ error: ParticipantVerificationPresentationError) -> Bool {
        switch error {
        case .ineligibleEmail, .codeIncorrect, .codeExpired, .codeNotRequested, .attemptsExceeded:
            return true
        case .resendTooSoon, .temporarilyUnavailable, .replacementBlocked:
            return false
        }
    }

    @ViewBuilder
    private func verificationError(isFieldError: Bool) -> some View {
        if let error = store.verificationError,
           Self.isFieldError(error) == isFieldError {
            CommonPlateInlineStatus(kind: .error, message: error.message)
                .accessibilityIdentifier("participant-verification-error")
        }
    }

    static let codeLifetimeNotice = "Codes expire after 10 minutes."

    /// Whether Continue is actionable: something is typed and no request is in
    /// flight. Shape and school are classified when it is pressed so invalid
    /// input can receive visible inline feedback without sending a request.
    static func canSendCode(email: String, isRequesting: Bool) -> Bool {
        !isRequesting && !NYUEmailPolicy.normalize(email).isEmpty
    }

    /// Opens the unsupported-school screen with no address: nothing is
    /// classified, requested, issued or stored, and Home stays closed.
    private func openUnsupportedWithoutEmail() {
        focusedField = nil
        unsupportedAddress = ""
    }

    private func continueTapped() {
        switch ParticipantEmailEntryAction.forSubmission(email) {
        case .showValidation(let message):
            localEmailError = message
        case .requestVerification(let address):
            localEmailError = nil
            Task { await store.requestCode(for: address) }
        }
    }

    /// Shape only. Whether the code is *correct* is not something this app may
    /// decide, and a locally "valid-looking" code still proves nothing.
    static func canSubmitCode(
        code: String,
        isSubmitting: Bool,
        isRequesting: Bool
    ) -> Bool {
        guard !isSubmitting, !isRequesting else { return false }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count == 6 && trimmed.allSatisfy(\.isNumber)
    }

    static func resendRemainingSeconds(availableAt: Date, now: Date) -> Int {
        max(0, Int(ceil(availableAt.timeIntervalSince(now))))
    }

    static func resendTitle(availableAt: Date, now: Date) -> String {
        let seconds = resendRemainingSeconds(availableAt: availableAt, now: now)
        guard seconds > 0 else { return "Send a new code" }
        return String(format: "Send a new code in %d:%02d", seconds / 60, seconds % 60)
    }

    static func canResend(
        availableAt: Date,
        now: Date,
        isRequesting: Bool,
        isSubmitting: Bool
    ) -> Bool {
        !isRequesting && !isSubmitting
            && resendRemainingSeconds(availableAt: availableAt, now: now) == 0
    }
}
