//
//  CommonPlateStyle.swift
//  CommonPlateios
//
// Shared Subtle Warmth design tokens (W4-F1): the disciplined brand tint, a
// warm-neutral accent surface, and a small spacing/radius scale, so touched
// screens draw from one shared vocabulary instead of inventing one-off
// values. This is presentation only — it carries no product or lifecycle
// behavior and must not be read as one.
import SwiftUI
import UIKit
import CoreText

enum CommonPlateStyle {
    /// Colors beyond what `Color.accentColor` (the `AccentColor` asset) and
    /// the standard system semantic colors already provide. Primary actions,
    /// links, and brand accents should prefer `.tint(.accentColor)` /
    /// `.buttonStyle(.borderedProminent)`, which already read the same brand
    /// asset — these are the few cases that need the value directly.
    enum Color {
        /// The shared base canvas for full-page F1/H2 screens. Uses the
        /// approved H2 Figma page-background token
        /// (`var(--h2-color-background)`, `#fbf9f6`) rather than plain
        /// `.systemBackground`: stark system white was the exact "still
        /// feels incredibly white" simulator finding, and this asset is what
        /// actually carries Subtle Warmth's "warm-neutral system foundation"
        /// the old doc comment here already claimed but the literal system
        /// color never provided. Deliberately distinct from, and quieter
        /// than, `warmSurface`'s bounded-block tint — this is the page wash
        /// `warmSurface`'s own doc comment says it must not become. The dark
        /// appearance reuses `warmSurface`'s existing accepted dark value (no
        /// separate dark direction exists in the current Figma, which is
        /// light-mode only); brand character still comes from hierarchy and
        /// the restrained accent, not a page wash.
        static let baseCanvas = SwiftUI.Color("CommonPlateBaseCanvas")

        /// W4-B1 GoodGrub brand roles. The terracotta `#AD563D` reference is
        /// the `AccentColor` asset itself (`brandFill`): fills and white-label
        /// controls use it in both appearances. Small brand *text* cannot use
        /// the fill directly (4.1–4.8:1 on light cards, 3.0:1 on dark), so
        /// `brandText` is a separate role with measured values.
        static let brandFill = SwiftUI.Color("AccentColor")
        static let brandText = SwiftUI.Color("CommonPlateBrandText")

        /// The one secondary-action surface: a light terracotta wash with a
        /// subtle terracotta border, used by every secondary button style.
        static let secondaryActionFill = brandFill.opacity(0.12)
        static let secondaryActionBorder = brandFill.opacity(0.4)

        /// Campus identity (NYU purple) is a qualifier, not the brand. Before
        /// verification the qualifier is neutral; after it, it may carry the
        /// campus color. Presentation only: it never changes eligibility.
        static let campusQualifierNeutral = SwiftUI.Color.secondary
        static let campusQualifierCampus = SwiftUI.Color("CommonPlateCampusPurple")

        static func campusQualifier(isVerified: Bool) -> SwiftUI.Color {
            isVerified ? campusQualifierCampus : campusQualifierNeutral
        }

        /// Neutral warm-gray roles (Faith's GoodGrub color decision): terracotta
        /// is reserved for brand and primary actions, so screenshot
        /// field-origin provenance (always paired with a source label), request
        /// timing/status text, and the drawn mock of a third-party screen are
        /// neutral. They share values today but stay separate roles.
        static let provenance = SwiftUI.Color("CommonPlateProvenance")
        static let timing = SwiftUI.Color("CommonPlateTiming")
        /// Genuinely urgent timing (an ASAP pickup) keeps an expressive warm
        /// emphasis instead of the neutral `timing`. Shares terracotta-family
        /// values with `brandText` today but is its own role; the label text
        /// ("ASAP") carries the meaning for anyone who cannot see the color.
        static let urgentTiming = SwiftUI.Color("CommonPlateUrgentTiming")
        static func timing(isUrgent: Bool) -> SwiftUI.Color {
            isUrgent ? urgentTiming : timing
        }
        static let illustration = SwiftUI.Color("CommonPlateIllustration")

        /// W4-H2 Settings fidelity: a plain, native "cleaner/lighter" row
        /// card — the approved Figma's About & Help / Request Alerts row
        /// grouping — distinct from `warmSurface`'s deliberate warm-neutral
        /// tint, which this area does not use.
        static let settingsRowSurface = SwiftUI.Color(uiColor: .secondarySystemBackground)

        /// Faith-selected V1 Settings (Figma `1517:6979` / `1517:7075`): the
        /// grouped About & Help card and the Sign Out destructive role.
        static let settingsGroupSurface = adaptive(
            light: (255, 251, 248), dark: (50, 43, 38)
        )
        static let settingsGroupDivider = adaptive(
            light: (232, 220, 210), dark: (91, 77, 68)
        )
        static let destructiveText = adaptive(
            light: (175, 47, 59), dark: (243, 160, 167)
        )
        static let homeUrgentStatus = adaptive(
            light: (162, 74, 82), dark: (243, 160, 167)
        )
        static let destructiveFill = adaptive(
            light: (255, 248, 246), dark: (56, 41, 42)
        )
        static let destructiveBorder = adaptive(
            light: (197, 96, 104), dark: (178, 107, 113)
        )

        /// A restrained warm-neutral surface for a bounded, grouped block of
        /// related content. Not a global background wash or a per-fact card
        /// fill. Native identity/settings sections intentionally do not use
        /// this treatment.
        static let warmSurface = SwiftUI.Color("CommonPlateWarmSurface")

        /// W4-H2 live-exchange request card surface/border — the approved
        /// Figma `--h2-color-surface-request` / `--h2-color-border-request`
        /// tokens. Distinct from `warmSurface`: the exchange board's ordinary
        /// request cards use a slightly different warm tone than a generic
        /// grouped-content block.
        ///
        /// W4-R5: adaptive. Light values are the approved light tokens, unchanged.
        /// Dark values were sampled from the approved dark Figma frames (Home
        /// Being Helped `1212:7964`, Request detail Available `1215:8017`);
        /// W4-B1 color refresh moves the dark pair from a purple-tinted gray to
        /// a warm neutral on the warm-brown canvas (Faith, 2026-10-19). This is
        /// the shared Home Request/Card surface, so every consumer follows it.
        static let requestCardSurface = adaptive(
            light: (245, 239, 232), dark: (50, 44, 40)
        )
        static let requestCardBorder = adaptive(
            light: (231, 221, 212), dark: (76, 68, 60)
        )

        /// W4-H2 Continue Helping active-reservation card surface/border —
        /// the approved Figma `--h2-color-surface-helping` /
        /// `--h2-color-border-helping` tokens, distinguishing an active
        /// reservation from an ordinary open request at a glance. GoodGrub
        /// color refresh: a warm-neutral (sand/clay) surface replaces the
        /// inherited lavender; shades await Faith's Simulator review.
        static let helpingCardSurface = adaptive(
            light: (240, 228, 216), dark: (62, 48, 42)
        )
        static let helpingCardBorder = adaptive(
            light: (222, 200, 182), dark: (92, 72, 62)
        )

        /// Shared subtle urgent-red Home card treatment for Confirm pickup
        /// and helping reservations inside the five-minute warning window.
        static let homeUrgentCardSurface = adaptive(
            light: (248, 233, 231), dark: (57, 43, 45)
        )
        static let homeUrgentCardBorder = adaptive(
            light: (236, 205, 208), dark: (98, 68, 72)
        )
        static let attentionCardSurface = adaptive(
            light: (248, 233, 231), dark: (66, 44, 54)
        )
        static let attentionCardBorder = adaptive(
            light: (236, 205, 208), dark: (104, 66, 80)
        )

        /// A color with an explicit light and dark value (0-255 RGB).
        private static func adaptive(
            light: (Double, Double, Double),
            dark: (Double, Double, Double)
        ) -> SwiftUI.Color {
            SwiftUI.Color(uiColor: UIColor { traits in
                let rgb = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(
                    red: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, alpha: 1
                )
            })
        }
    }

    /// A small spacing scale. Prefer these over ad hoc padding numbers on
    /// touched surfaces so spacing reads as one system rather than a
    /// per-screen guess.
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 20
        static let xl: CGFloat = 32
    }

    /// Modest corner radii, deliberately short of pill-shaped. Subtle Warmth
    /// prefers native control shapes; this exists for the few grouped
    /// surfaces (see `Color.warmSurface`) that need one.
    enum Radius {
        static let standard: CGFloat = 12
    }

    /// Shared action geometry deliberately reads as a rounded rectangle, not
    /// a capsule. The fixed minimum preserves a comfortable native tap target
    /// while the label's system type stays proportionate to display moments.
    enum Control {
        static let minimumHeight: CGFloat = 48
        static let majorActionMinimumHeight: CGFloat = 52
        /// On ordinary phones this is intentionally about four-fifths of the
        /// usable content width, so R1's major actions feel substantial but
        /// not like full-width form controls. Smaller/Dynamic Type layouts
        /// naturally use their available width instead of clipping.
        static let majorActionMaximumWidth: CGFloat = 292
    }

    /// W4-H2 shared Empty/Unavailable state-presentation grammar (Figma
    /// nodes 34:90, 35:90): both states center their title/body content
    /// inside this width so they read as two states of the same board
    /// rather than two different layouts.
    enum Metrics {
        static let stateContentWidth: CGFloat = 322
        /// Approved Figma Settings page margin (`o5VXC3QZWs4w9tQ8drVRC4`,
        /// node `82:255`): 18pt on each side — measurably narrower than the
        /// general-purpose `Spacing.l` (20pt) token, which read as slightly
        /// too wide/spread against the Figma Design in Faith's simulator
        /// review.
        static let settingsPageInset: CGFloat = 18
        /// Approved Figma Settings row-content inset, applied on top of
        /// `settingsPageInset` so row text/controls land at the Figma-exact
        /// 34pt from the screen edge (18 + 16) — e.g. the identity email,
        /// Request Alerts row labels/toggles, and About & Help row titles
        /// all measure to this same combined inset in the approved Design.
        static let settingsRowInset: CGFloat = 16
        /// W4-H4 final shared-content-column reconciliation: the one
        /// horizontal inset authority for the live Home board — ownership
        /// request cards, `Needs help right now` request cards, and the
        /// persistent `Request a Meal` CTA all apply this same value rather
        /// than each being sized independently. Deliberately its own named
        /// token rather than reusing `Spacing.l` (20pt) directly: `Spacing.l`
        /// remains the general-purpose scale step used across many unrelated
        /// screens, and widening it globally would restyle those screens
        /// too. A modest step up from `Spacing.l` moves Home's runtime
        /// proportions closer to the approved H2 Figma without the dramatic
        /// narrowing a jump to `Spacing.xl` (32pt) would produce.
        static let homeContentColumnInset: CGFloat = 24
    }
}

extension Font {
    /// Restrained Quiet Fraunces brand/display typography (W4-F1). The
    /// embedded Fraunces variable font and its SIL OFL notice live in
    /// `Resources/Fonts` and `Resources/Licenses`, respectively. This helper
    /// is reserved for rare, clearly display-oriented brand moments (e.g. the
    /// `CommonPlate` wordmark), never functional UI. Buttons, form controls,
    /// settings rows, instructions, metadata, body copy, and status/error
    /// text stay in system SF typography.
    ///
    /// `UIFontMetrics` scales the selected variable-font instance for the
    /// requested text style rather than freezing the wordmark at a fixed
    /// point size. If registration ever fails, the matching system Dynamic
    /// Type font is the safe fallback.
    static func commonPlateBrandDisplay(_ style: Font.TextStyle) -> Font {
        Font(CommonPlateStyle.BrandDisplay.uiFont(for: style))
    }

    /// Environment-aware variant: passing the view's `dynamicTypeSize` makes
    /// the display font track the size the view is actually rendered at, not
    /// only the device-wide category read when the font is built.
    static func commonPlateBrandDisplay(
        _ style: Font.TextStyle,
        dynamicTypeSize: DynamicTypeSize
    ) -> Font {
        Font(CommonPlateStyle.BrandDisplay.uiFont(for: style, dynamicTypeSize: dynamicTypeSize))
    }
}

extension CommonPlateStyle {
    /// Quiet Fraunces is CommonPlate's restrained application of Fraunces,
    /// not a separate proprietary typeface. Keeping its registered name and
    /// display scale here makes the only supported use explicit and testable.
    enum BrandDisplay {
        static let fontName = "Fraunces-Regular"

        /// Quiet Fraunces is a tuned Fraunces instance: softness gives the
        /// wordmark its gentle character, while WONK is explicitly off and a
        /// medium display weight keeps it calm rather than playful or heavy.
        /// These are implementation settings, not pixel-level product values.
        static let quietVariationAxes: [String: CGFloat] = [
            "SOFT": 55,
            "WONK": 0,
            "wght": 520
        ]

        static func pointSize(for style: Font.TextStyle) -> CGFloat {
            switch style {
            case .largeTitle: return 34
            case .title: return 28
            case .title2: return 22
            case .title3: return 20
            default: return 17
            }
        }

        static func uiFont(for style: Font.TextStyle) -> UIFont {
            let textStyle = uiTextStyle(for: style)
            let pointSize = pointSize(for: style)
            guard let baseFont = UIFont(name: fontName, size: pointSize) else {
                return UIFont.preferredFont(forTextStyle: textStyle)
            }

            let descriptor = baseFont.fontDescriptor.addingAttributes([
                UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): variationDictionary
            ])
            let quietFraunces = UIFont(descriptor: descriptor, size: pointSize)
            return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: quietFraunces)
        }

        /// Same font, scaled for an explicit Dynamic Type size (see
        /// `Font.commonPlateBrandDisplay(_:dynamicTypeSize:)`).
        static func uiFont(for style: Font.TextStyle, dynamicTypeSize: DynamicTypeSize) -> UIFont {
            let textStyle = uiTextStyle(for: style)
            let traits = UITraitCollection(
                preferredContentSizeCategory: contentSizeCategory(for: dynamicTypeSize)
            )
            guard let baseFont = UIFont(name: fontName, size: pointSize(for: style)) else {
                return UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traits)
            }
            let descriptor = baseFont.fontDescriptor.addingAttributes([
                UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): variationDictionary
            ])
            let quietFraunces = UIFont(descriptor: descriptor, size: pointSize(for: style))
            return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: quietFraunces, compatibleWith: traits)
        }

        private static func contentSizeCategory(for size: DynamicTypeSize) -> UIContentSizeCategory {
            switch size {
            case .xSmall: return .extraSmall
            case .small: return .small
            case .medium: return .medium
            case .large: return .large
            case .xLarge: return .extraLarge
            case .xxLarge: return .extraExtraLarge
            case .xxxLarge: return .extraExtraExtraLarge
            case .accessibility1: return .accessibilityMedium
            case .accessibility2: return .accessibilityLarge
            case .accessibility3: return .accessibilityExtraLarge
            case .accessibility4: return .accessibilityExtraExtraLarge
            case .accessibility5: return .accessibilityExtraExtraExtraLarge
            @unknown default: return .large
            }
        }

        private static var variationDictionary: [NSNumber: NSNumber] {
            Dictionary(uniqueKeysWithValues: quietVariationAxes.map { tag, value in
                (NSNumber(value: fourCharacterCode(tag)), NSNumber(value: Double(value)))
            })
        }

        private static func fourCharacterCode(_ tag: String) -> UInt32 {
            tag.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
        }

        private static func uiTextStyle(for style: Font.TextStyle) -> UIFont.TextStyle {
            switch style {
            case .largeTitle: return .largeTitle
            case .title: return .title1
            case .title2: return .title2
            case .title3: return .title3
            case .headline: return .headline
            case .subheadline: return .subheadline
            case .body: return .body
            case .callout: return .callout
            case .footnote: return .footnote
            case .caption: return .caption1
            case .caption2: return .caption2
            @unknown default: return .body
            }
        }
    }
}

extension View {
    /// The one request-card surface: Home cards, How GoodGrub Works and Welcome
    /// cards, and other card-like blocks share this fill, border and corner
    /// shape. Callers supply padding and may override the colors for status
    /// variants (for example an active-reservation card).
    func commonPlateCard(
        fill: Color = CommonPlateStyle.Color.requestCardSurface,
        border: Color = CommonPlateStyle.Color.requestCardBorder,
        cornerRadius: CGFloat = CommonPlateStyle.Radius.standard
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(fill, in: shape)
            .overlay(shape.strokeBorder(border, lineWidth: 1))
    }
}
