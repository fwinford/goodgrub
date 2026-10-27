//
//  RequestCardView.swift
//  CommonPlateios
//
// The one live-exchange request card (W4-H2), used by Home for every board
// row and the Continue Helping priority item. Visual target: the approved
// H2 Figma `Request / Card` component (states Open / Your Request /
// Helping). Membership, order, and every displayed value are backend-owned;
// this view only arranges them.
import SwiftUI

/// Which H2 board treatment a card renders. `.own` and `.helping` are
/// mutually exclusive by construction — the backend's self-claim guard makes
/// it impossible for the same request to be both the caller's own request
/// and an active reservation the caller holds.
enum RequestCardKind: Equatable {
    case open
    /// W4-H2 authoritative ownership truth (`FoodRequest.isOwnRequest`).
    case own
    /// An active helper reservation, showing the authoritative remaining
    /// time until `claimExpiresAt`.
    case helping(claimExpiresAt: Date)
    /// The backend-confirmed placement is awaiting requester-authoritative
    /// pickup. These are helper-authored placement values, not pickup truth.
    case waitingForPickup(orderNumber: String, etaText: String)
}

struct RequestCardView: View {
    let request: FoodRequest
    let kind: RequestCardKind
    /// W4-R2: suppressed only inside Home's dedicated `Your request(s)`
    /// zone, which already establishes ownership contextually via its own
    /// section heading — every other `.own` placement (e.g. the shared
    /// board, before this zone existed) keeps the eyebrow. Has no effect for
    /// `.open`/`.helping`, which never show it regardless.
    var showsOwnershipEyebrow: Bool = true
    /// W4-O1 temporary first-use discovery emphasis: reuses the existing
    /// lavender helping surface/border tokens; no geometry change.
    var isDiscoveryEmphasized: Bool = false
    /// W4-R5: the requester's own lifecycle phase for an `.own` card. When set
    /// the right-hand label is the approved status pill (`Available to helpers`
    /// / `Being helped`) instead of the pickup window; a scheduled request keeps
    /// its backend window text. Never set for a helper-facing card.
    var ownerPhase: OwnerRequestPhase? = nil
    /// W4-R3 readiness attention derived from the backend estimate and
    /// server-time anchor. `nil` means the estimate is not currently known.
    var placedOrderNeedsPickupConfirmation: Bool? = nil
    /// Home and its creation-continuity overlay share the compact hierarchy.
    var isHomePresentation = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder
    var body: some View {
        if isHomePresentation, case .helping(let claimExpiresAt) = kind {
            TimelineView(.periodic(from: Self.minuteAlignedStart(for: claimExpiresAt), by: 60)) { context in
                cardContent(now: context.date)
            }
        } else {
            cardContent(now: Date())
        }
    }

    private func cardContent(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if kind == .own && showsOwnershipEyebrow {
                Text(Self.ownRequestEyebrow)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(CommonPlateStyle.Color.brandText)
                    .accessibilityIdentifier("request-card-your-request-eyebrow")
            }

            if isHomePresentation {
                homeContent
            } else {
                fullContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CommonPlateStyle.Spacing.l)
        .commonPlateCard(fill: surfaceColor(now: now), border: borderColor(now: now))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var homeContent: some View {
        if dynamicTypeSize.isAccessibilitySize {
            homeResourceTitle
            if hasHomeTrailingStatus {
                ownerOrTimingLabel
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                homeResourceTitle
                if hasHomeTrailingStatus {
                    Spacer(minLength: CommonPlateStyle.Spacing.s)
                    ownerOrTimingLabel
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }

        Text(request.diningSpot.name)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if kind == .open || kind == .own,
           let preview = Self.homeMealPreview(for: request) {
            Text(preview)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("home-request-meal-preview")
        }
    }

    private var isWaitingForPickup: Bool {
        if case .waitingForPickup = kind { return true }
        return false
    }

    private var hasHomeTrailingStatus: Bool {
        if case .helping = kind { return true }
        return kind == .own || isWaitingForPickup
    }

    private var homeResourceTitle: some View {
        Text(Self.homeResourceText(for: request))
            .font(.headline)
            .lineSpacing(request.resource.estimatedDiningDollarsCents == nil ? 0 : -2)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var fullContent: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                quantityTitle
                ownerOrTimingLabel
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                quantityTitle
                Spacer(minLength: CommonPlateStyle.Spacing.s)
                ownerOrTimingLabel
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }

        Text(request.diningSpot.name)
            .font(.subheadline)
            .foregroundStyle(.secondary)

        let meals = RequestMealEntry.entries(for: request)
        if meals.isEmpty {
            Text(Self.mealLines(for: request))
                .font(.body)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(meals.enumerated()), id: \.offset) { _, meal in
                    RequestMealView(entry: meal, density: .compact)
                }
            }
            .accessibilityIdentifier("request-card-meals")
        }

        if case .helping = kind {
            Text(Self.continueLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CommonPlateStyle.Color.brandText)
                .padding(.top, 2)
                .accessibilityIdentifier("request-card-continue-label")
        }
    }

    /// A Meal Exchange top-up is a bare amount on its own second line
    /// ("+ $15.00"), so it never splits across the status column.
    private var quantityTitle: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.mealSwipesOrDollarsText(for: request))
            if let topUp = Self.cardTopUpText(for: request) {
                Text(topUp)
            }
        }
        .font(.headline)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var ownerOrTimingLabel: some View {
        switch (kind, ownerPhase) {
        case (.own, _) where request.status == .placed:
            placedOrderStatus
        case (.own, .available?):
            ownerStatusPill(Self.availableToHelpersLabel, color: CommonPlateStyle.Color.timing)
        case (.own, .reserved?):
            ownerStatusPill(Self.beingHelpedLabel, color: Self.beingHelpedColor)
        case (.own, .scheduled?) where isHomePresentation:
            if let start = request.windowStart {
                ownerStatusPill(Self.homeScheduledStatus(start: start), color: CommonPlateStyle.Color.timing)
            }
        case (.waitingForPickup, _):
            ownerStatusPill(Self.waitingForPickupLabel, color: Self.orderedColor)
        case (.helping(let claimExpiresAt), _):
            // Redraw on whole-minute boundaries of the deadline so Home agrees
            // with the Helping screen and the 5-minute warning. Still whole
            // minutes only, never a seconds countdown.
            TimelineView(.periodic(from: Self.minuteAlignedStart(for: claimExpiresAt), by: 60)) { context in
                Group {
                    if isHomePresentation {
                        // Neutral status dot like owner statuses; a clock
                        // replaces it only inside the warning window.
                        HStack(spacing: Self.homeHelpingIndicatorSpacing) {
                            if Self.isHelpingTimeUrgent(until: claimExpiresAt, now: context.date) {
                                Image(systemName: "clock")
                                    .accessibilityHidden(true)
                                    .accessibilityIdentifier("request-card-helping-clock")
                            } else {
                                Circle()
                                    .frame(width: 8, height: 8)
                                    .accessibilityHidden(true)
                                    .accessibilityIdentifier("request-card-helping-dot")
                            }
                            Text(Self.remainingTimeText(until: claimExpiresAt, now: context.date))
                        }
                        .accessibilityElement(children: .combine)
                    } else {
                        Text(Self.remainingTimeText(until: claimExpiresAt, now: context.date))
                    }
                }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(
                        isHomePresentation
                            ? Self.homeHelpingTimeColor(until: claimExpiresAt, now: context.date)
                            : CommonPlateStyle.Color.timing
                    )
            }
        default:
            if !isHomePresentation {
                Text(timingText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CommonPlateStyle.Color.timing(isUrgent: isUrgentTiming))
            }
        }
    }

    /// The non-Home timing treatment retains its existing ASAP emphasis.
    private var isUrgentTiming: Bool {
        if case .helping = kind { return false }
        return request.timing == .asap
    }

    @ViewBuilder
    private var placedOrderStatus: some View {
        if placedOrderNeedsPickupConfirmation == true {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityHidden(true)
                Text(Self.confirmPickupLabel)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isHomePresentation ? Self.homePickupAttentionColor : Self.pickupAttentionColor)
            .frame(height: 16)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("request-card-confirm-pickup")
        } else {
            HStack(spacing: 5) {
                Circle().fill(Self.orderedColor).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(Self.mealOrderedLabel)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Self.orderedColor)
            .frame(height: 16)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("request-card-meal-ordered")
        }
    }

    /// Figma R3 Home lifecycle tokens (`#257E62` ordered, `#B8506E` attention).
    static let orderedColor = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 94 / 255, green: 196 / 255, blue: 160 / 255, alpha: 1)
            : UIColor(red: 37 / 255, green: 126 / 255, blue: 98 / 255, alpha: 1)
    })
    static let pickupAttentionColor = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 230 / 255, green: 155 / 255, blue: 174 / 255, alpha: 1)
            : UIColor(red: 184 / 255, green: 80 / 255, blue: 110 / 255, alpha: 1)
    })
    static let homePickupAttentionColor = CommonPlateStyle.Color.homeUrgentStatus

    /// Same type as the timing label it replaces, so the trailing header slot
    /// reads identically whether the card is owned or not; only the leading
    /// status dot and semantic color differ.
    private func ownerStatusPill(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
        }
        .accessibilityIdentifier("request-card-owner-status")
    }

    static let availableToHelpersLabel = "Available to helpers"
    static let beingHelpedLabel = "Being helped"
    static let beingHelpedColor = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 214 / 255, green: 170 / 255, blue: 84 / 255, alpha: 1)
            : UIColor(red: 132 / 255, green: 92 / 255, blue: 24 / 255, alpha: 1)
    })

    private var needsPickupAttention: Bool {
        kind == .own && request.status == .placed && placedOrderNeedsPickupConfirmation == true
    }

    private func surfaceColor(now: Date) -> Color {
        if needsPickupAttention {
            return isHomePresentation
                ? CommonPlateStyle.Color.homeUrgentCardSurface
                : CommonPlateStyle.Color.attentionCardSurface
        }
        if case .helping(let claimExpiresAt) = kind, isHomePresentation {
            return Self.homeHelpingCardSurface(until: claimExpiresAt, now: now)
        }
        if isDiscoveryEmphasized { return CommonPlateStyle.Color.helpingCardSurface }
        switch kind {
        case .open, .own:
            return CommonPlateStyle.Color.requestCardSurface
        case .helping, .waitingForPickup:
            return CommonPlateStyle.Color.helpingCardSurface
        }
    }

    private func borderColor(now: Date) -> Color {
        if needsPickupAttention {
            return isHomePresentation
                ? CommonPlateStyle.Color.homeUrgentCardBorder
                : CommonPlateStyle.Color.attentionCardBorder
        }
        if case .helping(let claimExpiresAt) = kind, isHomePresentation {
            return Self.homeHelpingCardBorder(until: claimExpiresAt, now: now)
        }
        if isDiscoveryEmphasized { return CommonPlateStyle.Color.helpingCardBorder }
        switch kind {
        case .open, .own:
            return CommonPlateStyle.Color.requestCardBorder
        case .helping, .waitingForPickup:
            return CommonPlateStyle.Color.helpingCardBorder
        }
    }

    /// The right-aligned timing badge. `.helping` shows authoritative
    /// remaining time to `claimExpiresAt`; every other card shows the
    /// backend-derived timing: `ASAP` or `Today · 6:30 PM`, formatted from
    /// the authoritative `windowStart` in campus time (`RequestTimingLabels`).
    private var timingText: String {
        switch kind {
        case .open, .own:
            return request.cardTimingLabel()
        case .helping(let claimExpiresAt):
            return Self.remainingTimeText(until: claimExpiresAt)
        case .waitingForPickup:
            return Self.waitingForPickupLabel
        }
    }

    static let ownRequestEyebrow = "YOUR REQUEST"
    static let mealOrderedLabel = "Your meal was ordered"
    static let confirmPickupLabel = "Confirm pickup"
    static let continueLabel = "Continue →"
    static let waitingForPickupLabel = "Waiting for pickup"

    static func mealSwipesText(_ count: Int) -> String {
        count == 1 ? "1 meal swipe" : "\(count) meal swipes"
    }

    /// A Dining Dollars request has no swipes, so its amount takes the
    /// swipe count's place instead of showing "0 meal swipes".
    static func mealSwipesOrDollarsText(for request: FoodRequest) -> String {
        if request.resource.menuPath == .diningDollars,
           let cents = request.resource.estimatedDiningDollarsCents {
            return "\(DiningDollarsEntry.formatted(cents: cents)) Dining Dollars"
        }
        return mealSwipesText(request.mealSwipes)
    }

    static func cardTopUpText(for request: FoodRequest) -> String? {
        guard request.resource.menuPath == .mealExchange,
              let cents = request.resource.estimatedDiningDollarsCents else { return nil }
        return "+\u{00A0}\(DiningDollarsEntry.formatted(cents: cents))"
    }

    static func homeResourceText(for request: FoodRequest) -> String {
        guard let cents = request.resource.estimatedDiningDollarsCents else {
            return mealSwipesText(request.mealSwipes)
        }
        let dollars = "\(DiningDollarsEntry.formatted(cents: cents)) Dining Dollars"
        if request.resource.menuPath == .diningDollars { return dollars }
        return "\(mealSwipesText(request.mealSwipes)) + \(dollars)"
    }

    static func homeMealPreview(for request: FoodRequest) -> String? {
        guard request.resource.menuPath == .mealExchange,
              let first = request.resource.mealItems.first,
              !first.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let additional = request.resource.mealItems.count - 1
        return first.name + (additional > 0 ? " + \(additional) more" : "")
    }

    static let homeHelpingIndicatorSpacing: CGFloat = 5

    static func isHelpingTimeUrgent(until claimExpiresAt: Date, now: Date) -> Bool {
        claimExpiresAt.timeIntervalSince(now) <= 5 * 60
    }

    static func homeHelpingTimeColor(until claimExpiresAt: Date, now: Date) -> Color {
        isHelpingTimeUrgent(until: claimExpiresAt, now: now)
            ? CommonPlateStyle.Color.homeUrgentStatus
            : beingHelpedColor
    }

    static func homeHelpingCardSurface(until claimExpiresAt: Date, now: Date) -> Color {
        isHelpingTimeUrgent(until: claimExpiresAt, now: now)
            ? CommonPlateStyle.Color.homeUrgentCardSurface
            : CommonPlateStyle.Color.helpingCardSurface
    }

    static func homeHelpingCardBorder(until claimExpiresAt: Date, now: Date) -> Color {
        isHelpingTimeUrgent(until: claimExpiresAt, now: now)
            ? CommonPlateStyle.Color.homeUrgentCardBorder
            : CommonPlateStyle.Color.helpingCardBorder
    }

    static func homeScheduledStatus(start: Date, now: Date = Date()) -> String {
        let time = RequestTimingLabels.clockText(start)
        if NYUCampusTime.calendar.isDate(start, inSameDayAs: now), start >= now {
            return "Scheduled for \(time)"
        }
        let date = start.formatted(
            Date.FormatStyle(timeZone: NYUCampusTime.timeZone).month(.abbreviated).day()
        )
        return "Scheduled for \(date) · \(time)"
    }

    static func quantityText(for request: FoodRequest) -> String {
        if request.resource.menuPath == .diningDollars,
           let cents = request.resource.estimatedDiningDollarsCents {
            return "\(DiningDollarsEntry.formatted(cents: cents)) Dining Dollars"
        }
        if request.resource.menuPath == .mealExchange,
           let cents = request.resource.estimatedDiningDollarsCents {
            return "\(mealSwipesText(request.mealSwipes)) + \(DiningDollarsEntry.formatted(cents: cents)) Dining Dollars"
        }
        return mealSwipesText(request.mealSwipes)
    }

    /// The order text without the backend's trailing "($X Dining Dollars)"
    /// suffix when the header already shows that amount.
    static func bodyText(for request: FoodRequest) -> String {
        guard let cents = request.resource.estimatedDiningDollarsCents else {
            return request.foodDescription
        }
        let amount = "\(DiningDollarsEntry.formatted(cents: cents)) Dining Dollars"
        let suffix = request.resource.menuPath == .diningDollars ? " (\(amount))" : " + \(amount)"
        guard request.foodDescription.hasSuffix(suffix) else { return request.foodDescription }
        return String(request.foodDescription.dropLast(suffix.count))
    }

    /// The order text one meal per line. The backend joins multiple meals with
    /// "; "; detail screens show each on its own line, compact cards do not.
    static func mealLines(for request: FoodRequest) -> String {
        bodyText(for: request).components(separatedBy: "; ").joined(separator: "\n")
    }

    /// Authoritative deadline, presented as whole minutes remaining — never
    /// a live countdown timer (M1: quiet/immediate, no new gesture or timer
    /// architecture). Floors at "Reserved" rather than a negative/zero
    /// reading, since an actually-expired reservation is reconciled by the
    /// existing accepted reservation lifecycle, not by this label.
    /// A past instant whole minutes before `claimExpiresAt`, so a periodic
    /// schedule ticks exactly when the whole-minute reading changes.
    static func minuteAlignedStart(for claimExpiresAt: Date, now: Date = Date()) -> Date {
        let minutesBack = max(0, ceil(claimExpiresAt.timeIntervalSince(now) / 60)) + 1
        return claimExpiresAt.addingTimeInterval(-minutesBack * 60)
    }

    static func remainingTimeText(until claimExpiresAt: Date, now: Date = Date()) -> String {
        let remainingSeconds = claimExpiresAt.timeIntervalSince(now)
        let remainingMinutes = Int(ceil(remainingSeconds / 60))
        guard remainingMinutes > 0 else {
            return "Reserved"
        }
        return remainingMinutes == 1 ? "1 min left" : "\(remainingMinutes) min left"
    }
}
