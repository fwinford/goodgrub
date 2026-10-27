//
//  RequestFoodFormValidation.swift
//  CommonPlateios
//

import Foundation

/// W4-R4 exact currency entry.
///
/// Dining Dollars are held as the requester's own text while they type and
/// converted to an exact integer count of cents for validation and
/// submission. The conversion is done by integer arithmetic on the digits
/// themselves — never by parsing into a `Double` and scaling — so a value the
/// requester typed can never acquire floating-point rounding behaviour on its
/// way to the backend. `12.34` is exactly `1234`, always.
enum DiningDollarsEntry: Equatable {
    /// The requester typed nothing. On the Meal Exchange path this is valid
    /// and means "no Dining Dollars needed"; it is never read as `$0.00`.
    case empty
    /// An exact, positive amount in cents.
    case cents(Int)
    /// Text that is not an amount at all, or an amount of zero. Zero is
    /// invalid rather than empty-equivalent: a requester who typed `0` said
    /// something different from a requester who typed nothing, and neither
    /// should silently become the other.
    case invalid

    /// Parses ordinary dollar entry: optional `$`, optional thousands
    /// separators, and at most two decimal places.
    static func parse(_ text: String) -> DiningDollarsEntry {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }

        var normalized = trimmed
        if normalized.hasPrefix("$") { normalized.removeFirst() }
        normalized = normalized.trimmingCharacters(in: .whitespaces)
        if normalized.isEmpty { return .invalid }

        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return .invalid }

        guard let wholeText = ungroupedWholeDollars(String(parts[0])) else {
            return .invalid
        }
        let fractionText = parts.count == 2 ? String(parts[1]) : ""

        // A bare "." or ".50" is accepted for the fraction, but the whole part
        // must be digits when present, and the fraction at most two digits.
        guard wholeText.allSatisfy(isASCIIDigit),
              fractionText.allSatisfy(isASCIIDigit),
              fractionText.count <= 2,
              !(wholeText.isEmpty && fractionText.isEmpty) else {
            return .invalid
        }

        let dollars = wholeText.isEmpty ? 0 : Int(wholeText)
        guard let dollars else { return .invalid }

        // Pad so "5" after the point means 50 cents, not 5.
        let paddedFraction = fractionText.padding(
            toLength: 2,
            withPad: "0",
            startingAt: 0
        )
        let fraction = paddedFraction.isEmpty ? 0 : Int(paddedFraction)
        guard let fraction else { return .invalid }

        // Integer arithmetic throughout. The per-path ceilings are far under
        // any overflow threshold, but a pasted 30-digit number must be
        // refused rather than trapping.
        let (scaled, scaleOverflowed) = dollars.multipliedReportingOverflow(by: 100)
        guard !scaleOverflowed else { return .invalid }
        let (total, addOverflowed) = scaled.addingReportingOverflow(fraction)
        guard !addOverflowed else { return .invalid }
        return total > 0 ? .cents(total) : .invalid
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    /// The whole-dollar digits with thousands separators removed — but only
    /// when every separator is in a real thousands position (`1,234`,
    /// `12,345,678`). Anything else (`1,2`, `12,34`, `1,,234`, `,123`,
    /// `1234,567`) is `nil`: a misplaced comma is a typo whose intended
    /// amount is unknown, and stripping it would silently post a different
    /// number than the one on screen.
    private static func ungroupedWholeDollars(_ text: String) -> String? {
        guard text.contains(",") else { return text }
        let groups = text.split(separator: ",", omittingEmptySubsequences: false)
        guard let leading = groups.first,
              (1...3).contains(leading.count),
              groups.dropFirst().allSatisfy({ $0.count == 3 }) else {
            return nil
        }
        return groups.joined()
    }

    /// Exact cents to the display string, by the same integer arithmetic the
    /// backend uses (`formatDiningDollars`, `src/structuredRequest.ts`).
    static func formatted(cents: Int) -> String {
        "$\(cents / 100).\(String(format: "%02d", cents % 100))"
    }
}

/// The requester form's editable values. This remains private to the Request
/// Food flow: its session owner may outlive a transient pushed view, but it is
/// never persisted to disk/server or shared with fulfillment.
struct RequestFoodFormDraft: Equatable {
    var selectedDiningSpot: DiningSpot?
    /// W4-R4: which menu the requester is using. Requester-owned, with one
    /// W4-R4.1 exception: deterministic Screenshot Assistance evidence may
    /// switch it until the requester changes it after assistance has acted
    /// (`ScreenshotFieldManualEditState`).
    var menuPath: RequestMenuPath
    var timing: RequestTiming
    var preferredPickupTime: Date
    /// V1 meal-swipe requirement (W3-C1): an exact integer 1 through 5, chosen
    /// from a bounded picker rather than typed. Meaningful only on the Meal
    /// Exchange path; the submitted value for a Dining-Dollars-only request is
    /// exactly 0, derived in `activeMealSwipes` rather than stored here, so
    /// switching paths and switching back does not destroy the requester's
    /// swipe choice.
    var mealSwipes: Int

    /// W4-R4 meal-detail entries, always exactly `maxMealSwipes` long.
    ///
    /// This fixed length is the whole preservation mechanism. Lowering the
    /// swipe count changes which entries are *active* — and therefore which
    /// are shown and which are submitted — without touching the array, so a
    /// requester who drops from 4 swipes to 2 and back to 4 finds entries 3
    /// and 4 exactly as they left them. Nothing is destroyed on the way down
    /// and nothing is reconstructed on the way up, because nothing moved.
    ///
    /// Entries above the active count are excluded from the submitted request
    /// by `activeMealEntries` regardless of what they contain.
    var mealEntries: [MealItem]

    /// The single structured order-details value a Dining-Dollars-only
    /// request requires. Preserved across a path switch for the same reason
    /// hidden meal entries are: the requester's typing is theirs.
    var orderDetails: String

    /// W4-R4.1: the two Dining Dollars drafts are distinct domains and are
    /// never copied into, derived from, or reinterpreted as each other.
    ///
    /// The Meal Exchange branch's optional Dining Dollars TOP-UP, as typed.
    /// Empty means "none needed" and is never rendered or submitted as `$0.00`.
    var mealExchangeDiningDollarsText: String

    /// The Dining-Dollars-only branch's required whole-order amount, as typed.
    var diningDollarsOnlyText: String

    /// The amount text of the ACTIVE branch — the only one validation and
    /// submission ever read, and the one the form field edits. Writing it
    /// changes only the active branch's value; the inactive branch keeps its
    /// draft untouched (no capping, zeroing, truncating, or copying).
    var diningDollarsText: String {
        get {
            switch menuPath {
            case .mealExchange: return mealExchangeDiningDollarsText
            case .diningDollars: return diningDollarsOnlyText
            }
        }
        set {
            switch menuPath {
            case .mealExchange: mealExchangeDiningDollarsText = newValue
            case .diningDollars: diningDollarsOnlyText = newValue
            }
        }
    }

    init(
        selectedDiningSpot: DiningSpot? = nil,
        menuPath: RequestMenuPath = .mealExchange,
        timing: RequestTiming = .asap,
        preferredPickupTime: Date = Date(),
        mealSwipes: Int = RequestFoodFormDraft.mealSwipeOptions.first!,
        mealEntries: [MealItem] = RequestFoodFormDraft.emptyMealEntries,
        orderDetails: String = "",
        diningDollarsText: String = "",
        mealExchangeDiningDollarsText: String = "",
        diningDollarsOnlyText: String = ""
    ) {
        self.selectedDiningSpot = selectedDiningSpot
        self.menuPath = menuPath
        self.timing = timing
        self.preferredPickupTime = preferredPickupTime
        self.mealSwipes = mealSwipes
        // Normalized so the fixed-length invariant holds no matter what a
        // caller supplies: a shorter array is padded and a longer one is
        // truncated, rather than silently changing what "active" means.
        self.mealEntries = RequestFoodFormDraft.normalized(mealEntries)
        self.orderDetails = orderDetails
        self.mealExchangeDiningDollarsText = mealExchangeDiningDollarsText
        self.diningDollarsOnlyText = diningDollarsOnlyText
        // `diningDollarsText` is the long-standing single-value parameter: a
        // non-empty value is the ACTIVE branch's amount (for both the former
        // flat callers and D2 payload restoration, which carries only the
        // submitted branch's amount).
        if !diningDollarsText.isEmpty {
            self.diningDollarsText = diningDollarsText
        }
    }

    /// Test/support convenience for the former flat draft callers. It
    /// normalizes immediately into the canonical `MealItem` storage; no
    /// second draft representation is retained or sent on the wire.
    init(
        selectedDiningSpot: DiningSpot? = nil,
        menuPath: RequestMenuPath = .mealExchange,
        timing: RequestTiming = .asap,
        preferredPickupTime: Date = Date(),
        mealSwipes: Int = RequestFoodFormDraft.mealSwipeOptions.first!,
        mealEntries: [String],
        orderDetails: String = "",
        diningDollarsText: String = "",
        mealExchangeDiningDollarsText: String = "",
        diningDollarsOnlyText: String = ""
    ) {
        self.init(
            selectedDiningSpot: selectedDiningSpot,
            menuPath: menuPath,
            timing: timing,
            preferredPickupTime: preferredPickupTime,
            mealSwipes: mealSwipes,
            mealEntries: mealEntries.map { MealItem(name: $0) },
            orderDetails: orderDetails,
            diningDollarsText: diningDollarsText,
            mealExchangeDiningDollarsText: mealExchangeDiningDollarsText,
            diningDollarsOnlyText: diningDollarsOnlyText
        )
    }

    /// The exact bounded set the picker may offer and the backend accepts on
    /// the Meal Exchange path.
    static let mealSwipeOptions = Array(1...5)

    static let maxMealSwipes = 5

    static let emptyMealEntries = Array(repeating: MealItem(name: ""), count: maxMealSwipes)

    static func normalized(_ entries: [MealItem]) -> [MealItem] {
        if entries.count == maxMealSwipes { return entries }
        if entries.count > maxMealSwipes { return Array(entries.prefix(maxMealSwipes)) }
        return entries + Array(repeating: MealItem(name: ""), count: maxMealSwipes - entries.count)
    }

    /// The swipe count this draft actually submits: the requester's choice on
    /// the Meal Exchange path, and exactly 0 on the Dining-Dollars-only one.
    var activeMealSwipes: Int {
        menuPath == .mealExchange ? mealSwipes : 0
    }

    /// The indices whose meal fields are currently visible and required.
    var activeMealEntryIndices: Range<Int> {
        0..<activeMealSwipes
    }

    /// Exactly the entries this draft submits, trimmed. Entries above the
    /// active count — the ones a lowered swipe count hid — are excluded here,
    /// which is the single place that exclusion happens.
    var activeMealEntries: [MealItem] {
        activeMealEntryIndices.map {
            MealItem(
                name: mealEntries[$0].name.trimmingCharacters(in: .whitespacesAndNewlines),
                details: mealEntries[$0].details?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// The parsed estimate of the ACTIVE branch. `.empty` on the Meal
    /// Exchange path is valid and means no Dining Dollars are needed.
    var diningDollars: DiningDollarsEntry {
        DiningDollarsEntry.parse(diningDollarsText)
    }

    /// The accepted ceiling for the path this draft is currently on.
    var diningDollarsCeilingCents: Int {
        menuPath == .mealExchange
            ? RequestFoodFormDraft.mealExchangeDiningDollarsCeilingCents
            : RequestFoodFormDraft.diningDollarsOnlyCeilingCents
    }

    /// `> $0.00` and `<= $25.00` when supplied alongside meal swipes.
    static let mealExchangeDiningDollarsCeilingCents = 2_500
    /// `> $0.00` and `<= $50.00` when it is the whole request.
    static let diningDollarsOnlyCeilingCents = 5_000

    /// W4-D2 Path A: restores exactly what the frozen `CreateRequestPayload`
    /// itself carries — nothing reconstructed, guessed, or content-matched.
    /// Only called when `RequestStore` has confirmed the payload behind a
    /// terminal NO-CREATE was actually readable.
    ///
    /// `selectedDiningSpot.address` is `nil`: the payload carries only the
    /// vendor name, matching `DiningSpot`'s existing "wire-sourced, address
    /// unavailable" shape (see its declaration). `mealSwipes` falls back to
    /// the picker's own first option when the payload's is `0` (the
    /// Dining-Dollars-only path's submitted value), since the stored property
    /// is only ever meaningful on the Meal Exchange path and must stay within
    /// the picker's bounded set. Only the submitted branch's amount is
    /// restored (the payload carries nothing about the inactive branch's
    /// session draft, which cannot be reconstructed).
    init(restoring payload: CreateRequestPayload) {
        self.init(
            selectedDiningSpot: DiningSpot(name: payload.vendor, address: nil),
            menuPath: payload.menuPath.domainMenuPath,
            timing: payload.timing == .scheduled ? .later : .asap,
            preferredPickupTime: payload.windowStart ?? Date(),
            mealSwipes: payload.mealSwipes > 0
                ? payload.mealSwipes
                : RequestFoodFormDraft.mealSwipeOptions.first!,
            mealEntries: RequestFoodFormDraft.normalized(payload.mealItems),
            orderDetails: payload.orderDetails ?? "",
            diningDollarsText: payload.estimatedDiningDollarsCents
                .map(DiningDollarsEntry.formatted(cents:)) ?? ""
        )
    }
}

enum RequestFoodFormError: Error, Equatable {
    case missingDiningSpot
    /// A required, currently active meal-detail entry is blank (W4-R4).
    case missingMealDetail(index: Int)
    /// The Dining-Dollars-only path's required order-details value is blank.
    case missingOrderDetails
    /// Dining-Dollars-only requires an estimate; it cannot be left empty.
    case missingDiningDollars
    /// The estimate is not an amount, is zero, or exceeds the path's ceiling.
    case invalidDiningDollars(ceilingCents: Int)
    case invalidScheduledTime
    /// A `Later` selection that outlived scheduling itself. Distinct from
    /// `invalidScheduledTime` because the correction is different: there is no
    /// pickup time left to choose today, only ASAP.
    case scheduledTimingUnavailable

    /// A required entry value that has simply not been entered yet. It blocks
    /// posting (`validate` still reports it and `hasRequiredInput` still fails)
    /// but is never *presented* as an error: emptiness is incomplete, not
    /// invalid. Only an entered-but-wrong value earns visible feedback.
    var isIncompleteEntry: Bool {
        switch self {
        case .missingMealDetail, .missingOrderDetails, .missingDiningDollars:
            return true
        case .missingDiningSpot, .invalidDiningDollars, .invalidScheduledTime,
             .scheduledTimingUnavailable:
            return false
        }
    }

    var message: String {
        switch self {
        case .missingDiningSpot:
            return "Choose an NYU dining spot."
        case .missingMealDetail:
            return "Tell us what this meal swipe is for."
        case .missingOrderDetails:
            return "Tell us what to order."
        case .missingDiningDollars:
            return "Enter how many Dining Dollars this order needs."
        case .invalidDiningDollars(let ceilingCents):
            return "Enter an amount between $0.01 and \(DiningDollarsEntry.formatted(cents: ceilingCents))."
        case .invalidScheduledTime:
            return "Choose a pickup time later today."
        case .scheduledTimingUnavailable:
            return RequestFoodView.lapsedScheduledTimingNotice
        }
    }
}

/// Request-form fields in screen order. Only text fields can receive focus;
/// pickers still participate in submit-time validation and live correction
/// after their error has been presented.
///
/// The requester's email is deliberately absent (W3-I1): it is no longer a
/// field, because the requester is the verified participant this installation
/// remembers and the backend binds the request to that principal.
///
/// Pickup name is absent too, and since W4-R4 it does not exist anywhere in
/// the request contract.
enum RequestFoodFormField: Hashable, CaseIterable {
    case diningSpot
    /// One case per meal entry, so each has its own focus target and its own
    /// inline error, exactly like any other text field. Despite the case
    /// name, this governs the meal item's NAME field (`request-meal-item-*`),
    /// not its separate Details field — `focusedMealDetailsIndex` in
    /// `RequestFoodView` tracks Details' focus independently. Renaming this
    /// case would touch its other call sites across both `RequestFoodView`
    /// and `EditRequestView`, so it's left as-is.
    case mealDetail(index: Int)
    case orderDetails
    case diningDollars
    case pickupSchedule

    static var allCases: [RequestFoodFormField] {
        [.diningSpot]
            + (0..<RequestFoodFormDraft.maxMealSwipes).map { .mealDetail(index: $0) }
            + [.orderDetails, .diningDollars, .pickupSchedule]
    }

    var isTextField: Bool {
        switch self {
        case .mealDetail, .orderDetails, .diningDollars:
            return true
        case .diningSpot, .pickupSchedule:
            return false
        }
    }

    /// Fields whose rules and presentation belong to the selected menu path
    /// (Meal Exchange or Dining Dollars). Dining location and scheduling are
    /// the same on both, so a path switch never touches them.
    var isMenuPathSpecific: Bool {
        switch self {
        case .mealDetail, .orderDetails, .diningDollars:
            return true
        case .diningSpot, .pickupSchedule:
            return false
        }
    }
}

struct RequestFoodFieldError: Equatable, Identifiable {
    let field: RequestFoodFormField
    let error: RequestFoodFormError

    var id: RequestFoodFormField { field }
    var message: String { error.message }
}

/// Locally knowable request-form rules. The backend remains authoritative;
/// this validator exists only to keep obvious failures beside their fields and
/// prevent them from reaching the store.
enum RequestFoodFormValidator {
    /// Completeness for button presentation only. The timing picker is
    /// non-optional and a Later selection always carries a Date, so both of its
    /// representable states are complete. Whether that Date still fits today is
    /// validation, not completeness, and is intentionally checked on Submit.
    static func hasRequiredInput(_ draft: RequestFoodFormDraft) -> Bool {
        guard let diningSpot = draft.selectedDiningSpot,
              !diningSpot.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        switch draft.menuPath {
        case .mealExchange:
            // Every currently active meal-detail entry is required. A hidden
            // entry's content is irrelevant either way.
            guard draft.activeMealEntries.allSatisfy({ !$0.name.isEmpty }) else {
                return false
            }
            // Optional here: empty is complete, and means none are needed.
            switch draft.diningDollars {
            case .empty:
                break
            case .cents(let cents):
                guard cents <= draft.diningDollarsCeilingCents else { return false }
            case .invalid:
                return false
            }
        case .diningDollars:
            guard !draft.orderDetails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            guard case .cents(let cents) = draft.diningDollars,
                  cents <= draft.diningDollarsCeilingCents else {
                return false
            }
        }

        switch draft.timing {
        case .asap, .later:
            return true
        }
    }

    /// `isScheduledWindowValid` answers whether *this* chosen start still fits;
    /// `isScheduledTimingAvailable` answers whether any start does. Both are
    /// derived from the same time snapshot by the caller, and the pair is what
    /// separates a start the requester can correct from scheduling having closed
    /// underneath them — two failures that need different instructions, because
    /// only one of them still has a control to act on.
    static func validate(
        draft: RequestFoodFormDraft,
        isScheduledWindowValid: Bool,
        isScheduledTimingAvailable: Bool
    ) -> [RequestFoodFieldError] {
        var errors: [RequestFoodFieldError] = []

        if draft.selectedDiningSpot?.name
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            errors.append(RequestFoodFieldError(field: .diningSpot, error: .missingDiningSpot))
        }

        switch draft.menuPath {
        case .mealExchange:
            // Only the active entries are validated. A hidden entry is not a
            // failure no matter what it holds, because it is not part of this
            // request — which is the same reason it is not submitted.
            for index in draft.activeMealEntryIndices
            where draft.mealEntries[index].name
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(RequestFoodFieldError(
                    field: .mealDetail(index: index),
                    error: .missingMealDetail(index: index)
                ))
            }

            switch draft.diningDollars {
            case .empty:
                break
            case .cents(let cents) where cents > draft.diningDollarsCeilingCents:
                errors.append(RequestFoodFieldError(
                    field: .diningDollars,
                    error: .invalidDiningDollars(ceilingCents: draft.diningDollarsCeilingCents)
                ))
            case .cents:
                break
            case .invalid:
                errors.append(RequestFoodFieldError(
                    field: .diningDollars,
                    error: .invalidDiningDollars(ceilingCents: draft.diningDollarsCeilingCents)
                ))
            }

        case .diningDollars:
            if draft.orderDetails
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(RequestFoodFieldError(
                    field: .orderDetails,
                    error: .missingOrderDetails
                ))
            }

            switch draft.diningDollars {
            case .empty:
                errors.append(RequestFoodFieldError(
                    field: .diningDollars,
                    error: .missingDiningDollars
                ))
            case .cents(let cents) where cents > draft.diningDollarsCeilingCents:
                errors.append(RequestFoodFieldError(
                    field: .diningDollars,
                    error: .invalidDiningDollars(ceilingCents: draft.diningDollarsCeilingCents)
                ))
            case .cents:
                break
            case .invalid:
                errors.append(RequestFoodFieldError(
                    field: .diningDollars,
                    error: .invalidDiningDollars(ceilingCents: draft.diningDollarsCeilingCents)
                ))
            }
        }

        if draft.timing == .later && !isScheduledWindowValid {
            // Telling someone to choose a different pickup time is only useful
            // while there is a time left to choose. Once the last full window
            // has passed, the picker is gone and the only move left is ASAP —
            // so that is what this says, rather than pointing at a control the
            // form has already withdrawn.
            errors.append(RequestFoodFieldError(
                field: .pickupSchedule,
                error: isScheduledTimingAvailable
                    ? .invalidScheduledTime
                    : .scheduledTimingUnavailable
            ))
        }

        return errors
    }
}

/// View-local presentation history. A field joins this set only after its own
/// error has actually been shown, so another field's failure cannot make an
/// untouched field validate during its first keystrokes.
///
/// Incomplete entries (`RequestFoodFormError.isIncompleteEntry`) never join it
/// and are never visible, even for a field that earlier presented a real
/// invalid value: clearing a field back to empty returns it to neutral.
struct RequestFoodValidationPresentation: Equatable {
    private(set) var presentedFields: Set<RequestFoodFormField> = []

    mutating func presentInvalidField(
        _ field: RequestFoodFormField,
        from errors: [RequestFoodFieldError]
    ) {
        guard errors.contains(where: { $0.field == field && !$0.error.isIncompleteEntry }) else {
            return
        }
        presentedFields.insert(field)
    }

    mutating func presentAll(_ errors: [RequestFoodFieldError]) {
        presentedFields.formUnion(
            errors.filter { !$0.error.isIncompleteEntry }.map(\.field)
        )
    }

    /// The exact focus transition used by `RequestFoodView`. Only the invalid
    /// text field that actually lost focus is presented; programmatic changes
    /// with no previous field and sibling failures have no effect.
    mutating func handleFocusTransition(
        from previousField: RequestFoodFormField?,
        to currentField: RequestFoodFormField?,
        errors: [RequestFoodFieldError]
    ) {
        guard previousField != currentField,
              let previousField,
              previousField.isTextField else {
            return
        }
        presentInvalidField(previousField, from: errors)
    }

    /// Switching menu path starts the newly selected branch visually clean:
    /// only the branch-specific fields' presentation history is forgotten.
    /// Values are untouched, and the branch presents errors again through its
    /// ordinary blur/submit rules.
    mutating func resetMenuPathSpecificPresentation() {
        presentedFields = presentedFields.filter { !$0.isMenuPathSpecific }
    }

    /// A blur caused by the path switch itself (the focused field belonged to
    /// the branch just left) must not validate against the newly selected
    /// branch. `nil` means no focus-time path was recorded, which is an
    /// ordinary blur.
    static func blurBelongsToCurrentMenuPath(
        previousField: RequestFoodFormField?,
        menuPathAtFocus: RequestMenuPath?,
        currentMenuPath: RequestMenuPath
    ) -> Bool {
        guard let previousField, previousField.isMenuPathSpecific,
              let menuPathAtFocus else {
            return true
        }
        return menuPathAtFocus == currentMenuPath
    }

    func visibleErrors(from errors: [RequestFoodFieldError]) -> [RequestFoodFieldError] {
        errors.filter { presentedFields.contains($0.field) && !$0.error.isIncompleteEntry }
    }

    func visibleError(
        for field: RequestFoodFormField,
        from errors: [RequestFoodFieldError]
    ) -> RequestFoodFieldError? {
        visibleErrors(from: errors).first { $0.field == field }
    }
}

struct RequestFoodSubmissionResult: Equatable {
    let presentation: RequestFoodValidationPresentation
    let firstInvalidTextField: RequestFoodFormField?
    let didSubmit: Bool
}

/// W4-R2 2026-09-05 sync item 6: `RequestFoodView.submissionFailureOutcome(for:hasUnresolvedCreateAmbiguity:)`'s
/// return value — the one production-owned decision its real `submit()`
/// catch path calls verbatim, so a test can drive a real thrown error through
/// that exact function rather than only reconstructing the same decision
/// independently.
struct RequestFoodSubmissionFailureOutcome: Equatable {
    let mapped: RequestCreatePresentationError
    /// True exactly when the definitive-failure haptic and failure summary
    /// must both fire; false for every unresolved/write-uncertain ambiguity.
    let isDefinitiveFailure: Bool
}
