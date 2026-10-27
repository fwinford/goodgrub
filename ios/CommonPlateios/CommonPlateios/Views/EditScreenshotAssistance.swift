//
//  EditScreenshotAssistance.swift
//  CommonPlateios
//
// W4-R5 D-R5-4: optional Screenshot Assistance on Edit. This reuses the
// accepted R4.2 domain layer unchanged (`ScreenshotProposalStore`, venue
// recovery classification, manual-precedence application, the shared result
// state structs and `RequesterVenueRecoveryCallout`) and adds only the Edit
// form's own glue. Nothing here persists screenshots or provenance, and
// nothing here sends a request: the saved request's content only changes
// through `Save Changes`.
//
// Authority rule specific to Edit: every non-empty value the form was
// prefilled with is confirmed saved content and is treated as requester-owned.
// A screenshot therefore fills only what is empty, and a differing venue, menu
// path or swipe count is offered through the same explicit recovery/suggestion
// affordances the create form uses instead of silently replacing saved data.
import SwiftUI

struct EditScreenshotAssistanceState: Equatable {
    var manualEdits: ScreenshotFieldManualEditState
    var provenance = ScreenshotProposalAppliedFields()
    var checked = false
    var preservedEntryFeedback = ScreenshotPreservedEntryFeedbackState()
    var mealSwipeMismatch = ScreenshotMealSwipeMismatchState()
    var menuPathConflict = ScreenshotMenuPathConflictState()
    var venueRecovery = ScreenshotVenueRecoveryState()

    /// Prefilled saved content becomes requester-owned. Provenance is never
    /// restored from the original request.
    static func seeded(from draft: RequestFoodFormDraft) -> EditScreenshotAssistanceState {
        var edits = ScreenshotFieldManualEditState()
        edits.hasManuallyEditedLocation = draft.selectedDiningSpot != nil
        edits.hasManuallyEditedMealSwipes = draft.menuPath == .mealExchange
        edits.hasManuallyEditedMenuPath = true
        for index in 0..<RequestFoodFormDraft.maxMealSwipes {
            if !draft.mealEntries[index].name.isEmpty {
                edits.manuallyEditedMealItemNames.insert(index)
            }
            if !(draft.mealEntries[index].details ?? "").isEmpty {
                edits.manuallyEditedMealItemDetails.insert(index)
            }
        }
        edits.hasManuallyEditedOrderDetails = !draft.orderDetails.isEmpty
        edits.hasManuallyEditedDiningDollars = !draft.diningDollarsText.isEmpty
        edits.hasManuallyEditedDiningDollarsOnly = !draft.diningDollarsOnlyText.isEmpty
        return EditScreenshotAssistanceState(manualEdits: edits)
    }

    var venueRecoveryIsUnresolved: Bool {
        guard let recovery = venueRecovery.recovery else { return false }
        if case .unresolved = recovery.kind { return true }
        return false
    }

    // MARK: Result lifecycle

    mutating func clearResults() {
        preservedEntryFeedback.retire()
        mealSwipeMismatch.clear()
        menuPathConflict.clear()
        venueRecovery.clear()
    }

    /// A new selection retires the previous result's presentation, exactly as
    /// the create form does, and clears only screenshot-owned provenance.
    mutating func beginSelection() {
        clearResults()
        checked = false
        preservedEntryFeedback.beginSelection()
        provenance.menuPath = false
        if !manualEdits.hasManuallyEditedLocation { provenance.location = false }
        if !manualEdits.hasManuallyEditedMealSwipes { provenance.mealSwipes = false }
        if !manualEdits.hasManuallyEditedOrderDetails { provenance.orderDetails = false }
        if !manualEdits.hasManuallyEditedDiningDollarsOnly { provenance.diningDollarsOnly = false }
        for index in 0..<RequestFoodFormDraft.maxMealSwipes {
            if !manualEdits.hasManuallyEditedMealItemName(index) {
                provenance.mealItemNames.remove(index)
            }
            if !manualEdits.hasManuallyEditedMealItemDetails(index) {
                provenance.mealItemDetails.remove(index)
            }
        }
    }

    // MARK: Requester-owned edits

    mutating func setLocation(_ spot: DiningSpot?, in draft: inout RequestFoodFormDraft) {
        draft.selectedDiningSpot = spot
        manualEdits.hasManuallyEditedLocation = spot != nil
        provenance.location = false
    }

    mutating func setMealSwipes(_ count: Int, in draft: inout RequestFoodFormDraft) {
        guard RequestFoodFormDraft.mealSwipeOptions.contains(count) else { return }
        draft.mealSwipes = count
        manualEdits.hasManuallyEditedMealSwipes = true
        provenance.mealSwipes = false
        mealSwipeMismatch.clear()
    }

    mutating func setMealName(_ value: String, at index: Int, in draft: inout RequestFoodFormDraft) {
        draft.mealEntries[index].name = value
        if value.isEmpty {
            manualEdits.manuallyEditedMealItemNames.remove(index)
        } else {
            manualEdits.manuallyEditedMealItemNames.insert(index)
        }
        provenance.mealItemNames.remove(index)
    }

    mutating func setMealDetails(_ value: String, at index: Int, in draft: inout RequestFoodFormDraft) {
        draft.mealEntries[index].details = value.isEmpty ? nil : value
        if value.isEmpty {
            manualEdits.manuallyEditedMealItemDetails.remove(index)
        } else {
            manualEdits.manuallyEditedMealItemDetails.insert(index)
        }
        provenance.mealItemDetails.remove(index)
    }

    mutating func setOrderDetails(_ value: String, in draft: inout RequestFoodFormDraft) {
        draft.orderDetails = value
        manualEdits.hasManuallyEditedOrderDetails = !value.isEmpty
        provenance.orderDetails = false
    }

    mutating func setDiningDollars(_ value: String, in draft: inout RequestFoodFormDraft) {
        draft.diningDollarsText = value
        if draft.menuPath == .mealExchange {
            manualEdits.hasManuallyEditedDiningDollars = !value.isEmpty
        } else {
            manualEdits.hasManuallyEditedDiningDollarsOnly = !value.isEmpty
            provenance.diningDollarsOnly = false
        }
    }

    mutating func setMenuPath(_ path: RequestMenuPath, in draft: inout RequestFoodFormDraft) {
        manualEdits.recordMenuPathSelection(from: draft.menuPath, to: path)
        if path != draft.menuPath {
            menuPathConflict.clear()
            provenance.menuPath = false
        }
        draft.menuPath = path
        if path != .mealExchange { mealSwipeMismatch.clear() }
    }

    // MARK: Applying an analyzed outcome

    /// Applies one validated outcome — local or external, identically — through
    /// the same venue-recovery gate and manual-precedence rules as creation.
    /// A held A/D/B/C outcome never mutates the draft until its explicit
    /// recovery action.
    /// Returns the preserved-entry feedback generation when the accepted
    /// conditional message should show, so the caller can time it out.
    @discardableResult
    mutating func apply(
        _ outcome: ScreenshotProposalOutcome,
        token: ScreenshotSelectionToken,
        confirmedVenueRecovery: ScreenshotVenueRecovery? = nil,
        store: ScreenshotProposalStore,
        to draft: inout RequestFoodFormDraft
    ) -> Int? {
        if let confirmedVenueRecovery {
            guard confirmedVenueRecovery.token == token,
                  confirmedVenueRecovery.outcome == outcome else { return nil }
        }
        if confirmedVenueRecovery == nil,
           let kind = ScreenshotProposalStore.venueRecoveryKind(
            for: outcome,
            manualEdits: manualEdits,
            draft: draft
           ) {
            switch kind {
            case .unsupported, .conflicting:
                venueRecovery.present(ScreenshotVenueRecovery(
                    token: token,
                    outcome: outcome,
                    kind: kind,
                    wasGenuineRerun: false
                ))
            case .unresolved, .manualMismatch:
                // Rerun truth is captured now, not on confirmation.
                let wasGenuineRerun = recordCompletedAnalysis(eligible: true) ?? false
                venueRecovery.present(ScreenshotVenueRecovery(
                    token: token,
                    outcome: outcome,
                    kind: kind,
                    wasGenuineRerun: wasGenuineRerun
                ))
            }
            return nil
        }
        var edits = manualEdits
        if let confirmedVenueRecovery, case .manualMismatch = confirmedVenueRecovery.kind {
            // D's explicit choice replaces only the requester-owned location.
            edits.hasManuallyEditedLocation = false
        }
        let applied = store.apply(
            outcome,
            manualEdits: edits,
            to: &draft,
            venueConfirmation: confirmedVenueRecovery != nil
        )
        manualEdits = edits
        manualEdits.record(applied)
        if applied.establishedMenuPath { provenance.menuPath = true }
        if applied.location { provenance.location = true }
        if applied.mealSwipes { provenance.mealSwipes = true }
        if applied.diningDollarsOnly { provenance.diningDollarsOnly = true }
        if applied.orderDetails { provenance.orderDetails = true }
        provenance.mealItemNames.formUnion(applied.mealItemNames)
        provenance.mealItemDetails.formUnion(applied.mealItemDetails)
        mealSwipeMismatch.present(applied.suggestedMealSwipes, for: token, applied: applied)
        menuPathConflict.present(
            applied.suggestedMenuPath,
            outcome: outcome,
            for: token,
            venueConfirmation: confirmedVenueRecovery
        )

        var feedbackApplied = applied
        if applied.suggestedMenuPath != nil {
            // The inline path suggestion is the entire conflict treatment.
            feedbackApplied.preservedManualFieldCount = 0
        }
        let wasGenuineRerun = confirmedVenueRecovery?.wasGenuineRerun
            ?? recordCompletedAnalysis(eligible: outcome.eligible)
        guard let wasGenuineRerun else { return nil }
        return preservedEntryFeedback.showPreservedEntryFeedback(
            wasGenuineRerun: wasGenuineRerun,
            applying: feedbackApplied
        )
    }

    private mutating func recordCompletedAnalysis(eligible: Bool) -> Bool? {
        guard eligible else { return nil }
        checked = true
        return preservedEntryFeedback.recordCompletedAnalysis(eligible: true)
    }

    /// The only explicit A/D crossing of the store's application gate; it
    /// applies the held, already-validated outcome and never re-analyzes.
    @discardableResult
    mutating func confirmVenueRecovery(
        _ recovery: ScreenshotVenueRecovery,
        store: ScreenshotProposalStore,
        to draft: inout RequestFoodFormDraft
    ) -> Int? {
        guard venueRecovery.recovery == recovery,
              store.isCurrent(recovery.token) else { return nil }
        venueRecovery.clear()
        return apply(
            recovery.outcome,
            token: recovery.token,
            confirmedVenueRecovery: recovery,
            store: store,
            to: &draft
        )
    }

    mutating func dismissVenueRecovery(
        _ recovery: ScreenshotVenueRecovery,
        store: ScreenshotProposalStore
    ) {
        guard venueRecovery.recovery == recovery, store.isCurrent(recovery.token) else { return }
        venueRecovery.dismiss()
    }

    mutating func switchMenuPath(
        _ conflict: ScreenshotMenuPathConflict,
        store: ScreenshotProposalStore,
        to draft: inout RequestFoodFormDraft
    ) {
        guard menuPathConflict.suggestion == conflict,
              store.isCurrent(conflict.token),
              manualEdits.hasManuallyEditedMenuPath,
              draft.menuPath != conflict.proposedPath else { return }
        manualEdits.hasManuallyEditedMenuPath = false
        menuPathConflict.clear()
        apply(
            conflict.outcome,
            token: conflict.token,
            confirmedVenueRecovery: conflict.venueConfirmation,
            store: store,
            to: &draft
        )
    }

    mutating func dismissMenuPathConflict(
        _ conflict: ScreenshotMenuPathConflict,
        store: ScreenshotProposalStore
    ) {
        guard menuPathConflict.suggestion == conflict, store.isCurrent(conflict.token) else { return }
        menuPathConflict.dismiss()
    }

    mutating func adoptSuggestedMealSwipes(
        _ mismatch: ScreenshotMealSwipeMismatch,
        store: ScreenshotProposalStore,
        to draft: inout RequestFoodFormDraft
    ) {
        guard mealSwipeMismatch.suggestion == mismatch, store.isCurrent(mismatch.token) else { return }
        var currentDraft = draft
        var currentEdits = manualEdits
        var currentProvenance = provenance
        guard store.adoptSuggestedMealSwipes(
            mismatch.proposedCount,
            manualEdits: &currentEdits,
            provenance: &currentProvenance,
            to: &currentDraft
        ) else { return }
        draft = currentDraft
        manualEdits = currentEdits
        provenance = currentProvenance
        mealSwipeMismatch.clear()
    }

    /// Dismissal rejects only the surplus Meal subfields this result actually
    /// wrote and the requester has not since taken ownership of.
    mutating func dismissMealSwipeMismatch(
        _ mismatch: ScreenshotMealSwipeMismatch,
        store: ScreenshotProposalStore,
        in draft: inout RequestFoodFormDraft
    ) {
        guard mealSwipeMismatch.suggestion == mismatch, store.isCurrent(mismatch.token) else { return }
        let manualCount = draft.mealSwipes
        if manualEdits.hasManuallyEditedMealSwipes,
           RequestFoodFormDraft.mealSwipeOptions.contains(manualCount) {
            for index in manualCount..<RequestFoodFormDraft.maxMealSwipes {
                if mismatch.contributedMealItemNames.contains(index),
                   provenance.mealItemNames.contains(index),
                   !manualEdits.hasManuallyEditedMealItemName(index) {
                    draft.mealEntries[index].name = ""
                    provenance.mealItemNames.remove(index)
                }
                if mismatch.contributedMealItemDetails.contains(index),
                   provenance.mealItemDetails.contains(index),
                   !manualEdits.hasManuallyEditedMealItemDetails(index) {
                    draft.mealEntries[index].details = nil
                    provenance.mealItemDetails.remove(index)
                }
            }
        }
        mealSwipeMismatch.dismiss()
    }
}

/// The Optional Screenshot Assistance entry row, in the create form's
/// approved presentation.
struct EditScreenshotAssistanceRow: View {
    let isEnabled: Bool
    let isApplying: Bool
    let checked: Bool
    let notice: ScreenshotProposalNotice?
    let onTurnOn: () -> Void
    let onChoose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.s) {
            HStack {
                Text(RequestFoodView.screenshotAssistanceTitle)
                    .font(.subheadline.weight(.bold))
                Spacer()
                Text(isEnabled
                     ? RequestFoodView.screenshotAssistanceOptionalLabel
                     : RequestFoodView.screenshotAssistanceOffLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !isEnabled {
                pill(RequestFoodView.turnOnScreenshotAssistanceLabel, action: onTurnOn)
                    .accessibilityIdentifier("edit-request-screenshot-turn-on")
            } else if checked && !isApplying {
                HStack(spacing: CommonPlateStyle.Spacing.s) {
                    Text(RequestFoodView.screenshotCheckedLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: onChoose) {
                        Text(RequestFoodView.screenshotChangeLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(CommonPlateStyle.Color.brandText)
                    }
                    .accessibilityIdentifier("edit-request-screenshot-change")
                }
                .padding(CommonPlateStyle.Spacing.m)
                .frame(maxWidth: .infinity)
                .cardChrome()
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("edit-request-screenshot-checked-row")
            } else {
                Button(action: onChoose) {
                    HStack(spacing: CommonPlateStyle.Spacing.xs) {
                        if isApplying { ProgressView().tint(Color("AccentColor")) }
                        Text(isApplying
                             ? RequestFoodView.screenshotAnalyzingLabel
                             : RequestFoodView.screenshotChooseLabel)
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(CommonPlateStyle.Color.brandText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, CommonPlateStyle.Spacing.m)
                    .cardChrome()
                }
                .buttonStyle(.plain)
                .disabled(isApplying)
                .accessibilityIdentifier("edit-request-screenshot-picker")
            }

            if isEnabled, let notice, notice != .noUsefulExtraction {
                Text(notice.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(CommonPlateStyle.Spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardChrome()
                    .accessibilityIdentifier("edit-request-screenshot-notice")
            }
        }
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CommonPlateStyle.Color.brandText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, CommonPlateStyle.Spacing.m)
                .cardChrome()
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    func cardChrome() -> some View {
        background(
            CommonPlateStyle.Color.requestCardSurface,
            in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                .strokeBorder(CommonPlateStyle.Color.requestCardBorder)
        )
    }
}

/// The inline `We found …` suggestion shared by the menu-path and meal-swipe
/// results: one explicit action and a dismiss control.
struct EditScreenshotSuggestionInset: View {
    let message: String
    let actionTitle: String
    let onAction: () -> Void
    let onDismiss: () -> Void
    let dismissLabel: String
    let identifier: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: CommonPlateStyle.Spacing.xs) {
                messageText
                Spacer(minLength: 0)
                actions
            }
            VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
                messageText
                HStack {
                    Spacer(minLength: 0)
                    actions
                }
            }
        }
        .frame(minHeight: 44)
        .padding(.leading, CommonPlateStyle.Spacing.s)
        .background(
            CommonPlateStyle.Color.requestCardSurface.opacity(0.55),
            in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
        )
        .accessibilityIdentifier(identifier)
    }

    private var messageText: some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        HStack(spacing: CommonPlateStyle.Spacing.xs) {
            Button(actionTitle, action: onAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Color("AccentColor"))
                .accessibilityIdentifier("\(identifier)-action")
            Button(action: onDismiss) {
                Text("×")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(dismissLabel)
            .accessibilityIdentifier("\(identifier)-dismiss")
        }
    }
}
