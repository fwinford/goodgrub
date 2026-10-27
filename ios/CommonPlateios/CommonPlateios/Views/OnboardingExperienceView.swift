//
//  OnboardingExperienceView.swift
//  CommonPlateios
//
// W4-O1 first-use Welcome: one shared, role-free story that ends at the
// canonical Home. Presentation only; it creates no role or identity state.

import SwiftUI

/// Onboarding cards use the shared `commonPlateCard()` surface, the same one
/// as the Home request cards (Faith, device pass, 2026-10-22).

/// Exact accepted O1 copy, kept in one place so it can be asserted verbatim.
enum OnboardingCopy {
    static let brand = AppBrand.name
    static let heroTitle = "Meals move through the community."
    static let heroSubtitle = "Sometimes you need a meal. Sometimes you have an extra swipe to share."
    static let scrollInvitation = "See how it works"
    static let sectionLabel = "HOW \(AppBrand.nameUppercased) WORKS"
    static let continueTitle = "Continue"
    static let grubhubBadge = "Grubhub"

    struct Step: Equatable {
        let title: String
        let detail: String
        var showsGrubhubBadge = false
    }

    static let story: [Step] = [
        Step(title: "Someone posts a meal request",
             detail: "They find what they want on Grubhub, then copy the meal details into \(AppBrand.name)."),
        Step(title: "Other students can find it",
             detail: "It appears on Home, and students can get notified when a new request is posted."),
        Step(title: "Someone chooses to help",
             detail: "A student with extra swipes steps in."),
        Step(title: "They place the order",
             detail: "The helper orders through Grubhub, then shares the order details in \(AppBrand.name).",
             showsGrubhubBadge: true),
        Step(title: "The requester gets pickup information",
             detail: "\(AppBrand.name) notifies the requester when their pickup details are ready."),
        Step(title: "Then you pick it up",
             detail: "You use the pickup details to pick up your meal.")
    ]
}

enum OnboardingMotion {
    /// "Confident bounce" (Faith, CP2): two quick downward hops, the second
    /// smaller, then a rest before the cycle repeats.
    static let scrollCueTravel: CGFloat = 8
    static let scrollCueSecondBounceRatio: CGFloat = 0.5
    static let scrollCueDuration: TimeInterval = 2.0
    /// Share of each cycle spent on each hop; the remainder is rest.
    static let scrollCueBounceFraction: Double = 0.18
    static let storyCardRevealOffset: CGFloat = 8
    static let storyCardRevealDuration: TimeInterval = 0.25
    static let storyCardVisibilityThreshold: CGFloat = 0.15

    static func shouldRevealImmediately(reduceMotion: Bool, voiceOverEnabled: Bool) -> Bool {
        reduceMotion || voiceOverEnabled
    }

    /// Downward displacement at `progress` (0...1) through one cycle. Never
    /// negative, so the cue never rises toward its label; zero at both ends,
    /// so a repeating cycle has no seam.
    static func scrollCueOffset(progress: Double, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion else { return 0 }
        let p = min(max(progress, 0), 1)
        let hop = scrollCueBounceFraction
        if p < hop {
            return scrollCueTravel * CGFloat(sin(.pi * p / hop))
        }
        if p < hop * 2 {
            return scrollCueTravel * scrollCueSecondBounceRatio * CGFloat(sin(.pi * (p - hop) / hop))
        }
        return 0
    }

    static func addingVisibleStoryCards(_ visibleCards: Set<Int>, to revealedCards: Set<Int>) -> Set<Int> {
        revealedCards.union(visibleCards)
    }

    static func isStoryCardVisible(_ cardFrame: CGRect, within viewportFrame: CGRect) -> Bool {
        guard !cardFrame.isNull, !viewportFrame.isNull,
              cardFrame.width > 0, cardFrame.height > 0,
              viewportFrame.width > 0, viewportFrame.height > 0 else {
            return false
        }
        let intersection = cardFrame.intersection(viewportFrame)
        guard !intersection.isNull, !intersection.isEmpty else { return false }
        let visibleFraction = intersection.width * intersection.height
            / (cardFrame.width * cardFrame.height)
        return visibleFraction >= storyCardVisibilityThreshold
    }

    static func isStoryCardRevealed(
        index: Int,
        revealedCards: Set<Int>,
        reduceMotion: Bool
    ) -> Bool {
        reduceMotion || revealedCards.contains(index)
    }
}

private struct OnboardingScrollVisibility: Equatable {
    var viewportFrame: CGRect?
    var cardFrames: [Int: CGRect] = [:]
}

private struct OnboardingScrollVisibilityKey: PreferenceKey {
    static var defaultValue = OnboardingScrollVisibility()

    static func reduce(value: inout OnboardingScrollVisibility, nextValue: () -> OnboardingScrollVisibility) {
        let next = nextValue()
        if let viewportFrame = next.viewportFrame {
            value.viewportFrame = viewportFrame
        }
        value.cardFrames.merge(next.cardFrames, uniquingKeysWith: { _, next in next })
    }
}

struct OnboardingWelcomeView: View {
    let onContinue: () -> Void

    private static let scrollCoordinateSpace = "onboardingWelcomeScroll"

    /// Measured height of the anchored brand header, so the final story stop
    /// fills exactly the viewport visible beneath it.
    @State private var headerHeight: CGFloat = 96

    /// Presentation-only state; revealed cards stay visible when the student
    /// scrolls back without changing their geometry or content.
    @State private var scrollCueBounces = false
    @State private var revealedStoryCards: Set<Int> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private var revealsImmediately: Bool {
        OnboardingMotion.shouldRevealImmediately(
            reduceMotion: reduceMotion,
            voiceOverEnabled: voiceOverEnabled
        )
    }

    /// Icon tiles appear on the first, third, and last story cards only, and
    /// the even cards sit indented, as drawn in the approved Welcome.
    private static let cardIcons: [Int: String] = [
        0: "fork.knife", 2: "hand.raised", 5: "figure.walk"
    ]

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    heroPage(minHeight: geometry.size.height - headerHeight)
                    storySection(minHeight: geometry.size.height - headerHeight)
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: Self.scrollCoordinateSpace)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: OnboardingScrollVisibilityKey.self,
                        value: OnboardingScrollVisibility(
                            viewportFrame: proxy.frame(in: .named(Self.scrollCoordinateSpace))
                        )
                    )
                }
            )
            .onPreferenceChange(OnboardingScrollVisibilityKey.self, perform: revealVisibleStoryCards)
            // The brand header stays anchored while the story scrolls beneath.
            .safeAreaInset(edge: .top, spacing: 0) {
                brandHeader
                    .padding(.horizontal, CommonPlateStyle.Spacing.l)
                    .padding(.vertical, CommonPlateStyle.Spacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CommonPlateStyle.Color.baseCanvas)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { headerHeight = proxy.size.height }
                                .onChange(of: proxy.size.height) { _, height in
                                    headerHeight = height
                                }
                        }
                    )
            }
        }
        .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
        .accessibilityIdentifier("onboarding-welcome")
    }

    private var brandHeader: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
            Text(OnboardingCopy.brand)
                .font(.commonPlateBrandDisplay(.title))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func heroPage(minHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: CommonPlateStyle.Spacing.xl)

            VStack(spacing: CommonPlateStyle.Spacing.m) {
                Text(OnboardingCopy.heroTitle)
                    .font(.commonPlateBrandDisplay(.largeTitle))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(OnboardingCopy.heroSubtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: CommonPlateStyle.Spacing.xl)

            // Non-interactive invitation to scroll; deliberately not a Button.
            VStack(spacing: CommonPlateStyle.Spacing.xs) {
                Text(OnboardingCopy.scrollInvitation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(CommonPlateStyle.Color.brandText)
                    .accessibilityHidden(true)
                    .modifier(ScrollCueBounce(
                        progress: scrollCueBounces ? 1 : 0,
                        reduceMotion: reduceMotion
                    ))
                    .animation(
                        reduceMotion
                            ? nil
                            : .linear(duration: OnboardingMotion.scrollCueDuration)
                                .repeatForever(autoreverses: false),
                        value: scrollCueBounces
                    )
            }
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                // Start on the next main-queue turn, after the Welcome header and
                // viewport have been placed, so the repeating animation carries
                // only the offset and never the cue's initial placement.
                DispatchQueue.main.async { scrollCueBounces = true }
            }
        }
        .padding(.horizontal, CommonPlateStyle.Spacing.l)
        .padding(.bottom, CommonPlateStyle.Spacing.l)
        .frame(minHeight: minHeight)
    }

    private func storySection(minHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(OnboardingCopy.sectionLabel)
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(CommonPlateStyle.Color.brandText)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, CommonPlateStyle.Spacing.l)
                .padding(.bottom, CommonPlateStyle.Spacing.m)

            VStack(spacing: 0) {
                ForEach(Array(OnboardingCopy.story.enumerated()), id: \.offset) { index, step in
                    if index > 0 { StoryConnector() }
                    let isRevealed = OnboardingMotion.isStoryCardRevealed(
                        index: index,
                        revealedCards: revealedStoryCards,
                        reduceMotion: revealsImmediately
                    )
                    OnboardingStoryCard(
                        step: step,
                        iconName: Self.cardIcons[index],
                        isIndented: index % 2 == 1
                    )
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: OnboardingScrollVisibilityKey.self,
                                value: OnboardingScrollVisibility(
                                    cardFrames: [
                                        index: proxy.frame(in: .named(Self.scrollCoordinateSpace))
                                    ]
                                )
                            )
                        }
                    )
                    .opacity(isRevealed ? 1 : 0)
                    .offset(y: isRevealed ? 0 : OnboardingMotion.storyCardRevealOffset)
                    .animation(
                        revealsImmediately
                            ? nil
                            : .easeOut(duration: OnboardingMotion.storyCardRevealDuration)
                                .delay(Double(index % 3) * 0.035),
                        value: isRevealed
                    )
                }
            }
            .padding(.horizontal, CommonPlateStyle.Spacing.l)

            Spacer(minLength: CommonPlateStyle.Spacing.xl)

            Button(OnboardingCopy.continueTitle) {
                onContinue()
            }
            .commonPlateMajorPrimaryAction()
            .padding(.horizontal, CommonPlateStyle.Metrics.homeContentColumnInset)
            .accessibilityIdentifier("onboarding-continue-to-home")
        }
        // Keeps the section label below the opening fold so the first stop is
        // only the hero and its scroll invitation.
        .padding(.top, CommonPlateStyle.Spacing.xl + CommonPlateStyle.Spacing.l)
        .padding(.bottom, CommonPlateStyle.Spacing.s)
        .frame(minHeight: minHeight, alignment: .top)
    }

    private func revealVisibleStoryCards(_ visibility: OnboardingScrollVisibility) {
        if revealsImmediately {
            revealedStoryCards.formUnion(OnboardingCopy.story.indices)
            return
        }
        guard let viewportFrame = visibility.viewportFrame else { return }
        let visibleCards = Set(visibility.cardFrames.compactMap { entry in
            OnboardingMotion.isStoryCardVisible(entry.value, within: viewportFrame)
                ? entry.key
                : nil
        })
        let newlyVisibleCards = visibleCards.subtracting(revealedStoryCards)
        guard !newlyVisibleCards.isEmpty else { return }
        revealedStoryCards = OnboardingMotion.addingVisibleStoryCards(
            newlyVisibleCards,
            to: revealedStoryCards
        )
    }
}

/// One story step as a quiet bordered card, alternately indented, as drawn in
/// the approved Welcome. Combines into a single VoiceOver element.
struct OnboardingStoryCard: View {
    let step: OnboardingCopy.Step
    let iconName: String?
    let isIndented: Bool

    private static let indent: CGFloat = 32

    var body: some View {
        HStack(alignment: .top, spacing: CommonPlateStyle.Spacing.m) {
            if let iconName {
                Image(systemName: iconName)
                    .font(.footnote.weight(.semibold))
                    // Fixed 28 pt tile: cap the decorative glyph so it stays inside.
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(
                        Color.accentColor.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: CommonPlateStyle.Spacing.s) {
                    Text(step.title)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if step.showsGrubhubBadge {
                        Spacer(minLength: CommonPlateStyle.Spacing.s)
                        GrubhubTextBadge()
                    }
                }
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, CommonPlateStyle.Spacing.m)
        .padding(.vertical, CommonPlateStyle.Spacing.m)
        .commonPlateCard()
        .padding(.leading, isIndented ? Self.indent : 0)
        .padding(.trailing, isIndented ? 0 : Self.indent)
        .accessibilityElement(children: .combine)
    }
}

/// The short purple-dotted link between story cards that keeps the vertical
/// story reading as one continuous flow rather than six unrelated cards.
private struct StoryConnector: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.accentColor.opacity(0.22))
                .frame(width: 1.5)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 5, height: 5)
        }
        .frame(height: 20)
        .accessibilityHidden(true)
    }
}

/// The approved text-only `Grubhub` badge with a restrained orange tint. No
/// logo, mark, or third-party asset; this exception is not extended elsewhere.
private struct GrubhubTextBadge: View {
    private static let orange = Color(red: 0.96, green: 0.45, blue: 0.10)
    /// Mirrors the approved H1 Grubhub text values (light 156/71/0, dark
    /// 255/170/90) so the badge text stays legible in dark appearance.
    private static let text = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 170 / 255, blue: 90 / 255, alpha: 1)
            : UIColor(red: 156 / 255, green: 71 / 255, blue: 0, alpha: 1)
    })

    var body: some View {
        Text(OnboardingCopy.grubhubBadge)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Self.text)
            .padding(.horizontal, CommonPlateStyle.Spacing.s)
            .padding(.vertical, 2)
            .background(Self.orange.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(Self.orange.opacity(0.35), lineWidth: 0.5))
    }
}

/// One shared top anchor prevents first launch and recurring Home from drifting
/// as their surrounding layouts evolve independently.
struct CommonPlateBrandHeader: View {
    var body: some View {
        VStack(spacing: CommonPlateStyle.Spacing.xs) {
            Text(AppBrand.name)
                .font(.commonPlateBrandDisplay(.largeTitle))
            Text("at NYU")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(CommonPlateStyle.Color.campusQualifierNeutral)
        }
        .frame(maxWidth: .infinity)
    }
}

struct CommonPlateWarmGhostBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                // This control's fixed circle owns the symbol geometry. A
                // fixed symbol font keeps accessibility text sizes from
                // making the chevron protrude while nearby text still scales.
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(CommonPlateStyle.Color.warmSurface, in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(CommonPlateWarmGhostBackButtonStyle())
        .accessibilityLabel("Back")
    }
}

private struct CommonPlateWarmGhostBackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Interpolates cycle progress so the repeating linear animation draws the
/// double bounce from `OnboardingMotion.scrollCueOffset(progress:)`. Only the
/// chevron's rendered position moves; its layout slot never changes.
private struct ScrollCueBounce: GeometryEffect {
    var progress: Double
    let reduceMotion: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(
            translationX: 0,
            y: OnboardingMotion.scrollCueOffset(progress: progress, reduceMotion: reduceMotion)
        ))
    }
}
