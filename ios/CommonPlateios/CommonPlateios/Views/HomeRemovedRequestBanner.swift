//
//  HomeRemovedRequestBanner.swift
//  CommonPlateios
//
// W4-U1.2 CP5: the neutral Home notice for a request moderation removed. It is
// shown only while `RequestStore.showsOwnerRemovalNotice` is true, carries the
// approved copy verbatim, and offers the existing support action. It names no
// request, reporter, reason or rule.
import SwiftUI

struct HomeRemovedRequestBanner: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let onDismiss: () -> Void

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: CommonPlateStyle.Spacing.s))
            : AnyLayout(HStackLayout(alignment: .top, spacing: CommonPlateStyle.Spacing.s))
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: CommonPlateStyle.Spacing.s) {
                layout {
                    Image(systemName: "info.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text(RequestRemovedPresentation.message)
                        .font(.footnote.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("home-notice-request-removed-message")
                }
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("home-notice-request-removed-dismiss")
            }
            CommonPlateSupportAction(title: RequestRemovedPresentation.supportActionTitle)
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier("home-notice-request-removed-contact-support")
        }
        .padding(.leading, CommonPlateStyle.Spacing.m)
        .padding(.vertical, CommonPlateStyle.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            CommonPlateStyle.Color.helpingCardSurface,
            in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-notice-request-removed")
    }
}
