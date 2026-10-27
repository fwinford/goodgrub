//
//  RequesterVenueRecoveryCallout.swift
//  CommonPlateios
//
//  R4.2's result-scoped venue recovery presentation. Keeping this as a leaf
//  view leaves RequestFoodView responsible only for draft/token wiring.
import SwiftUI

struct RequesterVenueRecoveryCallout<LocationPicker: View>: View {
    let recovery: ScreenshotVenueRecovery
    let isAutofillEnabled: Bool
    let canTryOtherScreenshots: Bool
    let onConfirm: () -> Void
    let onDismiss: () -> Void
    let onTryOtherScreenshots: () -> Void
    private let locationPicker: () -> LocationPicker

    init(
        recovery: ScreenshotVenueRecovery,
        isAutofillEnabled: Bool,
        canTryOtherScreenshots: Bool,
        onConfirm: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onTryOtherScreenshots: @escaping () -> Void,
        @ViewBuilder locationPicker: @escaping () -> LocationPicker
    ) {
        self.recovery = recovery
        self.isAutofillEnabled = isAutofillEnabled
        self.canTryOtherScreenshots = canTryOtherScreenshots
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
        self.onTryOtherScreenshots = onTryOtherScreenshots
        self.locationPicker = locationPicker
    }

    var body: some View {
        VStack(alignment: .leading, spacing: recovery.kind == .unresolved ? Metrics.unresolvedSpacing : Metrics.spacing) {
            switch recovery.kind {
            case .unresolved:
                heading("We found order details, but couldn't identify the dining location.")
                RequesterFormFieldContainer(label: "Dining location") {
                    locationPicker()
                }
                actions(
                    primary: RecoveryAction(
                        title: "Autofill order details",
                        identifier: "request-venue-autofill",
                        isDisabled: !isAutofillEnabled,
                        perform: onConfirm
                    ),
                    secondary: RecoveryAction(
                        title: "Continue manually",
                        identifier: "request-venue-continue-manually",
                        perform: onDismiss
                    )
                )
            case .unsupported, .conflicting:
                heading(recovery.kind == .unsupported
                    ? "Restaurant not found on CommonPlate"
                    : "Screenshots show different restaurants")
                actions(
                    primary: RecoveryAction(
                        title: "Try other screenshots",
                        identifier: "request-venue-try-other-screenshots",
                        isDisabled: !canTryOtherScreenshots,
                        perform: onTryOtherScreenshots
                    ),
                    secondary: RecoveryAction(
                        title: "Continue manually",
                        identifier: "request-venue-continue-manually",
                        perform: onDismiss
                    )
                )
            case .manualMismatch(let screenshot, let manual):
                heading("Which dining location should we use?")
                Text("Your screenshots show \(screenshot.name), but you selected \(manual.name).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions(
                    primary: RecoveryAction(
                        title: "Use \(screenshot.name) & autofill",
                        identifier: "request-venue-use-screenshot",
                        perform: onConfirm
                    ),
                    secondary: RecoveryAction(
                        title: "Keep \(manual.name) & enter manually",
                        identifier: "request-venue-keep-manual",
                        perform: onDismiss
                    )
                )
            }
        }
        .padding(CommonPlateStyle.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            CommonPlateStyle.Color.requestCardSurface,
            in: RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .strokeBorder(CommonPlateStyle.Color.requestCardBorder)
        )
        .accessibilityIdentifier("request-venue-recovery")
    }

    private struct RecoveryAction {
        let title: String
        let identifier: String
        var isDisabled = false
        let perform: () -> Void
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The approved layout stacks the primary and secondary actions at the
    /// full card width at every text size, so one label never competes with
    /// the other for half the card. Each action is at least 46 pt tall and
    /// grows, wrapping on word boundaries, for long venue names or large
    /// Dynamic Type.
    private func actions(primary: RecoveryAction, secondary: RecoveryAction) -> some View {
        VStack(spacing: Metrics.spacing) {
            actionButton(primary, style: .primary)
            actionButton(secondary, style: .secondary)
        }
    }

    private func actionButton(_ action: RecoveryAction, style: RecoveryActionButtonStyle.Kind) -> some View {
        Button(action: action.perform) {
            Text(action.title)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(RecoveryActionButtonStyle(kind: style))
        .disabled(action.isDisabled)
        .accessibilityIdentifier(action.identifier)
    }
}

/// Approved Figma `1110:7268` card metrics (A–D recovery callouts).
private enum Metrics {
    static let cornerRadius: CGFloat = 14
    static let spacing: CGFloat = 8
    static let unresolvedSpacing: CGFloat = 10
    static let actionMinimumHeight: CGFloat = 46
}

/// Full-width recovery action: filled accent primary (grey when disabled) and a
/// canvas-filled, bordered accent-text secondary, both 14 pt rounded rectangles.
private struct RecoveryActionButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }

    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .subheadline) private var labelSize: CGFloat = 14

    private static let disabledFill = Color(red: 213.0 / 255, green: 211.0 / 255, blue: 211.0 / 255)
    private static let disabledLabel = Color(red: 112.0 / 255, green: 105.0 / 255, blue: 112.0 / 255)

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
        configuration.label
            .font(.system(size: labelSize, weight: .semibold))
            .foregroundStyle(labelColor)
            .padding(.horizontal, CommonPlateStyle.Spacing.m)
            .padding(.vertical, CommonPlateStyle.Spacing.s)
            .frame(maxWidth: .infinity, minHeight: Metrics.actionMinimumHeight)
            .background(fill, in: shape)
            .overlay {
                if kind == .secondary {
                    shape.strokeBorder(CommonPlateStyle.Color.requestCardBorder)
                }
            }
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }

    private var fill: Color {
        switch kind {
        case .primary: return isEnabled ? Color("AccentColor") : Self.disabledFill
        case .secondary: return CommonPlateStyle.Color.baseCanvas
        }
    }

    private var labelColor: Color {
        switch kind {
        case .primary: return isEnabled ? .white : Self.disabledLabel
        case .secondary: return Color("AccentColor")
        }
    }
}
