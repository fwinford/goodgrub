//
//  RequestTextModeration.swift
//  CommonPlateios
//
// W4-U1.1 requester-form state for a backend text-filtering refusal.
//
// `POST /api/request` refuses requester-authored text that matches the
// backend's participant-text filter with a stable, definitive, pre-mutation
// `REQUEST_TEXT_NOT_ALLOWED`. Nothing was created, so this is never ambiguous
// and never retried. The form consumes it as its own state — a section-level
// notice above the meal fields — and not as a generic failure: the draft, the
// Screenshot Assistance state, and every field stay exactly as the requester
// left them, no field is blamed, nothing blocked is echoed, and there is no
// modal, sheet, dedicated screen, or new retry control.
//
// The backend deliberately says nothing about WHICH value matched, so this
// state remembers the active authored text values that were submitted and
// reports itself stale the moment any of them changes — an edit, or a menu-path
// or swipe-count change that alters which authored text is active — and also
// the moment the participant authority it was answered under is replaced.
import Foundation

struct RequestTextModerationState: Equatable {
    /// The participant authority the refused submission was made under. A
    /// refusal belongs to that submission; a replaced identity cannot inherit
    /// it.
    let participantAuthority: String?
    /// The active authored text values at submission, compared verbatim so any
    /// edit — even whitespace — retires the notice.
    let moderatedTexts: [String]
}

enum RequestTextModeration {
    /// The approved section heading the notice sits directly beneath, and the
    /// approved neutral copy. Exact, and shared with the backend's refusal
    /// message so the two cannot drift apart.
    static let sectionHeading = "What would you like?"
    static let noticeCopy = "Keep request details respectful and food-related."

    /// Whether a thrown create error is the backend's definitive text-filtering
    /// refusal. Matches the stable code only — never the message — so no
    /// wording change can turn it into a different state.
    static func isRefusal(_ error: Error) -> Bool {
        guard let serviceError = error as? RequestServiceError,
              case .serverError(let code, _) = serviceError else {
            return false
        }
        return code == RequestOperationErrorCode.textNotAllowed
    }

    /// Exactly the requester-authored free-text values the submitted request
    /// carries: each active Meal's item and details on Meal Exchange, the order
    /// details on Dining Dollars only. Hidden meal entries a lowered swipe count
    /// excluded, and the inactive path's text, are not part of what was
    /// submitted and so are not part of what was moderated.
    static func activeAuthoredTexts(in draft: RequestFoodFormDraft) -> [String] {
        switch draft.menuPath {
        case .mealExchange:
            return draft.activeMealEntryIndices.flatMap { index in
                [draft.mealEntries[index].name, draft.mealEntries[index].details ?? ""]
            }
        case .diningDollars:
            return [draft.orderDetails]
        }
    }

    /// The state to hold after a refusal of `submitted`, answered under
    /// `authority`.
    static func state(
        afterRefusalOf submitted: RequestFoodFormDraft,
        authority: String?
    ) -> RequestTextModerationState {
        RequestTextModerationState(
            participantAuthority: authority,
            moderatedTexts: activeAuthoredTexts(in: submitted)
        )
    }

    /// Whether `state` still describes `draft` under `authority`. Used at
    /// render time as a second guard behind `reconciled`, so a stale notice can
    /// never be drawn even for the one frame before the clearing runs.
    static func isCurrent(
        _ state: RequestTextModerationState?,
        draft: RequestFoodFormDraft,
        authority: String?
    ) -> Bool {
        guard let state else { return false }
        return state.participantAuthority == authority
            && state.moderatedTexts == activeAuthoredTexts(in: draft)
    }

    /// The state after the draft or identity changed: the same state while it
    /// is still current, `nil` — permanently — the first time it is not. Once
    /// cleared it never returns on its own, even if the requester restores the
    /// exact text they had; only a fresh refusal sets it again.
    static func reconciled(
        _ state: RequestTextModerationState?,
        draft: RequestFoodFormDraft,
        authority: String?
    ) -> RequestTextModerationState? {
        isCurrent(state, draft: draft, authority: authority) ? state : nil
    }
}
