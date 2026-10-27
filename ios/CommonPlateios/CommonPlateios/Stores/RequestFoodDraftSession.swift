//
//  RequestFoodDraftSession.swift
//  CommonPlateios
//
// W4-R2 process-lifetime Request Food draft continuity. This owner is created
// by ContentView above the transient pushed route. It deliberately has no
// disk/server storage and no request-create, D1, credential, or operation
// authority.
import SwiftUI
import Combine

@MainActor
final class RequestFoodDraftSession: ObservableObject {
    @Published var draft = RequestFoodFormDraft()

    /// Manual-precedence is part of the unfinished draft's meaning. Keeping
    /// these flags beside the values prevents a later screenshot selected
    /// after route re-entry from overwriting a value the requester had
    /// already edited manually.
    @Published var screenshotManualEdits = ScreenshotFieldManualEditState()

    /// Retains the truthful "Suggested" presentation for values
    /// that remain accepted and unedited when the route is recreated.
    @Published var screenshotProvenance = ScreenshotProposalAppliedFields()

    /// One new-selection boundary for draft clearing and its matching badge
    /// clearing. A requester-owned value keeps both its value and authority;
    /// the Meal Exchange top-up retains its existing selection behavior.
    func beginScreenshotSelection(using store: ScreenshotProposalStore) -> ScreenshotSelectionToken {
        let token = store.beginSelection(clearing: &draft, manualEdits: screenshotManualEdits)
        screenshotProvenance.menuPath = false
        if !screenshotManualEdits.hasManuallyEditedLocation { screenshotProvenance.location = false }
        if !screenshotManualEdits.hasManuallyEditedMealSwipes { screenshotProvenance.mealSwipes = false }
        if !screenshotManualEdits.hasManuallyEditedOrderDetails { screenshotProvenance.orderDetails = false }
        if !screenshotManualEdits.hasManuallyEditedDiningDollarsOnly {
            screenshotProvenance.diningDollarsOnly = false
        }
        for index in 0..<RequestFoodFormDraft.maxMealSwipes {
            if !screenshotManualEdits.hasManuallyEditedMealItemName(index) {
                screenshotProvenance.mealItemNames.remove(index)
            }
            if !screenshotManualEdits.hasManuallyEditedMealItemDetails(index) {
                screenshotProvenance.mealItemDetails.remove(index)
            }
        }
        return token
    }

    /// The Request Food picker binding's requester-owned count transition.
    /// A store write or explicit screenshot adoption never calls this.
    func setMealSwipesManually(_ count: Int) {
        guard RequestFoodFormDraft.mealSwipeOptions.contains(count) else { return }
        draft.mealSwipes = count
        screenshotManualEdits.hasManuallyEditedMealSwipes = true
        screenshotProvenance.mealSwipes = false
    }

    /// Reject only surplus subfields that this result actually wrote. The
    /// caller fences the result token; these current manual/provenance checks
    /// also protect a subfield the requester has since taken ownership of.
    func rejectCurrentScreenshotSurplus(
        above manualCount: Int,
        names: Set<Int>,
        details: Set<Int>
    ) {
        guard screenshotManualEdits.hasManuallyEditedMealSwipes,
              draft.mealSwipes == manualCount,
              RequestFoodFormDraft.mealSwipeOptions.contains(manualCount) else { return }
        for index in manualCount..<RequestFoodFormDraft.maxMealSwipes {
            if names.contains(index),
               screenshotProvenance.mealItemNames.contains(index),
               !screenshotManualEdits.hasManuallyEditedMealItemName(index) {
                draft.mealEntries[index].name = ""
                screenshotProvenance.mealItemNames.remove(index)
            }
            if details.contains(index),
               screenshotProvenance.mealItemDetails.contains(index),
               !screenshotManualEdits.hasManuallyEditedMealItemDetails(index) {
                draft.mealEntries[index].details = nil
                screenshotProvenance.mealItemDetails.remove(index)
            }
        }
    }

    /// Called only after request creation is authoritatively confirmed. D1
    /// ambiguity, verification, route departure, backgrounding, and every
    /// definitive non-create leave this owner untouched.
    func clearAfterAuthoritativeCreation() {
        draft = RequestFoodFormDraft()
        screenshotManualEdits = ScreenshotFieldManualEditState()
        screenshotProvenance = ScreenshotProposalAppliedFields()
    }

    func retireForCompletedDeletion() {
        draft = RequestFoodFormDraft()
        screenshotManualEdits = ScreenshotFieldManualEditState()
        screenshotProvenance = ScreenshotProposalAppliedFields()
    }

    /// W4-D2 FIX 2026-09-18 (independent-review MUST FIX 2), Path A: installs
    /// the trusted draft `RequestStore` restored from a terminal NO-CREATE's
    /// recovered payload, and resets every other session-owned field —
    /// `screenshotManualEdits`, `screenshotProvenance`, and anything else this
    /// owner holds — so no manual-edit or provenance state left over from a
    /// previous request/session can attach to it.
    func replaceForTerminalRecovery(restoring draft: RequestFoodFormDraft) {
        self.draft = draft
        screenshotManualEdits = ScreenshotFieldManualEditState()
        screenshotProvenance = ScreenshotProposalAppliedFields()
    }

    /// W4-D2 FIX 2026-09-18 (independent-review MUST FIX 2), Path B: opens a
    /// new Request Food form after a terminal NO-CREATE whose payload was
    /// unavailable. Behaviorally identical to `clearAfterAuthoritativeCreation()`
    /// — a genuinely fresh session — kept as its own named operation so this
    /// call site's intent (terminal recovery, not a successful creation)
    /// stays legible and the two can be changed independently if they ever
    /// need to diverge.
    func startEmptyAfterTerminalRecovery() {
        clearAfterAuthoritativeCreation()
    }
}
