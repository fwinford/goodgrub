import SwiftUI

/// CP9 deletion surfaces (Figma board `1151:7504`). Modals are centered cards
/// over the app; Close always returns to it. Only completion is full-screen.
struct ParticipantDeletionView: View {
    @ObservedObject var store: ParticipantDeletionStore
    var onViewCurrentRequest: () -> Void = {}

    var body: some View {
        if store.isCompleted {
            ParticipantDeletionCompletedPage(store: store)
        } else if store.cleanupFailed {
            ParticipantDeletionCleanupPage(store: store)
        } else if let route = store.route {
            switch route {
            case .ready:
                ParticipantDeletionReadyPage(store: store)
            case .verify:
                ParticipantDeletionVerifyModal(store: store)
            case .openRequest:
                ParticipantDeletionModal(
                    store: store, identifier: "deletion-open-request",
                    title: "Finish your request first",
                    message: "You’re part of an active food request. Finish it before continuing with account deletion.",
                    showsClose: false
                ) {
                    ParticipantDeletionPrimaryButton(title: "Go to Request", identifier: "deletion-go-to-request") {
                        store.close()
                        onViewCurrentRequest()
                    }
                    ParticipantDeletionTextButton(title: "Keep My Account", identifier: "deletion-keep-account") {
                        Task { await store.keepAccount() }
                    }
                }
            case .wait:
                ParticipantDeletionModal(
                    store: store, identifier: "deletion-wait",
                    title: "CommonPlate needs a little more time",
                    message: "You can start your deletion request now. We’ll let you know when your account is ready to delete.",
                    showsClose: false
                ) {
                    ParticipantDeletionPrimaryButton(title: "Start Account Deletion", identifier: "deletion-start") {
                        Task { await store.startDeletion() }
                    }
                    ParticipantDeletionTextButton(title: "Keep My Account", identifier: "deletion-keep-account") {
                        store.close()
                    }
                }
            case .inProgress:
                ParticipantDeletionModal(
                    store: store, identifier: "deletion-in-progress",
                    title: "Account deletion is on hold",
                    message: "Your account isn’t ready to delete yet. We’ll let you know when you can continue.",
                    showsClose: false,
                    centersContent: true
                ) {
                    ParticipantDeletionPrimaryButton(title: "Got It", identifier: "deletion-got-it") {
                        store.close()
                    }
                    ParticipantDeletionTextButton(
                        title: "Cancel Account Deletion", identifier: "deletion-cancel"
                    ) { Task { await store.cancel() } }
                    .disabled(!store.canCancel)
                }
            case .status:
                if store.codeRequestFailed {
                    ParticipantDeletionModal(
                        store: store, identifier: "deletion-code-send-error",
                        title: "Code couldn’t be sent", message: nil,
                        keepsActionsOnError: true, showsClose: false
                    ) {
                        ParticipantDeletionPrimaryButton(title: "Try Again", identifier: "deletion-try-again") {
                            Task { await store.retry() }
                        }
                        .disabled(!store.canRetry)
                        ParticipantDeletionTextButton(title: "Cancel", identifier: "deletion-error-cancel") {
                            Task { await store.cancel() }
                        }
                    }
                } else {
                        ParticipantDeletionModal(
                            store: store, identifier: "deletion-status",
                            title: store.isUnresolved ? "Checking account deletion" : "Account deletion unavailable",
                            message: store.isUnresolved
                                ? "We could not confirm whether account deletion completed. Do not start another deletion."
                                : nil
                        ) {
                            if store.isUnresolved && store.errorMessage == nil {
                                ParticipantDeletionPrimaryButton(title: "Check deletion status", identifier: "deletion-check-status") {
                                    Task { await store.recover() }
                                }
                            }
                        }
                }
            }
        }
    }
}

// MARK: - Modal container (C, F, H, J/K, status)

enum ParticipantDeletionModalLayout {
    static let padding: CGFloat = 24
    static let titleSpacing: CGFloat = 20
    static let contentSpacing: CGFloat = 24
    static let actionSpacing: CGFloat = 16
    static let buttonHeight: CGFloat = 56
}

/// Shared chrome and spacing; content, rather than a height floor, sizes each state.
struct ParticipantDeletionModalFrame<Content: View, Actions: View>: View {
    let identifier: String
    let title: String
    var onClose: (() -> Void)?
    var hasContent = true
    var centersContent = false
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.34).accessibilityHidden(true)
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        ScrollView { details }
                            .frame(maxHeight: max(180, geometry.size.height - 96))
                            .scrollBounceBehavior(.basedOnSize)
                    } else {
                        details
                    }
                }
                .frame(maxWidth: min(314, geometry.size.width - 48))
                .fixedSize(horizontal: false, vertical: !dynamicTypeSize.isAccessibilitySize)
                .background(CommonPlateStyle.Color.baseCanvas,
                            in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: Color.black.opacity(0.12), radius: 18, y: 8)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(identifier)
                .accessibilityAddTraits(.isModal)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
    }

    private var details: some View {
        VStack(alignment: centersContent ? .center : .leading, spacing: 0) {
            HStack(alignment: .center, spacing: CommonPlateStyle.Spacing.s) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: centersContent ? .center : .leading)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("\(identifier)-title")
                if let onClose {
                    CommonPlateScreenCloseControl(
                        accessibilityLabel: "Close",
                        accessibilityIdentifier: "\(identifier)-close",
                        action: onClose
                    )
                }
            }
            if hasContent {
                VStack(alignment: .leading, spacing: ParticipantDeletionModalLayout.contentSpacing, content: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, ParticipantDeletionModalLayout.titleSpacing)
            }
            VStack(spacing: ParticipantDeletionModalLayout.actionSpacing, content: actions)
                .padding(.top, ParticipantDeletionModalLayout.contentSpacing)
        }
        .padding(ParticipantDeletionModalLayout.padding)
        .multilineTextAlignment(centersContent ? .center : .leading)
    }
}

private struct ParticipantDeletionModal<Actions: View>: View {
    @ObservedObject var store: ParticipantDeletionStore
    let identifier: String
    let title: String
    let message: String?
    var detail: String?
    var keepsActionsOnError = false
    var showsClose = true
    var centersContent = false
    var accessory: AnyView?
    var onClose: (() -> Void)?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        ParticipantDeletionModalFrame(
            identifier: identifier, title: title,
            onClose: showsClose && (store.errorMessage == nil || keepsActionsOnError)
                ? (onClose ?? store.close) : nil,
            hasContent: message != nil || detail != nil || accessory != nil || store.errorMessage != nil,
            centersContent: centersContent
        ) {
            details
        } actions: {
            modalActions
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: ParticipantDeletionModalLayout.contentSpacing) {
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(identifier)-message")
            }
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(identifier)-detail")
            }
            accessory
            if let error = store.errorMessage {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(CommonPlateStyle.Color.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("deletion-error")
            }
        }
    }

    private var modalActions: some View {
        Group {
            if store.errorMessage == nil || keepsActionsOnError {
                actions()
            } else {
                if store.canRetry {
                    ParticipantDeletionPrimaryButton(title: "Try Again", identifier: "deletion-try-again") {
                        Task { await store.retry() }
                    }
                }
                ParticipantDeletionTextButton(title: "Close", identifier: "deletion-error-close", action: store.close)
            }
            if store.isBusy {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Checking account deletion")
            }
        }
        .disabled(store.isBusy)
    }
}

private struct ParticipantDeletionPrimaryButton: View {
    let title: String
    let identifier: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(title, role: destructive ? .destructive : nil, action: action)
            .buttonStyle(ParticipantDeletionEntryDestructiveButtonStyle(
                fill: destructive ? CommonPlateStyle.Color.destructiveText : CommonPlateStyle.Color.brandFill,
                titleColor: .white
            ))
            .accessibilityIdentifier(identifier)
    }
}

struct ParticipantDeletionTextButton: View {
    let title: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .commonPlateSecondaryAction(minimumHeight: ParticipantDeletionModalLayout.buttonHeight)
            .accessibilityIdentifier(identifier)
    }
}

// MARK: - I: ready page

private struct ParticipantDeletionReadyPage: View {
    @ObservedObject var store: ParticipantDeletionStore

    var body: some View {
        NavigationStack {
            VStack(spacing: CommonPlateStyle.Spacing.l) {
                Spacer()
                Text("Your account is ready to delete")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("deletion-ready-title")
                if let error = store.errorMessage, store.route == .ready {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(CommonPlateStyle.Color.destructiveText)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("deletion-error")
                }
                ParticipantDeletionPrimaryButton(title: "Verify It’s You", identifier: "deletion-verify-its-you") {
                    Task { await store.openVerification() }
                }
                .frame(maxWidth: CommonPlateStyle.Control.majorActionMaximumWidth)
                ParticipantDeletionTextButton(
                    title: "Cancel Account Deletion", identifier: "deletion-cancel"
                ) { Task { await store.cancel() } }
                .frame(maxWidth: CommonPlateStyle.Control.majorActionMaximumWidth)
                .disabled(!store.canCancel)
                if store.isBusy { ProgressView().accessibilityLabel("Checking account deletion") }
                Spacer()
            }
            .padding(CommonPlateStyle.Spacing.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
            .disabled(store.isBusy)
            .navigationTitle("Account Deletion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { store.close() } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Back")
                        .accessibilityIdentifier("deletion-ready-back")
                }
            }
        }
    }
}

// MARK: - J: verification modal

private struct ParticipantDeletionVerifyModal: View {
    @ObservedObject var store: ParticipantDeletionStore
    @State private var code = ""

    private var isAuthorized: Bool { store.status?.phase == .authorized }
    private var isValidCode: Bool { code.utf8.count == 6 && code.utf8.allSatisfy { (48...57).contains($0) } }

    var body: some View {
        if isAuthorized {
            ParticipantDeletionFinalConfirmationModal(store: store)
        } else {
            codeEntry
        }
    }

    private var codeEntry: some View {
        // Read here (not inside the timeline) so each keystroke re-renders Verify.
        let canVerify = isValidCode
        return ParticipantDeletionModal(
            store: store, identifier: "deletion-verify", title: "Verify it’s you",
            message: store.verificationEmail.map { "Enter the 6-digit code we sent to \($0)." },
            keepsActionsOnError: true,
            accessory: AnyView(
                TextField("6-digit code", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .padding(CommonPlateStyle.Spacing.m)
                    .frame(minHeight: ParticipantDeletionModalLayout.buttonHeight)
                    .background(CommonPlateStyle.Color.settingsRowSurface,
                                in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard))
                    .accessibilityIdentifier("deletion-code")
                    .disabled(store.isBusy)
            ),
            onClose: { Task { await store.abandonVerification() } }
        ) {
            Group {
                ParticipantDeletionPrimaryButton(title: "Verify", identifier: "deletion-verify-code") {
                    let submitted = code
                    code = ""
                    Task { await store.redeem(code: submitted) }
                }
                .disabled(!canVerify)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: CommonPlateStyle.Spacing.s) {
                        if let challenge = store.status?.challenge, context.date >= challenge.expiresAt {
                            Text("That code has expired. Send a new code.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .accessibilityIdentifier("deletion-challenge-expired")
                        }
                        ParticipantDeletionResendAction(
                            cooldownEndsAt: store.status?.challenge?.cooldownEndsAt, now: context.date
                        ) {
                            Task { await store.requestCode() }
                        }
                    }
                }
            }
        }
        .onDisappear { code = "" }
    }
}

struct ParticipantDeletionResendAction: View {
    let cooldownEndsAt: Date?
    let now: Date
    let action: () -> Void

    private var remainingSeconds: Int {
        guard let cooldownEndsAt else { return 0 }
        return max(0, Int(ceil(cooldownEndsAt.timeIntervalSince(now))))
    }

    var body: some View {
        let seconds = remainingSeconds
        Button(
            seconds > 0
                ? String(format: "Send a new code in %d:%02d", seconds / 60, seconds % 60)
                : "Send a new code",
            action: action
        )
        .commonPlateSecondaryAction(minimumHeight: ParticipantDeletionModalLayout.buttonHeight)
        .accessibilityIdentifier("deletion-resend")
        .disabled(cooldownEndsAt == nil || seconds > 0)
    }
}

// MARK: - K: final confirmation after a redeemed code (Faith 2026-10-25)

/// Replaces code entry once authorized; Cancel abandons verification, while
/// only the explicit destructive action reaches completion.
private struct ParticipantDeletionFinalConfirmationModal: View {
    @ObservedObject var store: ParticipantDeletionStore

    var body: some View {
        ParticipantDeletionModal(
            store: store, identifier: "deletion-final", title: "Delete your account?",
            message: "Your identity is verified. Deleting your account can’t be undone.",
            keepsActionsOnError: true,
            showsClose: false
        ) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let expired = store.status?.authorization.map { context.date >= $0.expiresAt } ?? true
                VStack(spacing: ParticipantDeletionModalLayout.actionSpacing) {
                    if expired || !store.canComplete {
                        Text("Your verification is no longer valid. Request a new code to continue.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("deletion-authorization-unavailable")
                    }
                    ParticipantDeletionPrimaryButton(
                        title: "Delete Account", identifier: "deletion-final-confirmation", destructive: true
                    ) { Task { await store.complete() } }
                    .disabled(!store.canComplete || expired)
                    ParticipantDeletionTextButton(title: "Cancel", identifier: "deletion-final-cancel") {
                        Task { await store.abandonVerification() }
                    }
                }
            }
        }
    }
}

// MARK: - L: completion, and cleanup failure

private struct ParticipantDeletionCompletedPage: View {
    @ObservedObject var store: ParticipantDeletionStore

    var body: some View {
        VStack(spacing: CommonPlateStyle.Spacing.l) {
            Text(AppBrand.name)
                .font(.commonPlateBrandDisplay(.largeTitle))
                .padding(.top, CommonPlateStyle.Spacing.xl)
            Spacer()
            Image(systemName: "checkmark")
                .font(.title2.weight(.bold))
                .foregroundStyle(CommonPlateStyle.Color.brandText)
                .frame(width: 56, height: 56)
                .background(CommonPlateStyle.Color.brandFill.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            Text("Account deleted").font(.title.bold())
                .accessibilityIdentifier("deletion-completed-title")
            Text("Thanks for being part of CommonPlate. Your account and history have been deleted.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("deletion-completed-message")
            if let error = store.errorMessage {
                Text(error).font(.footnote).foregroundStyle(CommonPlateStyle.Color.destructiveText)
            }
            ParticipantDeletionPrimaryButton(title: "Done", identifier: "deletion-done", action: store.done)
                .frame(maxWidth: CommonPlateStyle.Control.majorActionMaximumWidth)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, CommonPlateStyle.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
    }
}

private struct ParticipantDeletionCleanupPage: View {
    @ObservedObject var store: ParticipantDeletionStore

    var body: some View {
        VStack(spacing: CommonPlateStyle.Spacing.l) {
            Spacer()
            Text("Device cleanup incomplete").font(.title2.bold())
            if let error = store.errorMessage {
                Text(error).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .accessibilityIdentifier("deletion-error")
            }
            ParticipantDeletionPrimaryButton(title: "Retry local cleanup", identifier: "deletion-retry-cleanup",
                                             action: store.resumeCleanup)
                .frame(maxWidth: CommonPlateStyle.Control.majorActionMaximumWidth)
            Spacer()
        }
        .padding(CommonPlateStyle.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
    }
}
