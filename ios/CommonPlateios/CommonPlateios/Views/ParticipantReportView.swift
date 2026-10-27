//
//  ParticipantReportView.swift
//  CommonPlateios
//
// The shared contextual reporting flow for W4-U1.2.
//
import SwiftUI
import UIKit

struct ParticipantReportView: View {
    let requestID: String
    @ObservedObject var store: RequestStore
    /// True when a Block question may follow a successful report.
    var offersBlockAfter = false
    /// W4-MSG1 CP6: true only when request chat is composed in. The backend,
    /// not this view, decides what (if anything) is attached.
    var discloseConversationContext = false
    let onFinished: () -> Void
    /// The participant chose to Block after the report; the owning surface
    /// starts its own Block confirmation once the popup is gone.
    var onBlockRequested: () -> Void = {}

    @Environment(\.openURL) private var openURL
    @State private var selectedReason: ParticipantReportReason?
    @State private var explanation = ""
    @State private var isSubmitting = false
    @State private var isShowingNotConfirmed = false
    @State private var isShowingSupportFallback = false
    @State private var didSubmit = false
    @State private var contentHeight: CGFloat = 0

    private let supportContact = CommonPlateSupportContact(bundle: .main)

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            card
                .padding(.horizontal, CommonPlateStyle.Spacing.l)
        }
        .accessibilityAddTraits(.isModal)
        .alert("Report not confirmed", isPresented: $isShowingNotConfirmed) {
            Button("Email \(AppBrand.name) Support") {
                supportContact.open(using: openURL) {
                    isShowingSupportFallback = true
                }
            }
            .disabled(!supportContact.isConfigured)
            Button("OK", role: .cancel) {}
        } message: {
            Text("We couldn't confirm that your report was received. If you still have a concern, you can email \(AppBrand.name) Support.")
        }
        .alert(
            CommonPlateSupportContact.unavailableEmailAppTitle,
            isPresented: $isShowingSupportFallback
        ) {
            Button(CommonPlateSupportContact.copyAddressTitle) {
                guard let address = supportContact.address else { return }
                UIPasteboard.general.string = address
            }
            Button(CommonPlateSupportContact.cancelTitle, role: .cancel) {}
        } message: {
            Text(CommonPlateSupportContact.unavailableEmailAppMessage)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
            headerRow
            ScrollView {
                VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
                    if didSubmit {
                        submittedContent
                    } else {
                        formContent
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ReportCardContentHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            .frame(height: contentHeight > 0 ? min(contentHeight, UIScreen.main.bounds.height * 0.55) : nil)
            .onPreferenceChange(ReportCardContentHeightKey.self) { contentHeight = $0 }
            actionButtons
        }
        .padding(CommonPlateStyle.Spacing.l)
        .frame(maxWidth: 340)
        .background(
            CommonPlateStyle.Color.baseCanvas,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    private var headerRow: some View {
        HStack {
            Text(didSubmit ? "Report submitted" : "Report student")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if !didSubmit {
                CommonPlateCloseControl(action: onFinished)
                    .disabled(isSubmitting)
                    .accessibilityLabel("Cancel")
                    .accessibilityIdentifier("participant-report-cancel")
            }
        }
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
            reasonChoices

            TextField(requiresDetails ? "Add details (required)" : "Add details (optional)", text: $explanation, axis: .vertical)
                .lineLimit(3...7)
                .font(.subheadline)
                .padding(CommonPlateStyle.Spacing.m)
                .background(
                    CommonPlateStyle.Color.settingsRowSurface,
                    in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                )
                .accessibilityIdentifier("participant-report-explanation")
                .onChange(of: explanation) { _, value in
                    let limited = Self.limitedExplanation(value)
                    if limited != value {
                        explanation = limited
                    }
                }

            if discloseConversationContext {
                Text(ParticipantReportConversationDisclosure.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("participant-report-conversation-disclosure")
            }
        }
    }

    private var submittedContent: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.s) {
            Text("Thanks for letting us know.")
                .font(.body)
            if offersBlockAfter {
                Text("Would you also like to block this student?")
                    .font(.body.weight(.semibold))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("participant-report-submitted")
    }

    private var requiresDetails: Bool {
        selectedReason == .otherConcern
    }

    private var canSubmit: Bool {
        guard selectedReason != nil, !isSubmitting else { return false }
        return !requiresDetails || !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: CommonPlateStyle.Spacing.s) {
            if didSubmit {
                if offersBlockAfter {
                    Button("Block student", action: onBlockRequested)
                        .commonPlatePrimaryAction()
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("participant-report-block-student")
                    Button("Not now", action: onFinished)
                        .commonPlateSecondaryAction()
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("participant-report-block-not-now")
                } else {
                    Button("Done", action: onFinished)
                        .commonPlatePrimaryAction()
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("participant-report-done")
                }
            } else {
                Button("Submit report") {
                    Task { await submit() }
                }
                .commonPlatePrimaryAction()
                .frame(maxWidth: .infinity)
                .disabled(!canSubmit)
                .accessibilityIdentifier("participant-report-submit")
            }
        }
    }

    private var reasonChoices: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ParticipantReportReason.allCases) { reason in
                Button {
                    selectedReason = reason
                } label: {
                    HStack(spacing: CommonPlateStyle.Spacing.s) {
                        Image(systemName: selectedReason == reason ? "largecircle.fill.circle" : "circle")
                            .accessibilityHidden(true)
                        Text(reason.title)
                            .font(.subheadline)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("participant-report-reason-\(reason.id)")
                .accessibilityAddTraits(selectedReason == reason ? .isSelected : [])
            }
        }
    }

    @MainActor
    private func submit() async {
        guard let selectedReason, canSubmit else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        let result = await store.submitParticipantReport(
            requestID: requestID,
            reason: selectedReason,
            explanation: explanation.isEmpty ? nil : explanation
        )
        switch result {
        case .submitted:
            store.markRequestReported(requestID: requestID)
            didSubmit = true
        case .notConfirmed:
            isShowingNotConfirmed = true
        }
    }

    static func limitedExplanation(_ value: String) -> String {
        var result = ""
        for character in value {
            let next = String(character)
            guard result.utf16.count + next.utf16.count <= 250 else { break }
            result.append(character)
        }
        return result
    }
}

private struct ReportCardContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum ParticipantReportConversationDisclosure {
    static let text =
        "If you and this student have a private conversation for this request, up to its 10 most recent sent messages may be attached to your report for moderation review. If they can't be captured, your report can still be submitted and moderators will see that evidence is incomplete. Messages may include personal details. Nothing from other conversations is included, and you can't choose which messages are attached."
}
