//
//  ScreenshotHelpView.swift
//  CommonPlateios
//
// W4-R2 Screenshot Help, recreated from the approved product-safe Figma
// sources (overview `220:696`, cart `267:1051`, past order `267:1073`).
// These are authored SwiftUI illustrations, never personal screenshots or
// assets from `eval/` / research fixtures.
import SwiftUI

enum ScreenshotExampleKind: String, CaseIterable, Identifiable {
    case cart
    case pastOrder

    var id: String { rawValue }

    var overviewTitle: String {
        switch self {
        case .cart: return "Your pickup order"
        case .pastOrder: return "A past order"
        }
    }

    var detailTitle: String {
        switch self {
        case .cart: return "Pickup order example"
        case .pastOrder: return "Past order example"
        }
    }

    var detailInstruction: String {
        switch self {
        case .cart:
            return "Use the screen before checkout where your food items are visible."
        case .pastOrder:
            return "Open a previous order so the food items and modifiers are visible."
        }
    }
}

/// Large centered first-use guidance matching Figma's `Requester / Notice
/// Modal`. Its parent owns the dimmed local overlay; example enlargement uses
/// popup-local state, never another `NavigationStack` or the app/root route.
struct ScreenshotHelpView: View {
    let onDismiss: () -> Void
    @State private var selectedExample: ScreenshotExampleKind?
    /// Independent-review fix: every runtime-measurement strategy tried here
    /// — `.scrollBounceBehavior(.basedOnSize)` (disproven: it never touches
    /// the size a `ScrollView` *reports* during layout, only rubber-band
    /// feel), `.fixedSize(horizontal: false, vertical: true)` (disproven: it
    /// could leave oversized content merely clipped rather than in a real
    /// scrollable viewport), `GeometryReader`/`PreferenceKey` measurement
    /// (confirmed, via a direct `UIHostingController` layout diagnostic
    /// against this exact content, to never settle to a real measured value
    /// in this app's runtime — `.onPreferenceChange` never fired past the
    /// key's default regardless of where the reader was placed), and
    /// `ViewThatFits` (confirmed by the same diagnostic to select its
    /// correct, non-scrolling candidate for *content*, but to still report
    /// its own outer size as the full ancestor proposal rather than the
    /// chosen candidate's real size, centering that smaller content and
    /// leaving equal dead space above and below it — this is the actual
    /// mechanism behind the reported dead space) — all failed for reasons
    /// specific to *measuring this content at runtime*, not to the concept
    /// of a bounded/scrollable card. `dynamicTypeSize` sidesteps runtime
    /// measurement entirely: it's a plain `@Environment` read, resolved
    /// synchronously during `body`, with none of the proposal-negotiation or
    /// preference-propagation behavior above. Ordinary Dynamic Type sizes
    /// are direct-measured (via this same diagnostic) to need ~420pt, well
    /// under `maxOverviewHeight` — `overviewContent` alone reliably hugs to
    /// that real height (also confirmed via the diagnostic: a plain,
    /// non-scrolling view always reports its own true content size,
    /// regardless of what its parent proposes). Accessibility Dynamic Type
    /// sizes may exceed that; only those use the height-capped `ScrollView`.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The same modal-height budget `RequestFoodView` proposes via its own
    /// `.frame(width: 314).frame(maxHeight: maxOverviewHeight)` wrapper —
    /// named here so the accessibility-size `ScrollView` fallback below caps
    /// itself to the same value that wrapper already caps the whole card to.
    static let maxOverviewHeight: CGFloat = 480

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        _selectedExample = State(initialValue: nil)
    }

    var body: some View {
        Group {
            if let selectedExample {
                // Regression fix: `ScreenshotExampleDetailView` owns a
                // `ScrollView` of its own (for the instruction copy plus the
                // enlarged mock) with no height bound of its own — it relies
                // entirely on an ancestor to cap it. That ancestor used to be
                // `RequestFoodView`'s unconditional `.frame(maxHeight: 480)`
                // wrapper; making that wrapper `nil` at ordinary sizes (the
                // overview dead-space fix) correctly let `overview` hug its
                // own small content, but also removed detail's only bound,
                // so its `ScrollView` expanded to the full ambient screen
                // height — the near-full-screen card, the large empty region
                // below the enlarged example, and the header/Back control
                // pushed up near the status area are all one direct
                // consequence of that missing bound, not a separate bug.
                // Detail's `ScrollView` always needs a bound (unlike
                // `overview`, which only needs one at accessibility sizes),
                // so this cap is unconditional here, restoring detail's
                // previously accepted bounded/centered presentation at every
                // size. `onBack`/`selectedExample` remain entirely local to
                // this view; nothing here touches Request Food's own
                // navigation.
                ScreenshotExampleDetailView(kind: selectedExample) {
                    self.selectedExample = nil
                }
                .frame(maxHeight: Self.maxOverviewHeight)
            } else {
                overview
            }
        }
        .tint(Color.accentColor)
    }

    private var overview: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView {
                    overviewContent
                }
                .frame(maxHeight: Self.maxOverviewHeight)
            } else {
                overviewContent
            }
        }
        .frame(maxWidth: .infinity)
        .background(CommonPlateStyle.Color.baseCanvas)
    }

    private var overviewContent: some View {
        VStack(spacing: 10) {
            Text(Self.title)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            VStack(spacing: 0) {
                ForEach(ScreenshotExampleKind.allCases) { kind in
                    if kind != ScreenshotExampleKind.allCases.first {
                        Divider()
                    }
                    Button {
                        selectedExample = kind
                    } label: {
                        exampleRow(kind)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("screenshot-help-example-\(kind.rawValue)")
                }
            }

            Button {
                onDismiss()
            } label: {
                Text(Self.dismissLabel)
            }
            .commonPlatePrimaryAction()
            .accessibilityIdentifier("screenshot-help-dismiss")
        }
        .padding(CommonPlateStyle.Spacing.l)
        .frame(maxWidth: .infinity)
    }

    /// W4-R2 2026-09-01 sync: two light/open visual disclosure rows, not
    /// nested card-in-card treatment — the thumbnail, label, and an obvious
    /// chevron affordance sit directly on the modal's own background with a
    /// simple hairline separator, rather than each row owning its own
    /// bordered/filled card surface.
    private func exampleRow(_ kind: ScreenshotExampleKind) -> some View {
        HStack(spacing: CommonPlateStyle.Spacing.m) {
            ScreenshotExampleThumbnail(kind: kind)
                .frame(width: 64, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(kind.overviewTitle)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            CommonPlateDisclosureIndicator()
        }
        .padding(.vertical, CommonPlateStyle.Spacing.s)
        .contentShape(Rectangle())
    }

    static let title = "What should I screenshot?"
    static let dismissLabel = "Got it"
}

struct ScreenshotExampleDetailView: View {
    let kind: ScreenshotExampleKind
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: CommonPlateStyle.Spacing.s) {
                // W4-R2 2026-09-05 sync item 7: the glyph's own visual frame
                // stays 32×32; the button's effective tap target grows to at
                // least 44×44 around it via an outer frame + content shape,
                // without making the surrounding title row tappable.
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 32, height: 32)
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Back to screenshot examples")
                .accessibilityIdentifier("screenshot-example-detail-back")

                Text(kind.detailTitle)
                    .font(.headline)

                Spacer(minLength: 32)
            }
            .padding(.horizontal, CommonPlateStyle.Spacing.m)
            .padding(.top, CommonPlateStyle.Spacing.s)

            ScrollView {
                // W4-R2 2026-09-05 sync item 3: the enlarged example centered
                // in the available body area, with its explanation beneath
                // the image — not the image beneath leading-aligned copy.
                VStack(alignment: .center, spacing: 10) {
                    ScreenshotExampleMock(kind: kind)
                        .frame(
                            width: ScreenshotExampleMock.width,
                            height: ScreenshotExampleMock.height(for: kind)
                        )
                        .accessibilityIdentifier("screenshot-example-detail-illustration-\(kind.rawValue)")

                    Text(kind.detailInstruction)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(CommonPlateStyle.Spacing.l)
                .frame(maxWidth: .infinity)
            }
        }
        .background(CommonPlateStyle.Color.baseCanvas)
    }
}

/// The approved examples are intentionally stylized product-safe mockups.
/// Fixed illustration geometry preserves their Figma composition; the screen
/// copy and navigation around them remain Dynamic-Type-aware native UI.
struct ScreenshotExampleMock: View {
    static let width: CGFloat = 240
    let kind: ScreenshotExampleKind

    var body: some View {
        Group {
            switch kind {
            case .cart: cart
            case .pastOrder: pastOrder
            }
        }
        .frame(width: Self.width, height: Self.height(for: kind), alignment: .top)
        .background(CommonPlateStyle.Color.baseCanvas)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(CommonPlateStyle.Color.requestCardBorder)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind == .cart
            ? "Example pickup cart with visible food item and total"
            : "Example past order with visible food items and modifiers")
    }

    static func height(for kind: ScreenshotExampleKind) -> CGFloat {
        kind == .cart ? 260 : 338
    }

    private var cart: some View {
        VStack(spacing: 0) {
            Text("Your pickup order")
                .font(.system(size: 15, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: 38)
            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text("Pickup, ASAP").font(.system(size: 11, weight: .semibold))
                Text("Ready in 4 mins").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 47, alignment: .leading)
            .padding(.horizontal, 13)
            Divider()

            VStack(alignment: .leading, spacing: 7) {
                Text("Campus dining").font(.system(size: 13, weight: .bold))
                Text("Items: 1").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                HStack(alignment: .top) {
                    Text("Turkey and White Cheddar Sub").font(.system(size: 10))
                    Spacer()
                    Text("$6.75").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Text("−  1  +")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(CommonPlateStyle.Color.requestCardSurface, in: Capsule())
                }
                Divider()
                HStack {
                    Text("Items subtotal")
                    Spacer()
                    Text("$6.75")
                }
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
                HStack {
                    Text("Total")
                    Spacer()
                    Text("$6.75")
                }
                .font(.system(size: 9, weight: .semibold))
                Text("Continue to checkout")
                    .font(.system(size: 8.5, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 18)
                    .background(CommonPlateStyle.Color.illustration.opacity(0.38), in: Capsule())
            }
            .padding(.horizontal, 13)
            .padding(.top, 12)
        }
    }

    private var pastOrder: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("View order").font(.system(size: 15, weight: .bold))
                HStack {
                    Text("‹ Orders")
                    Spacer()
                    Text("Help")
                }
                .font(.system(size: 10))
                .foregroundStyle(CommonPlateStyle.Color.illustration)
                .padding(.horizontal, 11)
            }
            .frame(height: 40)
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("NYU")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(CommonPlateStyle.Color.illustration, in: RoundedRectangle(cornerRadius: 3))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Upstein Food Court").font(.system(size: 12, weight: .semibold))
                        Text("5-11 University Place").font(.system(size: 9)).foregroundStyle(.secondary)
                        Text("Your order · #903").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pickup").font(.system(size: 10, weight: .bold))
                    Text("Feb 5, 2024 · 5:20 pm").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 14)
            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text("Order information").font(.system(size: 13, weight: .bold))
                Text("1  Pineapple Mango Coconut").font(.system(size: 10))
                modifier("• No Side")
                modifier("• No Bag")
                Divider()
                Text("1  Create Your Own Bowl").font(.system(size: 10))
                modifier("• Mixed Greens")
                modifier("• Roasted Sweet Potato")
                modifier("• Green Goddess Dressing")
                Text("View receipt")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CommonPlateStyle.Color.illustration.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 13)
            .padding(.top, 12)
        }
    }

    private func modifier(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .padding(.leading, 14)
    }
}

struct ScreenshotExampleThumbnail: View {
    let kind: ScreenshotExampleKind

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScreenshotExampleMock(kind: kind)
                .scaleEffect(1.0 / 3.0, anchor: .topLeading)
        }
        .frame(width: 80, height: 96, alignment: .topLeading)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Illustration: \(kind.overviewTitle)")
    }
}
