//
//  HomeNoticeBanner.swift
//  CommonPlateios
//
// The approved Figma Home notice (`Request withdrawn`, `Your <vendor> request
// expired`, `Couldn't open this request`): a quiet lavender banner under the
// header with one line of title, an optional second line, and a dismiss ✕.
// Presentation only: it decides nothing, and dismissal is the caller's
// acknowledgment of a notice the store already holds.
import SwiftUI

/// What a restricted (suspended) account is offered. Presentation only: the
/// restriction is the store's affirmative `isParticipantRestricted` marker
/// (`GET /api/participant/restriction`) and the backend still refuses posting
/// and helping on its own authority, so nothing here is a policy decision.
enum RestrictedAccountPresentation {
    static let title = "Account restricted"
    static let detail =
        "You can't post or help with new requests. Existing order information remains available when applicable."
    static let helpingNotice = "Your account is restricted. You can't help with new requests."

    static func offersRequestAMeal(isRestricted: Bool) -> Bool { !isRestricted }
    static func offersNewClaim(isRestricted: Bool) -> Bool { !isRestricted }
}

struct HomeRestrictionBanner: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // The icon and text share a row; the support action sits on its own line
        // below at the banner's leading edge. At accessibility sizes the icon
        // stacks above instead of taking width from the copy.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: CommonPlateStyle.Spacing.s))
            : AnyLayout(HStackLayout(alignment: .top, spacing: CommonPlateStyle.Spacing.s))
        VStack(alignment: .leading, spacing: 2) {
            layout {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(RestrictedAccountPresentation.title)
                        .font(.footnote.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(RestrictedAccountPresentation.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            CommonPlateSupportAction(title: "Contact support")
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier("home-restriction-contact-support")
        }
        .padding(.horizontal, CommonPlateStyle.Spacing.m)
        .padding(.vertical, CommonPlateStyle.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            CommonPlateStyle.Color.helpingCardSurface,
            in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-notice-account-restricted")
    }
}

struct HomeNoticeBanner: View {
    enum Icon: Equatable {
        case check
        case clock
        case none

        var symbolName: String? {
            switch self {
            case .check: return "checkmark"
            case .clock: return "clock"
            case .none: return nil
            }
        }
    }

    let icon: Icon
    let title: String
    var detail: String? = nil
    let identifier: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: CommonPlateStyle.Spacing.s) {
            if let symbol = icon.symbolName {
                Image(systemName: symbol)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(CommonPlateStyle.Color.brandText)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: CommonPlateStyle.Spacing.s)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("\(identifier)-dismiss")
        }
        .padding(.leading, CommonPlateStyle.Spacing.m)
        .padding(.vertical, 2)
        .background(
            CommonPlateStyle.Color.helpingCardSurface,
            in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}
