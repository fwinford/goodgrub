//
//  RequestFoodView.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
import PhotosUI
import SwiftUI
import UIKit

// W4-S3: a prepared screenshot (`ScreenshotPreparedImage`) now lives with the
// shared Screenshot Assistance runtime (`Services/ScreenshotAssistance/`).

/// W4-R2 2026-08-31 device/prototype sync: whether the newest completed
/// screenshot analysis was eligible, shown as the compact `✓ Screenshot
/// checked` result row. This supersedes the withdrawn item-21 three-outcome
/// explanatory copy — the row no longer distinguishes which of S1's outcomes
/// occurred, only that a completed analysis exists to show/replace with
/// `Change`.

// W4-R4: `RequestFoodFormError` now lives beside the draft and validator it
// describes, in `RequestFoodFormValidation.swift`, where its per-field cases
// (`missingMealDetail`, `missingOrderDetails`, the Dining Dollar cases) are
// declared alongside the fields that produce them.

enum RequestCreatePresentationError: Equatable {
    case invalidRequest
    case createdUnavailable
    /// `PARTICIPANT_VERIFICATION_REQUIRED`. Reachable only if the gate and this
    /// screen disagree about whether this installation is verified — the form
    /// asks for verification before submitting — so it says the same thing the
    /// gate does rather than inventing a second explanation.
    case verificationRequired
    /// `PARTICIPANT_AUTHORITY_INVALID`. The stored identity has been discarded
    /// by the time this renders, so the correction is to verify again.
    case verificationExpired
    /// `PARTICIPANT_VERIFICATION_UNAVAILABLE`. The backend could not check.
    /// Never presented as "you are not verified", because it does not say that.
    case verificationUnavailable
    /// `PARTICIPANT_PRINCIPAL_MISMATCH`. This app never sends an address, so
    /// this is a build/contract disagreement rather than anything the student
    /// typed; it is still recoverable by verifying the address they want.
    case principalMismatch
    case requestLimitReached
    /// `RATE_LIMITED`. Distinct from `requestLimitReached`: that one is the
    /// daily allowance and reopens tomorrow, this one is a short per-IP
    /// throttle that clears in about a minute. Both are refused ahead of the
    /// write, so neither is ambiguous.
    case rateLimited
    case publicActionsPaused
    case creationFailed
    case ambiguous
    case operationInProgress

    var message: String {
        switch self {
        case .invalidRequest:
            return "Check the information you entered and try again."
        case .createdUnavailable:
            return RequestOperationErrorCode.requestCreatedUnavailableMessage
        case .verificationRequired:
            return "Verify your NYU email to post a request."
        case .verificationExpired, .principalMismatch:
            return "Your NYU email needs to be verified again before posting."
        case .verificationUnavailable:
            return "We couldn’t check your NYU verification. Please try again in a moment."
        case .requestLimitReached:
            // Under the revised W3-R1 presentation contract, the daily quota is
            // not advertised on the ordinary form — only this actual-limit
            // recovery sentence, reached solely by a real backend refusal.
            return RequestFoodView.postingLimitReachedNotice
        case .rateLimited:
            // Same sentence the helper sees for a throttled claim, since the
            // situation and the next step are identical.
            return "Too many attempts. Please wait a moment and try again."
        case .publicActionsPaused:
            // One source for the locked sentence, so the notice shown before
            // data entry and this submit-time backstop cannot drift apart.
            return RequestFoodView.pauseNotice
        case .creationFailed:
            return "We couldn’t post your request. Please try again in a moment."
        case .ambiguous:
            // W4-D2 supersedes the former "Check Active Requests" sentence.
            return RequestFoodView.unresolvedCreateBody
        case .operationInProgress:
            return "Your request is already being posted."
        }
    }

    static func map(_ error: Error) -> RequestCreatePresentationError {
        guard let serviceError = error as? RequestServiceError else {
            return .creationFailed
        }

        switch serviceError {
        case .serverError(let code, _):
            switch code {
            case RequestOperationErrorCode.requestCreatedUnavailable:
                return .createdUnavailable
            case "INVALID_REQUEST":
                return .invalidRequest
            case ParticipantErrorCode.verificationRequired:
                return .verificationRequired
            case ParticipantErrorCode.authorityInvalid:
                return .verificationExpired
            case ParticipantErrorCode.verificationUnavailable:
                return .verificationUnavailable
            case ParticipantErrorCode.principalMismatch:
                return .principalMismatch
            case "REQUEST_LIMIT_REACHED":
                return .requestLimitReached
            case "RATE_LIMITED":
                return .rateLimited
            case "PUBLIC_ACTIONS_PAUSED":
                return .publicActionsPaused
            case "REQUEST_CREATION_FAILED":
                return .creationFailed
            default:
                return .creationFailed
            }
        case .ambiguousCreateOutcome:
            return .ambiguous
        case .operationInProgress:
            return .operationInProgress
        default:
            return .creationFailed
        }
    }
}

/// The one form-level error rendered beside the request submission action.
/// Field validation never enters this state; those errors remain owned by
/// their adjacent field rows.
/// W4-D2: the copy and single optional action of one recovery state.
struct RequestCreateRecoveryCopy: Equatable {
    let headline: String
    let body: String
    let actionLabel: String?
}

struct RequestSubmissionSectionPresentation: Equatable {
    let error: RequestCreatePresentationError
    let message: String
    let showsReturnHomeAction: Bool
}

/// What the requester screen shows. Availability is resolved before any field
/// exists, so `.form` — the only state with editable private fields and a
/// submit control — is reachable only from a confirmed `.available` answer.
enum RequestFormPresentation: Equatable {
    /// An earlier create may already have posted a request, so creation is
    /// blocked for the rest of this process. This outranks every availability
    /// state: whether posting happens to be open, paused, or unknown is a
    /// smaller fact than "your request may already exist", and none of those
    /// answers would change what this student can do next.
    case blockedByUnresolvedCreateAmbiguity
    /// A probe is running. No fields, no submit. Reached only while a check is
    /// genuinely in flight, so this state always has an answer coming.
    case checkingAvailability
    case form
    /// W4-R2: the requester tapped Submit and an authoritative answer is
    /// pending. Centered, one native indeterminate progress owner, no
    /// percentage and no haptic — the requester cannot yet know whether this
    /// will end in `.success` or a definitive failure.
    case posting
    /// W4-R2 D1: a durable unresolved create operation from a previous
    /// attempt (this session or a relaunch) is actively being reconciled
    /// against authoritative backend truth. Distinct from
    /// `.blockedByUnresolvedCreateAmbiguity`, which is the same ambiguity
    /// already resolved as still-unresolved: this state always has an answer
    /// coming, and neither success nor error semantics apply while it is
    /// pending.
    case checkingCreateAmbiguity
    /// W4-D2: a pending operation is persisted but its recovery identity
    /// cannot be read. Creation stays blocked with no check, retry, or clear
    /// action; ordinary navigation away remains available.
    case createIdentityUnavailable
    /// W4-D2: backend authority established terminal NO-CREATE for the
    /// earlier operation. Shown until `Return to request` (information
    /// recoverable) or `Start a new request` (information unavailable);
    /// blocks nothing.
    case createNotPosted
    /// Posting is paused, or availability could not be established. `retryable`
    /// is false for a paused backend, where retrying changes nothing.
    case unavailable(message: String, retryable: Bool)
    /// A create was confirmed by the backend.
    case success
}

/// W4-D2 FIX (rereview MUST FIX 3): the mounted-view local presentation
/// state that must never survive a Path A/B terminal-recovery replacement,
/// extracted into one directly testable owner so `resetFormLocalPresentationState()`
/// — the exact reset both `returnToRequest()` and `startNewRequest()` call —
/// can be exercised and proven clean without mounting `RequestFoodView`
/// itself. This project has no UI-test target (`docs/testing.md`), so this
/// seam is what stands in for one.
///
/// `focusedField` (`FocusState`, view-only) and `selectedScreenshotItems`
/// (`PhotosPickerItem`, no test-constructible instance) stay owned directly
/// by the view's own `@State`; their reset remains an unconditional one-line
/// assignment inside `resetFormLocalPresentationState()`, covered by the
/// existing production-wiring source test.
struct RequestFoodMountedPresentationState: Equatable {
    var validationPresentation = RequestFoodValidationPresentation()
    var submissionError: RequestCreatePresentationError?
    var showsLocalRejectionPointer = false
    var isShowingFailureSummary = false
    var isPresentingScreenshotPicker = false
    var isPresentingExactTimePicker = false
    var isPresentingTimingInfo = false
    var screenshotAfterglowFields = ScreenshotProposalAppliedFields()
    var screenshotChecked = false
    var mealSwipeMismatch = ScreenshotMealSwipeMismatchState()
    var venueRecovery = ScreenshotVenueRecoveryState()
    var preservedEntryFeedback = ScreenshotPreservedEntryFeedbackState()
    var expandedMealIndex: Int?
    /// W4-U1.1: the section-level text-filtering notice. Presentation state
    /// that belongs to one submission of one form, so a terminal-recovery
    /// replacement resets it to `nil` with everything else here.
    var textModeration: RequestTextModerationState?

    /// The one production reset both Path A and Path B route through.
    /// Always converges on the same clean defaults regardless of what this
    /// instance held before — stale validation, submission-error, focus
    /// pointer, failure-summary, picker/timing-sheet, and screenshot
    /// afterglow/checked state from a previous request can never survive it
    /// — and invalidates `screenshotProposalStore`'s current selection in
    /// the same step, so no in-flight analysis for the replaced form can
    /// repopulate it afterward.
    mutating func resetForTerminalRecovery(screenshotProposalStore: ScreenshotProposalStore) {
        var resetPreservedEntryFeedback = preservedEntryFeedback
        resetPreservedEntryFeedback.resetForTerminalRecovery()
        self = RequestFoodMountedPresentationState()
        // Retain the incremented timeout generation while resetting every
        // visible field. A delayed cleanup from the retired form can never
        // match a replacement form's feedback state.
        self.preservedEntryFeedback = resetPreservedEntryFeedback
        screenshotProposalStore.invalidateCurrentSelection()
    }
}

/// View-local lifecycle for the temporary preserved-entry acknowledgement.
/// This is deliberately not Screenshot Assistance domain/status state: it
/// only distinguishes the first completed analysis from a later completed
/// rerun and fences the view's short-lived cleanup task.
struct ScreenshotPreservedEntryFeedbackState: Equatable {
    private(set) var hasCompletedScreenshotAssistanceRun = false
    private(set) var isShowing = false
    private(set) var timeoutGeneration = 0

    /// A new picker selection retires any earlier acknowledgement timeout.
    mutating func beginSelection() {
        retire()
    }

    /// Hides any visible acknowledgement and fences its delayed cleanup. Used
    /// on view disappearance and Screenshot Assistance disablement; it never
    /// touches the completed-run flag.
    mutating func retire() {
        timeoutGeneration &+= 1
        isShowing = false
    }

    /// Records the current completed analysis. Only a successful eligible
    /// analysis counts as a completed run; ineligible outcomes establish
    /// nothing, and failed/cancelled/nil outcomes never reach this method.
    /// Only an eligible completion after an earlier eligible completion is a
    /// genuine rerun eligible for this feedback.
    mutating func completeAnalysis(
        eligible: Bool,
        applying applied: ScreenshotProposalAppliedFields
    ) -> Int? {
        guard let wasGenuineRerun = recordCompletedAnalysis(eligible: eligible) else { return nil }
        return showPreservedEntryFeedback(
            wasGenuineRerun: wasGenuineRerun,
            applying: applied
        )
    }

    /// Completion is independent of application for held A/D outcomes. The
    /// returned fact is captured with that result and cannot be recomputed by
    /// a later explicit confirmation.
    mutating func recordCompletedAnalysis(eligible: Bool) -> Bool? {
        guard eligible else { return nil }
        let isGenuineRerun = hasCompletedScreenshotAssistanceRun
        hasCompletedScreenshotAssistanceRun = true
        return isGenuineRerun
    }

    mutating func showPreservedEntryFeedback(
        wasGenuineRerun: Bool,
        applying applied: ScreenshotProposalAppliedFields
    ) -> Int? {
        guard wasGenuineRerun, applied.didPreserveManualContent else { return nil }

        timeoutGeneration &+= 1
        isShowing = true
        return timeoutGeneration
    }

    /// Path A/B replacement makes both the previous run and its delayed
    /// cleanup irrelevant to the newly installed form.
    mutating func resetForTerminalRecovery() {
        timeoutGeneration &+= 1
        isShowing = false
        hasCompletedScreenshotAssistanceRun = false
    }

    mutating func clearAfterTimeout(ifCurrent timeoutGeneration: Int) {
        guard self.timeoutGeneration == timeoutGeneration else { return }
        isShowing = false
    }
}

/// Result-scoped suggestion and dismissal; neither survives a new selection.
struct ScreenshotMealSwipeMismatch: Equatable {
    let token: ScreenshotSelectionToken
    let proposedCount: Int
    /// Only the Meal subfields written by this analyzed result may be
    /// rejected. Earlier accepted or requester-owned content is not inferred
    /// from the count or from a whole Meal row.
    let contributedMealItemNames: Set<Int>
    let contributedMealItemDetails: Set<Int>

    var message: String { "We found \(proposedCount) meals" }
    var action: String { "Use \(proposedCount) swipes" }
}

/// Keeps the approved manual provenance label after this result is dismissed,
/// while refusing to present that same result again.
struct ScreenshotMealSwipeMismatchState: Equatable {
    private(set) var suggestion: ScreenshotMealSwipeMismatch?
    private(set) var dismissedToken: ScreenshotSelectionToken?

    var showsManualProvenance: Bool {
        suggestion != nil || dismissedToken != nil
    }

    mutating func present(
        _ count: Int?,
        for token: ScreenshotSelectionToken,
        applied: ScreenshotProposalAppliedFields = ScreenshotProposalAppliedFields()
    ) {
        guard let count else {
            suggestion = nil
            if dismissedToken != token { dismissedToken = nil }
            return
        }
        if dismissedToken != token {
            dismissedToken = nil
            suggestion = ScreenshotMealSwipeMismatch(
                token: token,
                proposedCount: count,
                contributedMealItemNames: applied.mealItemNames,
                contributedMealItemDetails: applied.mealItemDetails
            )
        }
    }

    mutating func dismiss() {
        dismissedToken = suggestion?.token
        suggestion = nil
    }

    mutating func clear() {
        suggestion = nil
        dismissedToken = nil
    }
}

/// One analyzed result can recommend the opposite path until it is accepted
/// or dismissed. A dismissed token cannot re-present during ordinary edits.
struct ScreenshotMenuPathConflict: Equatable {
    let token: ScreenshotSelectionToken
    let proposedPath: RequestMenuPath
    let outcome: ScreenshotProposalOutcome
    /// A prior A/D action may have already authorized this exact held result.
    /// The inline Switch continuation carries that result-scoped authority
    /// forward; it cannot authorize another outcome or token.
    let venueConfirmation: ScreenshotVenueRecovery?
}

struct ScreenshotMenuPathConflictState: Equatable {
    private(set) var suggestion: ScreenshotMenuPathConflict?
    private(set) var dismissedToken: ScreenshotSelectionToken?

    mutating func present(
        _ path: RequestMenuPath?,
        outcome: ScreenshotProposalOutcome,
        for token: ScreenshotSelectionToken,
        venueConfirmation: ScreenshotVenueRecovery? = nil
    ) {
        guard dismissedToken != token else { return }
        suggestion = path.map {
            ScreenshotMenuPathConflict(
                token: token,
                proposedPath: $0,
                outcome: outcome,
                venueConfirmation: venueConfirmation
            )
        }
    }

    mutating func dismiss() {
        dismissedToken = suggestion?.token
        suggestion = nil
    }

    mutating func clear() {
        suggestion = nil
        dismissedToken = nil
    }
}

/// R4.2 venue recovery is result-scoped like the existing path/swipe rows.
/// Dismissal preserves D's manual-location provenance for only this result.
struct ScreenshotVenueRecoveryState: Equatable {
    private(set) var recovery: ScreenshotVenueRecovery?
    private(set) var dismissedToken: ScreenshotSelectionToken?
    private(set) var dismissedManualToken: ScreenshotSelectionToken?

    var showsManualLocationProvenance: Bool {
        if let recovery, case .manualMismatch = recovery.kind { return true }
        return dismissedManualToken != nil
    }

    mutating func present(_ recovery: ScreenshotVenueRecovery) {
        guard dismissedToken != recovery.token else { return }
        self.recovery = recovery
    }

    mutating func dismiss() {
        dismissedToken = recovery?.token
        if let recovery, case .manualMismatch = recovery.kind {
            dismissedManualToken = recovery.token
        }
        recovery = nil
    }

    mutating func clear() {
        recovery = nil
        dismissedToken = nil
        dismissedManualToken = nil
    }
}

/// Observe outside-input taps without intercepting native input switching or scrolling.
struct RequesterOutsideInputDismissal: UIViewRepresentable {
    final class TapView: UIView, UIGestureRecognizerDelegate {
        private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(dismissInput))

        override func didMoveToWindow() {
            super.didMoveToWindow()
            tap.view?.removeGestureRecognizer(tap)
            guard let window else { return }
            tap.cancelsTouchesInView = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
        }

        @objc private func dismissInput() {
            window?.endEditing(true)
        }

        static func isInput(_ view: UIView?) -> Bool {
            var ancestor = view
            while let current = ancestor {
                if current is UITextField || current is UITextView { return true }
                ancestor = current.superview
            }
            return false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            bounds.contains(touch.location(in: self)) && !Self.isInput(touch.view)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func detach() {
            tap.view?.removeGestureRecognizer(tap)
        }
    }

    func makeUIView(context: Context) -> TapView {
        let view = TapView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: TapView, context: Context) {}

    static func dismantleUIView(_ uiView: TapView, coordinator: ()) {
        uiView.detach()
    }
}

/// Requester-facing request form. Temporary input and presentation state stay
/// here; confirmed canonical collection state is owned by `RequestStore`.
struct RequestFoodView: View {
    /// Shared verbatim with the web request form.
    static let pauseNotice = "Posting a meal request is temporarily unavailable."

    /// Shown when the pause probe itself failed. Deliberately not the locked
    /// sentence: the app does not know that posting is paused, only that it
    /// could not find out, and it must not claim otherwise.
    static let availabilityUnknownNotice =
        "We couldn’t check whether posting is available right now. Please try again in a moment."

    /// Shown when the backend answers `REQUEST_LIMIT_REACHED`. Names the reset
    /// the requester is actually waiting for — campus midnight, not the
    /// device's — rather than a vague "tomorrow", and never describes the
    /// refusal in API terms, which is not what happened and not something a
    /// student can act on.
    static let postingLimitReachedNotice =
        "Daily request limit reached. Try again after midnight Eastern Time."

    /// Shown beneath the single scheduled-time control, which collects only a
    /// start; the end is derived by the backend. The student would otherwise
    /// have no way to know when helpers actually see this, or for how long.
    static let scheduledWindowNotice =
        "Helpers will start seeing this request at this time, and for 3 hours after it."

    /// Shown once no start is left inside the current campus day. Scheduling is
    /// withheld rather than offered as an unusable picker; tomorrow scheduling
    /// is not part of this flow.
    static let scheduledUnavailableNotice = "\(scheduledClosedForToday) ASAP only."

    /// The fact both scheduling-closed messages share.
    static let scheduledClosedForToday = "Scheduling is closed for today."

    /// The same fact plus the only move left, for a requester who selected
    /// `Later` while it was still offered and stayed on the form past the last
    /// valid window. Their selection is never rewritten for them — a draft that
    /// silently changes itself is worse than one that explains what to do — so
    /// the error names ASAP and waits for them to choose it.
    static let lapsedScheduledTimingNotice =
        "\(scheduledClosedForToday) Choose ASAP to post this request now."

    /// The pointer shown beside `Submit Request` when a local rejection has no
    /// text field to focus. Every invalid field already carries its own message,
    /// but the only two that cannot take focus are pickers, and a tap that moves
    /// nothing and says nothing reads as a broken button — which is exactly what
    /// a lapsed `Later` selection produced.
    static let localRejectionPointerNotice = "Check the highlighted fields above."

    @ObservedObject var store: RequestStore
    /// The one W4-S1 state owner for AI screenshot proposals. Entirely
    /// separate from `store`: it never calls `store.createRequest(...)` and
    /// only ever mutates `draft` through the manual-precedence-aware
    /// application this screen calls below.
    @ObservedObject var screenshotProposalStore: ScreenshotProposalStore
    /// Process/session-only draft state owned above this transient route.
    /// RequestStore remains the sole create/D1 authority.
    @ObservedObject var draftSession: RequestFoodDraftSession
    /// Observed, not owned: the verified identity outlives this screen, and the
    /// gate below has to see the same one every other participant action does.
    @ObservedObject var identityStore: ParticipantIdentityStore
    /// Shared production owner for the exact draft/operation continuation.
    /// This view reports lifecycle events; it does not keep a parallel pending
    /// intent in private SwiftUI state.
    @ObservedObject var verificationCoordinator:
        ParticipantActionVerificationCoordinator
    /// The destination that owns this form. Continuation consumption checks it
    /// so navigation replacement (including notification routing) cannot let a
    /// still-mounted stale form post after verification.
    @Binding var path: [AppRoute]
    let onExit: () -> Void

    @State private var validationPresentation = RequestFoodValidationPresentation()
    @State private var submissionError: RequestCreatePresentationError?
    /// Set only by a local rejection that had no text field to focus. Backend
    /// failures never set it — they own `submissionError`, which is the
    /// authoritative message for anything the server decided.
    @State private var showsLocalRejectionPointer = false
    /// W4-U1.1: set only by the backend's definitive text-filtering refusal,
    /// and only while it still describes the current draft and participant
    /// authority (`RequestTextModeration`). Deliberately separate from
    /// `submissionError`: it never routes to the failure summary, never
    /// disables `Post request`, and never touches the draft.
    @State private var textModeration: RequestTextModerationState?
    /// Moves VoiceOver to the notice when it appears, without assigning blame
    /// to any field.
    @AccessibilityFocusState private var isTextModerationNoticeFocused: Bool
    @State private var didCreateRequest = false
    /// Fences the one Success→Home handoff if SwiftUI re-evaluates the
    /// handoff task while this destination remains mounted, so the finished
    /// screen is removed exactly once. The semantic success acknowledgement
    /// itself (haptic and announcement) belongs to
    /// `RequestCreationContinuityView`, which fences it the same way against
    /// its own continuity identity.
    @State private var hasAcknowledgedSuccess = false
    /// W4-R2 definitive-failure presentation: true only while the centered
    /// `SAVED DRAFT` / `Review draft` failure state (rather than the ordinary
    /// editable form) is showing. Never true for D1 ambiguity, which has its
    /// own dedicated presentation, or for local field-validation rejections,
    /// which stay inline on the still-visible form.
    @State private var isShowingFailureSummary = false
    @FocusState private var focusedField: RequestFoodFormField?
    /// Tracks focus for the meal item's Details field specifically. The meal
    /// item NAME field's focus is tracked by `focusedField`'s
    /// `.mealDetail(index:)` case instead, despite that case's name.
    @FocusState private var focusedMealDetailsIndex: Int?
    @State private var isSoftwareKeyboardVisible = false
    @State private var isShowingGrubhubOpenFailure = false
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Independent-review fix: `.frame(maxHeight:)` alone does not behave as
    /// a passive "shrink to content, capped" constraint here — confirmed by
    /// a direct `UIHostingController` layout diagnostic against this exact
    /// wrapper chain (`.frame(width: 314).frame(maxHeight: 480)`), which
    /// showed even trivial one-line content forced to the full 480pt: this
    /// flexible frame expands to fill whatever it is proposed (screen
    /// height, since the enclosing `ZStack` ignores the safe area) up to its
    /// max, rather than reporting the child's own smaller natural size. That
    /// is the true, physically-confirmed cause of the persistent dead space
    /// below `Got it` — not anything inside `ScreenshotHelpView`, which was
    /// re-verified (with the same diagnostic) to correctly hug its own
    /// content to ~420pt once nothing forces it wider. The height cap is
    /// therefore applied only when content can actually need it —
    /// accessibility Dynamic Type sizes, where `ScreenshotHelpView`'s own
    /// internal `ScrollView` fallback also engages — and omitted entirely at
    /// ordinary sizes, letting the modal hug its true content height.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // MARK: - W4-S1 AI screenshot assistance

    /// W4-R4: up to five screenshots, selected together, as evidence for one
    /// logical Grubhub order. `PhotosPicker`'s own `maxSelectionCount` bounds
    /// the selection at the source; `ScreenshotProposalStore` and the backend
    /// each re-check the same bound independently.
    @State private var selectedScreenshotItems: [PhotosPickerItem] = []
    /// W4-S3 consent-authority revision: there is no per-attempt third-party-AI
    /// disclosure before photo selection or during analysis — choosing and
    /// locally analyzing screenshots sends nothing off-device, and while
    /// Screenshot Assistance is On with standing consent, an automatic
    /// external fallback attempt (when the local attempt cannot run or yields
    /// nothing) proceeds without a new prompt. The only disclosure is the one
    /// `isPresentingScreenshotAssistanceDisclosure` presents, shown once,
    /// before the Off → On transition becomes effective.
    /// W4-R2 2026-09-01 sync: presents the system photo picker only once
    /// Screenshot Help (if needed) is satisfied — `beginScreenshotAssistanceFlow()`
    /// and Screenshot Help's `Got it` are the only places that set this
    /// `true`. Programmatic (`.photosPicker(isPresented:)`), not a direct
    /// `PhotosPicker` link, so the row's tap can run that gating decision
    /// first.
    @State private var isPresentingScreenshotPicker = false
    /// W4-R2 Screenshot Help (`What should I screenshot?`): one local
    /// centered overlay, independent of the Screenshot Assistance disclosure.
    /// Owned as a `Binding` (not local `@State`) so `RequestFoodEntryView`
    /// can suppress its own toolbar Back button while this overlay owns
    /// input — a competing, still-functional underlying Back control was the
    /// exact walkthrough finding this closes: leaving it merely disabled
    /// would still be the "decorative/nonfunctional Back" item 9 already
    /// prohibits, so the entry screen removes it from the toolbar entirely
    /// instead.
    @Binding var isPresentingScreenshotHelp: Bool
    /// W4-S3 consent-authority revision: the `Turn on Screenshot Assistance?`
    /// disclosure, shown from the Off-state `Turn on Screenshot Assistance`
    /// row before the Off → On transition becomes effective. Independent of
    /// `isPresentingScreenshotHelp` — Help and this disclosure are never
    /// shown together, since Help only ever appears once Screenshot
    /// Assistance is already On. A `Binding`, not local `@State`, for the
    /// same reason `isPresentingScreenshotHelp` is: `RequestFoodEntryView`
    /// needs it to suppress its own toolbar Back button while this overlay
    /// owns input.
    @Binding var isPresentingScreenshotAssistanceDisclosure: Bool
    /// W4-R2 2026-08-31 round-2 sync: true exactly while `presentation` is
    /// `.posting` or `.success`, so `RequestFoodEntryView` can remove its
    /// Back control for the transient submission sequence — no alternative
    /// cancel/dismiss action replaces it. Owned as a binding for the same
    /// reason `isPresentingScreenshotHelp` is: the entry screen, not this
    /// view, owns the toolbar Back item.
    @Binding var isSuppressingBackNavigation: Bool
    /// Prototype C exact-time selection. The sheet owns only presentation;
    /// the selected value continues to live in the same `draft` as quick-time
    /// choices and request creation.
    @State private var isPresentingExactTimePicker = false
    /// W4-R2 2026-09-02 sync: the on-demand `How timing works` explanation.
    /// Purely local presentation state — opening/dismissing it never touches
    /// `draft`.
    @State private var isPresentingTimingInfo = false
    /// W4-R2 motion: exactly the fields `apply(...)` just changed, shown with
    /// a brief restrained afterglow and cleared shortly after — never a
    /// sequential/typing animation and never a haptic (S1 proposals get no
    /// haptic at all).
    @State private var screenshotAfterglowFields = ScreenshotProposalAppliedFields()
    /// W4-R2 2026-08-31 sync: whether the newest analysis for the current
    /// selection completed and was eligible. Reset when a new selection
    /// begins (`Change`/a fresh pick), so the compact result row only ever
    /// reflects the current selection's own outcome.
    @State private var screenshotChecked = false
    /// One suggestion belongs to one completed, current analysis token.
    /// Dismissal rejects that token's surplus Meal contribution; a later
    /// analysis receives a new token and may make a fresh suggestion.
    @State private var mealSwipeMismatch = ScreenshotMealSwipeMismatchState()
    @State private var menuPathConflict = ScreenshotMenuPathConflictState()
    @State private var venueRecovery = ScreenshotVenueRecoveryState()
    /// A bounded, rerun-only acknowledgement. It is intentionally view-local:
    /// it neither changes draft authority nor survives route recreation.
    @State private var preservedEntryFeedback = ScreenshotPreservedEntryFeedbackState()
    /// Expansion is pure, local editor presentation — never a save
    /// transaction. At most one stable meal index may be open at a time.
    @State private var expandedMealIndex: Int?
    /// Raw measurements behind `Post request`'s placement. A reference type on
    /// purpose: writing a measurement must not invalidate the form.
    @State private var layoutMeasurements = RequesterFormMeasurementBox()
    /// The published placement decision: `nil` until measured, then whether
    /// `Post request` anchors to the bottom. Changes only when the answer does.
    @State private var anchorsPostRequestDecision: Bool?
    /// The menu path that was current when the focused field gained focus, so
    /// a blur caused by the path switch itself is not validated against the
    /// newly selected branch.
    @State private var focusedFieldMenuPath: RequestMenuPath?

    /// Short aliases keep the existing field/submission code operating on the
    /// shared owner without introducing a second local copy.
    private var draft: RequestFoodFormDraft {
        get { draftSession.draft }
        nonmutating set { draftSession.draft = newValue }
    }

    /// Explicit requester-interaction provenance for the three allowlisted
    /// proposal fields (see `ScreenshotFieldManualEditState`'s declaration).
    /// Set only by this screen's three custom bindings below — never by a
    /// store-applied proposal write — and retained with the process draft.
    private var screenshotManualEdits: ScreenshotFieldManualEditState {
        get { draftSession.screenshotManualEdits }
        nonmutating set { draftSession.screenshotManualEdits = newValue }
    }

    /// Which allowlisted fields currently hold an accepted screenshot value
    /// that the requester has not manually edited since. This presentation
    /// provenance is retained with the process draft across route recreation.
    private var screenshotProvenance: ScreenshotProposalAppliedFields {
        get { draftSession.screenshotProvenance }
        nonmutating set { draftSession.screenshotProvenance = newValue }
    }

    /// Campus time, not device time. Every day boundary, every clamp, and the
    /// picker itself are computed here, so the same selection means the same
    /// New York instant on a phone in Brooklyn and one in Berkeley.
    private var calendar: Calendar {
        NYUCampusTime.calendar
    }

    /// The store-owned create ambiguity outlives this view and takes precedence
    /// over local submission errors.
    private var effectiveSubmissionError: RequestCreatePresentationError? {
        Self.effectiveSubmissionError(
            hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity,
            submissionError: submissionError
        )
    }

    private var isSubmissionEnabled: Bool {
        Self.isSubmissionEnabled(
            draft: draft,
            submissionError: effectiveSubmissionError,
            isCreating: store.isCreating
        )
    }

    let diningSpots = SupportedVendorCatalog.diningSpots

    /// Computed once per body evaluation so both the switch below and the
    /// Posting/Success Back-suppression side effect agree on the same
    /// answer.
    private var presentation: RequestFormPresentation {
        Self.presentation(
            hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity,
            availability: store.requestCreationAvailability,
            isCheckingAvailability: store.isCheckingRequestCreationAvailability,
            hasAttemptedAvailabilityCheck: store.hasAttemptedRequestCreationAvailabilityCheck,
            didCreateRequest: didCreateRequest,
            isCreating: store.isCreating,
            createRecovery: store.createRecoveryPresentation
        )
    }

    var body: some View {
        ZStack {
            Group {
                switch presentation {
                case .blockedByUnresolvedCreateAmbiguity:
                    blockedByAmbiguityView
                case .checkingCreateAmbiguity:
                    checkingCreateAmbiguityView
                case .createIdentityUnavailable:
                    createIdentityUnavailableView
                case .createNotPosted:
                    createNotPostedView
                case .posting:
                    postingView
                case .success:
                    successHandoffView
                case .checkingAvailability:
                    availabilityCheckView
                case .unavailable(let message, let retryable):
                    unavailableView(message: message, retryable: retryable)
                case .form:
                    if isShowingFailureSummary, let error = effectiveSubmissionError {
                        definitiveFailureView(error: error)
                    } else {
                        requestForm
                    }
                }
            }
            .accessibilityHidden(isPresentingScreenshotHelp || isPresentingScreenshotAssistanceDisclosure)

            if isPresentingScreenshotHelp {
                // W4-R2 final walkthrough sync: both layers share one
                // `ignoresSafeArea()` container so the modal centers against
                // the full device screen (status bar/nav bar included), not
                // merely the safe content area beneath the pushed
                // `Request Food` navigation bar — that narrower centering
                // context was what previously read as "not actually
                // centered."
                ZStack {
                    Color.black.opacity(0.34)
                        .accessibilityHidden(true)

                    ScreenshotHelpView {
                        // W4-R2 2026-09-01 sync item 5: `Got it` — and only
                        // `Got it` — owns marking Screenshot Help completed.
                        // The overlay's only dismissal path is this closure,
                        // so mere presentation or a local detail Back can
                        // never reach here and mark it learned.
                        screenshotProposalStore.recordScreenshotHelpCompleted()
                        isPresentingScreenshotHelp = false
                        isPresentingScreenshotPicker = true
                    }
                    // Independent-review fix: `.frame(maxHeight:)` expands to
                    // fill the proposed height rather than passively capping
                    // smaller content (see `dynamicTypeSize`'s declaration).
                    // Applying it only for accessibility Dynamic Type sizes —
                    // exactly where `ScreenshotHelpView`'s own internal
                    // `ScrollView` fallback engages — lets ordinary sizes hug
                    // their true content height with no cap at all.
                    .frame(width: 314)
                    .frame(maxHeight: dynamicTypeSize.isAccessibilitySize ? 480 : nil)
                    .background(
                        CommonPlateStyle.Color.baseCanvas,
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: Color.black.opacity(0.12), radius: 18, y: 8)
                    .padding(.horizontal, CommonPlateStyle.Spacing.l)
                    .accessibilityIdentifier("request-screenshot-help-modal")
                    .accessibilityAddTraits(.isModal)
                }
                .ignoresSafeArea()
            }

            if isPresentingScreenshotAssistanceDisclosure {
                // W4-S3 consent-authority revision: the `Turn on Screenshot
                // Assistance?` disclosure — the same centered modal shell as
                // Screenshot Help above (same outer white-card
                // width/height/position/corner radius and dimmed background
                // treatment), a small overlay rather than an embedded form
                // state or a new navigation screen.
                ZStack {
                    Color.black.opacity(0.34)
                        .accessibilityHidden(true)

                    ScreenshotAssistanceDisclosureView(
                        onTurnOn: confirmTurnOnScreenshotAssistance,
                        onNotNow: dismissScreenshotAssistanceDisclosure
                    )
                    .frame(width: 314)
                    .frame(maxHeight: dynamicTypeSize.isAccessibilitySize ? 480 : nil)
                    .background(
                        CommonPlateStyle.Color.baseCanvas,
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: Color.black.opacity(0.12), radius: 18, y: 8)
                    .padding(.horizontal, CommonPlateStyle.Spacing.l)
                    .accessibilityIdentifier("request-screenshot-assistance-disclosure-modal")
                    .accessibilityAddTraits(.isModal)
                }
                .ignoresSafeArea()
            }
        }
        .navigationTitle("Request Food")
        // W4-R2 2026-08-31 round-2 sync: keeps `isSuppressingBackNavigation`
        // in lockstep with `presentation`, including the first render
        // (`initial: true`) — a fresh instance that mounts already `.posting`
        // (e.g. restored mid-submission) must not briefly show Back before
        // this runs.
        .onChange(of: presentation, initial: true) { _, newPresentation in
            isSuppressingBackNavigation = Self.shouldSuppressBackNavigation(presentation: newPresentation)
        }
        // Campus time for everything this screen draws and reads, including the
        // scheduled-start picker. Without these, a phone left on another
        // timezone would offer and display its own wall clock while the backend
        // interpreted the resulting instant as New York — the requester would
        // pick 6 PM and helpers would see a different hour.
        .environment(\.timeZone, NYUCampusTime.timeZone)
        .environment(\.calendar, NYUCampusTime.calendar)
        // Runs before anything is rendered, and the pre-probe state is
        // `.unknown`, so the form cannot flash while the answer is pending.
        // Skipped entirely while blocked: the answer could not change this
        // screen, so asking for it would be a request made for nothing.
        .task {
            guard Self.shouldProbeAvailability(
                hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity
            ) else {
                return
            }
            await store.refreshRequestCreationAvailability()
        }
        // A sheet, not a push: this screen stays mounted underneath, so the
        // draft it holds is still there when verification finishes — and still
        // there when it does not.
        .sheet(isPresented: isPresentingVerification) {
            ParticipantVerificationView(
                store: identityStore,
                cancel: verificationCoordinator.requesterCancelled
            )
        }
        // A local `.ambiguous` only ever mirrors the store's block. Once the
        // store retires the operation (expired, unauthorized, or NO-CREATE),
        // it must stop disabling submission on this screen.
        .onChange(of: store.hasUnresolvedCreateAmbiguity) { _, isUnresolved in
            if !isUnresolved, submissionError == .ambiguous {
                submissionError = nil
            }
            // W4-D2: a block that clears without a NO-CREATE notice (another
            // retirement, or a confirmed different participant becoming
            // current) reaches the form only through the ordinary
            // availability check this screen skipped while blocked.
            if !isUnresolved,
               store.createRecoveryPresentation == .none,
               !store.hasAttemptedRequestCreationAvailabilityCheck {
                Task { await store.refreshRequestCreationAvailability() }
            }
        }
        .onChange(of: identityStore.identity) { previous, current in
            guard case .requestCreation(let submittedDraft)? =
                    verificationCoordinator.requesterIdentityDidChange(
                        from: previous,
                        to: current,
                        path: path
                    ) else {
                return
            }
            // The coordinator cleared both continuation owners before
            // returning this exact snapshot, so no duplicate publication can
            // enqueue another create.
            Task { await submit(draftSnapshot: submittedDraft) }
        }
        .onChange(of: path) { _, currentPath in
            verificationCoordinator.requesterNavigationChanged(path: currentPath)
        }
        .onDisappear {
            verificationCoordinator.requesterDisappeared()
            // Review finding: old work must be invalidated on disappearance,
            // not just superseded by a later selection — otherwise a
            // still-running analysis for a screen the requester has already
            // left could still be applied if this exact view instance were
            // ever reused.
            screenshotProposalStore.invalidateCurrentSelection()
            mealSwipeMismatch.clear()
            menuPathConflict.clear()
            venueRecovery.clear()
            preservedEntryFeedback.retire()
        }
        .onChange(of: screenshotProposalStore.isAIAssistanceEnabled) { _, isEnabled in
            if !isEnabled {
                preservedEntryFeedback.retire()
                mealSwipeMismatch.clear()
                menuPathConflict.clear()
                venueRecovery.clear()
            }
        }
        .onChange(of: selectedScreenshotItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            // Minted synchronously, here, before any async work for this
            // selection starts — "last selection wins from the moment the
            // requester chooses it," not from whenever its preprocessing
            // happens to finish.
            let token = draftSession.beginScreenshotSelection(using: screenshotProposalStore)
            mealSwipeMismatch.clear()
            menuPathConflict.clear()
            venueRecovery.clear()
            screenshotAfterglowFields = ScreenshotProposalAppliedFields()
            // A fresh selection starts its own result: the prior selection's
            // `✓ Screenshot checked` row must not keep describing this new,
            // not-yet-analyzed selection.
            screenshotChecked = false
            preservedEntryFeedback.beginSelection()
            Task { await processSelectedScreenshots(newItems, token: token) }
        }
        // W4-R2 2026-09-01 sync: programmatic presentation so
        // `beginScreenshotAssistanceFlow()` can run the Screenshot Help
        // gating decision before the system picker ever opens, rather than a
        // direct `PhotosPicker` link opening it immediately on tap.
        .photosPicker(
            isPresented: $isPresentingScreenshotPicker,
            selection: $selectedScreenshotItems,
            maxSelectionCount: ScreenshotProposalStore.maxScreenshotSelection,
            matching: .images,
            photoLibrary: .shared()
        )
        .sheet(isPresented: $isPresentingExactTimePicker) {
            exactTimePickerSheet
        }
    }

    // MARK: - W4-S1 AI screenshot assistance

    /// Approved Figma `Requester / Screenshot Assistance` component: a title
    /// row with `Optional`, a full-width pill action using the same
    /// request-card surface/border tokens, and — only for the Unsupported/No
    /// useful extraction outcomes — a bordered recovery-note box with the
    /// approved exact wording. Every other `ScreenshotProposalNotice` case
    /// (verification/invalid-image/unavailable) is not part of the approved
    /// component's variant set; it keeps its existing accepted message text,
    /// presented in the same recovery-note box for visual consistency only.
    @ViewBuilder
    private var screenshotAssistanceRow: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.s) {
            HStack {
                Text(Self.screenshotAssistanceTitle)
                    .font(.subheadline.weight(.bold))
                Spacer()
                Text(
                    screenshotProposalStore.isAIAssistanceEnabled
                        ? Self.screenshotAssistanceOptionalLabel
                        : Self.screenshotAssistanceOffLabel
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // W4-R2 2026-09-01 round-2 sync item 1: Off remains a
            // discoverable, directly recoverable opt-in from Request Food
            // itself — never a disabled `Choose Grubhub screenshot` control
            // plus explanatory text.
            if !screenshotProposalStore.isAIAssistanceEnabled {
                Button {
                    beginTurnOnScreenshotAssistanceFlow()
                } label: {
                    Text(Self.turnOnScreenshotAssistanceLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CommonPlateStyle.Color.brandText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, CommonPlateStyle.Spacing.m)
                        .background(
                            CommonPlateStyle.Color.requestCardSurface,
                            in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                                .strokeBorder(CommonPlateStyle.Color.requestCardBorder)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("request-screenshot-turn-on")
            } else if screenshotChecked && !screenshotProposalStore.isApplying {
                // W4-R2 2026-08-31 sync: the compact completed-result row
                // replaces the initial picker affordance once analysis for
                // the current selection has finished. `Change` is the only
                // actionable element — it reopens the same picker to select
                // and analyze another screenshot.
                HStack(spacing: CommonPlateStyle.Spacing.s) {
                    Text(Self.screenshotCheckedLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        beginScreenshotAssistanceFlow()
                    } label: {
                        Text(Self.screenshotChangeLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(CommonPlateStyle.Color.brandText)
                    }
                    .accessibilityIdentifier("request-screenshot-change")
                }
                .padding(.vertical, CommonPlateStyle.Spacing.m)
                .padding(.horizontal, CommonPlateStyle.Spacing.m)
                .frame(maxWidth: .infinity)
                .background(
                    CommonPlateStyle.Color.requestCardSurface,
                    in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                        .strokeBorder(CommonPlateStyle.Color.requestCardBorder)
                )
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("request-screenshot-checked-row")
            } else {
                Button {
                    beginScreenshotAssistanceFlow()
                } label: {
                    HStack(spacing: CommonPlateStyle.Spacing.xs) {
                        if screenshotProposalStore.isApplying {
                            ProgressView()
                                .tint(Color("AccentColor"))
                        }
                        Text(
                            screenshotProposalStore.isApplying
                                ? Self.screenshotAnalyzingLabel
                                : Self.screenshotChooseLabel
                        )
                        .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(CommonPlateStyle.Color.brandText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, CommonPlateStyle.Spacing.m)
                    .background(
                        CommonPlateStyle.Color.requestCardSurface,
                        in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                            .strokeBorder(CommonPlateStyle.Color.requestCardBorder)
                    )
                }
                .buttonStyle(.plain)
                .tint(Color("AccentColor"))
                .disabled(screenshotProposalStore.isApplying)
                .accessibilityIdentifier("request-screenshot-picker")
            }

            // W4-R2 2026-09-01 sync item 1: the permanent `What should I
            // screenshot?` support row is removed — Screenshot Help now
            // appears only as automatic first-use contextual education (see
            // `beginScreenshotAssistanceFlow()`), never as a standalone
            // always-visible entry point. W4-R2 2026-09-01 round-2 sync item
            // 1: the Off state itself is handled entirely by the
            // `Turn on Screenshot Assistance` branch above — there is no
            // separate withdrawn Off notice anymore.
            if screenshotProposalStore.isAIAssistanceEnabled,
               let notice = screenshotProposalStore.notice, notice != .noUsefulExtraction {
                // `.noUsefulExtraction` is excluded: the compact `✓
                // Screenshot checked` result row above already communicates
                // that this exact eligible analysis completed, so this box
                // would otherwise duplicate that fact.
                Text(notice.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(CommonPlateStyle.Spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        CommonPlateStyle.Color.requestCardSurface,
                        in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                            .strokeBorder(CommonPlateStyle.Color.requestCardBorder)
                    )
                    .accessibilityIdentifier("request-screenshot-notice")
            }

        }
    }

    static let screenshotCheckedLabel = "✓ Screenshot checked"
    static let screenshotChangeLabel = "Change"

    static let screenshotAssistanceTitle = "Screenshot Assistance"
    static let screenshotAssistanceOptionalLabel = "Optional"
    static let screenshotAssistanceOffLabel = "Off"
    static let screenshotChooseLabel = "Choose Grubhub screenshot"
    static let screenshotAnalyzingLabel = "Analyzing screenshot…"
    static let turnOnScreenshotAssistanceLabel = "Turn on Screenshot Assistance"

    /// W4-S3 requester flow ordering (supersedes the pre-S3
    /// disclosure-before-picker ordering): the only entry point for
    /// `Choose Grubhub screenshot` / `Change`.
    ///
    /// ```
    /// Choose Grubhub screenshot
    ///   → Screenshot Help (if not yet completed) → photo picker
    ///   → photo picker directly (if Help already completed)
    ///   → on-device analysis attempt
    ///   → normal success / ineligible behavior
    ///     OR an automatic external fallback attempt under standing consent
    /// ```
    ///
    /// There is no third-party-AI disclosure or consent before photo
    /// selection, and no per-attempt disclosure during analysis: choosing and
    /// locally analyzing screenshots sends nothing off-device, and the one
    /// `Turn on Screenshot Assistance?` disclosure already ran before this
    /// flow could be reached while Off. Screenshot Help completion is
    /// independent of every other state.
    private func beginScreenshotAssistanceFlow() {
        guard screenshotProposalStore.isAssistanceAvailable,
              screenshotProposalStore.isAIAssistanceEnabled, !screenshotProposalStore.isApplying else {
            return
        }
        proceedToScreenshotSelection()
    }

    /// Screenshot Help first-use education, then the picker.
    private func proceedToScreenshotSelection() {
        if screenshotProposalStore.hasCompletedScreenshotHelp {
            isPresentingScreenshotPicker = true
        } else {
            isPresentingScreenshotHelp = true
        }
    }

    /// Shared image preparation (`ScreenshotInputPreparer`: decode and bounded
    /// normalization — pixels only) — no network call, and nothing leaves the
    /// device. The Requester workflow derives its own independent on-device
    /// Vision OCR evidence from the ordered selection inside
    /// `ScreenshotProposalStore.analyzeScreenshot`. By the time a selection
    /// reaches this screen, Screenshot Help gating has already run in
    /// `beginScreenshotAssistanceFlow()`.
    ///
    /// Every stage re-checks `screenshotProposalStore.isCurrent(token)` and
    /// `.isAIAssistanceEnabled` before proceeding: a newer selection or AI
    /// Assistance being turned Off at any point must stop this exact attempt
    /// from reaching the next stage, and in particular must make any external
    /// transfer for it impossible.
    /// W4-R4: every selected screenshot is prepared, then all of them are
    /// analyzed together as evidence for one logical order. Preparing them
    /// sequentially keeps the existing per-stage staleness checks meaningful
    /// — a newer selection retires this whole set partway through.
    ///
    /// A single image that fails to load, decode, or normalize abandons the
    /// whole attempt rather than silently analyzing a subset: the requester
    /// chose those screenshots together, and a result quietly computed from
    /// fewer of them would misrepresent what was examined.
    @MainActor
    private func processSelectedScreenshots(
        _ items: [PhotosPickerItem],
        token: ScreenshotSelectionToken
    ) async {
        selectedScreenshotItems = []

        // Defense in depth beside `PhotosPicker`'s own `maxSelectionCount`:
        // the bound is re-checked here, in the store, and again server-side.
        let bounded = Array(items.prefix(ScreenshotProposalStore.maxScreenshotSelection))
        guard bounded.count == items.count else { return }

        var inputs: [ScreenshotPreparedImage] = []
        for item in bounded {
            guard let data = try? await item.loadTransferable(type: Data.self) else { return }
            guard screenshotProposalStore.isCurrent(token), screenshotProposalStore.isAIAssistanceEnabled else {
                return
            }

            guard let input = ScreenshotInputPreparer.prepare(
                imageData: data,
                isStillCurrent: {
                    screenshotProposalStore.isCurrent(token) && screenshotProposalStore.isAIAssistanceEnabled
                }
            ) else {
                return
            }
            inputs.append(input)
        }

        guard !inputs.isEmpty else { return }
        await beginScreenshotAnalysis(inputs, token: token)
    }

    /// W4-S3 consent-authority revision: `Turn on Screenshot Assistance`
    /// presents the `Turn on Screenshot Assistance?` disclosure before the
    /// Off → On transition becomes effective — it no longer flips the
    /// setting directly.
    private func beginTurnOnScreenshotAssistanceFlow() {
        guard screenshotProposalStore.isAssistanceAvailable else { return }
        isPresentingScreenshotAssistanceDisclosure = true
    }

    /// `Turn On`: establishes Screenshot Assistance's standing
    /// external-transfer consent and enables the feature, then continues
    /// into the same Screenshot Help / picker step as `Choose Grubhub
    /// screenshot` (unchanged Off-state re-entry behavior beyond the
    /// disclosure itself).
    private func confirmTurnOnScreenshotAssistance() {
        isPresentingScreenshotAssistanceDisclosure = false
        screenshotProposalStore.setAIAssistanceEnabled(true)
        proceedToScreenshotSelection()
    }

    /// `Not Now`: dismisses the disclosure, records no consent, and leaves
    /// Screenshot Assistance Off.
    private func dismissScreenshotAssistanceDisclosure() {
        isPresentingScreenshotAssistanceDisclosure = false
    }

    @MainActor
    private func beginScreenshotAnalysis(
        _ inputs: [ScreenshotPreparedImage],
        token: ScreenshotSelectionToken
    ) async {
        // W4-S3 consent-authority revision: authority is supplied as a
        // provider, read by the store only at the moment an external
        // fallback attempt would run (after OCR and the local attempt),
        // never captured here at the start. The store's own standing
        // consent check (Screenshot Assistance On) gates whether that
        // fallback attempt may proceed at all — there is no separate
        // per-attempt permission step here any more.
        let outcome = await screenshotProposalStore.analyzeScreenshot(
            images: inputs,
            participantAuthority: { identityStore.currentAuthority() },
            token: token
        )
        // Applied synchronously, after the suspension point above: a
        // `@State` draft cannot be passed `inout` across an `await`, so the
        // outcome returns here and is applied in one non-suspending step.
        // Re-checked again here (not just inside `analyzeScreenshot`): the
        // gap between that call returning and this line running is itself a
        // point where a newer selection could have started.
        guard let outcome, screenshotProposalStore.isCurrent(token) else { return }
        applyScreenshotOutcome(outcome, token: token)
    }

    /// Applies one validated outcome — local or external, identically — and
    /// drives the existing compact result presentation.
    @MainActor
    private func applyScreenshotOutcome(
        _ outcome: ScreenshotProposalOutcome,
        token: ScreenshotSelectionToken,
        confirmedVenueRecovery: ScreenshotVenueRecovery? = nil
    ) {
        if let confirmedVenueRecovery {
            guard confirmedVenueRecovery.token == token,
                  confirmedVenueRecovery.outcome == outcome else { return }
        }
        if confirmedVenueRecovery == nil,
           let kind = ScreenshotProposalStore.venueRecoveryKind(
            for: outcome,
            manualEdits: screenshotManualEdits,
            draft: draft
        ) {
            switch kind {
            case .unsupported, .conflicting:
                // B/C are not completed assistance outcomes. They never set
                // checked/afterglow/feedback, and apply is unreachable.
                venueRecovery.present(ScreenshotVenueRecovery(
                    token: token,
                    outcome: outcome,
                    kind: kind,
                    wasGenuineRerun: false
                ))
            case .unresolved, .manualMismatch:
                // A/D completed eligible analysis is truthful even while its
                // proposal is held. Capture rerun truth now, not on confirm.
                let wasGenuineRerun = recordCompletedScreenshotAnalysis(eligible: true) ?? false
                venueRecovery.present(ScreenshotVenueRecovery(
                    token: token,
                    outcome: outcome,
                    kind: kind,
                    wasGenuineRerun: wasGenuineRerun
                ))
            }
            return
        }
        var edits = screenshotManualEdits
        if let confirmedVenueRecovery, case .manualMismatch = confirmedVenueRecovery.kind {
            // D's explicit choice replaces only the requester-owned location.
            edits.hasManuallyEditedLocation = false
        }
        let applied = screenshotProposalStore.apply(
            outcome,
            manualEdits: edits,
            to: &draft,
            venueConfirmation: confirmedVenueRecovery != nil
        )
        screenshotManualEdits = edits
        screenshotManualEdits.record(applied)
        if applied.establishedMenuPath { screenshotProvenance.menuPath = true }
        if applied.location { screenshotProvenance.location = true }
        if applied.mealSwipes { screenshotProvenance.mealSwipes = true }
        if applied.diningDollarsOnly { screenshotProvenance.diningDollarsOnly = true }
        mealSwipeMismatch.present(applied.suggestedMealSwipes, for: token, applied: applied)
        menuPathConflict.present(
            applied.suggestedMenuPath,
            outcome: outcome,
            for: token,
            venueConfirmation: confirmedVenueRecovery
        )
        if applied.orderDetails { screenshotProvenance.orderDetails = true }
        screenshotProvenance.mealItemNames.formUnion(applied.mealItemNames)
        screenshotProvenance.mealItemDetails.formUnion(applied.mealItemDetails)

        var feedbackApplied = applied
        if applied.suggestedMenuPath != nil {
            // The inline path assistance is the entire conflict treatment.
            feedbackApplied.preservedManualFieldCount = 0
        }
        let wasGenuineRerun = confirmedVenueRecovery?.wasGenuineRerun
            ?? recordCompletedScreenshotAnalysis(eligible: outcome.eligible)
        if let wasGenuineRerun,
           let feedbackTimeoutGeneration = preservedEntryFeedback.showPreservedEntryFeedback(
            wasGenuineRerun: wasGenuineRerun,
            applying: feedbackApplied
           ) {
            // Fenced only by the feedback's own generation: the store token
            // goes stale on disappearance or disablement, and gating on it
            // would strand the visible message.
            Task {
                try? await Task.sleep(for: Self.preservedEntryFeedbackDuration)
                preservedEntryFeedback.clearAfterTimeout(
                    ifCurrent: feedbackTimeoutGeneration
                )
            }
        }

        // W4-R2 motion: only the fields this exact call changed receive the
        // brief restrained afterglow — no sequential animation, no haptic.
        // Fenced by the same token every other stage here checks, so a
        // superseded selection's delayed clear cannot erase a later
        // selection's still-current afterglow.
        guard !applied.isEmpty else { return }
        screenshotAfterglowFields = applied
        Task {
            try? await Task.sleep(for: Self.afterglowDuration)
            guard screenshotProposalStore.isCurrent(token) else { return }
            screenshotAfterglowFields = ScreenshotProposalAppliedFields()
        }
    }

    /// The only explicit A/D crossing of the store's application gate.
    /// Confirmation applies the held, already-validated outcome through the
    /// ordinary field-level precedence/path rules; it never re-analyzes.
    @MainActor
    private func confirmVenueRecovery(_ recovery: ScreenshotVenueRecovery) {
        guard venueRecovery.recovery == recovery,
              screenshotProposalStore.isCurrent(recovery.token) else { return }
        venueRecovery.clear()
        applyScreenshotOutcome(
            recovery.outcome,
            token: recovery.token,
            confirmedVenueRecovery: recovery
        )
    }

    /// Completion is separate from field application for held A/D outcomes.
    /// B/C never reach this seam.
    @discardableResult
    private func recordCompletedScreenshotAnalysis(eligible: Bool) -> Bool? {
        guard eligible else { return nil }
        screenshotChecked = true
        return preservedEntryFeedback.recordCompletedAnalysis(eligible: true)
    }

    static let afterglowDuration: Duration = .milliseconds(900)

    static let filledFromScreenshotLabel = "Suggested"
    static let preservedEntryFeedbackMessage =
        "Screenshot checked. Your existing entries were kept."
    /// Kept as a named seam so the temporary acknowledgement's intended
    /// lifetime is inspectable without a fragile wall-clock test.
    static let preservedEntryFeedbackDuration: Duration = .seconds(3)

    /// The only path that may set `screenshotManualEdits.hasManuallyEditedMealSwipes`
    /// — latches on genuine user interaction with the picker, including
    /// reselecting the same value, and never on a store-applied proposal
    /// write (which mutates `draft.mealSwipes` directly).
    private var mealSwipesBinding: Binding<Int> {
        Binding(
            get: { draft.mealSwipes },
            set: { newValue in
                draftSession.setMealSwipesManually(newValue)
                mealSwipeMismatch.clear()
            }
        )
    }

    /// The only path that may set
    /// `screenshotManualEdits.hasManuallyEditedLocation` — latches on a real
    /// picker interaction that leaves a real value selected. Selecting `nil`
    /// ("Select a spot") is a manual clear (W4-R2 2026-08-31 sync): the field
    /// becomes empty and unlatches, so it is eligible for a future screenshot
    /// suggestion again rather than permanently locked requester-owned-empty.
    /// A store-applied proposal write never goes through this binding.
    private var selectedDiningSpotBinding: Binding<DiningSpot?> {
        Binding(
            get: { draft.selectedDiningSpot },
            set: { newValue in
                draft.selectedDiningSpot = newValue
                screenshotManualEdits.hasManuallyEditedLocation = newValue != nil
                screenshotProvenance.location = false
            }
        )
    }

    /// Name and Details each acquire authority only from their own current,
    /// non-empty manual value. This is deliberately not a whole-meal latch.
    private func mealItemNameBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { draft.mealEntries[index].name },
            set: { newValue in
                draft.mealEntries[index].name = newValue
                recordManualMealItemNameEdit(index, hasContent: !newValue.isEmpty)
            }
        )
    }

    private func mealItemDetailsBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { draft.mealEntries[index].details ?? "" },
            set: { newValue in
                draft.mealEntries[index].details = newValue.isEmpty ? nil : newValue
                recordManualMealItemDetailsEdit(index, hasContent: !newValue.isEmpty)
            }
        )
    }

    private func recordManualMealItemNameEdit(_ index: Int, hasContent: Bool) {
        if hasContent {
            screenshotManualEdits.manuallyEditedMealItemNames.insert(index)
        } else {
            screenshotManualEdits.manuallyEditedMealItemNames.remove(index)
        }
        screenshotProvenance.mealItemNames.remove(index)
    }

    private func recordManualMealItemDetailsEdit(_ index: Int, hasContent: Bool) {
        if hasContent {
            screenshotManualEdits.manuallyEditedMealItemDetails.insert(index)
        } else {
            screenshotManualEdits.manuallyEditedMealItemDetails.remove(index)
        }
        screenshotProvenance.mealItemDetails.remove(index)
    }

    /// The Dining-Dollars-only order-details field, under the same
    /// manual-precedence rule as a meal entry.
    private var orderDetailsBinding: Binding<String> {
        Binding(
            get: { draft.orderDetails },
            set: { newValue in
                draft.orderDetails = newValue
                screenshotManualEdits.hasManuallyEditedOrderDetails = !newValue.isEmpty
                screenshotProvenance.orderDetails = false
            }
        )
    }

    /// The field edits the ACTIVE branch's amount only (W4-R4.1). The
    /// narrowly supported current-cart estimate fills the Meal Exchange top-up
    /// alone and remains requester-owned: any nonempty manual edit of the
    /// top-up prevents a later proposal from replacing it. Typing the
    /// Dining-Dollars-only amount touches neither the top-up draft nor its
    /// manual-edit flag.
    private var diningDollarsBinding: Binding<String> {
        Binding(
            get: { draft.diningDollarsText },
            set: {
                draft.diningDollarsText = $0
                if draft.menuPath == .mealExchange {
                    screenshotManualEdits.hasManuallyEditedDiningDollars = !$0.isEmpty
                } else {
                    screenshotManualEdits.hasManuallyEditedDiningDollarsOnly = !$0.isEmpty
                    screenshotProvenance.diningDollarsOnly = false
                }
            }
        )
    }

    /// Switching menus destroys nothing: the meal entries, order details, and
    /// BOTH branches' typed amounts survive a switch (W4-R4.1 keeps the Meal
    /// Exchange top-up and the Dining-Dollars-only amount as separate drafts),
    /// so a requester who changes their mind twice finds their own words still
    /// there. Which of them are submitted is decided by `menuPath` at
    /// submission, not by clearing fields here. An actual requester change
    /// becomes requester-owned
    /// (`recordMenuPathSelection`); re-selecting the current option is a no-op.
    private var menuPathBinding: Binding<RequestMenuPath> {
        Binding(
            get: { draft.menuPath },
            set: { newValue in
                screenshotManualEdits.recordMenuPathSelection(from: draft.menuPath, to: newValue)
                if newValue != draft.menuPath {
                    menuPathConflict.clear()
                    screenshotProvenance.menuPath = false
                }
                draft.menuPath = newValue
                if newValue != .mealExchange { mealSwipeMismatch.clear() }
            }
        )
    }

    private var preferredPickupTimeBinding: Binding<Date> {
        Binding(
            get: { draft.preferredPickupTime },
            set: { draft.preferredPickupTime = $0 }
        )
    }

    /// The sheet is open exactly while the identity store has a flow running.
    /// Read-only from this screen's side — dismissing it goes through
    /// `cancelVerification()`, so an abandoned flow is abandoned in one place.
    private var isPresentingVerification: Binding<Bool> {
        Binding(
            get: { verificationCoordinator.isPresentingRequestCreationVerification },
            set: { isPresented in
                if !isPresented {
                    verificationCoordinator.requesterSheetDismissed()
                }
            }
        )
    }

    /// The blocked screen (W4-D2 state 1: exact recovery identity known,
    /// outcome unresolved). It deliberately renders no fields and no submit
    /// control — there is nothing here to correct and nothing to resend.
    /// No haptic: D1 unresolved is neither success nor error semantics.
    private var blockedByAmbiguityView: some View {
        unresolvedCreateAmbiguityView(isActivelyChecking: false)
    }

    /// The same state while an exact reconciliation is actually running: the
    /// `Check again` action is replaced by progress until it answers.
    private var checkingCreateAmbiguityView: some View {
        unresolvedCreateAmbiguityView(isActivelyChecking: true)
    }

    /// Faith's final 2026-09-17 copy. `Check again` appears only when the
    /// store says another exact reconciliation can change the answer. `Go to
    /// Home` is ordinary navigation, present because leaving is always safe
    /// and the durable record survives this screen closing. There is no
    /// separate `Checking your request` screen: while reconciliation is in
    /// flight the requester stays on this exact screen and the primary
    /// action's own label becomes `Checking…`.
    private func unresolvedCreateAmbiguityView(isActivelyChecking: Bool) -> some View {
        let copy = Self.presentedRecoveryCopy(for: Self.unresolvedRecovery(store.createRecoveryPresentation))
        return recoveryStateView(systemName: "ellipsis", copy: copy) {
            if isActivelyChecking {
                Button {
                } label: {
                    HStack(spacing: CommonPlateStyle.Spacing.xs) {
                        ProgressView()
                        Text(Self.checkingAgainLabel)
                    }
                    .frame(maxWidth: CommonPlateStyle.Control.majorActionMaximumWidth)
                }
                .buttonStyle(.borderedProminent)
                .disabled(true)
                .accessibilityIdentifier("request-checking-again")
            } else if let action = copy.actionLabel {
                Button(action) {
                    checkAgain()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: CommonPlateStyle.Control.majorActionMaximumWidth)
                .accessibilityIdentifier("request-check-again")
            }

            Button(Self.goToHomeLabel) {
                onExit()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("request-ambiguous-dismiss")
        }
        .accessibilityIdentifier(isActivelyChecking ? "request-checking-ambiguity" : "request-blocked-ambiguity")
    }

    /// W4-D2 state 2: a pending operation exists but its recovery identity
    /// cannot be read. No recovery action of any kind; `Go to Home` is only
    /// the ordinary way out, so this is never a dead end. No haptic.
    private var createIdentityUnavailableView: some View {
        recoveryStateView(
            systemName: "exclamationmark",
            copy: Self.presentedRecoveryCopy(for: .identityUnavailable)
        ) {
            Button(Self.goToHomeLabel) {
                onExit()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("request-ambiguous-dismiss")
        }
        .accessibilityIdentifier("request-identity-unavailable")
    }

    /// W4-D2 state 3: authoritative terminal NO-CREATE, split 2026-09-17 into
    /// Path A (`Return to request`, submitted information recoverable) and
    /// Path B (`Start a new request`, information genuinely unavailable) —
    /// decided by which of the two `.notCreated…` cases
    /// `store.createRecoveryPresentation` reports. FIX 2026-09-18
    /// (independent-review MUST FIX 1): this view never holds the raw
    /// `CreateRequestPayload` — `returnToRequest()` asks the store to
    /// consume and restore it. Neither path resends or reuses the
    /// terminalized operation identity; a later submission always mints a
    /// fresh one.
    private var createNotPostedView: some View {
        let isRecoverable = store.createRecoveryPresentation == .notCreatedRecoverable
        let copy = Self.presentedRecoveryCopy(for: store.createRecoveryPresentation)
        return recoveryStateView(systemName: "xmark", copy: copy) {
            if let action = copy.actionLabel {
                Button(action) {
                    if isRecoverable {
                        returnToRequest()
                    } else {
                        startNewRequest()
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: CommonPlateStyle.Control.majorActionMaximumWidth)
                .accessibilityIdentifier(isRecoverable ? "request-return-to-request" : "request-start-new")
            }

            Button(Self.goToHomeLabel) {
                onExit()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("request-not-posted-dismiss")
        }
        .accessibilityIdentifier("request-not-posted")
    }

    /// The shared centered layout of the three W4-D2 recovery states.
    private func recoveryStateView<Actions: View>(
        systemName: String,
        copy: RequestCreateRecoveryCopy,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: CommonPlateStyle.Spacing.l) {
            statusIcon(systemName: systemName)

            VStack(spacing: CommonPlateStyle.Spacing.xs) {
                Text(copy.headline)
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)

                Text(copy.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("request-submission-error")
            }
            .frame(maxWidth: CommonPlateStyle.Metrics.stateContentWidth)

            VStack(spacing: CommonPlateStyle.Spacing.m) {
                actions()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(CommonPlateStyle.Color.baseCanvas)
    }

    private func checkAgain() {
        Task {
            guard await store.reconcilePendingCreateOperationIfNeeded() else { return }
            // Backend authority says this exact operation created the
            // request: the same authoritative success a submission gets.
            didCreateRequest = true
            draftSession.clearAfterAuthoritativeCreation()
        }
    }

    /// W4-D2 FIX 2026-09-18 (independent-review MUST FIX 2): the one place
    /// Path A and Path B reset every form-local presentation field that must
    /// not survive a terminal-recovery replacement, so the two paths can
    /// never drift apart on what they clear. Covers validation/error
    /// presentation, the local rejection pointer, focus, screenshot
    /// selection/analysis/afterglow/check state, and picker state. Never
    /// touches `draftSession` — that boundary is
    /// `RequestFoodDraftSession`'s own terminal-recovery operations, called
    /// separately by each path below.
    ///
    /// FIX (rereview MUST FIX 3): the fields `RequestFoodMountedPresentationState`
    /// owns are round-tripped through its own `resetForTerminalRecovery(_:)`
    /// — the exact production reset a test can exercise directly — rather
    /// than assigned inline here, so this method and the tested seam can
    /// never drift apart. `focusedField`/`selectedScreenshotItems` stay
    /// directly assigned, matching their declaration's own reasoning above.
    private func resetFormLocalPresentationState() {
        var mountedState = RequestFoodMountedPresentationState(
            validationPresentation: validationPresentation,
            submissionError: submissionError,
            showsLocalRejectionPointer: showsLocalRejectionPointer,
            isShowingFailureSummary: isShowingFailureSummary,
            isPresentingScreenshotPicker: isPresentingScreenshotPicker,
            isPresentingExactTimePicker: isPresentingExactTimePicker,
            isPresentingTimingInfo: isPresentingTimingInfo,
            screenshotAfterglowFields: screenshotAfterglowFields,
            screenshotChecked: screenshotChecked,
            mealSwipeMismatch: mealSwipeMismatch,
            venueRecovery: venueRecovery,
            preservedEntryFeedback: preservedEntryFeedback,
            expandedMealIndex: expandedMealIndex,
            textModeration: textModeration
        )
        // Retires any in-flight analysis and its notice for the previous
        // selection, exactly like leaving the screen would — this replaces
        // the form/draft without navigating away, so nothing else does this.
        mountedState.resetForTerminalRecovery(screenshotProposalStore: screenshotProposalStore)
        validationPresentation = mountedState.validationPresentation
        submissionError = mountedState.submissionError
        showsLocalRejectionPointer = mountedState.showsLocalRejectionPointer
        isShowingFailureSummary = mountedState.isShowingFailureSummary
        focusedField = nil
        focusedFieldMenuPath = nil
        selectedScreenshotItems = []
        isPresentingScreenshotPicker = mountedState.isPresentingScreenshotPicker
        isPresentingExactTimePicker = mountedState.isPresentingExactTimePicker
        isPresentingTimingInfo = mountedState.isPresentingTimingInfo
        textModeration = mountedState.textModeration
        screenshotAfterglowFields = mountedState.screenshotAfterglowFields
        screenshotChecked = mountedState.screenshotChecked
        mealSwipeMismatch = mountedState.mealSwipeMismatch
        venueRecovery = mountedState.venueRecovery
        menuPathConflict.clear()
        preservedEntryFeedback = mountedState.preservedEntryFeedback
        expandedMealIndex = mountedState.expandedMealIndex
    }

    /// W4-D2 Path B: opens the ordinary empty Request Food form. Never
    /// reconstructs, guesses, or content-matches the old request information
    /// — the draft session is reset to its plain default, exactly like a
    /// fresh entry into this screen.
    private func startNewRequest() {
        store.acknowledgeCreateNotPosted()
        draftSession.startEmptyAfterTerminalRecovery()
        resetFormLocalPresentationState()
        Task {
            await store.refreshRequestCreationAvailability()
        }
    }

    /// W4-D2 Path A: restores only the exact frozen `CreateRequestPayload`
    /// behind the terminal NO-CREATE notice into the request form. FIX
    /// 2026-09-18 (independent-review MUST FIX 1): the raw payload never
    /// reaches this view — `consumeRecoverableDraftForReturnToRequest()`
    /// consumes it store-side and hands back only the restored draft. Does
    /// not submit, does not reconcile, and does not reuse the terminalized
    /// operation identity — the next intentional Submit goes through the
    /// ordinary `createRequest` path and mints a fresh one.
    ///
    /// FIX (rereview MUST FIX 2): a `nil` consume means Path A is no longer
    /// current — already consumed, already acknowledged, or superseded by a
    /// fresh submission since this action was offered — not that Path B is
    /// now authoritative. It must never mutate the form, clear an
    /// already-restored draft, or start an empty request; the store's own
    /// current presentation, not this stale action, decides what the
    /// requester sees next.
    private func returnToRequest() {
        guard let restoredDraft = store.consumeRecoverableDraftForReturnToRequest() else {
            return
        }
        draftSession.replaceForTerminalRecovery(restoring: restoredDraft)
        resetFormLocalPresentationState()
        Task {
            await store.refreshRequestCreationAvailability()
        }
    }

    /// W4-R2 Posting: one native indeterminate progress owner, centered, no
    /// percentage and no haptic. Reached only from an ordinary in-flight
    /// submission (`store.isCreating` with no unresolved ambiguity); resolves
    /// into `.success` (one haptic, direct replacement in the same locus) or
    /// `definitiveFailureView` (one haptic).
    private var postingView: some View {
        VStack(spacing: CommonPlateStyle.Spacing.m) {
            ProgressView()
                .controlSize(.large)
                // W4-R2: the one native indeterminate progress owner tinted
                // CommonPlate purple — no custom progress/percentage/stages,
                // no start haptic.
                .tint(Color("AccentColor"))
            Text(Self.postingTitle)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .padding(.bottom, 60)
        .background(CommonPlateStyle.Color.baseCanvas)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("request-posting")
    }

    /// W4-R2 definitive failure: a centered result state (not the ordinary
    /// editable form) naming what happened, the exact draft that is still
    /// saved, and one way back into it. The title is the approved Figma
    /// wording; the subtitle is the existing, already-approved per-error
    /// `error.message` — preserving the distinct guidance those messages
    /// already carry (e.g. a rate limit or verification issue reads
    /// differently from an ordinary creation failure) rather than collapsing
    /// every definitive outcome into one generic sentence. The draft summary
    /// restates only already-entered field values — vendor, timing, quantity
    /// — never new copy. `Review draft` returns to the exact same,
    /// still-intact `RequestFoodFormDraft`; nothing here clears or mutates it.
    private func definitiveFailureView(error: RequestCreatePresentationError) -> some View {
        VStack(spacing: CommonPlateStyle.Spacing.l) {
            statusIcon(systemName: "xmark")

            VStack(spacing: CommonPlateStyle.Spacing.xs) {
                Text(Self.definitiveFailureTitle)
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)

                Text(error.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("request-submission-error")
            }
            .frame(maxWidth: CommonPlateStyle.Metrics.stateContentWidth)

            VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
                Text(Self.savedDraftLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("request-saved-draft-label")

                Text(Self.draftSummaryText(for: draft))
                    .font(.subheadline)
                    .accessibilityIdentifier("request-saved-draft-summary")
            }
            .frame(maxWidth: CommonPlateStyle.Metrics.stateContentWidth, alignment: .leading)
            .padding(CommonPlateStyle.Spacing.m)
            .background(
                CommonPlateStyle.Color.warmSurface,
                in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
            )

            Spacer(minLength: 0)

            Button(Self.reviewDraftLabel) {
                isShowingFailureSummary = false
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: CommonPlateStyle.Control.majorActionMaximumWidth)
            .accessibilityIdentifier("request-review-draft")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(CommonPlateStyle.Color.baseCanvas)
    }

    /// The soft circular icon badge shared by every W4-R2 status state
    /// (approved Figma `Requester / Status` component).
    private func statusIcon(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.title2.weight(.semibold))
            .foregroundStyle(Color("AccentColor"))
            .frame(width: 56, height: 56)
            .background(CommonPlateStyle.Color.warmSurface, in: Circle())
            .accessibilityHidden(true)
    }

    static let goToHomeLabel = "Go to Home"
    // W4-D2 recovery copy (Faith's final 2026-09-17 recovery-UX decision,
    // superseding the 2026-09-16 copy below it replaced).
    static let unresolvedCreateHeadline = "Your request may have posted"
    static let unresolvedCreateBody = "\(AppBrand.name) couldn’t confirm whether your request posted."
    static let checkAgainLabel = "Check again"
    /// The primary action's own loading label while `Check again`'s
    /// reconciliation is in flight — never a separate screen.
    static let checkingAgainLabel = "Checking…"
    static let identityUnavailableHeadline = "We can’t safely confirm what happened to this request."
    static let identityUnavailableBody = "To prevent a duplicate, \(AppBrand.name) won’t submit another request."
    static let notPostedHeadline = "Your request wasn’t posted"
    /// Path A: the submitted request information is recoverable.
    static let notPostedRecoverableBody =
        "Your request details are still here. Return to your request to review them before submitting again."
    static let returnToRequestLabel = "Return to request"
    /// Path B: the submitted request information is genuinely unavailable.
    static let notPostedUnavailableBody = "You’ll need to enter the request details again."
    static let startNewRequestLabel = "Start a new request"
    static let postingTitle = "Posting request…"
    static let definitiveFailureTitle = "Your request wasn’t posted"
    static let savedDraftLabel = "SAVED DRAFT"
    static let reviewDraftLabel = "Review draft"

    /// A truthful restatement of only already-entered draft values — vendor,
    /// timing, quantity — never new copy and never anything the backend
    /// returned.
    static func draftSummaryText(for draft: RequestFoodFormDraft) -> String {
        let vendor = draft.selectedDiningSpot?.name ?? "—"
        let quantity = RequestCardView.mealSwipesText(draft.mealSwipes)
        let timing: String
        switch draft.timing {
        case .asap:
            timing = "ASAP"
        case .later:
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            formatter.timeZone = NYUCampusTime.timeZone
            timing = formatter.string(from: draft.preferredPickupTime)
        }
        return "\(vendor) · \(quantity) · \(timing)"
    }

    /// The headline, body, and at most one recovery action for a W4-D2
    /// recovery state. `nil` when there is nothing to present.
    static func recoveryCopy(
        for recovery: RequestCreateRecoveryPresentation
    ) -> RequestCreateRecoveryCopy? {
        switch recovery {
        case .none:
            return nil
        case .unresolved(let canCheckAgain):
            return RequestCreateRecoveryCopy(
                headline: unresolvedCreateHeadline,
                body: unresolvedCreateBody,
                actionLabel: canCheckAgain ? checkAgainLabel : nil
            )
        case .identityUnavailable:
            return RequestCreateRecoveryCopy(
                headline: identityUnavailableHeadline,
                body: identityUnavailableBody,
                actionLabel: nil
            )
        case .notCreatedRecoverable:
            return RequestCreateRecoveryCopy(
                headline: notPostedHeadline,
                body: notPostedRecoverableBody,
                actionLabel: returnToRequestLabel
            )
        case .notCreatedUnavailable:
            return RequestCreateRecoveryCopy(
                headline: notPostedHeadline,
                body: notPostedUnavailableBody,
                actionLabel: startNewRequestLabel
            )
        }
    }

    /// `recoveryCopy` for a state a view is actually rendering. `.none` is
    /// never rendered; if it were, it would read as unresolved with no check.
    static func presentedRecoveryCopy(
        for recovery: RequestCreateRecoveryPresentation
    ) -> RequestCreateRecoveryCopy {
        recoveryCopy(for: recovery) ?? RequestCreateRecoveryCopy(
            headline: unresolvedCreateHeadline,
            body: unresolvedCreateBody,
            actionLabel: nil
        )
    }

    /// The blocked state always presents as unresolved. A block the store has
    /// not described (which no current path produces) offers no check,
    /// rather than one that could do nothing.
    static func unresolvedRecovery(
        _ recovery: RequestCreateRecoveryPresentation
    ) -> RequestCreateRecoveryPresentation {
        if case .unresolved = recovery {
            return recovery
        }
        return .unresolved(canCheckAgain: false)
    }

    /// Only confirmed availability reveals the form. An `.unknown` result after
    /// a completed probe becomes retryable once no check is running.
    static func presentation(
        hasUnresolvedCreateAmbiguity: Bool,
        availability: RequestCreationAvailability,
        isCheckingAvailability: Bool,
        hasAttemptedAvailabilityCheck: Bool,
        didCreateRequest: Bool,
        /// Defaults to `false` so every existing call site not concerned with
        /// the W4-R2 centered Posting/Checking states is unaffected: passing
        /// no value reproduces the exact presentation this function already
        /// returned before those states existed.
        isCreating: Bool = false,
        /// W4-D2 store-owned recovery state. Defaults to `.none` so existing
        /// call sites keep the presentation they already had.
        createRecovery: RequestCreateRecoveryPresentation = .none
    ) -> RequestFormPresentation {
        // First, ahead of everything. A paused or unresolved availability answer
        // is true but beside the point once a create may already have posted:
        // showing it would replace the one warning that matters with a smaller
        // one, and the student would leave thinking nothing had happened.
        if hasUnresolvedCreateAmbiguity {
            if createRecovery == .identityUnavailable {
                return .createIdentityUnavailable
            }
            // D1 reconciliation actively running (`isCreating`) stays on this
            // same unresolved screen with its primary action reading
            // `Checking…` — never a separate screen; already-resolved
            // still-unresolved ambiguity reads the static warning with its
            // one `Go to Home` exit. Neither carries success/error semantics.
            return isCreating ? .checkingCreateAmbiguity : .blockedByUnresolvedCreateAmbiguity
        }

        if didCreateRequest {
            return .success
        }

        // W4-D2: the earlier operation authoritatively did not post. Said
        // once, ahead of the form, until the requester chooses `Return to
        // request` or `Start a new request`.
        if createRecovery == .notCreatedRecoverable || createRecovery == .notCreatedUnavailable,
           !isCreating {
            return .createNotPosted
        }

        // An ordinary submission in flight (never true except from `.form`,
        // since only that state's Submit action calls `store.createRequest`)
        // replaces the form with the centered Posting state until an
        // authoritative answer exists.
        if isCreating {
            return .posting
        }

        switch availability {
        case .available:
            return .form
        case .unknown:
            if isCheckingAvailability {
                return .checkingAvailability
            }
            return hasAttemptedAvailabilityCheck
                ? .unavailable(message: availabilityUnknownNotice, retryable: true)
                // Nothing has run yet — the screen's own `.task` is about to
                // start the first probe. Withheld, never retryable: there is
                // nothing to retry.
                : .checkingAvailability
        case .paused:
            return .unavailable(message: pauseNotice, retryable: false)
        case .unavailable:
            return .unavailable(message: availabilityUnknownNotice, retryable: true)
        }
    }

    /// W4-R2 2026-08-31 round-2 sync: Back is available for every ordinary
    /// state — including D1 ambiguity, availability checks/unavailable, and
    /// the ordinary/failure form — and suppressed only for the transient
    /// Posting/Success submission sequence, which supplies its own exit
    /// (Posting resolves on its own; Success dismisses natively after its
    /// dwell). No other exit replaces the suppressed Back control.
    static func shouldSuppressBackNavigation(presentation: RequestFormPresentation) -> Bool {
        switch presentation {
        case .posting, .success:
            return true
        case .blockedByUnresolvedCreateAmbiguity, .checkingCreateAmbiguity,
             .createIdentityUnavailable, .createNotPosted,
             .checkingAvailability, .unavailable, .form:
            return false
        }
    }

    private var availabilityCheckView: some View {
        ProgressView("Checking availability…")
            .padding()
    }

    private func unavailableView(message: String, retryable: Bool) -> some View {
        VStack(spacing: 16) {
            Text(message)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("request-unavailable-notice")

            if retryable {
                Button("Try Again") {
                    Task {
                        await store.refreshRequestCreationAvailability()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }

    /// W4-D2 Success→Home continuity handoff.
    ///
    /// The Success presentation itself — the actual created requester-owned
    /// card rising from below, its restrained settle, `Request posted`, the
    /// one success haptic, the one VoiceOver announcement, the Home reveal,
    /// and the landing into Home's real first owned slot — is owned by
    /// `RequestCreationContinuityView`, mounted above the navigation stack
    /// (see that file for why a pushed screen structurally cannot perform
    /// that landing). By the time this state is reachable, that overlay is
    /// already covering the screen opaquely, so this state's only remaining
    /// job is to remove this now-finished screen underneath it — the
    /// requester never sees this happen, and Home is therefore already
    /// mounted, laid out, and publishing its real first-slot geometry well
    /// before the landing begins.
    ///
    /// It renders the plain canvas rather than any copy or icon because
    /// nothing here is meant to be seen: a second `Request posted`, a
    /// checkmark, or a second card underneath the overlay would be exactly
    /// the duplicate-card defect this replaces.
    ///
    /// Fail-closed: this state is also reached when authoritative CREATED
    /// produced no current-authority continuity to present — an authority
    /// that changed mid-flight, which `applyConfirmed` already refuses to
    /// resolve as this participant's own or to insert. No overlay exists in
    /// that case, and none is fabricated: there is no `Request posted`
    /// without a real card, and no stale earlier card is substituted. The
    /// requester simply returns to Home, whose own authoritative state
    /// governs what is shown there.
    private var successHandoffView: some View {
        CommonPlateStyle.Color.baseCanvas
            .ignoresSafeArea()
            .accessibilityHidden(true)
            .task {
                guard !hasAcknowledgedSuccess else { return }
                hasAcknowledgedSuccess = true
                onExit()
            }
    }

    static let successMessage = RequestCreationContinuityView.successMessage
    /// Faith's accepted total Success dwell, unchanged by W4-D2 and now owned
    /// with the presentation itself — re-exported here so existing call sites
    /// and proofs keep one source of truth rather than two.
    static var successDwellDuration: Duration {
        RequestCreationContinuityMotionPlan.successDwellDuration
    }

    private var requestForm: some View {
        let now = Date()
        let isScheduledTimingAvailable = Self.isScheduledTimingAvailable(
            now: now,
            calendar: calendar
        )
        let timingOptions = Self.availableTimingOptions(now: now, calendar: calendar)
        let quickScheduledTimes = Self.quickScheduledTimes(now: now, calendar: calendar)
        let isLaterActive = draft.timing == .later && isScheduledTimingAvailable
        let errors = validationErrors(now: now)
        let visibleScheduleError = validationPresentation
            .visibleError(for: .pickupSchedule, from: errors)?
            .error

        // W4-R4 (2026-09-26): a stable ScrollView/VStack skeleton with one
        // canonical, fixed inter-section rhythm. Nothing here negotiates spare
        // viewport height: expanding a meal or revealing Later controls
        // changes only that local section, content below it moves naturally,
        // and content above it stays where it is. The one adaptive decision is
        // where `Post request` lives (see `RequesterFormLayoutMetrics`).
        let anchorsPostRequest = anchorsPostRequestDecision ?? false
        let isPlacementMeasured = anchorsPostRequestDecision != nil

        return ScrollView {
            VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
                VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
                    // The content above the path selector is one fixed-flow
                    // section. Its stable `.m` rhythm never changes when a later
                    // Meal Exchange or Timing section grows.
                    VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
                        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
                            Text(Self.yourOrderEyebrow)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)

                            if screenshotProposalStore.isAssistanceAvailable {
                                screenshotAssistanceRow
                            }
                        }

                        if let recovery = venueRecovery.recovery {
                            venueRecoveryCallout(recovery)
                        }

                        if !venueRecoveryIsUnresolved {
                            VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
                                RequesterFormFieldContainer(
                                    label: Self.diningLocationLabel,
                                    manualProvenanceLabel: venueRecovery.showsManualLocationProvenance
                                        ? Self.manuallySelectedLabel : nil,
                                    showsProvenance: screenshotProvenance.location,
                                    isGlowing: screenshotAfterglowFields.location,
                                    provenanceIdentifier: "request-dining-spot-provenance"
                                ) {
                                    diningSpotControl
                                }

                                if let destination = Self.requesterGrubhubURL(
                                    restaurantID: draft.selectedDiningSpot?.id,
                                    menuPath: draft.menuPath
                                ) {
                                    Button {
                                        isShowingGrubhubOpenFailure = false
                                        GrubhubHandoff.open(
                                            destination: destination,
                                            using: { url, completion in openURL(url, completion: completion) }
                                        ) { opened in
                                            isShowingGrubhubOpenFailure = !opened
                                        }
                                    } label: {
                                        Label("View menu on Grubhub", systemImage: "arrow.up.right")
                                            .font(.subheadline.weight(.medium))
                                            .frame(minHeight: 44)
                                            .contentShape(Rectangle())
                                    }
                                    // Keeps the 44pt target but lets it overlap the
                                    // stack spacing, so the link sits closer to
                                    // Dining location and the next section.
                                    .padding(.vertical, -CommonPlateStyle.Spacing.s)
                                    .accessibilityIdentifier("request-view-on-grubhub")
                                    .accessibilityHint("Opens the selected restaurant and menu in Grubhub or your browser.")
                                    .alert("Couldn't open Grubhub", isPresented: $isShowingGrubhubOpenFailure) {
                                        Button("OK", role: .cancel) {}
                                    }
                                }

                                fieldErrorText(
                                    .diningSpot,
                                    errors: errors,
                                    identifier: "request-dining-spot-error"
                                )
                            }
                        }

                        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .firstTextBaseline, spacing: CommonPlateStyle.Spacing.s) {
                                    menuPathLabelText
                                    Spacer(minLength: CommonPlateStyle.Spacing.s)
                                    menuPathProvenance
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    menuPathLabelText
                                    menuPathProvenance
                                }
                            }

                            if let conflict = menuPathConflict.suggestion {
                                menuPathConflictInset(conflict)
                            }

                            menuPathControl
                        }
                    }

                    VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
                        switch draft.menuPath {
                        case .mealExchange:
                            mealExchangeFields(errors: errors)
                        case .diningDollars:
                            diningDollarsOnlyFields(errors: errors)
                        }
                    }

                    // Timing remains one local section. Later-only controls grow
                    // this stack and push only following content down.
                    VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
                            RequesterTimingHeader(
                                isPresentingInfo: $isPresentingTimingInfo,
                                infoIdentifier: "request-timing-info"
                            )

                            // Only the timings that still have a selectable start
                            // are offered, so "Later" cannot be selected when it
                            // is impossible.
                            timingControl(timingOptions: timingOptions)
                                .onChange(of: draft.timing) { _, newTiming in
                                    guard newTiming == .later else {
                                        return
                                    }
                                    if !Self.isValidScheduledWindow(
                                        startingAt: draft.preferredPickupTime,
                                        now: now,
                                        calendar: calendar
                                    ), let firstQuickTime = quickScheduledTimes.first {
                                        draft.preferredPickupTime = firstQuickTime
                                    }
                                }

                            // Withheld once the lapsed-Later error is on screen:
                            // that message already opens with this exact
                            // sentence, and printing it twice would read as two
                            // separate findings about the same closed window.
                            if Self.showsScheduledUnavailableNotice(
                                isScheduledTimingAvailable: isScheduledTimingAvailable,
                                visibleScheduleError: visibleScheduleError
                            ) {
                                Text(Self.scheduledUnavailableNotice)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("scheduled-unavailable-notice")
                            }

                            // W4-R4: Later controls are inserted locally. ASAP
                            // reserves none of their footprint; they grow the
                            // Timing section, content above it stays put, and
                            // content below it moves with the restrained
                            // `laterMotionAnimation` set where the selection
                            // changes (`timingControl`).
                            if isLaterActive {
                                laterTimeChoices(quickTimes: quickScheduledTimes)
                                    .padding(.top, CommonPlateStyle.Spacing.s)
                                    .transition(.opacity)
                            }

                            // This one location is deliberately outside the
                            // available-only DatePicker branch. If time passes
                            // while "Later" is selected, a submitted scheduling
                            // error stays visible beside the timing controls
                            // rather than disappearing with the picker.
                            fieldErrorText(
                                .pickupSchedule,
                                errors: errors,
                                identifier: "request-pickup-schedule-error"
                            )

                        }
                }
                .requesterMeasuringHeight(RequesterFormContentHeightKey.self)

                // Tall form: the action is ordinary scroll content and follows
                // the form. It stays laid out but invisible until the three
                // measurements exist, so a short form never flashes it here
                // before it settles at the bottom.
                if !anchorsPostRequest && !isSoftwareKeyboardVisible {
                    postRequestSection
                        .opacity(isPlacementMeasured ? 1 : 0)
                        .allowsHitTesting(isPlacementMeasured)
                        .accessibilityHidden(!isPlacementMeasured)
                }
            }
            .padding(.horizontal, CommonPlateStyle.Spacing.l)
            .padding(.top, RequesterFormLayoutMetrics.contentTopPadding)
            // ScrollView already respects the device safe area; this small
            // inset is the only bottom clearance beyond it, and the anchored
            // action below uses the same value so the two placements meet.
            .padding(.bottom, RequesterFormLayoutMetrics.contentBottomPadding)
        }
        // Short form: the action occupies the same bottom safe-area position
        // Home's `Request a Meal` uses, outside the scroll content.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if anchorsPostRequest && !isSoftwareKeyboardVisible {
                postRequestSection
                    .padding(.horizontal, CommonPlateStyle.Spacing.l)
                    .padding(.bottom, RequesterFormLayoutMetrics.contentBottomPadding)
                    .background(CommonPlateStyle.Color.baseCanvas)
            }
        }
        // The whole region's height, taken outside the inset so it does not
        // depend on where the action currently is, and outside the keyboard
        // so raising the keyboard cannot flip the action's placement.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: RequesterViewportHeightKey.self,
                    value: proxy.size.height
                )
            }
            .ignoresSafeArea(.keyboard)
        )
        .onPreferenceChange(RequesterViewportHeightKey.self) { value in
            recordLayoutMeasurement { metrics in
                if abs(metrics.viewportHeight - value) > 0.5 { metrics.viewportHeight = value }
            }
        }
        .onPreferenceChange(RequesterFormContentHeightKey.self) { value in
            recordLayoutMeasurement { metrics in
                if abs(metrics.formContentHeight - value) > 0.5 { metrics.formContentHeight = value }
            }
        }
        .onPreferenceChange(RequesterPostRequestHeightKey.self) { value in
            recordLayoutMeasurement { metrics in
                if abs(metrics.postRequestHeight - value) > 0.5 { metrics.postRequestHeight = value }
            }
        }
        .background(CommonPlateStyle.Color.baseCanvas)
        // Native requester controls use the named asset directly. The
        // environment `Color.accentColor` can resolve to system blue on a
        // mounted device despite the asset catalog's global-accent setting.
        .tint(Color("AccentColor"))
        .scrollDismissesKeyboard(.interactively)
        .background(RequesterOutsideInputDismissal())
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isSoftwareKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            isSoftwareKeyboardVisible = false
        }
        .overlay(alignment: .top) {
            if preservedEntryFeedback.isShowing {
                Text(Self.preservedEntryFeedbackMessage)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.vertical, CommonPlateStyle.Spacing.s)
                    .padding(.horizontal, CommonPlateStyle.Spacing.m)
                    .background(
                        CommonPlateStyle.Color.warmSurface,
                        in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                    )
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                    .padding(.top, CommonPlateStyle.Spacing.s)
                    .accessibilityIdentifier("request-screenshot-preserved-feedback")
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: preservedEntryFeedback.isShowing)
        .onChange(of: focusedField) { previousField, currentField in
            let transitionNow = Date()
            if RequestFoodValidationPresentation.blurBelongsToCurrentMenuPath(
                previousField: previousField,
                menuPathAtFocus: focusedFieldMenuPath,
                currentMenuPath: draft.menuPath
            ) {
                validationPresentation.handleFocusTransition(
                    from: previousField,
                    to: currentField,
                    errors: validationErrors(now: transitionNow)
                )
            }
            focusedFieldMenuPath = currentField == nil ? nil : draft.menuPath
        }
        // Meal Exchange ↔ Dining Dollars: the newly selected branch begins
        // visually clean. Values are preserved; only presentation history for
        // branch-specific fields is dropped.
        .onChange(of: draft.menuPath) { _, _ in
            validationPresentation.resetMenuPathSpecificPresentation()
        }
        // Any edit — including switching the timing to ASAP, which is the
        // correction the lapsed-Later message asks for — retires the pointer.
        // The field errors themselves keep updating live on their own terms.
        .onChange(of: draft) { _, _ in
            showsLocalRejectionPointer = false
            // W4-U1.1: the first edit to any moderated value — or any change
            // to which authored text is active — retires the notice for good.
            textModeration = RequestTextModeration.reconciled(
                textModeration,
                draft: draft,
                authority: identityStore.currentAuthority()
            )
        }
        // A replaced participant cannot inherit a refusal made for the
        // previous one.
        .onChange(of: identityStore.identity) { _, _ in
            textModeration = RequestTextModeration.reconciled(
                textModeration,
                draft: draft,
                authority: identityStore.currentAuthority()
            )
        }
    }

    private func recordLayoutMeasurement(_ update: (inout RequesterFormLayoutMetrics) -> Void) {
        update(&layoutMeasurements.metrics)
        let decision = layoutMeasurements.placementDecision
        if decision != anchorsPostRequestDecision {
            anchorsPostRequestDecision = decision
        }
    }

    /// The `Post request` section: an optional local-rejection pointer above
    /// the primary action. Measured wherever it is mounted, so the placement
    /// decision uses its real height.
    @ViewBuilder
    private var postRequestSection: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.s) {
            // Only when the rejection had nowhere to move focus. A
            // backend failure owns this section through
            // `submissionError` and is never replaced or accompanied
            // by the pointer.
            if Self.showsLocalRejectionPointer(
                isPresenting: showsLocalRejectionPointer,
                submissionError: effectiveSubmissionError
            ) {
                Text(Self.localRejectionPointerNotice)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("request-submission-pointer")
            }

            // W4-R2: a backend-authoritative outcome for
            // `effectiveSubmissionError` is never rendered inline
            // here — D1 ambiguity has its own dedicated
            // `blockedByAmbiguityView` and every other definitive
            // outcome has its own dedicated `definitiveFailureView`
            // (`isShowingFailureSummary`), both reached via
            // `presentation(...)` before this form ever re-renders.
            // This section remains reachable only through
            // `effectiveSubmissionError`'s continued use in
            // `isSubmissionEnabled` below, disabling Post request for
            // the same instant it takes to transition away.

            Button {
                Task {
                    await submit()
                }
            } label: {
                Text(Self.postRequestLabel)
            }
            .commonPlatePrimaryAction()
            .disabled(!isSubmissionEnabled)
            .accessibilityIdentifier("request-post-request")
        }
        .requesterMeasuringHeight(RequesterPostRequestHeightKey.self)
    }

    // MARK: - W4-R2 approved `Requester / Form Field` controls

    /// Strict N1 venue/menu lookup only: an unmapped or missing venue shows no
    /// link rather than a generic Grubhub fallback.
    static func requesterGrubhubURL(
        restaurantID: DiningSpot.ID?,
        menuPath: RequestMenuPath
    ) -> URL? {
        guard let restaurantID else { return nil }
        return GrubhubRestaurantDestination.url(restaurantID: restaurantID, menuPath: menuPath)
    }

    /// A custom binding, not `$draft.selectedDiningSpot` directly — see
    /// `selectedDiningSpotBinding`'s declaration. A plain `Menu`, not
    /// `Picker(.menu)`, so no automatic chevron/list-row chrome is added —
    /// the approved field box shows only placeholder/value text.
    private var diningSpotControl: some View {
        Menu {
            Button(Self.selectDiningLocationPlaceholder) {
                selectedDiningSpotBinding.wrappedValue = nil
            }
            ForEach(diningSpots) { spot in
                Button(spot.name) {
                    selectedDiningSpotBinding.wrappedValue = spot
                }
            }
        } label: {
            HStack {
                Text(draft.selectedDiningSpot?.name ?? Self.selectDiningLocationPlaceholder)
                    .font(.subheadline)
                    .foregroundStyle(draft.selectedDiningSpot == nil ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // W4-R2: an obvious native-selectable affordance within the
                // approved bordered field, superseding the former deliberate
                // omission of picker chrome — the catalog/control model is
                // unchanged.
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("request-dining-spot-picker")
        .tint(Color("AccentColor"))
        .accessibilityLabel(
            "\(Self.diningLocationLabel): \(draft.selectedDiningSpot?.name ?? Self.selectDiningLocationPlaceholder)"
        )
    }

    private var venueRecoveryIsUnresolved: Bool {
        guard let recovery = venueRecovery.recovery else { return false }
        if case .unresolved = recovery.kind { return true }
        return false
    }

    private func venueRecoveryCallout(_ recovery: ScreenshotVenueRecovery) -> some View {
        RequesterVenueRecoveryCallout(
            recovery: recovery,
            isAutofillEnabled: draft.selectedDiningSpot != nil,
            canTryOtherScreenshots: screenshotProposalStore.isAssistanceAvailable
                && screenshotProposalStore.isAIAssistanceEnabled && !screenshotProposalStore.isApplying,
            onConfirm: { confirmVenueRecovery(recovery) },
            onDismiss: {
                guard venueRecovery.recovery == recovery,
                      screenshotProposalStore.isCurrent(recovery.token) else { return }
                venueRecovery.dismiss()
            },
            onTryOtherScreenshots: {
                guard screenshotProposalStore.isAIAssistanceEnabled,
                      !screenshotProposalStore.isApplying else { return }
                beginScreenshotAssistanceFlow()
            }
        ) {
            diningSpotControl
        }
    }

    private var menuPathLabelText: some View {
        Text(Self.menuPathLabel)
            .font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var menuPathProvenance: some View {
        // "Manually selected" only explains an override of Screenshot
        // Assistance (it established the path, or is offering one inline). A
        // plain manual choice with no AI check involved shows nothing.
        if screenshotManualEdits.hasManuallyEditedMenuPath,
           screenshotManualEdits.hasScreenshotEstablishedMenuPath
            || menuPathConflict.suggestion != nil {
            Text(Self.manuallySelectedLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("request-menu-path-provenance")
        } else if screenshotProvenance.menuPath {
            Text(Self.filledFromScreenshotLabel)
                .font(.caption2)
                .foregroundStyle(CommonPlateStyle.Color.provenance)
                .accessibilityIdentifier("request-menu-path-provenance")
        }
    }

    private func menuPathConflictInset(_ conflict: ScreenshotMenuPathConflict) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: CommonPlateStyle.Spacing.xs) {
                menuPathConflictMessage(conflict)
                Spacer(minLength: 0)
                menuPathConflictActions(conflict)
            }
            VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
                menuPathConflictMessage(conflict)
                HStack {
                    Spacer(minLength: 0)
                    menuPathConflictActions(conflict)
                }
            }
        }
        .frame(minHeight: 44)
        .padding(.leading, CommonPlateStyle.Spacing.s)
        .background(
            CommonPlateStyle.Color.requestCardSurface.opacity(0.55),
            in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
        )
        .accessibilityIdentifier("request-menu-path-conflict")
    }

    private func menuPathConflictMessage(_ conflict: ScreenshotMenuPathConflict) -> some View {
        Text("We found \(Self.menuPathTitle(conflict.proposedPath))")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func menuPathConflictActions(_ conflict: ScreenshotMenuPathConflict) -> some View {
        HStack(spacing: CommonPlateStyle.Spacing.xs) {
            Button("Switch") {
                guard menuPathConflict.suggestion == conflict,
                      screenshotProposalStore.isCurrent(conflict.token),
                      screenshotManualEdits.hasManuallyEditedMenuPath,
                      draft.menuPath != conflict.proposedPath else { return }
                screenshotManualEdits.hasManuallyEditedMenuPath = false
                menuPathConflict.clear()
                applyScreenshotOutcome(
                    conflict.outcome,
                    token: conflict.token,
                    confirmedVenueRecovery: conflict.venueConfirmation
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(Color("AccentColor"))
            .accessibilityIdentifier("request-switch-screenshot-menu-path")

            Button {
                guard menuPathConflict.suggestion == conflict,
                      screenshotProposalStore.isCurrent(conflict.token) else { return }
                menuPathConflict.dismiss()
            } label: {
                Text("×")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss menu suggestion")
            .accessibilityIdentifier("request-dismiss-screenshot-menu-path")
        }
    }

    /// W4-R4 `Which menu are you using?`: the requester's choice between Meal
    /// Exchange and Dining Dollars. Reuses the same segmented grammar the
    /// accepted `Requester / Timing` control already uses, so the new
    /// selection reads as part of the existing native CommonPlate form
    /// language rather than a new control vocabulary.
    private var menuPathControl: some View {
        HStack(spacing: CommonPlateStyle.Spacing.xs) {
            ForEach(Self.menuPathOptions, id: \.self) { option in
                let isSelected = draft.menuPath == option
                Button {
                    menuPathBinding.wrappedValue = option
                } label: {
                    Text(Self.menuPathTitle(option))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, CommonPlateStyle.Spacing.s)
                        .background(
                            isSelected ? CommonPlateStyle.Color.baseCanvas : Color.clear,
                            in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard - 3, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .accessibilityIdentifier(
                    option == .mealExchange
                        ? "request-menu-path-meal-exchange"
                        : "request-menu-path-dining-dollars"
                )
            }
        }
        .padding(CommonPlateStyle.Spacing.xs)
        .background(
            CommonPlateStyle.Color.requestCardSurface,
            in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("request-menu-path-picker")
    }

    /// The Meal Exchange resource fields: the optional Dining Dollar estimate,
    /// the swipe count, then exactly one required meal-detail field per
    /// selected swipe.
    @ViewBuilder
    private func mealExchangeFields(errors: [RequestFoodFieldError]) -> some View {
        diningDollarsField(
            label: Self.diningDollarsLabel,
            trailingLabel: Self.screenshotAssistanceOptionalLabel,
            placeholder: Self.diningDollarsPlaceholder,
            errors: errors
        )

        RequesterFormFieldContainer(
            label: Self.mealSwipesLabel,
            manualProvenanceLabel: screenshotManualEdits.hasManuallyEditedMealSwipes
                && mealSwipeMismatch.showsManualProvenance ? Self.manuallySelectedLabel : nil,
            showsProvenance: screenshotProvenance.mealSwipes,
            isGlowing: screenshotAfterglowFields.mealSwipes,
            provenanceIdentifier: "request-meal-swipes-provenance",
            assistance: mealSwipeMismatch.suggestion.map { AnyView(mealSwipeMismatchInset($0)) }
        ) {
            mealSwipesControl
        }

        // W4-U1.1: directly above the Meal cards the refusal concerns.
        textModerationSection

        // One stable-position card per selected swipe. Fields above the count
        // are not built and their draft contents remain untouched.
        ForEach(Array(draft.activeMealEntryIndices), id: \.self) { index in
            mealEditorCard(index: index, errors: errors)
        }

    }

    private func mealSwipeMismatchInset(_ mismatch: ScreenshotMealSwipeMismatch) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: CommonPlateStyle.Spacing.xs) {
                mealSwipeMismatchMessage(mismatch)
                Spacer(minLength: 0)
                mealSwipeMismatchActions(mismatch)
            }
            VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
                mealSwipeMismatchMessage(mismatch)
                HStack {
                    Spacer(minLength: 0)
                    mealSwipeMismatchActions(mismatch)
                }
            }
        }
        .frame(minHeight: 44)
        .padding(.leading, CommonPlateStyle.Spacing.s)
        .background(
            CommonPlateStyle.Color.requestCardSurface.opacity(0.55),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .accessibilityIdentifier("request-meal-swipe-mismatch")
    }

    private func mealSwipeMismatchMessage(_ mismatch: ScreenshotMealSwipeMismatch) -> some View {
        Text(mismatch.message)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func mealSwipeMismatchActions(_ mismatch: ScreenshotMealSwipeMismatch) -> some View {
        HStack(spacing: CommonPlateStyle.Spacing.xs) {
            Button(mismatch.action) {
                guard mealSwipeMismatch.suggestion == mismatch,
                      screenshotProposalStore.isCurrent(mismatch.token) else { return }
                var currentDraft = draft
                var currentEdits = screenshotManualEdits
                var currentProvenance = screenshotProvenance
                guard screenshotProposalStore.adoptSuggestedMealSwipes(
                    mismatch.proposedCount,
                    manualEdits: &currentEdits,
                    provenance: &currentProvenance,
                    to: &currentDraft
                ) else { return }
                draft = currentDraft
                screenshotManualEdits = currentEdits
                screenshotProvenance = currentProvenance
                mealSwipeMismatch.clear()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(Color("AccentColor"))
            .accessibilityIdentifier("request-use-screenshot-swipes")

            Button {
                guard mealSwipeMismatch.suggestion == mismatch,
                      screenshotProposalStore.isCurrent(mismatch.token) else { return }
                draftSession.rejectCurrentScreenshotSurplus(
                    above: draft.mealSwipes,
                    names: mismatch.contributedMealItemNames,
                    details: mismatch.contributedMealItemDetails
                )
                mealSwipeMismatch.dismiss()
            } label: {
                Text("×")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss meal swipe suggestion")
            .accessibilityIdentifier("request-dismiss-screenshot-swipes")
        }
    }

    @ViewBuilder
    private func mealEditorCard(index: Int, errors: [RequestFoodFieldError]) -> some View {
        let meal = draft.mealEntries[index]
        let mealNameError = Self.mealItemNamePrompt(for: meal)
            ?? fieldError(.mealDetail(index: index), errors: errors)
        let hasVisibleValidationError = mealNameError != nil
        let isEmptyMealItem = meal.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // W4-R4 (2026-09-28 unified badge sync): the `Meal N` row shows
        // exactly ONE right-aligned provenance indicator, in the identical
        // position whether the Meal is collapsed or expanded. Faith authorized
        // a union rule: the badge appears whenever EITHER field is still
        // screenshot-derived, not only when both are.
        let showsMealSummaryProvenance = !isEmptyMealItem
            && (screenshotProvenance.mealItemNames.contains(index) || screenshotProvenance.mealItemDetails.contains(index))
        RequesterMealEntryControl(
            label: Self.mealDetailLabel(index: index),
            index: index,
            identifierPrefix: "request-meal",
            isExpanded: expandedMealIndex == index,
            mealName: meal.name,
            mealDetails: meal.details,
            hasError: hasVisibleValidationError,
            isGlowing: screenshotAfterglowFields.mealEntries.contains(index),
            onExpand: { expandedMealIndex = index },
            onDone: {
                focusedField = nil
                focusedMealDetailsIndex = nil
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                )
                expandedMealIndex = nil
            },
            trailing: {
                if showsMealSummaryProvenance {
                    screenshotFieldProvenance(
                        "request-meal-summary-provenance-\(index)",
                        isGlowing: screenshotAfterglowFields.mealEntries.contains(index)
                    )
                }
            },
            item: {
                TextField("e.g. Chicken Wings", text: mealItemNameBinding(index), axis: .vertical)
                    .font(Self.mealEditorValueFont)
                    .lineLimit(2)
                    .focused($focusedField, equals: .mealDetail(index: index))
                    .accessibilityIdentifier("request-meal-item-\(index)")
                    .accessibilityHint(Text(mealNameError ?? ""))
            },
            details: {
                TextField(Self.mealDetailsPlaceholder, text: mealItemDetailsBinding(index), axis: .vertical)
                    .font(Self.mealEditorValueFont)
                    .lineLimit(3)
                    .focused($focusedMealDetailsIndex, equals: index)
                    .accessibilityIdentifier("request-meal-details-\(index)")
            }
        )
        if let mealNameError {
            Text(mealNameError)
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("request-meal-error-\(index)")
        }
    }

    static func mealItemNamePrompt(for meal: MealItem) -> String? {
        guard meal.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let details = meal.details,
              !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "Enter a meal item to go with these details."
    }

    /// The same accepted CommonPlate purple provenance treatment used by
    /// `RequesterFormFieldContainer`'s trailing `Suggested`
    /// label (W4-R4 2026-09-28 unified badge sync) — this must not render
    /// gray/secondary while other requester provenance indicators are purple.
    private func screenshotFieldProvenance(_ identifier: String, isGlowing: Bool = false) -> some View {
        Text(Self.filledFromScreenshotLabel)
            .font(.caption2)
            .foregroundStyle(isGlowing ? CommonPlateStyle.Color.provenance : CommonPlateStyle.Color.provenance.opacity(0.82))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: isGlowing)
            .accessibilityIdentifier(identifier)
    }

    /// The Dining-Dollars-only resource fields: one required order-details
    /// value and a required estimate.
    @ViewBuilder
    private func diningDollarsOnlyFields(errors: [RequestFoodFieldError]) -> some View {
        // W4-U1.1: directly above the order details the refusal concerns.
        textModerationSection

        // W4-R4 (2026-09-27): the empty control matches the 76pt collapsed
        // Meal Exchange ordering-control target, NOT the compact Dining
        // Dollars amount-field height (supersedes the 2026-09-26 compact
        // decision). Multiline/wrapping-capable; grows locally as entered
        // content needs more lines. An empty value is incomplete rather than
        // invalid, so no error text is ever attached to this field.
        RequesterFormFieldContainer(
            label: Self.orderDetailsLabel,
            showsProvenance: screenshotProvenance.orderDetails,
            isGlowing: screenshotAfterglowFields.orderDetails,
            provenanceIdentifier: "request-order-details-provenance",
            controlIdentifier: "request-order-details-control"
        ) {
            TextField(Self.orderDetailsPlaceholder, text: orderDetailsBinding, axis: .vertical)
                .font(.subheadline)
                .lineLimit(1...)
                .focused($focusedField, equals: .orderDetails)
                .accessibilityLabel(Self.orderDetailsLabel)
                .accessibilityIdentifier("request-order-details")
                // Top-aligned, not vertically centered, like the Meal entry
                // control it targets. `orderDetailsEmptyContentHeight` is
                // sized so the rendered control (this content plus the
                // container's own 12pt top/bottom padding) reaches the same
                // 76pt target as `collapsedMealControlHeight`.
                .frame(maxWidth: .infinity, minHeight: Self.orderDetailsEmptyContentHeight, alignment: .topLeading)
        }

        diningDollarsField(
            label: Self.diningDollarsRequiredLabel,
            placeholder: Self.diningDollarsPlaceholder,
            errors: errors
        )
    }

    /// The shared Dining Dollar entry field. Ordinary dollar entry with a
    /// decimal keypad; the exact value is parsed to integer cents
    /// (`DiningDollarsEntry`) rather than through any floating-point step.
    private func diningDollarsField(
        label: String,
        trailingLabel: String? = nil,
        placeholder: String,
        errors: [RequestFoodFieldError]
    ) -> some View {
        // An EMPTY required estimate is incomplete, not invalid: it stays
        // neutral (`RequestFoodFormError.isIncompleteEntry`) while `Post
        // request` remains disabled. Only an entered out-of-range or
        // malformed amount shows its message beneath the field.
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
            RequesterFormFieldContainer(
                label: label,
                trailingLabel: trailingLabel,
                showsProvenance: draft.menuPath == .diningDollars
                    && screenshotProvenance.diningDollarsOnly,
                provenanceIdentifier: "request-dining-dollars-provenance",
                controlIdentifier: "request-dining-dollars-control"
            ) {
                TextField(placeholder, text: diningDollarsBinding)
                    .font(.subheadline)
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: .diningDollars)
                    .accessibilityLabel(label)
                    .accessibilityHint(Text(fieldError(.diningDollars, errors: errors) ?? ""))
                    .accessibilityIdentifier("request-dining-dollars")
            }

            fieldErrorText(
                .diningDollars,
                errors: errors,
                identifier: "request-dining-dollars-error"
            )
        }
    }

    /// A custom binding, not `$draft.mealSwipes` directly, so
    /// `screenshotManualEdits.hasManuallyEditedMealSwipes` latches on genuine
    /// user interaction only — never on an AI-applied write, which mutates
    /// `draft` directly rather than through this binding. A bounded menu, not
    /// free-form entry, so this app can never submit a value the backend
    /// would refuse.
    private var mealSwipesControl: some View {
        RequesterMealSwipesMenu(
            count: mealSwipesBinding,
            label: Self.mealSwipesLabel,
            identifier: "request-meal-swipes-picker"
        )
    }

    /// Approved Figma `Requester / Timing` segmented control: same
    /// warm-surface/baseCanvas grammar as the request-card and form-field
    /// tokens, reused rather than native `.pickerStyle(.segmented)`'s system
    /// coloring. Selection/validation authority is unchanged — this is
    /// presentation only.
    private func timingControl(timingOptions: [RequestTiming]) -> some View {
        HStack(spacing: CommonPlateStyle.Spacing.xs) {
            ForEach(timingOptions) { option in
                let isSelected = draft.timing == option
                Button {
                    // The one place Later inserts or leaves. Animating the
                    // change of this one value (not the form) means only what
                    // the insertion actually moves is animated.
                    withAnimation(Self.laterMotionAnimation(reduceMotion: reduceMotion)) {
                        draft.timing = option
                    }
                } label: {
                    Text(option.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, CommonPlateStyle.Spacing.s)
                        .background(
                            isSelected ? CommonPlateStyle.Color.baseCanvas : Color.clear,
                            in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard - 3, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(CommonPlateStyle.Spacing.xs)
        .background(
            CommonPlateStyle.Color.requestCardSurface,
            in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    /// Prototype C's lightweight secondary row. Values are generated from the
    /// same accepted scheduling validator used by submission, so a quick
    /// choice cannot present a time the payload would refuse.
    private func laterTimeChoices(quickTimes: [Date]) -> some View {
        // W4-R2 2026-09-02 sync item 3: the selected pill is the sole source
        // of truth for the selected Later time — no separate `Selected:`
        // line. A custom selection is one whose minute matches none of the
        // current quick choices; `Choose time` then becomes that chosen time
        // and visibly reads as selected, exactly like a quick-time pill.
        let isCustomTimeSelected = !quickTimes.contains {
            Self.isSameCampusMinute($0, draft.preferredPickupTime, calendar: calendar)
        }

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CommonPlateStyle.Spacing.s) {
                ForEach(quickTimes, id: \.self) { time in
                    let isSelected = Self.isSameCampusMinute(
                        time,
                        draft.preferredPickupTime,
                        calendar: calendar
                    )
                    quickTimeButton(time, isSelected: isSelected)
                }

                chooseTimeButton(isCustomTimeSelected: isCustomTimeSelected)
            }
        }
        .tint(Color("AccentColor"))
        .accessibilityElement(children: .contain)
    }

    /// Before a custom selection this reads `Choose time`; after one, it
    /// becomes the effective chosen time and visibly reads as selected —
    /// the same pill-is-the-selection contract `quickTimeButton` already
    /// uses, so there is never a second representation of the custom value.
    @ViewBuilder
    private func chooseTimeButton(isCustomTimeSelected: Bool) -> some View {
        if isCustomTimeSelected {
            Button(Self.timeLabel(for: draft.preferredPickupTime)) {
                isPresentingExactTimePicker = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(Color("AccentColor"))
            .accessibilityAddTraits(.isSelected)
            .accessibilityIdentifier("request-choose-exact-time")
        } else {
            Button(Self.chooseTimeLabel) {
                isPresentingExactTimePicker = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Color("AccentColor"))
            .accessibilityIdentifier("request-choose-exact-time")
        }
    }

    @ViewBuilder
    private func quickTimeButton(_ time: Date, isSelected: Bool) -> some View {
        if isSelected {
            Button(Self.timeLabel(for: time)) {
                draft.preferredPickupTime = time
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(Color("AccentColor"))
            .accessibilityAddTraits(.isSelected)
        } else {
            Button(Self.timeLabel(for: time)) {
                draft.preferredPickupTime = time
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Color("AccentColor"))
        }
    }

    /// Native iOS wheel time selection, completed with the native Done
    /// toolbar action. It writes directly to the mounted request draft.
    private var exactTimePickerSheet: some View {
        let now = Date()
        let latest = Self.latestScheduledStart(on: now, calendar: calendar) ?? now
        let range = min(now, latest)...latest

        return NavigationStack {
            Form {
                DatePicker(
                    Self.chooseTimeLabel,
                    selection: preferredPickupTimeBinding,
                    in: range,
                    displayedComponents: [.hourAndMinute]
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .accessibilityLabel(Self.chooseTimeLabel)
                .accessibilityIdentifier("request-native-time-picker")
            }
            .navigationTitle(Self.chooseTimeLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        isPresentingExactTimePicker = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    static let yourOrderEyebrow = "YOUR ORDER"
    static let diningLocationLabel = "Dining location"
    static let selectDiningLocationPlaceholder = "Choose dining location"
    static let orderDetailsLabel = "What are you ordering?"
    /// Same example-text treatment as the Meal item ordering field
    /// (2026-09-27 supersedes the 2026-09-26 "no placeholder" decision).
    static let orderDetailsPlaceholder = "e.g. Chicken Wings"
    static let mealSwipesLabel = "Number of meal swipes"
    static let manuallySelectedLabel = "Manually selected"
    static let timingLabel = "Timing"
    static let chooseTimeLabel = "Choose time"
    static let postRequestLabel = "Post request"

    // MARK: - W4-R4 structured request copy

    static let menuPathLabel = "Which menu are you using?"
    static let mealExchangeTitle = "Meal Exchange"
    static let diningDollarsTitle = "Dining Dollars"
    static let menuPathOptions: [RequestMenuPath] = [.mealExchange, .diningDollars]

    static func menuPathTitle(_ menuPath: RequestMenuPath) -> String {
        switch menuPath {
        case .mealExchange: return mealExchangeTitle
        case .diningDollars: return diningDollarsTitle
        }
    }

    /// One label per selected swipe, numbered from the requester's point of
    /// view rather than from the zero-based draft index.
    static func mealDetailLabel(index: Int) -> String {
        "Meal \(index + 1)"
    }

    static let mealDetailPlaceholder = "What are you ordering?"
    /// Exact accepted copy for a meal's optional details field (2026-09-26).
    static let mealDetailsPlaceholder = "e.g. Buffalo sauce, chips, fountain drink"

    /// Later's restrained local reveal (~0.22s ease-out). Reduce Motion removes
    /// the animation entirely, so the insertion is an immediate layout change.
    static let laterMotionDuration: Double = 0.22
    static func laterMotionAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: laterMotionDuration)
    }
    /// The Meal label stays outside the 76pt collapsed or 158pt expanded
    /// rounded control.
    static let mealLabelRowHeight: CGFloat = 18
    static let mealLabelToControlSpacing: CGFloat = 7
    static let collapsedMealControlHeight: CGFloat = 76
    static let expandedMealControlHeight: CGFloat = 158
    /// W4-R4 (2026-09-27): `RequesterFormFieldContainer` adds 12pt top/bottom
    /// padding around its content, so the Dining-Dollars-only ordering
    /// field's content must fill this much to reach the same 76pt rendered
    /// control height as the collapsed Meal Exchange entry.
    static let orderDetailsEmptyContentHeight: CGFloat = collapsedMealControlHeight - 24
    /// Entered `Meal item` and entered `Details` share this one value style
    /// (W4-R4 2026-09-26 equal-typography decision).
    static let mealEditorValueFont: Font = .subheadline
    /// Expanded-editor vertical rhythm. `Done` keeps a 44pt native tap target
    /// with deliberate separation from the optional details field.
    static let mealEditorTopInset: CGFloat = 10
    static let mealEditorValueToDividerSpacing: CGFloat = 8
    static let mealEditorDividerToDetailsSpacing: CGFloat = 9
    static let mealEditorDetailsToDoneSpacing: CGFloat = 4
    static let mealEditorBottomInset: CGFloat = 4
    static let diningDollarsLabel = "Dining Dollars"
    static let diningDollarsRequiredLabel = "Dining Dollars"
    static let diningDollarsPlaceholder = "$0.00"
    static let asapTimingNotice =
        "If no one places the order, it expires 3 hours after you post it."
    /// W4-R2 2026-09-02 sync item 4: exact on-demand explanation replacing
    /// the removed persistent `asapTimingNotice`/`scheduledWindowNotice`
    /// subtitles.
    static let timingInfoTitle = "How timing works"
    static let timingInfoBody = """
        ASAP is shown to helpers now.
        Later is shown at your chosen time.
        Requests stay open for up to 3 hours.
        """
    static let timingInfoAccessibilityLabel = "Timing information"
    @MainActor
    private func submit(draftSnapshot: RequestFoodFormDraft? = nil) async {
        submissionError = nil
        showsLocalRejectionPointer = false
        isShowingFailureSummary = false
        // A new intentional submission supersedes any earlier text-filtering
        // notice; the backend answers this one afresh.
        textModeration = nil

        let submittedDraft = draftSnapshot ?? draft
        // Read before the first suspension point, so a refusal that arrives
        // after the participant was replaced can be recognized as stale rather
        // than attributed to whoever is current when it lands.
        let submittedAuthority = identityStore.currentAuthority()

        // The gate, and the whole reason it lives here rather than in the
        // store: `draft` is `@State` on a screen that stays mounted behind the
        // verification sheet, so the completed request survives verification by
        // construction. Nothing is submitted, cleared, or reset on the way in
        // or the way out — a failed, expired, abandoned, or ambiguous
        // verification simply returns to the same filled form.
        if !identityStore.isVerified {
            _ = verificationCoordinator.beginRequestCreation(
                draft: submittedDraft,
                path: path
            )
            return
        }

        let now = Date()
        do {
            let result = try await Self.orchestrateSubmission(
                draft: submittedDraft,
                now: now,
                calendar: calendar,
                presentation: validationPresentation
            ) { payload in
                try await store.createRequest(payload)
            }
            validationPresentation = result.presentation
            if result.didSubmit {
                didCreateRequest = true
                // The store has authoritatively confirmed creation. Clear the
                // completed process/session draft now so a genuinely new
                // Request Food entry cannot inherit it. Ambiguous and failed
                // paths never reach this branch.
                draftSession.clearAfterAuthoritativeCreation()
            } else {
                // A collapsed Meal's editor is mounted but hidden, so it must
                // not be handed focus (it would raise the keyboard for a
                // field nobody can see). Rejection leaves focus alone there,
                // exactly as when the collapsed card had no editor.
                focusedField = Self.focusTargetAfterRejection(
                    result.firstInvalidTextField,
                    expandedMealIndex: expandedMealIndex
                )
                showsLocalRejectionPointer = Self.showsLocalRejectionPointer(for: result)
            }
        } catch {
            // W4-U1.1: the backend's definitive text-filtering refusal is a
            // specific form state, not a failure. Nothing was created, the
            // draft stays whole and editable, and no failure summary, error
            // haptic, or submission error is produced for it.
            if RequestTextModeration.isRefusal(error) {
                presentTextModerationNotice(
                    refusedDraft: submittedDraft,
                    submittedAuthority: submittedAuthority
                )
                return
            }
            // W4-R2 2026-09-05 sync item 6: the real catch path calls the
            // same production-owned decision `submissionFailureOutcome(for:
            // hasUnresolvedCreateAmbiguity:)` a test can drive directly with
            // a real thrown error — not a second, independently-maintained
            // reconstruction of the same map/gate logic.
            let outcome = Self.submissionFailureOutcome(
                for: error,
                hasUnresolvedCreateAmbiguity: store.hasUnresolvedCreateAmbiguity
            )
            submissionError = outcome.mapped
            if outcome.isDefinitiveFailure {
                CommonPlateHaptics.error()
                isShowingFailureSummary = true
            }
        }
    }

    /// W4-U1.1: records the notice for a refusal of `refusedDraft`, but only
    /// while it still describes the form the requester is looking at — the same
    /// participant authority, and the same active authored text. A late answer
    /// for a replaced identity or an already-edited draft is stale and shows
    /// nothing.
    @MainActor
    private func presentTextModerationNotice(
        refusedDraft: RequestFoodFormDraft,
        submittedAuthority: String?
    ) {
        let refusal = RequestTextModeration.state(
            afterRefusalOf: refusedDraft,
            authority: submittedAuthority
        )
        guard RequestTextModeration.isCurrent(
            refusal,
            draft: draft,
            authority: identityStore.currentAuthority()
        ) else {
            return
        }
        textModeration = refusal
    }

    /// The notice for the current draft and identity, or `nil`. Re-checked at
    /// render time so a stale notice can never be drawn.
    private var currentTextModeration: RequestTextModerationState? {
        RequestTextModeration.isCurrent(
            textModeration,
            draft: draft,
            authority: identityStore.currentAuthority()
        ) ? textModeration : nil
    }

    /// The approved section heading with the moderation notice directly
    /// beneath it. Only drawn after a backend refusal that still applies, and
    /// placed ahead of the Meal fields it concerns. It names no Meal, field, or
    /// term; VoiceOver moves to the notice as it appears.
    @ViewBuilder
    private var textModerationSection: some View {
        if currentTextModeration != nil {
            VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.s) {
                Text(RequestTextModeration.sectionHeading)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("request-text-moderation-heading")

                TextModerationNoticeCard(message: RequestTextModeration.noticeCopy)
                .accessibilityFocused($isTextModerationNoticeFocused)
                .accessibilityIdentifier("request-text-moderation-notice")
                .onAppear { isTextModerationNoticeFocused = true }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("request-text-moderation")
        }
    }

    /// The one production-owned decision `submit()`'s real catch path calls
    /// verbatim: map the caught error to its local presentation, then decide
    /// whether it is a definitive non-create (haptic + failure summary) or an
    /// unresolved/write-uncertain outcome, using the exact same
    /// `isDefinitiveNonCreate` gate. Extracted (independent-review fix) so a
    /// test can drive a real ambiguous `REQUEST_CREATION_FAILED` outcome and a
    /// real definitive `INVALID_REQUEST` outcome through this exact function
    /// — the same one `submit()` calls — rather than only reconstructing the
    /// same decision independently against pure functions `submit()` might
    /// stop calling without a test noticing. `mapped` alone is not
    /// authoritative: it is this view's own local presentation mapping of the
    /// caught Swift error, and `RequestStore.createRequest` can arm
    /// `hasUnresolvedCreateAmbiguity` for the exact same server code
    /// (`REQUEST_CREATION_FAILED`) that this local mapping resolves to
    /// `.creationFailed`, a definitive-looking case
    /// (`RequestOperationErrorCode.isWriteUncertain`). Deciding the haptic
    /// from `mapped` alone could therefore fire the authoritative-failure
    /// haptic for a write whose outcome is still unresolved and may in fact
    /// have succeeded. The store's own D1 authority —
    /// `hasUnresolvedCreateAmbiguity`, read fresh by the caller after the
    /// throw — is the one place that actually knows whether this exact write
    /// is unresolved, so it is the deciding signal, not a second local guess
    /// at the same fact.
    static func submissionFailureOutcome(
        for error: Error,
        hasUnresolvedCreateAmbiguity: Bool
    ) -> RequestFoodSubmissionFailureOutcome {
        let mapped = RequestCreatePresentationError.map(error)
        return RequestFoodSubmissionFailureOutcome(
            mapped: mapped,
            isDefinitiveFailure: isDefinitiveNonCreate(
                mapped: mapped,
                hasUnresolvedCreateAmbiguity: hasUnresolvedCreateAmbiguity
            )
        )
    }

    /// The one authoritative decision point for whether a caught submission
    /// error is a definitive non-create (error haptic + failure summary) as
    /// opposed to an unresolved/write-uncertain outcome. An armed
    /// `hasUnresolvedCreateAmbiguity` always outranks the local `mapped`
    /// value: `RequestFoodView.presentation(...)` already renders the D1
    /// blocked/checking states ahead of the ordinary form whenever ambiguity
    /// is armed, so this keeps the haptic/failure-summary side effect
    /// consistent with what the requester actually sees rather than firing a
    /// definitive-failure cue for a write the store itself has not ruled
    /// out. `.operationInProgress` remains excluded regardless: it is a
    /// local in-process guard, never an authoritative backend answer.
    static func isDefinitiveNonCreate(
        mapped: RequestCreatePresentationError,
        hasUnresolvedCreateAmbiguity: Bool
    ) -> Bool {
        guard !hasUnresolvedCreateAmbiguity else { return false }
        return mapped != .ambiguous && mapped != .operationInProgress
    }

    /// Validates and normalizes the draft before invoking submit; `RequestStore`
    /// retains lifecycle and duplicate-operation authority.
    static func orchestrateSubmission(
        draft: RequestFoodFormDraft,
        now: Date,
        calendar: Calendar,
        presentation: RequestFoodValidationPresentation,
        submission: (CreateRequestPayload) async throws -> Void
    ) async throws -> RequestFoodSubmissionResult {
        let scheduledWindowIsValid = isValidScheduledWindow(
            startingAt: draft.preferredPickupTime,
            now: now,
            calendar: calendar
        )
        let errors = RequestFoodFormValidator.validate(
            draft: draft,
            isScheduledWindowValid: scheduledWindowIsValid,
            // Same `now` as the window check above: one snapshot decides both
            // halves of this submission, so they cannot disagree.
            isScheduledTimingAvailable: isScheduledTimingAvailable(
                now: now,
                calendar: calendar
            )
        )
        var updatedPresentation = presentation
        updatedPresentation.presentAll(errors)

        guard errors.isEmpty else {
            return RequestFoodSubmissionResult(
                presentation: updatedPresentation,
                firstInvalidTextField: errors.first { $0.field.isTextField }?.field,
                didSubmit: false
            )
        }

        let payload = try makePayload(draft: draft, now: now, calendar: calendar)
        try await submission(payload)
        return RequestFoodSubmissionResult(
            presentation: updatedPresentation,
            firstInvalidTextField: nil,
            didSubmit: true
        )
    }

    /// Every caller passes the snapshot it is already reasoning about — the
    /// render's `now`, or the focus transition's — so availability, validity,
    /// and what is drawn are all answers about the same instant.
    private func validationErrors(now: Date) -> [RequestFoodFieldError] {
        RequestFoodFormValidator.validate(
            draft: draft,
            isScheduledWindowValid: Self.isValidScheduledWindow(
                startingAt: draft.preferredPickupTime,
                now: now,
                calendar: calendar
            ),
            isScheduledTimingAvailable: Self.isScheduledTimingAvailable(
                now: now,
                calendar: calendar
            )
        )
    }

    private func fieldError(
        _ field: RequestFoodFormField,
        errors: [RequestFoodFieldError]
    ) -> String? {
        validationPresentation.visibleError(for: field, from: errors)?.message
    }

    @ViewBuilder
    private func fieldErrorText(
        _ field: RequestFoodFormField,
        errors: [RequestFoodFieldError],
        identifier: String
    ) -> some View {
        if let message = fieldError(field, errors: errors) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier(identifier)
        }
    }

    static func formExpirationNotice(for timing: RequestTiming) -> String {
        switch timing {
        case .asap:
            return asapTimingNotice
        case .later:
            return "A scheduled request expires 3 hours after the time you choose."
        }
    }

    /// An ambiguous create is the only state that gets an escape action. The
    /// POST may already have succeeded, so submission stays disabled and no
    /// retry is offered — leaving is the only safe move. Confirmed backend
    /// rejections are recoverable in place and must not receive it.
    static func showsReturnHomeAction(
        for error: RequestCreatePresentationError?
    ) -> Bool {
        error == .ambiguous
    }

    /// The plain "closed for today" footnote is suppressed exactly when the
    /// lapsed-Later error is visible, because that error already states it and
    /// then adds the correction. It still renders for an ASAP draft, where it is
    /// the only explanation of why `Later` is missing from the picker.
    static func showsScheduledUnavailableNotice(
        isScheduledTimingAvailable: Bool,
        visibleScheduleError: RequestFoodFormError?
    ) -> Bool {
        !isScheduledTimingAvailable && visibleScheduleError != .scheduledTimingUnavailable
    }

    static func focusTargetAfterRejection(
        _ field: RequestFoodFormField?,
        expandedMealIndex: Int?
    ) -> RequestFoodFormField? {
        if case .mealDetail(let index)? = field, expandedMealIndex != index { return nil }
        return field
    }

    /// A local rejection that moved focus has already answered the tap. One that
    /// could not — every remaining error belongs to a picker — needs a line the
    /// requester can see without hunting up a form they may be scrolled past.
    static func showsLocalRejectionPointer(for result: RequestFoodSubmissionResult) -> Bool {
        !result.didSubmit && result.firstInvalidTextField == nil
    }

    /// The render-time rule. The pointer is local-only, so a backend answer
    /// always wins the section.
    static func showsLocalRejectionPointer(
        isPresenting: Bool,
        submissionError: RequestCreatePresentationError?
    ) -> Bool {
        isPresenting && submissionError == nil
    }

    static func submissionSectionPresentation(
        for error: RequestCreatePresentationError?
    ) -> RequestSubmissionSectionPresentation? {
        guard let error else { return nil }
        return RequestSubmissionSectionPresentation(
            error: error,
            message: error.message,
            showsReturnHomeAction: showsReturnHomeAction(for: error)
        )
    }

    /// Submission stays disabled after an ambiguous outcome, so a request that
    /// may already exist cannot be posted a second time.
    static func allowsSubmission(
        after error: RequestCreatePresentationError?
    ) -> Bool {
        error != .ambiguous
    }

    /// Whether entering the screen should start an availability probe.
    ///
    /// A blocked screen has no use for the answer: `presentation` returns the
    /// blocked state regardless of what comes back, so probing would spend a
    /// request to change nothing. Skipping it also keeps the store's
    /// availability flags at whatever they already were, rather than churning
    /// them behind a screen that never reads them.
    static func shouldProbeAvailability(
        hasUnresolvedCreateAmbiguity: Bool
    ) -> Bool {
        !hasUnresolvedCreateAmbiguity
    }

    static func effectiveSubmissionError(
        hasUnresolvedCreateAmbiguity: Bool,
        submissionError: RequestCreatePresentationError?
    ) -> RequestCreatePresentationError? {
        hasUnresolvedCreateAmbiguity ? .ambiguous : submissionError
    }

    /// The request button communicates only whether every required control has
    /// a value and whether the existing lifecycle permits another attempt.
    /// Format and scheduling validity deliberately remain Submit-time checks so
    /// a completed but malformed value can reveal its adjacent error.
    static func isSubmissionEnabled(
        draft: RequestFoodFormDraft,
        submissionError: RequestCreatePresentationError?,
        isCreating: Bool
    ) -> Bool {
        guard !isCreating, allowsSubmission(after: submissionError) else {
            return false
        }
        return RequestFoodFormValidator.hasRequiredInput(draft)
    }

    /// Scheduling is possible only while a selectable start remains inside the
    /// current campus day. Both the day boundary and the cutoff come from
    /// `Calendar`, never raw second arithmetic, so the rule stays correct
    /// across a DST transition instead of being 23 or 25 hours wrong.
    static func isScheduledTimingAvailable(now: Date, calendar: Calendar) -> Bool {
        isValidScheduledWindow(startingAt: now, now: now, calendar: calendar)
    }

    /// The timings the picker may offer. "Later" is withheld entirely rather
    /// than presented as an unusable date picker.
    static func availableTimingOptions(
        now: Date,
        calendar: Calendar
    ) -> [RequestTiming] {
        isScheduledTimingAvailable(now: now, calendar: calendar)
            ? RequestTiming.allCases
            : [.asap]
    }

    /// Nearby half-hour choices beginning at the next campus-clock boundary.
    /// The values are not product constants: every candidate is calendar-
    /// derived from `now`, then admitted only by the existing Later validator.
    static func quickScheduledTimes(
        now: Date,
        calendar: Calendar,
        maximumCount: Int = 3
    ) -> [Date] {
        guard maximumCount > 0,
              let hourStart = calendar.dateInterval(of: .hour, for: now)?.start else {
            return []
        }

        let minutesIntoHour = calendar.dateComponents([.minute], from: hourStart, to: now).minute ?? 0
        let firstOffset = ((minutesIntoHour / 30) + 1) * 30
        guard let first = calendar.date(byAdding: .minute, value: firstOffset, to: hourStart) else {
            return []
        }

        return (0..<maximumCount).compactMap { index in
            guard let candidate = calendar.date(byAdding: .minute, value: index * 30, to: first),
                  isValidScheduledWindow(startingAt: candidate, now: now, calendar: calendar) else {
                return nil
            }
            return candidate
        }
    }

    static func isSameCampusMinute(_ lhs: Date, _ rhs: Date, calendar: Calendar) -> Bool {
        calendar.isDate(lhs, equalTo: rhs, toGranularity: .minute)
    }

    static func timeLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        formatter.timeZone = NYUCampusTime.timeZone
        return formatter.string(from: date)
    }

    /// Builds the exact payload this draft submits.
    ///
    /// W4-R4: the structured half is taken from the draft's *active* values
    /// only. A meal field the requester hid by lowering their swipe count is
    /// excluded here, by construction — `activeMealEntries` never reaches
    /// past the active count, so hidden content cannot be sent and then
    /// filtered somewhere downstream. The draft keeps that content; the
    /// request simply does not contain it.
    static func makePayload(
        draft: RequestFoodFormDraft,
        now: Date,
        calendar: Calendar
    ) throws -> CreateRequestPayload {
        let scheduledWindowIsValid = isValidScheduledWindow(
            startingAt: draft.preferredPickupTime,
            now: now,
            calendar: calendar
        )
        let errors = RequestFoodFormValidator.validate(
            draft: draft,
            isScheduledWindowValid: scheduledWindowIsValid,
            isScheduledTimingAvailable: isScheduledTimingAvailable(
                now: now,
                calendar: calendar
            )
        )
        if let firstError = errors.first {
            throw firstError.error
        }
        guard let selectedDiningSpot = draft.selectedDiningSpot else {
            throw RequestFoodFormError.missingDiningSpot
        }

        let trimmedVendor = selectedDiningSpot.name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Exact cents, never a `Double`. `.empty` on the Meal Exchange path
        // sends no amount at all rather than a fabricated `$0.00`; validation
        // above has already refused `.empty` on the Dining-Dollars-only path,
        // where it is required.
        let estimatedDiningDollarsCents: Int?
        switch draft.diningDollars {
        case .cents(let cents):
            estimatedDiningDollarsCents = cents
        case .empty, .invalid:
            estimatedDiningDollarsCents = nil
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
            orderDetails = draft.orderDetails
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        switch draft.timing {
        case .asap:
            return CreateRequestPayload(
                vendor: trimmedVendor,
                timing: .asap,
                windowStart: nil,
                menuPath: menuPath,
                mealSwipes: draft.activeMealSwipes,
                mealItems: mealItems,
                orderDetails: orderDetails,
                estimatedDiningDollarsCents: estimatedDiningDollarsCents
            )
        case .later:
            // Only the start. The end of a request's availability is derived
            // from it by the backend (`src/requestTiming.ts`), and the create
            // shape is strict, so sending an end would both be refused and
            // claim authority this app does not have.
            return CreateRequestPayload(
                vendor: trimmedVendor,
                timing: .scheduled,
                windowStart: draft.preferredPickupTime,
                menuPath: menuPath,
                mealSwipes: draft.activeMealSwipes,
                mealItems: mealItems,
                orderDetails: orderDetails,
                estimatedDiningDollarsCents: estimatedDiningDollarsCents
            )
        }
    }

    /// How far before the next campus-day boundary the last selectable start
    /// sits.
    ///
    /// Deliberately unchanged from the value accepted before W3-R1, when a
    /// selection meant a 30-minute pickup window, so `scheduledTimingUnavailable`
    /// and its recovery path still open and close at exactly the instants they
    /// always have. Under the current contract this is a same-day scheduling
    /// horizon and not a window length: availability runs three hours from the
    /// chosen start and may cross midnight. Moving it is a product decision,
    /// not a consequence of the timing change.
    static let scheduledStartCutoffMinutesBeforeDayEnd = 30

    static func endOfDay(containing date: Date, calendar: Calendar) -> Date? {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
    }

    static func latestScheduledStart(on date: Date, calendar: Calendar) -> Date? {
        guard let endOfDay = endOfDay(containing: date, calendar: calendar) else {
            return nil
        }
        return calendar.date(
            byAdding: .minute,
            value: -scheduledStartCutoffMinutesBeforeDayEnd,
            to: endOfDay
        )
    }

    /// Whether this start may still be selected: it has not already passed, and
    /// it falls on or before the last start of the current campus day.
    ///
    /// This decides what the picker offers and what Submit accepts. It is not a
    /// lifecycle rule — the backend decides when a request is actually visible
    /// and when it expires, from its own clock.
    static func isValidScheduledWindow(
        startingAt start: Date,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        guard start >= now,
              let latestStart = latestScheduledStart(on: now, calendar: calendar) else {
            return false
        }
        return start <= latestStart
    }
}

/// The `Timing` label with its quiet trailing info affordance and explanation
/// alert, shared by the create and Edit forms.
struct RequesterTimingHeader: View {
    @Binding var isPresentingInfo: Bool
    let infoIdentifier: String

    var body: some View {
        HStack(spacing: CommonPlateStyle.Spacing.xs) {
            Text(RequestFoodView.timingLabel)
                .font(.subheadline.weight(.semibold))
            Spacer()
            // At least a 44x44 tap target; the glyph sits flush with the
            // trailing content edge, like `Optional`.
            Button {
                isPresentingInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel(RequestFoodView.timingInfoAccessibilityLabel)
            .accessibilityIdentifier(infoIdentifier)
        }
        .alert(RequestFoodView.timingInfoTitle, isPresented: $isPresentingInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(RequestFoodView.timingInfoBody)
        }
    }
}

/// One Meal entry shared by the create and Edit forms: a `Meal N` label row
/// above a collapsed summary that expands into the bordered editor (with Done).
/// Both presentations stay mounted so toggling never rebuilds the multiline
/// editor. The caller owns the fields, expansion state, focus and validation.
struct RequesterMealEntryControl<Trailing: View, Item: View, Details: View>: View {
    let label: String
    let index: Int
    let identifierPrefix: String
    let isExpanded: Bool
    let mealName: String
    let mealDetails: String?
    let hasError: Bool
    var isGlowing = false
    let onExpand: () -> Void
    let onDone: () -> Void
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let item: () -> Item
    @ViewBuilder let details: () -> Details

    private var borderColor: Color {
        hasError
            ? Color.red.opacity(0.72)
            : isGlowing ? CommonPlateStyle.Color.provenance.opacity(0.5) : CommonPlateStyle.Color.requestCardBorder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RequestFoodView.mealLabelToControlSpacing) {
            HStack {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !isExpanded && hasError {
                    Text("Required")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                } else {
                    trailing()
                }
            }
            .frame(height: RequestFoodView.mealLabelRowHeight)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("\(identifierPrefix)-label-row-\(index)")

            ZStack(alignment: .topLeading) {
                RequesterMealEntryCard(
                    hasError: hasError,
                    isGlowing: isGlowing,
                    identifier: "\(identifierPrefix)-control-\(index)",
                    onDone: onDone,
                    doneIdentifier: "\(identifierPrefix)-done-\(index)",
                    item: item,
                    details: details
                )
                .mealPresentation(isActive: isExpanded)

                collapsedSummary
                    .mealPresentation(isActive: !isExpanded)
            }
        }
    }

    private var collapsedSummary: some View {
        let isEmptyMealItem = mealName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button(action: onExpand) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isEmptyMealItem ? RequestFoodView.mealDetailPlaceholder : mealName)
                    .font(.subheadline)
                    .foregroundStyle(isEmptyMealItem ? .secondary : .primary)
                if let details = mealDetails, !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Same text size as Meal item; secondary through color only.
                    Text(details)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            // Top-aligned. The 76pt target governs only the EMPTY control; a
            // filled summary is content-driven with 44 as the tap-target floor.
            .frame(
                maxWidth: .infinity,
                minHeight: isEmptyMealItem ? RequestFoodView.collapsedMealControlHeight : 44,
                alignment: .topLeading
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(identifierPrefix)-collapsed-\(index)")
        .background(
            hasError ? Color.red.opacity(0.07) : CommonPlateStyle.Color.baseCanvas,
            in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(identifierPrefix)-control-\(index)")
    }
}

/// One bordered Meal control holding the item and its optional details, shared
/// by the create and Edit forms. The caller owns the fields, so bindings,
/// focus and validation stay with it; `onDone` adds create's Done row.
struct RequesterMealEntryCard<Item: View, Details: View>: View {
    let hasError: Bool
    var isGlowing = false
    let identifier: String
    var onDone: (() -> Void)? = nil
    var doneIdentifier = ""
    @ViewBuilder let item: () -> Item
    @ViewBuilder let details: () -> Details

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Meal item")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if hasError {
                    Text("Required")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
            .frame(height: 15)

            item()
                .padding(.top, CommonPlateStyle.Spacing.xs)

            Divider()
                .padding(.top, RequestFoodView.mealEditorValueToDividerSpacing)

            HStack {
                Text("Details")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(RequestFoodView.screenshotAssistanceOptionalLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 15)
            .padding(.top, RequestFoodView.mealEditorDividerToDetailsSpacing)

            details()
                .padding(.top, CommonPlateStyle.Spacing.xs)

            if let onDone {
                HStack {
                    Spacer()
                    Button(action: onDone) {
                        Text("Done")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(CommonPlateStyle.Color.brandText)
                            .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(doneIdentifier)
                }
                .frame(minHeight: 44)
                .padding(.top, RequestFoodView.mealEditorDetailsToDoneSpacing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, RequestFoodView.mealEditorTopInset)
        .padding(.bottom, RequestFoodView.mealEditorBottomInset)
        .frame(
            maxWidth: .infinity,
            minHeight: onDone == nil ? nil : RequestFoodView.expandedMealControlHeight,
            alignment: .topLeading
        )
        .background(
            hasError ? Color.red.opacity(0.07) : CommonPlateStyle.Color.baseCanvas,
            in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                .strokeBorder(
                    hasError
                        ? Color.red.opacity(0.72)
                        : isGlowing ? CommonPlateStyle.Color.provenance.opacity(0.5) : CommonPlateStyle.Color.requestCardBorder,
                    lineWidth: 1
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// The bounded `1...5` meal-swipe menu shared by the create and Edit forms.
/// The caller supplies the binding, so provenance latching stays with it.
struct RequesterMealSwipesMenu: View {
    @Binding var count: Int
    let label: String
    let identifier: String

    var body: some View {
        Menu {
            ForEach(RequestFoodFormDraft.mealSwipeOptions, id: \.self) { option in
                Button("\(option)") { count = option }
            }
        } label: {
            HStack {
                Text(RequestCardView.mealSwipesText(count))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier(identifier)
        .tint(Color("AccentColor"))
        .accessibilityLabel("\(label): \(RequestCardView.mealSwipesText(count))")
    }
}

/// W4-R2 approved `Requester / Form Field` visual language (Figma node
/// `209:364`): a bold field label with inline trailing `Suggested`
/// provenance, and a bordered warm-canvas control box beneath.
/// Reused for the requester form's approved field kinds (Dining location,
/// Order details, Meal swipes). Purely presentational: it owns no draft
/// state and enforces no validation; the caller's `content` is the actual
/// interactive control.
struct RequesterFormFieldContainer<Content: View>: View {
    let label: String
    var trailingLabel: String? = nil
    var manualProvenanceLabel: String? = nil
    var showsProvenance: Bool = false
    var isGlowing: Bool = false
    var provenanceIdentifier: String?
    /// Optional inline help between the label/provenance and bordered control.
    var assistance: AnyView? = nil
    /// Identifies the bordered control box itself (not only the text inside
    /// it), so its rendered frame can be measured.
    var controlIdentifier: String?
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // `ViewThatFits` lets the provenance caption drop to its own line
            // under larger Dynamic Type sizes rather than clipping or
            // overlapping the label — the approved component's own
            // documented behavior ("may wrap/stack rather than clipping").
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: CommonPlateStyle.Spacing.s) {
                    labelText
                    Spacer(minLength: CommonPlateStyle.Spacing.s)
                    trailingLabelText
                }
                VStack(alignment: .leading, spacing: 2) {
                    labelText
                    trailingLabelText
                }
            }

            if let assistance { assistance }

            identifiedControlBox(
                content
                    .padding(.horizontal, 13)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CommonPlateStyle.Color.baseCanvas)
                    .overlay(
                        RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                            .strokeBorder(CommonPlateStyle.Color.requestCardBorder)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous))
            )
        }
    }

    @ViewBuilder
    private func identifiedControlBox<Box: View>(_ box: Box) -> some View {
        if let controlIdentifier {
            box
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(controlIdentifier)
        } else {
            box
        }
    }

    private var labelText: some View {
        Text(label)
            .font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var trailingLabelText: some View {
        if let manualProvenanceLabel {
            Text(manualProvenanceLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(provenanceIdentifier ?? "")
        } else if let trailingLabel {
            Text(trailingLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if showsProvenance {
            Text(RequestFoodView.filledFromScreenshotLabel)
                .font(.caption2)
                .foregroundStyle(isGlowing ? CommonPlateStyle.Color.provenance : CommonPlateStyle.Color.provenance.opacity(0.82))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: isGlowing)
                .accessibilityIdentifier(provenanceIdentifier ?? "")
        }
    }
}

/// The W4-U1.1 requester moderation notice: the approved inline card (Figma
/// 885:5716) — `#D64045` red border, icon, and copy on a `#FFF7F7` surface,
/// with dark-mode counterparts that keep it legible on the dark canvas. The
/// icon is decorative, so VoiceOver reads the card as the copy alone.
private struct TextModerationNoticeCard: View {
    let message: String

    private static let content = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 240 / 255, green: 130 / 255, blue: 135 / 255, alpha: 1)
            : UIColor(red: 214 / 255, green: 64 / 255, blue: 69 / 255, alpha: 1)
    })
    private static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 214 / 255, green: 64 / 255, blue: 69 / 255, alpha: 0.16)
            : UIColor(red: 255 / 255, green: 247 / 255, blue: 247 / 255, alpha: 1)
    })
    private static let cornerRadius: CGFloat = 13

    var body: some View {
        HStack(spacing: CommonPlateStyle.Spacing.s) {
            Image(systemName: CommonPlateStatusKind.error.symbolName)
                .font(.subheadline)
                .accessibilityHidden(true)
            Text(message)
                .font(.footnote.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Self.content)
        .padding(.horizontal, CommonPlateStyle.Spacing.m)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Self.surface,
            in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Self.content)
        }
        .accessibilityElement(children: .combine)
    }
}
