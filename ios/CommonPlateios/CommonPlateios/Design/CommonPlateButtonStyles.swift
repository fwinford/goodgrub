//
//  CommonPlateButtonStyles.swift
//  CommonPlateios
//
// Shared primary/secondary/destructive action conventions (W4-F1). These
// name an intended hierarchy; they change no button's action, availability,
// or destination.
import SwiftUI

extension View {
    /// The screen's one primary action.
    func commonPlatePrimaryAction() -> some View {
        buttonStyle(CommonPlateFilledActionStyle())
    }

    /// A secondary, still-first-class action alongside a primary one.
    func commonPlateSecondaryAction() -> some View {
        commonPlateSecondaryAction(minimumHeight: CommonPlateStyle.Control.minimumHeight)
    }

    func commonPlateSecondaryAction(minimumHeight: CGFloat) -> some View {
        buttonStyle(CommonPlateSoftActionStyle(minimumHeight: minimumHeight))
    }

    /// The R1 major-action family is intentionally narrower and more tactile
    /// than ordinary form/actions. Keeping this separate prevents a visual
    /// polish pass from silently changing controls owned by other slices.
    func commonPlateMajorPrimaryAction() -> some View {
        buttonStyle(CommonPlateMajorFilledActionStyle())
    }

    func commonPlateMajorSecondaryAction() -> some View {
        buttonStyle(CommonPlateMajorSoftActionStyle())
    }

    /// The centered width shared by R1's major primary and secondary actions.
    /// The outer inset keeps the controls intentionally narrower on phones;
    /// the cap preserves that proportion on wider layouts without imposing an
    /// unsafe fixed width on small screens or wrapped Dynamic Type labels.
    func commonPlateMajorActionFrame() -> some View {
        frame(maxWidth: CommonPlateStyle.Control.majorActionMaximumWidth)
            .frame(maxWidth: .infinity)
    }

    /// A destructive action presented inline beside a secondary action (e.g.
    /// Sign Out in Settings' identity section). Red outline and text on a
    /// faint red wash, never a solid red fill; neutral gray when disabled.
    func commonPlateDestructiveAction() -> some View {
        buttonStyle(CommonPlateDestructiveButtonStyle())
    }

    /// A tertiary, low-emphasis action (e.g. a footer link) that must not
    /// visually compete with the screen's primary/secondary actions.
    func commonPlateTertiaryAction() -> some View {
        buttonStyle(.plain)
            .font(.footnote)
            .modifier(CommonPlateTextActionColor(enabledColor: CommonPlateStyle.Color.brandText))
    }
}

/// Shared rectangular action construction. A moderate 12-point continuous
/// radius keeps controls soft without letting a large native control turn
/// into a capsule. Both label and geometry are system-native in spirit, while
/// their proportions intentionally harmonize with the quieter display type.
private struct CommonPlateFilledActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isEnabled ? Color.white : Color.primary)
            .commonPlateActionLabelLayout()
            .background(
                RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                    .fill(isEnabled ? Color.accentColor : Color.gray.opacity(0.28))
            )
            .opacity(configuration.isPressed && isEnabled ? 0.82 : 1)
    }
}

private struct CommonPlateSoftActionStyle: ButtonStyle {
    var minimumHeight: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isEnabled ? CommonPlateStyle.Color.brandText : Color.secondary)
            .commonPlateActionLabelLayout(minimumHeight: minimumHeight)
            .commonPlateSecondaryActionSurface(isEnabled: isEnabled)
            .opacity(configuration.isPressed && isEnabled ? 0.82 : 1)
    }
}

/// R1's only elevated controls. The low-opacity shadow is intentional
/// separation from the canvas, not a card/floating-button treatment.
private struct CommonPlateMajorFilledActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .foregroundStyle(isEnabled ? Color.white : Color.primary)
            .commonPlateMajorActionLabelLayout()
            .background(
                RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                    .fill(isEnabled ? Color.accentColor : Color.gray.opacity(0.28))
            )
            .shadow(color: .black.opacity(isEnabled ? 0.18 : 0), radius: 4, y: 2)
            .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed && isEnabled ? 0.88 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct CommonPlateMajorSoftActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .foregroundStyle(isEnabled ? CommonPlateStyle.Color.brandText : Color.secondary)
            .commonPlateMajorActionLabelLayout()
            .commonPlateSecondaryActionSurface(isEnabled: isEnabled)
            .shadow(color: .black.opacity(isEnabled ? 0.18 : 0), radius: 4, y: 2)
            .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed && isEnabled ? 0.88 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Flat R1 tertiary actions retain their hierarchy while still answering a
/// tap immediately. Reduce Motion needs no special branch because no geometry
/// changes in this treatment.
struct CommonPlateFlatActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.62 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

private extension View {
    /// The single source of the secondary-action fill and border, shared by
    /// the standard and major secondary styles.
    func commonPlateSecondaryActionSurface(isEnabled: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
        return background(shape.fill(isEnabled ? CommonPlateStyle.Color.secondaryActionFill : Color.gray.opacity(0.16)))
            .overlay(shape.strokeBorder(isEnabled ? CommonPlateStyle.Color.secondaryActionBorder : Color.gray.opacity(0.3), lineWidth: 1))
    }

    /// Buttons keep a comfortable 48-point minimum at ordinary text sizes,
    /// but never an exact height: wrapping accessibility labels may grow the
    /// control vertically. Internal padding belongs inside the shared style so
    /// every consumer has enough room before its outer layout constrains it.
    func commonPlateActionLabelLayout(minimumHeight: CGFloat = CommonPlateStyle.Control.minimumHeight) -> some View {
        multilineTextAlignment(.center)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, CommonPlateStyle.Spacing.l)
            .padding(.vertical, CommonPlateStyle.Spacing.m)
            .frame(
                maxWidth: .infinity,
                minHeight: minimumHeight
            )
    }

    func commonPlateMajorActionLabelLayout() -> some View {
        multilineTextAlignment(.center)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, CommonPlateStyle.Spacing.l)
            .padding(.vertical, CommonPlateStyle.Spacing.m)
            .frame(
                maxWidth: .infinity,
                minHeight: CommonPlateStyle.Control.majorActionMinimumHeight
            )
    }
}

private struct CommonPlateTextActionColor: ViewModifier {
    let enabledColor: Color
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.foregroundStyle(isEnabled ? enabledColor : .secondary)
    }
}

private struct CommonPlateDestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
        return configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isEnabled ? CommonPlateStyle.Color.destructiveText : Color.secondary)
            .commonPlateActionLabelLayout()
            .background(shape.fill(isEnabled ? CommonPlateStyle.Color.destructiveFill : Color.gray.opacity(0.16)))
            .overlay(shape.strokeBorder(isEnabled ? CommonPlateStyle.Color.destructiveBorder : Color.gray.opacity(0.3), lineWidth: 1))
            .opacity(configuration.isPressed && isEnabled ? 0.82 : 1)
    }
}
