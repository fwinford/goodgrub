import SwiftUI

struct PushNotificationSection: View {
    static let deniedTitle = "Notifications are off"
    static let deniedBody = "Turn on notifications in Settings to use Request Alerts."
    static let failureMessage = "Something went wrong while updating Request Alerts."
    static let openSettingsButtonTitle = "Open Settings"
    static let tryAgainButtonTitle = "Try Again"
    static let toggleTitle = "Push notifications"
    static let permissionMessage = "Allow notifications in iPhone Settings to turn on Push notifications."
    static let updateFailureTitle = "Couldn't update notifications"
    static let updateFailureMessage = "Your notification preference couldn't be updated. Try again."
    static let ambiguousMessage = "Your notification preference couldn't be confirmed. Try again to resolve the requested change."

    @State private var isPresentingPermissionAlert = false
    @State private var isPresentingFailureAlert = false

    @ObservedObject var store: PushSubscriptionStore
    var isHomePromotion = false
    /// Home's promotion disappears once Push is On; Home uses this to know the
    /// student asked from there and confirm the result in its place.
    var onHomeEnableRequested: (() -> Void)? = nil

    var body: some View {
        Group {
            if isHomePromotion {
                homePromotion
            } else {
                settingsToggle
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            await store.refreshAuthorizationStatus()
            presentFailureIfNeeded()
        }
        .onChange(of: store.state) { _, _ in presentFailureIfNeeded() }
        .onChange(of: store.failure) { _, _ in presentFailureIfNeeded() }
    }

    private var settingsToggle: some View {
        Toggle(Self.toggleTitle, isOn: Binding(
            get: { store.state == .on },
            set: { enabled in
                if showsFailure {
                    isPresentingFailureAlert = true
                } else if enabled && store.state == .denied {
                    isPresentingPermissionAlert = true
                } else {
                    Task {
                        if enabled { await store.enable() }
                        else { await store.disable() }
                        if store.state == .denied {
                            isPresentingPermissionAlert = true
                        }
                        presentFailureIfNeeded()
                    }
                }
            }
        ))
        .tint(Color.accentColor)
        .disabled(store.isBusy)
        .frame(minHeight: CommonPlateStyle.Control.minimumHeight)
        .accessibilityIdentifier("settings-push-alerts-toggle")
        .alert(Self.deniedTitle, isPresented: $isPresentingPermissionAlert) {
            Button(Self.openSettingsButtonTitle) { store.openSystemSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.permissionMessage)
        }
        .alert(Self.updateFailureTitle, isPresented: $isPresentingFailureAlert) {
            Button(Self.tryAgainButtonTitle) {
                Task {
                    await store.retryUpdate()
                    if store.state == .denied {
                        isPresentingPermissionAlert = true
                    }
                    presentFailureIfNeeded()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(failureAlertMessage)
        }
    }

    private var homePromotion: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.s) {
            if store.state != .settingUp && showsFailure {
                Text(Self.failureMessage).font(.subheadline).foregroundStyle(.secondary)
                Button(Self.tryAgainButtonTitle) {
                    Task { await store.retryUpdate() }
                }
                .commonPlateSecondaryAction()
            } else if store.state == .denied {
                Text(Self.deniedTitle).font(.subheadline.weight(.semibold))
                Text(Self.deniedBody).font(.subheadline).foregroundStyle(.secondary)
                Button(Self.openSettingsButtonTitle) { store.openSystemSettings() }
                    .commonPlateSecondaryAction()
            } else {
                Button {
                    onHomeEnableRequested?()
                    Task { await store.enable() }
                } label: {
                    Text(HomeExchangeView.requestAlertsActionTitle)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(CommonPlateStyle.Color.brandText)
                        .padding(.horizontal, CommonPlateStyle.Spacing.l)
                        .frame(minHeight: 44)
                        .opacity(store.state == .settingUp ? 0 : 1)
                        .overlay {
                            if store.state == .settingUp {
                                ProgressView()
                                    .accessibilityLabel("Updating Request Alerts")
                            }
                        }
                }
                .disabled(store.state == .settingUp)
                .buttonStyle(.plain)
                .background(
                    CommonPlateStyle.Color.brandText.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                )
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("home-empty-request-alerts")
            }
        }
    }

    private var failureAlertMessage: String {
        if case .ambiguous = store.state { return Self.ambiguousMessage }
        return Self.updateFailureMessage
    }

    private func presentFailureIfNeeded() {
        guard !isHomePromotion, !store.isBusy, showsFailure else { return }
        isPresentingFailureAlert = true
    }

    private var showsFailure: Bool {
        if store.failure != nil || store.state == .failed { return true }
        if case .ambiguous = store.state { return true }
        return false
    }
}
