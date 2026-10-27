//
//  HowCommonPlateWorksViews.swift
//  CommonPlateios
//
// W4-O1 Settings → How CommonPlate Works reference hub and its two detail
// screens. Stateless: it neither reads nor changes onboarding or discovery
// state, and `Return to Home` only clears the navigation path.

import SwiftUI

enum HowCommonPlateWorksCopy {
    static let hubTitle = "How \(AppBrand.name) Works"
    static let hubPremise = "Request a meal. Help when you can."
    static let hubOverview =
        "\(AppBrand.name) connects students who need a meal with students who have extra swipes to share."

    static let requestingDestinationTitle = "Requesting a meal"
    static let requestingDestinationDetail =
        "How to post what you need and what happens when someone helps."
    static let helpingDestinationTitle = "Helping someone"
    static let helpingDestinationDetail =
        "How to choose a request, place the order, and send pickup details back."

    static let requestingLede = "Post what you need so another student can choose to help."
    static let requestingSteps: [OnboardingCopy.Step] = [
        .init(title: "Create your request",
              detail: "Share the meal details another student needs to understand what you’re asking for."),
        .init(title: "Other students can find it",
              detail: "Your request appears on Home so an eligible student can choose to help."),
        .init(title: "Pickup details come back to you",
              detail: "You’ll get the order details and an idea of when to pick it up.")
    ]

    static let helpingLede = "Use an extra swipe to help fulfill another student’s request."
    static let helpingSteps: [OnboardingCopy.Step] = [
        .init(title: "Find a request",
              detail: "Eligible requests appear on Home when another student needs help."),
        .init(title: "Choose to help",
              detail: "Open a request and choose to take it on."),
        .init(title: "Place the order in Grubhub",
              detail: "Use your extra swipes to place the requested order."),
        .init(title: "Send the pickup details back",
              detail: "Return the order information through \(AppBrand.name) so the requester knows what to pick up.")
    ]

    static let returnToHome = "Return to Home"
}

struct HowCommonPlateWorksHubView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.l) {
                VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.s) {
                    Text(HowCommonPlateWorksCopy.hubPremise)
                        .font(.commonPlateBrandDisplay(.title2))
                        .accessibilityAddTraits(.isHeader)
                    Text(HowCommonPlateWorksCopy.hubOverview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: CommonPlateStyle.Spacing.m) {
                    destination(
                        route: .howRequestingWorks,
                        icon: "fork.knife",
                        title: HowCommonPlateWorksCopy.requestingDestinationTitle,
                        detail: HowCommonPlateWorksCopy.requestingDestinationDetail,
                        identifier: "how-works-requesting"
                    )
                    destination(
                        route: .howHelpingWorks,
                        icon: "hand.raised",
                        title: HowCommonPlateWorksCopy.helpingDestinationTitle,
                        detail: HowCommonPlateWorksCopy.helpingDestinationDetail,
                        identifier: "how-works-helping"
                    )
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(CommonPlateStyle.Spacing.l)
        }
        .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
        .navigationTitle(HowCommonPlateWorksCopy.hubTitle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("how-commonplate-works-hub")
    }

    private func destination(
        route: AppRoute,
        icon: String,
        title: String,
        detail: String,
        identifier: String
    ) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: CommonPlateStyle.Spacing.m) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    // Fixed 36 pt tile: cap the decorative glyph so it stays inside.
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(
                        Color.accentColor.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(CommonPlateStyle.Spacing.m)
            .commonPlateCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

struct HowCommonPlateWorksDetailView: View {
    let title: String
    let lede: String
    let steps: [OnboardingCopy.Step]
    let identifier: String
    let onReturnHome: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.l) {
                Text(lede)
                    .font(.commonPlateBrandDisplay(.title3))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        ReferenceStepRow(
                            number: index + 1,
                            step: step,
                            isLast: index == steps.count - 1
                        )
                    }
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(CommonPlateStyle.Spacing.l)
        }
        .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
        // The standard bottom action, same placement and width as Home's.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(HowCommonPlateWorksCopy.returnToHome) {
                onReturnHome()
            }
            .commonPlateMajorPrimaryAction()
            .padding(.horizontal, CommonPlateStyle.Metrics.homeContentColumnInset)
            .padding(.top, CommonPlateStyle.Spacing.s)
            .frame(maxWidth: .infinity)
            .background(CommonPlateStyle.Color.baseCanvas)
            .accessibilityIdentifier("how-works-return-home")
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(identifier)
    }
}

/// A numbered reference step: a small lavender marker joined to the next by a
/// quiet vertical line, as drawn in the approved Settings detail screens.
private struct ReferenceStepRow: View {
    let number: Int
    let step: OnboardingCopy.Step
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: CommonPlateStyle.Spacing.m) {
            ZStack(alignment: .top) {
                if !isLast {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(width: 2)
                        .padding(.top, 26)
                }
                Text("\(number)")
                    .font(.caption.weight(.semibold))
                    // Fixed 24 pt marker: cap so the numeral stays inside it.
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(CommonPlateStyle.Color.brandText)
                    .frame(width: 24, height: 24)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
            }
            .frame(width: 24)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, isLast ? 0 : CommonPlateStyle.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
