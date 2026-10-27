//
//  EditRequestPresentation.swift
//  CommonPlateios
//
// W4-R5 pure rules behind Edit Request and the requester-owned detail: how the
// saved request becomes an editable draft, what counts as a change, which new
// start times may be chosen, what is sent, and which approved sentence each
// outcome earns. No state and no store: every decision is a function of its
// arguments, so each is provable without a view.
//
// Two rules are easy to get wrong and are fixed here:
//  - The original-creation-day horizon governs only a NEW timing selection.
//    An unchanged timing is never validated against it and never recalculates
//    a window (`timingChange`).
//  - An outcome the app does not know is never worded as a success or a
//    failure. `unconfirmed` is its own sentence, and it is the only one a
//    student sees for an operation the backend might have committed.
import Foundation

enum EditRequestPresentation {
    // MARK: Approved copy (Faith, 2026-10-18)

    static let screenTitle = "Edit Request"
    static let saveChangesTitle = "Save Changes"

    static let discardTitle = "Discard changes?"
    static let discardMessage = "Your edits won’t be saved."
    static let keepEditingTitle = "Keep editing"
    static let discardChangesTitle = "Discard changes"

    static let conflictMessage =
        "This request changed while you were editing. Your changes weren’t saved."
    static let unconfirmedEditMessage =
        "Something went wrong. We couldn’t confirm your changes."
    static let unconfirmedWithdrawMessage =
        "Something went wrong. We couldn’t confirm your withdrawal."
    static let saveFailedMessage = "Couldn’t save your changes. Please try again."
    static let withdrawFailedMessage = "Couldn’t withdraw this request. Please try again."
    static let horizonTonightMessage = "Start by 11:30 PM tonight."
    static let horizonPassedMessage = "The 11:30 PM cutoff has passed. The time can’t be changed."
    static let reservedEditMessage = "A helper reserved this request. Your changes weren’t saved."
    /// The Figma conflict banner for a Withdraw that lost to a reservation.
    static let reservedWithdrawMessage = "A helper has reserved this request. It wasn’t withdrawn."
    static let updatedSinceNotificationNotice =
        "This request was updated. You’re viewing the latest details."
    static let editDisabledWhileHelpedNote = "You can’t edit while someone is helping."
    static let changesSavedNotice = "Changes saved"
    static let requestWithdrawnNotice = "Request withdrawn"

    // MARK: Draft

    /// The saved request as an editable draft. Only the confirmed saved fields:
    /// the screenshot provenance and any AI proposal that once shaped them are
    /// never restored (they are not persisted).
    /// A saved request carries only its vendor name, so its spot has no address
    /// and would never equal the catalog spot a screenshot resolves to. Using
    /// the catalog spot with the same name keeps the same-venue comparison
    /// honest; an unlisted vendor is preserved exactly as saved.
    static func canonicalSpot(_ spot: DiningSpot) -> DiningSpot {
        SupportedVendorCatalog.diningSpots.first { $0.name == spot.name } ?? spot
    }

    static func draft(from owner: OwnerRequest) -> RequestFoodFormDraft {
        let request = owner.request
        let isMealExchange = request.resource.menuPath == .mealExchange
        let dollars = request.resource.estimatedDiningDollarsCents
            .map(DiningDollarsEntry.formatted(cents:)) ?? ""
        return RequestFoodFormDraft(
            selectedDiningSpot: canonicalSpot(request.diningSpot),
            menuPath: request.resource.menuPath,
            timing: request.timing,
            preferredPickupTime: request.windowStart ?? Date(),
            mealSwipes: request.mealSwipes > 0
                ? request.mealSwipes
                : RequestFoodFormDraft.mealSwipeOptions.first!,
            mealEntries: RequestFoodFormDraft.normalized(request.resource.mealItems),
            orderDetails: request.resource.orderDetails ?? "",
            mealExchangeDiningDollarsText: isMealExchange ? dollars : "",
            diningDollarsOnlyText: isMealExchange ? "" : dollars
        )
    }

    /// An unresolved edit's own submitted content as a draft, so a form locked
    /// behind an unknown outcome shows exactly what is awaiting confirmation.
    static func draft(from payload: EditRequestPayload, original: OwnerRequest) -> RequestFoodFormDraft {
        let menuPath = payload.menuPath.domainMenuPath
        let dollars = payload.estimatedDiningDollarsCents
            .map(DiningDollarsEntry.formatted(cents:)) ?? ""
        let timing: RequestTiming
        switch payload.timing {
        case .unchanged: timing = original.request.timing
        case .asap: timing = .asap
        case .scheduled: timing = .later
        }
        return RequestFoodFormDraft(
            selectedDiningSpot: canonicalSpot(DiningSpot(name: payload.vendor, address: nil)),
            menuPath: menuPath,
            timing: timing,
            preferredPickupTime: payload.windowStart ?? original.request.windowStart ?? Date(),
            mealSwipes: payload.mealSwipes > 0
                ? payload.mealSwipes
                : RequestFoodFormDraft.mealSwipeOptions.first!,
            mealEntries: RequestFoodFormDraft.normalized(payload.mealItems),
            orderDetails: payload.orderDetails ?? "",
            mealExchangeDiningDollarsText: menuPath == .mealExchange ? dollars : "",
            diningDollarsOnlyText: menuPath == .diningDollars ? dollars : ""
        )
    }

    // MARK: Timing

    /// What the edit says about timing. `unchanged` is the ordinary edit: the
    /// backend keeps the availability window exactly as it is. Anything else is
    /// an explicit new selection that recalculates it.
    struct TimingChange: Equatable {
        let timing: EditTimingWire
        let windowStart: Date?
    }

    static func timingChange(draft: RequestFoodFormDraft, original: OwnerRequest) -> TimingChange {
        switch (original.request.timing, draft.timing) {
        case (.asap, .asap):
            return TimingChange(timing: .unchanged, windowStart: nil)
        case (.asap, .later):
            return TimingChange(timing: .scheduled, windowStart: draft.preferredPickupTime)
        case (.later, .asap):
            return TimingChange(timing: .asap, windowStart: nil)
        case (.later, .later):
            if let saved = original.request.windowStart,
               abs(saved.timeIntervalSince(draft.preferredPickupTime)) < 1 {
                return TimingChange(timing: .unchanged, windowStart: nil)
            }
            return TimingChange(timing: .scheduled, windowStart: draft.preferredPickupTime)
        }
    }

    /// The latest start a *new* selection may have: 11:30 PM America/New_York on
    /// the request's **original** creation day, as the backend stated it.
    struct Horizon: Equatable {
        let latestStart: Date
        /// Whether any start at all can still be chosen (`now` has not passed
        /// the latest start).
        let canSchedule: Bool
        /// Whether the original creation day is still today in campus time —
        /// the only case in which "tonight" is accurate.
        let creationDayIsToday: Bool
    }

    static func horizon(owner: OwnerRequest, now: Date, calendar: Calendar = NYUCampusTime.calendar) -> Horizon {
        Horizon(
            latestStart: owner.latestScheduledStart,
            canSchedule: now <= owner.latestScheduledStart,
            creationDayIsToday: calendar.isDate(owner.request.createdAt, inSameDayAs: now)
        )
    }

    /// Whether this start may be newly selected: not in the past and not after
    /// the horizon.
    static func isSelectableStart(_ start: Date, now: Date, horizon: Horizon) -> Bool {
        start >= now && start <= horizon.latestStart
    }

    /// The sentence for an unusable new timing selection. "Tonight" only while
    /// it is accurate; otherwise the plain refusal.
    static func horizonMessage(horizon: Horizon) -> String {
        horizon.canSchedule && horizon.creationDayIsToday
            ? horizonTonightMessage
            : horizonPassedMessage
    }

    // MARK: Payload

    enum PayloadError: Error, Equatable {
        case invalid(RequestFoodFormError)
        case unusableTiming
    }

    static func makePayload(
        draft: RequestFoodFormDraft,
        owner: OwnerRequest,
        now: Date,
        calendar: Calendar = NYUCampusTime.calendar
    ) throws -> EditRequestPayload {
        guard let revision = owner.contentRevision else {
            throw PayloadError.invalid(.missingDiningSpot)
        }
        let change = timingChange(draft: draft, original: owner)
        let horizon = horizon(owner: owner, now: now, calendar: calendar)
        // Validated only for a NEW scheduled selection; an unchanged timing is
        // never held to the horizon.
        let scheduledOK: Bool
        switch change.timing {
        case .scheduled:
            scheduledOK = change.windowStart.map {
                isSelectableStart($0, now: now, horizon: horizon)
            } ?? false
        case .asap:
            // "Now" is a new timing selection too: it must start by the
            // original creation day's horizon, like a scheduled start.
            scheduledOK = horizon.canSchedule
        case .unchanged:
            scheduledOK = true
        }
        if let first = RequestFoodFormValidator.validate(
            draft: draft,
            isScheduledWindowValid: scheduledOK || draft.timing != .later,
            isScheduledTimingAvailable: horizon.canSchedule
        ).first(where: { $0.field != .pickupSchedule }) {
            throw PayloadError.invalid(first.error)
        }
        if !scheduledOK { throw PayloadError.unusableTiming }
        guard let spot = draft.selectedDiningSpot else {
            throw PayloadError.invalid(.missingDiningSpot)
        }

        let cents: Int?
        switch draft.diningDollars {
        case .cents(let value): cents = value
        case .empty, .invalid: cents = nil
        }
        let menuPath: RequestMenuPathWire
        let mealItems: [MealItem]
        let orderDetails: String?
        switch draft.menuPath {
        case .mealExchange:
            menuPath = .mealExchange
            mealItems = draft.activeMealEntries
            orderDetails = nil
        case .diningDollars:
            menuPath = .diningDollars
            mealItems = []
            orderDetails = draft.orderDetails.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return EditRequestPayload(
            vendor: spot.name.trimmingCharacters(in: .whitespacesAndNewlines),
            menuPath: menuPath,
            mealSwipes: draft.activeMealSwipes,
            mealItems: mealItems,
            orderDetails: orderDetails,
            estimatedDiningDollarsCents: cents,
            timing: change.timing,
            windowStart: change.windowStart,
            expectedContentRevision: revision
        )
    }

    /// Whether the draft differs from the saved request: the contents the
    /// backend stores, or a new timing selection. Hidden meal entries a lowered
    /// swipe count excluded are not part of the request and never count.
    static func hasChanges(
        draft: RequestFoodFormDraft,
        owner: OwnerRequest,
        now: Date,
        calendar: Calendar = NYUCampusTime.calendar
    ) -> Bool {
        let saved = Self.draft(from: owner)
        if timingChange(draft: draft, original: owner).timing != .unchanged { return true }
        return comparable(draft) != comparable(saved)
    }

    private struct EditSnapshot: Equatable {
        let vendor: String
        let menuPath: RequestMenuPath
        let swipes: Int
        let items: [MealItem]
        let orderDetails: String
        let cents: DiningDollarsEntry
    }

    private static func comparable(_ draft: RequestFoodFormDraft) -> EditSnapshot {
        EditSnapshot(
            vendor: draft.selectedDiningSpot?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            menuPath: draft.menuPath,
            swipes: draft.activeMealSwipes,
            items: draft.menuPath == .mealExchange ? draft.activeMealEntries : [],
            orderDetails: draft.menuPath == .diningDollars
                ? draft.orderDetails.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            cents: draft.diningDollars
        )
    }

    // MARK: Outcomes

    /// Every way a Save can end, each mapped to exactly one approved sentence
    /// (or to leaving the screen for a verified-gone request).
    enum SaveOutcome: Equatable {
        case conflict
        case reserved
        case textNotAllowed
        case horizon(tonight: Bool)
        /// The request is verifiably gone; the screen leaves rather than show a
        /// form for something that no longer exists.
        case withdrawn
        case expired
        /// A definitive failure: nothing was applied.
        case saveFailed
        /// The outcome is unknown. Never worded as success or failure.
        case unconfirmedEdit
        /// An earlier *withdrawal* is unconfirmed and blocks this save.
        case unconfirmedWithdraw
    }

    static func saveOutcome(
        for error: Error,
        unresolved: PendingRequestUpdate?,
        owner: OwnerRequest,
        now: Date,
        calendar: Calendar = NYUCampusTime.calendar
    ) -> SaveOutcome {
        if RequestTextModeration.isRefusal(error) { return .textNotAllowed }
        guard let serviceError = error as? RequestServiceError else { return .saveFailed }
        switch serviceError {
        case .ambiguousUpdateOutcome:
            return .unconfirmedEdit
        case .unresolvedUpdate:
            return unresolved?.kind == .withdraw ? .unconfirmedWithdraw : .unconfirmedEdit
        case .serverError(let code, _):
            switch code {
            case RequestUpdateErrorCode.revisionConflict: return .conflict
            case RequestUpdateErrorCode.requestReserved,
                 RequestUpdateErrorCode.requestAlreadyPlaced: return .reserved
            case RequestUpdateErrorCode.horizonExceeded:
                let h = horizon(owner: owner, now: now, calendar: calendar)
                return .horizon(tonight: h.canSchedule && h.creationDayIsToday)
            case RequestUpdateErrorCode.requestWithdrawn: return .withdrawn
            // A replayed identity whose request has since left the system (its
            // ledger outlived nothing to act on): no longer ongoing work.
            case RequestUpdateErrorCode.requestExpired,
                 RequestUpdateErrorCode.operationExpired: return .expired
            default: return .saveFailed
            }
        default:
            return .saveFailed
        }
    }

    static func message(for outcome: SaveOutcome) -> String? {
        switch outcome {
        case .conflict: return conflictMessage
        case .reserved: return reservedEditMessage
        case .textNotAllowed: return RequestTextModeration.noticeCopy
        case .horizon(let tonight): return tonight ? horizonTonightMessage : horizonPassedMessage
        case .saveFailed: return saveFailedMessage
        case .unconfirmedEdit: return unconfirmedEditMessage
        case .unconfirmedWithdraw: return unconfirmedWithdrawMessage
        case .withdrawn, .expired: return nil
        }
    }

    /// The status presentation each message uses: an unconfirmed outcome is the
    /// calm "uncertain" kind (never an error), a conflict is a conflict.
    static func statusKind(for outcome: SaveOutcome) -> CommonPlateStatusKind {
        switch outcome {
        case .conflict, .reserved: return .conflict
        case .unconfirmedEdit, .unconfirmedWithdraw: return .uncertain
        case .textNotAllowed, .horizon, .saveFailed, .withdrawn, .expired: return .error
        }
    }

    /// Withdraw outcomes, parallel to `SaveOutcome`.
    enum WithdrawOutcome: Equatable {
        case reserved
        case withdrawn
        case expired
        case failed
        case unconfirmedWithdraw
        case unconfirmedEdit
    }

    static func withdrawOutcome(for error: Error, unresolved: PendingRequestUpdate?) -> WithdrawOutcome {
        guard let serviceError = error as? RequestServiceError else { return .failed }
        switch serviceError {
        case .ambiguousUpdateOutcome:
            return .unconfirmedWithdraw
        case .unresolvedUpdate:
            return unresolved?.kind == .edit ? .unconfirmedEdit : .unconfirmedWithdraw
        case .serverError(let code, _):
            switch code {
            case RequestUpdateErrorCode.requestReserved,
                 RequestUpdateErrorCode.requestAlreadyPlaced: return .reserved
            case RequestUpdateErrorCode.requestWithdrawn: return .withdrawn
            // A replayed identity whose request has since left the system (its
            // ledger outlived nothing to act on): no longer ongoing work.
            case RequestUpdateErrorCode.requestExpired,
                 RequestUpdateErrorCode.operationExpired: return .expired
            default: return .failed
            }
        default:
            return .failed
        }
    }

    static func message(for outcome: WithdrawOutcome) -> String? {
        switch outcome {
        case .reserved: return reservedWithdrawMessage
        case .failed: return withdrawFailedMessage
        case .unconfirmedWithdraw: return unconfirmedWithdrawMessage
        case .unconfirmedEdit: return unconfirmedEditMessage
        case .withdrawn, .expired: return nil
        }
    }
}
