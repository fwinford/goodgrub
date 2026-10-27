//
//  ScreenshotAssistanceDisclosureView.swift
//  CommonPlateios
//
// W4-S3 consent-authority revision (2026-10-01 HQ sync): the disclosure shown
// before Screenshot Assistance's Off → On transition becomes effective. This
// replaces the per-attempt external-AI fallback popup as the consent
// boundary — `Turn On` is the only action that establishes external-transfer
// consent, and that consent persists while Screenshot Assistance stays On
// (no repeated per-attempt prompt). `Not Now` leaves the feature Off and
// records nothing.
//
// Both presentation sites (`RequestFoodView`'s `Turn on Screenshot
// Assistance` row and `SettingsView`'s toggle) show this identical surface,
// inside the same centered-modal shell Screenshot Help and the retired
// per-attempt popup used (not a `.sheet`, no navigation screen).
import SwiftUI

struct ScreenshotAssistanceDisclosureView: View {
    let onTurnOn: () -> Void
    let onNotNow: () -> Void
    /// Same reason `ScreenshotHelpView.overview` reads this: a plain,
    /// synchronous `@Environment` value resolved during `body`, with none of
    /// the runtime-measurement failure modes documented on that property.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The same modal-height budget the shared call-site shell caps this
    /// view to.
    static let maxHeight: CGFloat = 480

    // Exact accepted copy (weekly spec W4-S3 consent-authority revision sync,
    // item 6). No on-device/local-processing, model-routing,
    // provider-qualification, or fallback-architecture language.
    static let title = "Turn on Screenshot Assistance?"
    static let body =
        "Screenshot Assistance can help fill in details from screenshots you add to \(AppBrand.name). Some screenshots may be sent to OpenAI to generate these suggestions."
    static let offRecoveryLine = "You can turn Screenshot Assistance off anytime in Settings."
    static let turnOnActionTitle = "Turn On"
    static let notNowActionTitle = "Not Now"

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView {
                    content
                }
                .frame(maxHeight: Self.maxHeight)
            } else {
                content
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.l) {
            Text(Self.title)
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("screenshot-assistance-disclosure-title")

            Text(Self.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("screenshot-assistance-disclosure-body")

            Text(Self.offRecoveryLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("screenshot-assistance-disclosure-off-recovery")

            VStack(spacing: CommonPlateStyle.Spacing.s) {
                Button(Self.turnOnActionTitle) {
                    onTurnOn()
                }
                .commonPlatePrimaryAction()
                .accessibilityIdentifier("screenshot-assistance-disclosure-turn-on")

                Button(Self.notNowActionTitle) {
                    onNotNow()
                }
                .commonPlateSecondaryAction()
                .accessibilityIdentifier("screenshot-assistance-disclosure-not-now")
            }
        }
        .padding(CommonPlateStyle.Spacing.xl)
    }
}
