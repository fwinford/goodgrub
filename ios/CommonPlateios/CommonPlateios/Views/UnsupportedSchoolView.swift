//
//  UnsupportedSchoolView.swift
//  CommonPlateios
//
// W4-B1: what a student sees when the address they entered is well formed but
// not at a supported school. Nothing is sent, stored, or promised: there is no
// waitlist, and the only outward action is composing an email the student
// sends themselves.

import SwiftUI
import UIKit

struct UnsupportedSchoolView: View {
    static let heading = "We're not at your school yet"
    static let body = "\(AppBrand.name) is starting at \(AppBrand.campus), and we hope to expand to more campuses in the future."
    static let wordmark = AppBrand.name
    static let contactTitle = "Contact \(AppBrand.name)"
    static let haveNYUEmailTitle = "I have an NYU email"

    let contact: SupportContact
    /// The screen's only way back; it deliberately has no separate close
    /// control (Faith, CP2 2026-10-25).
    let onHaveNYUEmail: () -> Void
    /// Injectable so tests can observe the copy without a pasteboard.
    var copyAddress: (String) -> Void = { UIPasteboard.general.string = $0 }

    @Environment(\.openURL) private var openURL
    @State private var isShowingMailFailure = false

    var body: some View {
        // Scrolls when large text outgrows the screen, so the actions keep
        // their natural height instead of being compressed.
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
        .alert(SupportContact.openFailedTitle, isPresented: $isShowingMailFailure) {
            Button(SupportContact.copyActionTitle) {
                if let address = contact.address { copyAddress(address) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SupportContact.openFailedBody)
        }
    }

    private var content: some View {
        VStack(spacing: CommonPlateStyle.Spacing.xl) {
            Text(Self.wordmark)
                .font(.commonPlateBrandDisplay(.title2))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("unsupported-school-wordmark")

            Spacer(minLength: 0)

            VStack(spacing: CommonPlateStyle.Spacing.l) {
                Image("UnsupportedSchoolPlate")
                    .renderingMode(.template)
                    .foregroundStyle(CommonPlateStyle.Color.brandFill)
                    .frame(width: 120, height: 120)
                    .background(
                        CommonPlateStyle.Color.brandFill.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 36, style: .continuous)
                    )
                    .accessibilityHidden(true)

                Text(Self.heading)
                    .font(.title.weight(.bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("unsupported-school-heading")

                Text(Self.body)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("unsupported-school-body")

                VStack(spacing: CommonPlateStyle.Spacing.s) {
                    Button(Self.contactTitle, action: contactTapped)
                        .commonPlateMajorPrimaryAction()
                        .disabled(!contact.isConfigured)
                        .accessibilityIdentifier("unsupported-school-contact")

                    Button(Self.haveNYUEmailTitle, action: onHaveNYUEmail)
                        .commonPlateMajorSecondaryAction()
                        .accessibilityIdentifier("unsupported-school-have-nyu-email")
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, CommonPlateStyle.Spacing.l)
        .padding(.vertical, CommonPlateStyle.Spacing.l)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }

    private func contactTapped() {
        guard let url = contact.mailtoURL else { return }
        openURL(url) { accepted in
            if !accepted { isShowingMailFailure = true }
        }
    }
}
