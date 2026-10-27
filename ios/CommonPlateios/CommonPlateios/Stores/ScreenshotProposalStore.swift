//
//  ScreenshotProposalStore.swift
//  CommonPlateios
//
// The one state owner for the W4-S1 non-authoritative AI screenshot
// proposal capability. Entirely separate from `RequestStore`: this store can
// never call `RequestStore.createRequest(...)`, mint/consume a W3-D1
// operation identity, or otherwise touch Request/D1 lifecycle. It only ever
// mutates the caller-supplied `RequestFoodFormDraft` it is handed, and only
// within the accepted allowlist (location, literal food, meal swipes).
import Combine
import Foundation

/// Non-fatal presentation outcome of one analysis attempt. `unsupported` and
/// `noUsefulExtraction` are ordinary partial-proposal outcomes, not errors —
/// they exist so presentation can explain "nothing to fill in" without
/// treating it the same as an actual failure.
enum ScreenshotProposalNotice: Equatable {
    case verificationRequired
    case verificationExpired
    case invalidImage
    case unsupportedScreenshot
    case noUsefulExtraction
    case unavailable

    var message: String {
        switch self {
        case .verificationRequired:
            return "Verify your NYU email to use AI screenshot assistance."
        case .verificationExpired:
            return "Your NYU email needs to be verified again to use AI screenshot assistance."
        case .invalidImage:
            return "Choose a single Grubhub cart or order-detail screenshot."
        case .unsupportedScreenshot:
            // Approved Figma `Requester / Screenshot Assistance,
            // State=Unsupported` recovery-note wording.
            return "This screenshot doesn’t have enough request details. Try another screenshot or continue manually."
        case .noUsefulExtraction:
            // Approved Figma `Requester / Screenshot Assistance,
            // State=No useful extraction` recovery-note wording.
            return "\(AppBrand.name) couldn’t find request details in this screenshot. Your form is unchanged."
        case .unavailable:
            return "We couldn’t analyze that screenshot right now. You can still fill out the form manually."
        }
    }

    static func map(_ error: Error) -> ScreenshotProposalNotice {
        guard let serviceError = error as? ScreenshotProposalServiceError else {
            return .unavailable
        }
        switch serviceError {
        case .verificationRequired:
            return .verificationRequired
        case .authorityInvalid:
            return .verificationExpired
        case .invalidImage:
            return .invalidImage
        case .unavailable, .excluded:
            return .unavailable
        }
    }
}

/// Explicit requester-interaction provenance for the three allowlisted
/// proposal fields, owned beside the process/session draft and passed into
/// every store call that reads or clears them.
///
/// Deliberately not inferred from value equality (review finding: value
/// equality is wrong whenever a requester types then clears a field while a
/// proposal is pending, or changes an AI value and later manually returns to
/// the same value — neither is distinguishable from "never touched" by
/// comparing values alone). Each flag is set by exactly one thing: a real
/// user interaction with that field's control (`RequestFoodView`'s custom
/// bindings). A store-applied proposal write never sets it — that is what
/// keeps a programmatic AI write from ever being mistaken for a manual edit.
///
/// A flag represents current, non-empty requester content — never edit
/// history. Clearing a field removes only that field's protection. Structured
/// meal names and details therefore use separate sets: an edit to one is
/// never authority over the other.
struct ScreenshotFieldManualEditState: Equatable {
    var hasManuallyEditedLocation = false
    var hasManuallyEditedMealSwipes = false
    /// Indices are fixed draft positions, so a temporarily hidden meal keeps
    /// the authority belonging to each of its current subfields.
    var manuallyEditedMealItemNames: Set<Int> = []
    var manuallyEditedMealItemDetails: Set<Int> = []
    /// The Dining-Dollars-only order-details field, which the same
    /// manual-precedence rule covers.
    var hasManuallyEditedOrderDetails = false
    /// The Meal Exchange branch's current-cart Dining Dollars TOP-UP is still
    /// only a proposal. Once the requester edits it, later screenshot
    /// selections cannot overwrite that value. It concerns the top-up draft
    /// only; the Dining-Dollars-only amount has its own authority flag below.
    var hasManuallyEditedDiningDollars = false
    /// Requester edits protect the Dining-Dollars-only whole-order estimate
    /// independently of the Meal Exchange top-up.
    var hasManuallyEditedDiningDollarsOnly = false
    /// A real requester change of the menu path owns the selection. A store
    /// write and a same-value selection never set this flag.
    var hasManuallyEditedMenuPath = false
    /// Screenshot Assistance has applied or confirmed a deterministic path in
    /// this draft session. Set only through `record(_:)`, from
    /// `ScreenshotProposalAppliedFields.establishedMenuPath`.
    var hasScreenshotEstablishedMenuPath = false

    /// Records what an `apply(...)` call established, after the caller has
    /// applied it. The only way `hasScreenshotEstablishedMenuPath` is set.
    mutating func record(_ applied: ScreenshotProposalAppliedFields) {
        if applied.establishedMenuPath {
            hasScreenshotEstablishedMenuPath = true
        }
    }

    /// The one requester-selector interaction rule. Re-selecting the already
    /// current option is a no-op, not a manual path change.
    mutating func recordMenuPathSelection(from current: RequestMenuPath, to selected: RequestMenuPath) {
        guard selected != current else { return }
        hasManuallyEditedMenuPath = true
    }

    func hasManuallyEditedMealItemName(_ index: Int) -> Bool {
        manuallyEditedMealItemNames.contains(index)
    }

    func hasManuallyEditedMealItemDetails(_ index: Int) -> Bool {
        manuallyEditedMealItemDetails.contains(index)
    }
}

/// Which of the three allowlisted proposal fields a single `apply(...)` call
/// actually wrote into the draft (W4-R2 presentation plumbing only — this
/// carries no additional S1 authority). `RequestFoodView` uses this purely to
/// drive its own provenance caption ("Suggested") and brief
/// afterglow on exactly the fields that changed; it has no bearing on what
/// `apply(...)` is allowed to write, which remains governed entirely by the
/// allowlist and manual-precedence rules below.
struct ScreenshotProposalAppliedFields: Equatable {
    /// This call switched the selector to a deterministic path.
    var menuPath = false
    /// This call accepted a deterministic path proposal — whether it switched
    /// the selector or the selector already showed that path. Drives the
    /// view's recording of `hasScreenshotEstablishedMenuPath`.
    var establishedMenuPath = false
    /// An opposite deterministic path was withheld from a requester-owned
    /// selection. The view may offer explicit acceptance for this result.
    var suggestedMenuPath: RequestMenuPath?
    var location = false
    var mealSwipes = false
    /// A valid current result proposes a larger count than a requester-owned
    /// Meal Exchange count. Presentation may offer explicit adoption.
    var suggestedMealSwipes: Int?
    /// Exactly the structured meal subfields this call wrote. These are also
    /// the independent presentation-provenance units.
    var mealItemNames: Set<Int> = []
    var mealItemDetails: Set<Int> = []
    var orderDetails = false
    var diningDollars = false
    var diningDollarsOnly = false
    /// A proposal contained at least one field that was kept because it
    /// currently held requester-owned non-empty content. This is deliberately
    /// aggregate: the UI displays one temporary message per rerun.
    var preservedManualFieldCount = 0

    var didPreserveManualContent: Bool {
        preservedManualFieldCount > 0
    }

    /// Compatibility/readability helper for effects that operate on an entire
    /// meal card, not authority or provenance. Never use this to decide
    /// whether either subfield may be changed.
    var mealEntries: Set<Int> {
        mealItemNames.union(mealItemDetails)
    }

    var isEmpty: Bool {
        !menuPath && !location && !mealSwipes && mealItemNames.isEmpty && mealItemDetails.isEmpty && !orderDetails && !diningDollars && !diningDollarsOnly
    }
}

/// Why a local outcome falls through to the external attempt: the two
/// requester-visible local fallback classes. Each maps to an existing
/// requester treatment when the external attempt also cannot run or also
/// yields nothing.
enum ScreenshotExternalFallbackReason: Equatable {
    /// Local model unavailable, combination not qualified, or attempt failed →
    /// the existing `.unavailable` notice.
    case localUnavailable
    /// Local attempt completed with zero usable valid fields → the existing
    /// `.noUsefulExtraction` treatment.
    case noUsefulExtraction
}

/// Result-scoped R4.2 recovery. This is presentation/application state only;
/// it is never part of the provider response, request payload, or draft.
enum ScreenshotVenueRecoveryKind: Equatable {
    case unresolved
    case unsupported
    case conflicting
    case manualMismatch(screenshot: DiningSpot, manual: DiningSpot)
}

struct ScreenshotVenueRecovery: Equatable {
    let token: ScreenshotSelectionToken
    let outcome: ScreenshotProposalOutcome
    let kind: ScreenshotVenueRecoveryKind
    /// Captured at completed A/D analysis time so explicit confirmation cannot
    /// become a synthetic second completed run.
    let wasGenuineRerun: Bool
}

@MainActor
final class ScreenshotProposalStore: ObservableObject {
    /// W4-R4: the exact number of screenshots that may be selected as
    /// evidence for one logical Grubhub order. Mirrors the backend's own
    /// `MAX_SCREENSHOT_IMAGES` (`src/screenshotProposalRoute.ts`), which
    /// enforces the same bound independently of what this client sends.
    static let maxScreenshotSelection = 5

    @Published private(set) var notice: ScreenshotProposalNotice?
    @Published private(set) var isAIAssistanceEnabled: Bool
    /// W4-R2 2026-09-01 sync: independent local Screenshot Help
    /// education-completion state — never inferred from or coupled to
    /// `isAIAssistanceEnabled`. See `recordScreenshotHelpCompleted()`.
    @Published private(set) var hasCompletedScreenshotHelp: Bool
    /// Generations with analysis work currently in flight. A set, not a
    /// single flag (review finding: one shared boolean can be cleared by
    /// older work while newer work is still running) — mirrors
    /// `EmailAlertStateStore.inFlightAuthorities`. `isApplying` below reports
    /// only whether the *current* generation is among them, so a superseded
    /// generation finishing (and removing itself) can never clear busy state
    /// a newer generation still owns.
    @Published private var inFlightGenerations: Set<Int> = []

    /// The one availability gate for requester Screenshot Assistance. When it
    /// is excluded, no consent, saved preference, draft, or restored state can
    /// enable local or external analysis; saved preferences stay untouched.
    private let availability: RequesterScreenshotAssistanceAvailability
    private let service: ScreenshotProposalService
    /// The shared runtime, parameterized with the Requester workflow adapter.
    private let runtime: ScreenshotAssistanceRuntime<RequesterOrderWorkflow>
    /// W4-S3: generation identity, cancellation, and stale-result fencing are
    /// the shared runtime's mechanism (`ScreenshotAttemptFence`), and the fence
    /// is the RUNTIME's own — every token it mints identifies it, so the
    /// runtime can itself refuse an external permission for a stale attempt.
    /// This store keeps the Requester policy on top of it. Cancelling a tracked
    /// task is a real "stop mattering right now" instruction, cooperatively
    /// observed by the async call chain itself — not a hint a race can still
    /// slip past.
    private var fence: ScreenshotAttemptFence { runtime.fence }
    private let preferences: ScreenshotProposalPreferencesStoring

    /// Whether analysis for the current selection is in flight. `false` for
    /// a superseded generation's still-finishing work, even while that work
    /// is technically still running.
    var isApplying: Bool {
        inFlightGenerations.contains(fence.currentGeneration)
    }

    /// Whether requester Screenshot Assistance exists for this store at all.
    /// Views present no entry point when this is `false`.
    var isAssistanceAvailable: Bool { availability.isAvailable }

    init(
        availability: RequesterScreenshotAssistanceAvailability,
        service: ScreenshotProposalService,
        preferences: ScreenshotProposalPreferencesStoring,
        runtime: ScreenshotAssistanceRuntime<RequesterOrderWorkflow>? = nil
    ) {
        self.availability = availability
        self.service = service
        self.preferences = preferences
        self.runtime = runtime ?? RequesterScreenshotAssistanceProduction.makeRuntime(service: service)
        self.isAIAssistanceEnabled = availability.isAvailable
            && preferences.hasValidScreenshotAssistanceConsent
        self.hasCompletedScreenshotHelp = preferences.hasCompletedScreenshotHelp
    }

    /// W4-S3 consent-authority revision: the one toggle IS the consent
    /// record. `enabled == true` is the `Turn On` action's effect — the only
    /// path that may establish a valid consent record — and callers must
    /// reach it only after the requester has seen and confirmed the
    /// disclosure (`RequestFoodView`/`SettingsView` own presenting it; this
    /// store never presents UI). `enabled == false` is Off: it revokes the
    /// consent record and must retire the current generation, not just
    /// cancel its task (review finding carried over from the pre-revision
    /// popup model: "turning it back On cannot allow an old analysis outcome
    /// to become current"). Retiring makes `isCurrent(_:)` `false` for every
    /// token minted before this call, deterministically, regardless of the
    /// cancellation's own timing, and fences any in-flight local or automatic
    /// external attempt so no transfer already in flight can be applied late
    /// and no new one can start. Turning Screenshot Assistance back On does
    /// not itself revive anything: a later analysis only ever starts from a
    /// fresh `beginSelection(...)` token, under its own fresh `Turn On`.
    func setAIAssistanceEnabled(_ enabled: Bool) {
        guard availability.isAvailable else {
            retireCurrentSelection()
            return
        }
        if enabled {
            preferences.grantScreenshotAssistanceConsent()
        } else {
            preferences.revokeScreenshotAssistanceConsent()
        }
        isAIAssistanceEnabled = enabled
        if !enabled {
            retireCurrentSelection()
        }
    }

    /// W4-R2 2026-09-01 sync: records Screenshot Help education completion.
    /// Callers must invoke this only when the requester actually completes
    /// Screenshot Help through `Got it` — never merely because Screenshot
    /// Help was presented or a detail state was opened. Independent of
    /// `setAIAssistanceEnabled(_:)`: the AI-enabled toggle neither infers nor
    /// is inferred from this state.
    func recordScreenshotHelpCompleted() {
        preferences.hasCompletedScreenshotHelp = true
        hasCompletedScreenshotHelp = true
    }

    func clearNotice() {
        notice = nil
    }

    /// Whether `token` is still the current selection. Every async stage in
    /// `RequestFoodView`'s screenshot pipeline (image load, OCR, local
    /// analysis, immediately before any external transfer, and after it
    /// returns) checks this before proceeding or mutating shared state; a
    /// `false` result means abort silently — the work belongs to a selection
    /// the requester has since replaced or left.
    func isCurrent(_ token: ScreenshotSelectionToken) -> Bool {
        fence.isCurrent(token)
    }

    /// Mints a new selection identity and immediately clears whatever is
    /// still AI-owned in `draft` from the previous selection — synchronously,
    /// before any async work for the new selection begins. This is what
    /// makes stale-generation clearing correct even when the new image later
    /// fails to load, decode, or OCR: the old AI-owned values are already
    /// gone by the time any of that could fail, not left in place until a
    /// later analysis call "wins."
    ///
    /// A field with current requester-owned non-empty content is never cleared
    /// here. Screenshot-derived values remain eligible to be replaced by a
    /// newer proposal, while each structured meal subfield is handled alone.
    ///
    /// A new selection retires whatever the previous one was doing: any
    /// in-flight local or automatic-external attempt for it is fenced, so a
    /// late result can never be applied to this one.
    func beginSelection(
        clearing draft: inout RequestFoodFormDraft,
        manualEdits: ScreenshotFieldManualEditState
    ) -> ScreenshotSelectionToken {
        // A newer selection immediately retires and cancels whatever the
        // previous one was doing, synchronously — see `ScreenshotAttemptFence`.
        let token = fence.beginAttempt()
        // Excluded: mint the (unusable) token but leave the draft untouched.
        guard availability.isAvailable else { return token }
        notice = nil
        if !manualEdits.hasManuallyEditedLocation {
            draft.selectedDiningSpot = nil
        }
        for index in 0..<RequestFoodFormDraft.maxMealSwipes {
            if !manualEdits.hasManuallyEditedMealItemName(index) {
                draft.mealEntries[index].name = ""
            }
            if !manualEdits.hasManuallyEditedMealItemDetails(index) {
                draft.mealEntries[index].details = nil
            }
        }
        if !manualEdits.hasManuallyEditedOrderDetails {
            draft.orderDetails = ""
        }
        if !manualEdits.hasManuallyEditedMealSwipes {
            draft.mealSwipes = RequestFoodFormDraft.mealSwipeOptions.first!
        }
        if !manualEdits.hasManuallyEditedDiningDollarsOnly {
            draft.diningDollarsOnlyText = ""
        }
        // The selector and Meal Exchange top-up keep their existing
        // new-selection behavior. The Dining-Dollars-only whole-order amount
        // clears only while screenshot-owned; its provenance clears at this
        // same boundary in `RequestFoodDraftSession`.
        return token
    }

    /// Invalidates the current selection without touching any draft — for
    /// screen disappearance (review finding: "invalidate old work on
    /// relevant dismissal/disappearance"), where there is no longer a live
    /// `RequestFoodFormDraft` to clear stale values from, but any in-flight
    /// work for this screen must still stop mattering: `isCurrent(_:)` will
    /// report `false` for whatever token it was still carrying.
    func invalidateCurrentSelection() {
        retireCurrentSelection()
    }

    private func retireCurrentSelection() {
        fence.retire()
        notice = nil
    }

    /// Analyzes the already-prepared screenshots of one selection, local-first,
    /// falling through to one automatic external attempt when consent to do so
    /// is already standing.
    ///
    /// 1. The Requester workflow's deterministic on-device eligibility gate
    ///    runs first (it derives its own on-device OCR evidence from the
    ///    ordered selection). A wholly ineligible selection returns an
    ///    ineligible outcome (existing `unsupportedScreenshot` treatment) and
    ///    NEVER reaches any provider.
    /// 2. One local attempt runs. A useful result (at least one valid proposal
    ///    field, even partial) is returned to be applied.
    /// 3. Only when the local attempt was unavailable/unqualified, failed, or
    ///    completed with zero usable fields does `attemptExternalFallback`
    ///    run. W4-S3 consent-authority revision: Screenshot Assistance being
    ///    On IS valid standing consent (`setAIAssistanceEnabled(_:)`'s only
    ///    documentation) — there is no separate per-attempt
    ///    external-transfer permission dialog any more, so a qualified local
    ///    path and the accepted external path both proceed under the one
    ///    standing consent, with no new prompt. Without current participant
    ///    authority (a session/identity fact, independent of AI consent) the
    ///    external attempt does not run and the same local outcome is
    ///    presented as the ordinary requester treatment instead (`.unavailable`
    ///    notice, or the empty eligible outcome, which `apply` turns into
    ///    `.noUsefulExtraction`).
    ///
    /// Nothing here mutates `draft`; the caller applies the result
    /// synchronously afterward via `apply(_:manualEdits:to:)`, since a
    /// SwiftUI `@State` draft cannot be passed `inout` across an `await`
    /// suspension point.
    /// W4-R4: `images` is the complete set of normalized screenshots for one
    /// logical order (1 to 5), analyzed together rather than one at a time, so
    /// overlapping evidence describes one order instead of several.
    ///
    /// `participantAuthority` supplies the requester's CURRENT participant
    /// authority (`nil` once it was lost after this already-admitted form
    /// mounted). It is evaluated ONLY at the moment an external attempt would
    /// run — after evidence derivation and the local attempt have finished,
    /// and again immediately before the provider is invoked — never earlier,
    /// so authority lost while those ran can never still yield a transfer.
    /// Local analysis and its ordinary outcome notice are unaffected by it,
    /// and its value is not retained.
    func analyzeScreenshot(
        images: [ScreenshotPreparedImage],
        participantAuthority: @escaping @MainActor () -> String?,
        token: ScreenshotSelectionToken
    ) async -> ScreenshotProposalOutcome? {
        guard !images.isEmpty,
              images.count <= ScreenshotProposalStore.maxScreenshotSelection,
              let selection = ScreenshotSelection(images: images) else {
            return nil
        }
        guard availability.isAvailable else { return nil }
        guard isCurrent(token) else { return nil }
        guard isAIAssistanceEnabled else { return nil }

        // The Requester workflow's eligibility gate and OCR evidence
        // derivation. Tracked by the fence so a retired selection stops
        // recognizing immediately, but deliberately NOT counted as in flight:
        // `isApplying` keeps covering exactly the provider attempt, as it did
        // when this preparation ran in the view before the store was called.
        let evaluationTask = Task<ScreenshotAssistanceRuntime<RequesterOrderWorkflow>.Evaluation?, Never> { [runtime] in
            await runtime.evaluate(selection, for: token)
        }
        fence.track(evaluationTask, for: token)
        let derived = await evaluationTask.value
        fence.untrack(token)
        guard isCurrent(token) else { return nil }

        guard let evaluation = derived else {
            return ScreenshotProposalOutcome(eligible: false, proposal: .empty)
        }
        // Derived once from the ordered, eligible OCR evidence. The local
        // attempt remains unconditional; only the later fallback decision may
        // withhold transfer for a reliable B/C result.
        let venueClassification = RequesterVenueClassifier.classify(
            imageEvidenceTexts: evaluation.derived.orderedTexts(for: evaluation.selection),
            vendors: SupportedVendorCatalog.diningSpots
        )

        let task = Task<ScreenshotAnalysisAttemptResult<ScreenshotProposalOutcome>, Never> { [runtime] in
            await runtime.runLocal(evaluation)
        }
        fence.track(task, for: token)
        inFlightGenerations.insert(token.generation)
        defer {
            inFlightGenerations.remove(token.generation)
            fence.untrack(token)
        }

        let result = await task.value

        // `isAIAssistanceEnabled` is not re-checked separately here: Off
        // already retired this generation, so a stale `token` already fails
        // `isCurrent` below in that case.
        guard isCurrent(token) else { return nil }

        switch result {
        case .completed(let analysis):
            // Requester does not surface provider-cited evidence; whatever the
            // runtime returned beside the outcome is released here.
            let outcome = analysis.outcome
            guard outcome.eligible else { return outcome }
            if outcome.isEmpty {
                return await attemptExternalFallback(
                    .noUsefulExtraction,
                    evaluation: evaluation,
                    venueClassification: venueClassification,
                    participantAuthority: participantAuthority,
                    token: token
                )
            }
            return outcome.withVenueDisposition(
                Self.reconcileAcceptedCatalogAnchor(venueClassification, proposal: outcome.proposal)
            )
        case .localUnavailable, .failed:
            return await attemptExternalFallback(
                .localUnavailable,
                evaluation: evaluation,
                venueClassification: venueClassification,
                participantAuthority: participantAuthority,
                token: token
            )
        case .cancelled:
            // Leaving mid-analysis, or being cancelled by a newer
            // selection/AI-Off, is not a reportable failure.
            return nil
        }
    }

    /// W4-S3 consent-authority revision: runs the one terminal external
    /// attempt automatically under Screenshot Assistance's standing consent —
    /// no popup, no per-attempt tap. Without current participant authority
    /// (read here, at the decision, and nowhere earlier) the attempt does not
    /// run and the ordinary local-outcome treatment is presented instead; no
    /// Screenshot Assistance-owned verification prompt is ever launched from
    /// here.
    ///
    /// Returns the outcome to apply, or `nil` for a notice-only treatment, a
    /// stale/cancelled/superseded attempt, or a failure (which sets `notice`).
    private func attemptExternalFallback(
        _ reason: ScreenshotExternalFallbackReason,
        evaluation: ScreenshotAssistanceRuntime<RequesterOrderWorkflow>.Evaluation,
        venueClassification: RequesterVenueClassification,
        participantAuthority: @escaping @MainActor () -> String?,
        token: ScreenshotSelectionToken
    ) async -> ScreenshotProposalOutcome? {
        // R4.2's only S3-adjacent change: after the unchanged local attempt,
        // but before authority is read or a permission is minted, B/C withhold
        // an otherwise permitted external transfer. This is not a runtime
        // policy change and uses the runtime's existing fence unchanged.
        let venueDisposition = venueClassification.disposition
        if venueDisposition.blocksProposalApplication {
            return ScreenshotProposalOutcome(
                eligible: true,
                proposal: .empty,
                venueDisposition: venueDisposition
            )
        }
        guard participantAuthority() != nil else {
            return presentLocalOutcome(for: reason)?.withVenueDisposition(venueDisposition)
        }

        // The runtime mints the permission for exactly this token and this
        // evaluation, and only while the token is current and is the attempt the
        // evaluation was produced for. A refusal means the selection was
        // retired: nothing is resumed and no resource exists.
        guard let permission = runtime.authorizeExternalTransfer(for: token, evaluation: evaluation) else {
            return nil
        }

        let task = Task<Result<ScreenshotProposalOutcome, Error>, Never> { [runtime] in
            do {
                // Observed even if this task was cancelled before its body
                // ever started running — the transfer is never reached in
                // that case.
                try Task.checkCancellation()
                let analysis = try await runtime.runExternal(
                    authority: participantAuthority,
                    permission: permission
                )
                return .success(analysis.outcome)
            } catch {
                return .failure(error)
            }
        }
        fence.track(task, for: token)
        inFlightGenerations.insert(token.generation)
        defer {
            inFlightGenerations.remove(token.generation)
            fence.untrack(token)
        }

        let result = await task.value

        if case .failure(let error) = result,
           let failure = error as? ScreenshotAnalysisFailure {
            // Refused by the runtime's own gates, before any provider work: no
            // provider call. A retired selection presents nothing; authority
            // that disappeared between the offer decision and the transfer
            // boundary presents the local outcome that caused the fallback.
            switch failure {
            case .authorityUnavailable:
                guard isCurrent(token), isAIAssistanceEnabled else { return nil }
                // Same local treatment as the no-authority branch above: the
                // local outcome keeps its venue disposition, otherwise `apply`
                // would drop the existing `noUsefulExtraction` notice.
                return presentLocalOutcome(for: reason)?.withVenueDisposition(venueDisposition)
            case .permissionUnavailable:
                return nil
            default:
                break
            }
        }

        // A transfer that already began cannot be recalled, but its result is
        // never treated as usable once this selection has been retired.
        guard isCurrent(token) else { return nil }

        switch result {
        case .success(let outcome):
            return outcome.withVenueDisposition(
                Self.reconcileAcceptedCatalogAnchor(venueClassification, proposal: outcome.proposal)
            )
        case .failure(let error):
            if error is CancellationError { return nil }
            notice = ScreenshotProposalNotice.map(error)
            return nil
        }
    }

    /// The existing requester treatment for a local fallback outcome:
    /// `.unavailable` is a notice (nothing to apply); zero usable fields is the
    /// ordinary eligible-but-empty outcome, which `apply` turns into the
    /// existing `.noUsefulExtraction` treatment.
    private func presentLocalOutcome(for reason: ScreenshotExternalFallbackReason) -> ScreenshotProposalOutcome? {
        switch reason {
        case .localUnavailable:
            notice = .unavailable
            return nil
        case .noUsefulExtraction:
            return ScreenshotProposalOutcome(eligible: true, proposal: .empty)
        }
    }

    /// R4.1's accepted resolver may populate `selectedDiningSpot` from the
    /// catalog matcher over the joined text. That recognition is E/D authority
    /// only where no V1 Meal Exchange venue observation exists in any eligible
    /// image (for example Dining Dollars without a Meal Exchange header). It
    /// never overrides V1 evidence (§5a):
    ///
    /// - no V1 observation: a present `selectedDiningSpot` stands (E, or D
    ///   against a differing manual location);
    /// - any V1 observation that is not reliably supported — including an
    ///   indeterminate image mixed with a supported one — stays unresolved (A),
    ///   whatever `selectedDiningSpot` holds;
    /// - reliably supported V1 evidence stands only when the proposal names
    ///   the same catalog entry; a disagreement is uncertainty (A).
    ///
    /// B/C pass through unchanged. Provider output gains no venue authority.
    static func reconcileAcceptedCatalogAnchor(
        _ classification: RequesterVenueClassification,
        proposal: ScreenshotProposal
    ) -> RequesterVenueDisposition {
        switch classification.disposition {
        case .unsupported, .conflicting:
            return classification.disposition
        case .supported(let anchor):
            return proposal.selectedDiningSpot == anchor ? classification.disposition : .unresolved
        case .unresolved:
            guard !classification.hasV1Observation,
                  let catalogAnchor = proposal.selectedDiningSpot else { return .unresolved }
            return .supported(catalogAnchor)
        }
    }

    /// Applies an outcome `analyzeScreenshot` returned. Synchronous and
    /// side-effect-bounded to `draft`/`notice` only — safe to call with an
    /// `inout` `@State` draft because it never suspends. Callers must check
    /// `isCurrent(token)` again immediately before calling this (the result
    /// may have gone stale during the gap between `analyzeScreenshot`
    /// returning and this being called back on the main actor).
    ///
    /// A field with current requester-owned non-empty content never receives a
    /// proposed value here. `preservedManualFieldCount` records only values a
    /// proposal actually tried to replace, so it can drive the bounded rerun
    /// feedback without treating every successful run as preservation.
    @discardableResult
    func apply(
        _ outcome: ScreenshotProposalOutcome,
        manualEdits: ScreenshotFieldManualEditState,
        to draft: inout RequestFoodFormDraft,
        venueConfirmation: Bool = false
    ) -> ScreenshotProposalAppliedFields {
        var applied = ScreenshotProposalAppliedFields()
        // Ineligible selections retain the established unsupported treatment
        // before any R4.2 anchoring branch can inspect their proposal shape.
        guard outcome.eligible else {
            notice = .unsupportedScreenshot
            return applied
        }
        // This is the sole mutating application seam. B/C always withhold;
        // A/D may cross it only after their explicit recovery action.
        guard let disposition = outcome.venueDisposition else {
            // Classification is mandatory for every eligible R4.2 result.
            // A missing disposition is never an implicit supported anchor.
            return applied
        }
        if disposition.blocksProposalApplication { return applied }
        if case .supported(let anchor) = disposition,
           let proposedLocation = outcome.proposal.selectedDiningSpot,
           proposedLocation != anchor {
            // A classifier result cannot stand in for the validated proposal
            // anchor when the proposal supplies one. A confirmed A result may
            // intentionally have no proposal location: the requester’s
            // selected venue is the destination for its useful details.
            return applied
        }
        if !venueConfirmation,
           Self.venueRecoveryKind(for: outcome, manualEdits: manualEdits, draft: draft) != nil {
            return applied
        }
        // An unanchored path-only result is not a venue authority. Keep the
        // existing no-useful-extraction treatment rather than letting a
        // deterministic menu-path proposal mutate the draft by itself.
        if outcome.proposal.selectedDiningSpot == nil,
           !Self.proposalHasOrderDetails(outcome.proposal) {
            notice = .noUsefulExtraction
            return applied
        }
        if case .unresolved = disposition,
           outcome.proposal.selectedDiningSpot != nil,
           !Self.proposalHasOrderDetails(outcome.proposal) {
            // R4.1 catalog text can populate a proposal location even when
            // R4.2 cannot establish venue authority. It is not useful
            // extraction until the requester has independently confirmed an
            // A result, and location itself is never copied from unresolved
            // evidence.
            notice = .noUsefulExtraction
            return applied
        }
        // W4-R4.1: the deterministic path is resolved FIRST, so everything
        // branch-dependent below is written into the branch the form is
        // actually on after this proposal. A requester-owned manual path is
        // never overwritten; an attempted opposite path is offered inline,
        // while a same-path proposal changes and preserves nothing.
        if outcome.eligible, let proposedPath = outcome.proposal.menuPath {
            if manualEdits.hasManuallyEditedMenuPath {
                if draft.menuPath != proposedPath {
                    applied.suggestedMenuPath = proposedPath
                }
            } else {
                if draft.menuPath != proposedPath {
                    draft.menuPath = proposedPath
                    applied.menuPath = true
                }
                applied.establishedMenuPath = true
            }
        }
        if case .supported = disposition, let spot = outcome.proposal.selectedDiningSpot {
            if manualEdits.hasManuallyEditedLocation {
                applied.preservedManualFieldCount += 1
            } else {
                draft.selectedDiningSpot = spot
                applied.location = true
            }
        }
        // Meal swipes first, so the entry fill below writes into the count
        // this same proposal just established rather than the previous one.
        if let mealSwipes = outcome.proposal.mealSwipes,
           applied.suggestedMenuPath == nil {
            if manualEdits.hasManuallyEditedMealSwipes {
                applied.preservedManualFieldCount += 1
                if outcome.eligible, draft.menuPath == .mealExchange,
                   mealSwipes > draft.mealSwipes, (1...5).contains(mealSwipes) {
                    applied.suggestedMealSwipes = mealSwipes
                }
            } else {
                draft.mealSwipes = mealSwipes
                applied.mealSwipes = true
            }
        }

        if let mealItems = outcome.proposal.mealItems, !mealItems.isEmpty,
           applied.suggestedMenuPath == nil {
            switch draft.menuPath {
            case .mealExchange:
                // One proposed item per active meal field, in order. A name
                // and its optional details are independent manual-authority
                // and provenance units; writing one never authorizes writing
                // the other.
                let proposedEntryCount = applied.suggestedMealSwipes ?? draft.mealSwipes
                for index in 0..<min(proposedEntryCount, RequestFoodFormDraft.maxMealSwipes)
                where index < mealItems.count {
                    let proposal = mealItems[index]
                    if manualEdits.hasManuallyEditedMealItemName(index) {
                        applied.preservedManualFieldCount += 1
                    } else {
                        draft.mealEntries[index].name = proposal.name
                        applied.mealItemNames.insert(index)
                    }
                    // `nil` means this partial proposal did not offer a
                    // Details value. It must not manufacture an update by
                    // clearing a sibling field; the next selection's normal
                    // AI-owned clearing remains the generation boundary.
                    if let details = proposal.details {
                        if manualEdits.hasManuallyEditedMealItemDetails(index) {
                            applied.preservedManualFieldCount += 1
                        } else {
                            draft.mealEntries[index].details = details
                            applied.mealItemDetails.insert(index)
                        }
                    }
                }
            case .diningDollars:
                // The Dining-Dollars-only path has one order-details field
                // rather than per-swipe entries, so the observed items are
                // joined into it — the same values, in the same order, in the
                // one field this path actually has. Matches the backend's
                // `deriveFoodSummary` item-to-text convention
                // (`src/structuredRequest.ts`): "name (details)" when details
                // are present, else just "name".
                if !manualEdits.hasManuallyEditedOrderDetails {
                    draft.orderDetails = mealItems
                        .map { item in item.details.map { "\(item.name) (\($0))" } ?? item.name }
                        .joined(separator: "; ")
                    applied.orderDetails = true
                } else {
                    applied.preservedManualFieldCount += 1
                }
            }
        }

        // This narrow R4 authority is populated only by the independent
        // current-cart/order-level OCR rule. It fills ONLY the Meal Exchange
        // branch's top-up draft; the Dining-Dollars-only whole-order Total is
        // handled separately below. Neither submits a request.
        if let cents = outcome.proposal.estimatedDiningDollarsCents,
           applied.suggestedMenuPath == nil,
           draft.menuPath == .mealExchange,
           !manualEdits.hasManuallyEditedDiningDollars {
            draft.mealExchangeDiningDollarsText = DiningDollarsEntry.formatted(cents: cents)
            applied.diningDollars = true
        } else if outcome.proposal.estimatedDiningDollarsCents != nil,
                  applied.suggestedMenuPath == nil,
                  draft.menuPath == .mealExchange {
            applied.preservedManualFieldCount += 1
        }

        if let cents = outcome.proposal.diningDollarsOrderTotalCents,
           applied.suggestedMenuPath == nil,
           draft.menuPath == .diningDollars {
            if manualEdits.hasManuallyEditedDiningDollarsOnly {
                applied.preservedManualFieldCount += 1
            } else {
                draft.diningDollarsOnlyText = DiningDollarsEntry.formatted(cents: cents)
                applied.diningDollarsOnly = true
            }
        }

        if outcome.isEmpty {
            notice = .noUsefulExtraction
        }

        return applied
    }

    /// The one policy-to-presentation bridge for A–D. It deliberately sees no
    /// raw OCR and never changes the draft.
    static func venueRecoveryKind(
        for outcome: ScreenshotProposalOutcome,
        manualEdits: ScreenshotFieldManualEditState,
        draft: RequestFoodFormDraft
    ) -> ScreenshotVenueRecoveryKind? {
        guard outcome.eligible else { return nil }
        switch outcome.venueDisposition {
        case .conflicting?: return .conflicting
        case .unsupported?: return .unsupported
        case .supported(let anchor)?:
            // A supported anchor the proposal does not name is uncertainty
            // (A). Reconciliation never produces it; this keeps the gate
            // fail-closed for any hand-built outcome.
            guard let screenshot = outcome.proposal.selectedDiningSpot, screenshot == anchor else {
                return proposalHasOrderDetails(outcome.proposal) ? .unresolved : nil
            }
            // E applies as today; only a conflict with a requester-owned
            // location is D.
            guard manualEdits.hasManuallyEditedLocation,
                  let manual = draft.selectedDiningSpot,
                  manual != screenshot else { return nil }
            return .manualMismatch(screenshot: screenshot, manual: manual)
        case .unresolved?:
            return proposalHasOrderDetails(outcome.proposal) ? .unresolved : nil
        case nil: return nil
        }
    }

    private static func proposalHasOrderDetails(_ proposal: ScreenshotProposal) -> Bool {
        !(proposal.mealItems?.isEmpty ?? true)
            || proposal.mealSwipes != nil
            || proposal.estimatedDiningDollarsCents != nil
            || proposal.diningDollarsOrderTotalCents != nil
    }

    /// Explicit acceptance of this result's larger, independently validated
    /// swipe proposal. The view checks the result token before calling this.
    /// This is screenshot provenance, never a picker/manual edit.
    func adoptSuggestedMealSwipes(
        _ count: Int,
        manualEdits: inout ScreenshotFieldManualEditState,
        provenance: inout ScreenshotProposalAppliedFields,
        to draft: inout RequestFoodFormDraft
    ) -> Bool {
        guard draft.menuPath == .mealExchange,
              manualEdits.hasManuallyEditedMealSwipes,
              count > draft.mealSwipes, (1...5).contains(count) else { return false }
        draft.mealSwipes = count
        manualEdits.hasManuallyEditedMealSwipes = false
        provenance.mealSwipes = true
        return true
    }
}
