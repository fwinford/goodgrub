//
//  PrivacySafetyView.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
import SwiftUI

struct PrivacySafetyView: View {
    @ObservedObject var participantIdentityStore: ParticipantIdentityStore
    var deletionRow: ParticipantDeletionRowState = .none
    var onDeleteAccount: (() -> Void)? = nil
    var onOpenDeletion: () -> Void = {}
    @State private var isPresentingDeletionConfirmation = false

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Privacy & Safety")
                        .font(.title)
                        .fontWeight(.semibold)

                    Text("CommonPlate is for voluntary student-to-student food help. It is not a place to sell meal swipes, exchange money, or share account access.")
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Use CommonPlate safely")
                            .font(.headline)

                        Text("• Do not share your NYU login, ID card, or account access.")
                        Text("• Do not exchange money for meal swipes or orders.")
                        Text("• Only place orders you are comfortable placing.")
                        Text("• Keep requests respectful, accurate, and food-related.")
                        Text("• Do not include sensitive personal information in requests or notes.")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Privacy")
                            .font(.headline)

                        Text("Order details are only used to coordinate food pickup. Contact information should only be used for coordinating the request.")
                            .foregroundStyle(.secondary)
                    }

                    // W4-U1.3: the one route to Block management
                    // (Settings → Privacy & Safety → Blocked Students). Offered
                    // only with a verified participant, since a block belongs to
                    // one. The list shows interaction context, never identity.
                    if participantIdentityStore.identity != nil {
                        NavigationLink(value: AppRoute.blockedStudents) {
                            HStack(alignment: .center) {
                                Text(ParticipantBlockCopy.managementRowTitle)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Spacer(minLength: CommonPlateStyle.Spacing.s)
                                CommonPlateDisclosureIndicator()
                            }
                            .frame(minHeight: CommonPlateStyle.Control.minimumHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("privacy-safety-blocked-students")
                        if onDeleteAccount != nil, deletionRow != .none {
                            Button(action: onOpenDeletion) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Account Deletion")
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Text(deletionRow == .readyToDelete ? "Ready to delete" : "On hold")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .accessibilityIdentifier("privacy-safety-account-deletion-status")
                                    }
                                    Spacer(minLength: CommonPlateStyle.Spacing.s)
                                    CommonPlateDisclosureIndicator()
                                }
                                .frame(minHeight: CommonPlateStyle.Control.minimumHeight)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("privacy-safety-account-deletion")
                        } else if onDeleteAccount != nil {
                            Button {
                                var transaction = Transaction()
                                transaction.disablesAnimations = true
                                withTransaction(transaction) { isPresentingDeletionConfirmation = true }
                            } label: {
                                HStack(alignment: .center) {
                                    Text("Delete CommonPlate Account")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(CommonPlateStyle.Color.destructiveText)
                                    Spacer(minLength: CommonPlateStyle.Spacing.s)
                                    CommonPlateDisclosureIndicator()
                                }
                                .frame(minHeight: CommonPlateStyle.Control.minimumHeight)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("privacy-safety-delete-account")
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Need more support?")
                            .font(.headline)

                        Text("CommonPlate is not a replacement for official food support. NYU offers food accessibility resources for students who need short-term or ongoing help. You can find them in Settings under Food Resources.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Privacy & Safety")
        // A clear, unanimated full-screen cover keeps the page and navigation bar in place under the scrim.
        .fullScreenCover(isPresented: $isPresentingDeletionConfirmation) {
            ParticipantDeletionEntryConfirmationView(
                onConfirm: { dismissDeletionConfirmation(then: onDeleteAccount) },
                onDismiss: { dismissDeletionConfirmation(then: nil) }
            )
            .presentationBackground(.clear)
        }
    }

    private func dismissDeletionConfirmation(then action: (() -> Void)?) {
        // One confirm per presentation: B may still be on screen for a frame
        // after J appears beneath it.
        guard isPresentingDeletionConfirmation else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { isPresentingDeletionConfirmation = false }
        action?()
    }
}

private struct ParticipantDeletionEntryConfirmationView: View {
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ParticipantDeletionModalFrame(
            identifier: "deletion-entry-confirmation",
            title: "Delete your account?"
        ) {
            Text("This permanently deletes your CommonPlate account and history.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("deletion-entry-confirmation-message")

            Text("Blocks may still apply if you rejoin with the same NYU email.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("deletion-entry-confirmation-safety-note")
        } actions: {
            Button("Delete Account", role: .destructive, action: onConfirm)
                .buttonStyle(ParticipantDeletionEntryDestructiveButtonStyle(
                    fill: CommonPlateStyle.Color.destructiveText,
                    titleColor: .white
                ))
                .accessibilityIdentifier("deletion-entry-confirmation-confirm")

            ParticipantDeletionTextButton(
                title: "Keep My Account", identifier: "deletion-entry-confirmation-keep-account",
                action: onDismiss
            )
        }
    }
}

struct ParticipantDeletionEntryDestructiveButtonStyle: ButtonStyle {
    let fill: Color
    let titleColor: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isEnabled ? titleColor : .secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, CommonPlateStyle.Spacing.l)
            .padding(.vertical, CommonPlateStyle.Spacing.m)
            .frame(maxWidth: .infinity, minHeight: ParticipantDeletionModalLayout.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                    .fill(isEnabled ? fill : Color.gray.opacity(0.28))
            )
            .opacity(configuration.isPressed && isEnabled ? 0.82 : 1)
    }
}
