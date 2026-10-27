//
//  HomeExchangeView.swift
//  CommonPlateios
//
// W4-H2: Home's live CommonPlate exchange — the board-first root content that
// supersedes R1's recurring static launcher. Renders the same authoritative
// `RequestStore` state the retired Active Requests screen rendered (membership,
// order, active reservation, and now caller-relative ownership), composed
// into the approved H2 states: populated/low-activity board, Continue
// Helping, Your Request, Empty Exchange (E1), and Exchange Unavailable (U4).
//
// This view owns Home composition and navigation only. It creates no new
// request/reservation/ownership truth of its own — every value it renders
// comes from `RequestStore`.
import SwiftUI

struct HomeExchangeView: View {
    @ObservedObject var store: RequestStore
    @ObservedObject var identityStore: ParticipantIdentityStore
    @ObservedObject var alertSubscriptionStore: AlertSubscriptionStore
    @ObservedObject var pushSubscriptionStore: PushSubscriptionStore
    @ObservedObject var unsubscribeStore: ParticipantEmailUnsubscribeStore
    /// W4-D2 crossfade handoff: relayed by `ContentView` from the continuity
    /// overlay's own `RequestCreationContinuityHandoffKey` publication — see
    /// `RequestCreationContinuityLayout.isHomeCardRevealed(phase:reduceMotion:hasLandingDestination:)`.
    /// This is the *only* signal that fades this Home card in early. It is
    /// set for Reduce Motion with a usable destination and for the
    /// no-usable-target in-place crossfade; standard motion with a usable
    /// destination never sets it, so that branch's existing instant swap is
    /// unaffected.
    let isRevealingLandingContinuityCard: Bool
    let onRequestMeal: () -> Void
    /// W4-O1: the one request currently receiving the temporary first-use
    /// discovery treatment, or nil. Derived by `HelpingDiscovery` from this
    /// same board's own order; Home never reorders or invents a request.
    var discoverySelectedRequestID: String? = nil
    /// W4-O1: reports the request whose Home `Needs help` card the student
    /// just tapped, only while the discovery treatment is active. This is
    /// the one completion source for discovery; navigation that does not go
    /// through a Home card (a notification tap, Settings) never reports.
    var onOpenEligibleRequestCard: (String) -> Void = { _ in }
    /// W4-O1: the accessibility-activation counterpart of
    /// `onOpenEligibleRequestCard`. SwiftUI handles a `NavigationLink`'s
    /// VoiceOver activation natively and never runs the card's touch
    /// gesture, so while the discovery treatment is active the card's
    /// default accessibility action calls this once to report the card open
    /// and push the same request detail the link would.
    var onActivateEligibleRequestCard: (FoodRequest) -> Void = { _ in }
    var onHelperPickupNoticePresentation: (String?) -> Void = { _ in }

    /// W4-R5 (Active Requests retirement): the safety-critical claim notices
    /// that used to be delivered on Active Requests are delivered here, in the
    /// store's FIFO order, only while Home is the presented destination.
    @State private var presentedClaimUnavailableNotice: ClaimUnavailableNotice?

    /// HQ decision 3 (authored Home refresh presentation): presentation-only
    /// state derived *from inside* `.refreshable`'s own closure — never from
    /// an independent drag gesture or threshold. SwiftUI has already decided
    /// the user completed a pull-to-refresh before this closure runs, so
    /// setting these flags around the existing `store.fetchRequests()` call
    /// only observes native refresh lifecycle; it never decides whether a
    /// refresh happens.
    @State private var isRefreshInFlight = false
    /// Faith (W4-N1): tapping `Request Alerts` on Home hid the promotion with
    /// no feedback. Set only by that tap; the confirmation shows only once the
    /// store itself reports On, never on launch reconciliation.
    @State private var isAwaitingHomeRequestAlertsResult = false
    @State private var showsRequestAlertsOnConfirmation = false
    /// W4-H3 A2 header ownership. `true` while the stationary band header owns
    /// the CommonPlate header (rest, pull, active refresh, native collapse);
    /// `false` once the in-scroll header copy has scrolled away from rest and
    /// owns it. Derived only from passively measured scroll position (see
    /// `HomeHeaderAnchorKey`) — never from refresh state, a timer, a gesture,
    /// or UIKit introspection.
    @State private var ownsBandHeader = true
    /// Measured height of the reserved top band, so short content can be
    /// sized to the band-reduced viewport and gain no artificial scroll range.
    @State private var headerBandHeight: CGFloat = 0
    @State private var boardSectionTopInContent: CGFloat = 0
    /// W4-H3 truthful-success acknowledgment: whether the bare micro-check is
    /// currently faded in, and the generation that owns its pending
    /// show/hide. A new refresh (or a newer success) invalidates any older
    /// pending presentation, so a stale timer can never show or hide the mark
    /// for a different refresh. Cosmetic only — it never decides an outcome.
    @State private var isShowingRefreshSuccess = false
    @State private var refreshSuccessGeneration = 0
    /// Whether the refresh in progress began from Unavailable (Decision 12
    /// Option B input). Presentation only; never decides an outcome.
    @State private var isRecoveryRefresh = false
    /// W4-H3 authored post-refresh settle (Decision 11; see `HomeRefreshSettle`).
    /// Presentation only: the hold applied to the dynamic Home region, the fixed
    /// lane the check sits in, and the passive scroll state machine are all set
    /// only on a truthful successful refresh and read only by the presentation.
    /// None of it feeds a refresh, `RequestStore`, data, or header ownership. The
    /// machine is a reference type, so per-frame samples invalidate nothing.
    @State private var refreshSettleHold: CGFloat = 0
    @State private var refreshSuccessLaneCenter: CGFloat = 0
    @State private var refreshSettleRestMinY: CGFloat = 0
    @State private var refreshSettleMachine = HomeRefreshSettleMachine()
    /// W4-H3 context-bound acknowledgment: whether this Home presentation is
    /// currently the presented destination. Set by appearance/disappearance
    /// only, so a pending acknowledgment task that outlives the presentation
    /// (e.g. the user pushed a request or Settings) reads `false` when it would
    /// begin. Presentation-only; it feeds no refresh, store, or data decision.
    @State private var isHomePresented = false
    /// True from the start of a native refresh until shortly after its
    /// presentation settles. Scopes the brief hierarchy-resolution animation
    /// to refresh-driven category changes only, so unrelated Home changes
    /// (e.g. the request-creation continuity landing) keep their existing
    /// unanimated behavior.
    @State private var animatesHierarchyResolution = false
    /// Faith-selected pickup collapse (Figma `1603:7208`): the card the
    /// authoritative confirmation just retired, frozen so it can exit on
    /// screen once Home is back, rather than vanishing behind the pop.
    /// Presentation only — it never feeds a store, refresh, or ownership
    /// decision and is always cleared when Home leaves.
    @State private var pickupExit: PickupExitHold?
    @State private var pickupNoticeRevealed = true
    @State private var ownRequestSnapshot: [PickupSnapshotEntry] = []
    @State private var lastSeenPickupNotice = false
    @State private var pickupCollapseTask: Task<Void, Never>?
    @State private var isPlayingPickupCollapse = false
    @State private var hapticedHelperPickupIDs: Set<String> = []
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// HQ decision 5: a presentation-only maximum for the initial Loading
    /// state. This never touches `RequestStore` truth or its
    /// fetch/generation boundary — it only tells `boardState` to stop
    /// presenting Loading and present Exchange Unavailable once 5 seconds
    /// have elapsed with no authoritative result yet. If the same
    /// still-current fetch later resolves (success or failure), `boardState`
    /// reads that authoritative result directly and this flag no longer
    /// matters — a fast response is never held back, and a slow-but-eventual
    /// success still recovers Home normally.
    @State private var hasInitialLoadDeadlineElapsed = false
    static let initialLoadDeadline: Duration = .seconds(5)

    static func combinedOwnRequests(
        _ ongoingRequests: [FoodRequest],
        placedOrders: [PlacedOrder]
    ) -> [FoodRequest] {
        let placedIDs = Set(placedOrders.map(\.id))
        return (ongoingRequests.filter { !placedIDs.contains($0.id) } +
                placedOrders.map(\.request))
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        exchangeContent
        .alert(item: $presentedClaimUnavailableNotice) { notice in
            Alert(
                title: Text(HelperRequestPresentation.claimUnavailableTitle(for: notice.reason)),
                message: HelperRequestPresentation.claimUnavailableDetail(for: notice.reason).map(Text.init),
                dismissButton: .default(Text("OK")) {
                    store.acknowledgeClaimUnavailableNotice(id: notice.id)
                }
            )
        }
        .onChange(of: store.claimUnavailableNotice?.id) { _, _ in
            presentNextClaimUnavailableAlertIfNeeded()
        }
        .onChange(of: presentedClaimUnavailableNotice?.id) { _, presentedID in
            if presentedID == nil { presentNextClaimUnavailableAlertIfNeeded() }
        }
        .onAppear {
            isHomePresented = true
            if ownRequestSnapshot.isEmpty {
                ownRequestSnapshot = pickupSnapshot(of: liveOwnRequests)
                lastSeenPickupNotice = store.hasPickupConfirmationNotice
            }
            if pickupExit != nil || !pickupNoticeRevealed { playPickupCollapse() }
            presentHelperPickupNoticeOnce()
        }
        .onChange(of: store.helperPickupNoticeRequestID) { _, _ in
            if isHomePresented {
                onHelperPickupNoticePresentation(store.helperPickupNoticeRequestID)
                presentHelperPickupNoticeOnce()
            }
        }
        .onChange(of: PickupObservationKey(
            noticeOn: store.hasPickupConfirmationNotice,
            ids: liveOwnRequests.map(\.id)
        )) { _, _ in observePickupConfirmation() }
        .onAppear {
            Task { await store.refreshHelperContinuations() }
        }
        .onAppear { presentNextClaimUnavailableAlertIfNeeded() }
        .onDisappear {
            isHomePresented = false
            onHelperPickupNoticePresentation(nil)
            // A collapse that has not played never lingers as a frozen card.
            finishPickupCollapseImmediately()
            // Leaves no stale transform or mark for the next time Home appears.
            endRefreshSettleImmediately()
        }
        // Fetch-on-appearance contract: an initial load on first appearance, a refresh classified by
        // `hasSuccessfullyFetchedRequests` on any later one, guarded so a
        // redraw or a concurrent Try Again never starts a second fetch.
        .task {
            guard !store.isFetching else { return }
            await store.fetchRequests()
        }
        // W4-R5: the participant's own requests are read alongside the board,
        // independently, so neither read's outcome decides the other.
        .task { await store.fetchOwnerRequests() }
        .task { await store.fetchPlacedOrders() }
        // HQ decision 5: a bounded maximum wait for the initial Loading
        // presentation, layered over the existing authoritative fetch — not
        // a second reload source and not a fake minimum delay. Runs
        // concurrently with the fetch task above; if the fetch has already
        // resolved (success or failure) by the time this wakes, it is a
        // no-op, since `boardState` no longer reads this flag once
        // `hasSuccessfullyFetchedRequests` or `hasFailedInitialFetchAtLeastOnce`
        // is true.
        .task {
            try? await Task.sleep(for: Self.initialLoadDeadline)
            guard !store.hasSuccessfullyFetchedRequests,
                  !store.hasFailedInitialFetchAtLeastOnce else { return }
            hasInitialLoadDeadlineElapsed = true
        }
        // Participant-scoped ownership review (Section 9): `store.requests`
        // carries caller-relative `isOwnRequest` truth resolved for whoever
        // was authoritative at the moment of the last fetch. Verification
        // completing, Change Email completing, or Remove Email all change
        // who "own" means without this board otherwise ever refreshing on
        // their own — the same `.onChange(of: identityStore.identity)`
        // re-key `RequestDetailView` already uses for its own per-request
        // stale-participation truth. This invokes no reload path but the
        // existing authoritative one, and reuses its existing
        // fetchGeneration fence for correctness, not a new truth owner.
        .onChange(of: identityStore.identity) { _, _ in
            // Invalidates the previous participant's caller-relative
            // ownership *before* reloading, so the window between an identity
            // change and replacement truth fails closed rather than showing
            // the old participant's own/not-own conclusions as this one's.
            // `R5-IR-1`: a replaced participant's board is retired in this
            // same turn, not on the next scheduler hop.
            store.invalidateRequestDataIfIdentityReplaced()
            Task { await store.reconcileOwnershipForCurrentAuthority() }
            Task { await store.fetchOwnerRequests() }
            Task { await store.fetchPlacedOrders() }
            Task { await store.reconcilePendingPlacedPickupIfNeeded() }
            Task { await store.refreshHelperContinuations() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await store.fetchOwnerRequests() }
            Task { await store.fetchPlacedOrders() }
            Task { await store.refreshHelperContinuations() }
        }
    }

    /// The one place H2 observes the native `.refreshable` interaction
    /// actually firing, and the only reload path it ever invokes —
    /// `store.fetchRequests()`, identical to initial load and every other
    /// Home refresh. No independent gesture, threshold, or second refresh
    /// state machine decides whether this runs; SwiftUI already decided the
    /// user completed a pull-to-refresh before calling this closure.
    private func performAuthoredRefresh() async {
        animatesHierarchyResolution = true
        isRefreshInFlight = true
        // W4-R5: the same pull also re-reads the participant's own requests.
        // Independent of the board read: it never changes this refresh's own
        // truthful outcome, though a board that cannot be verified is not
        // presented as healthy (see `boardState(store:)`).
        Task { await store.fetchOwnerRequests() }
        Task { await store.fetchPlacedOrders() }
        Task { await store.refreshHelperContinuations() }
        // Read before the fetch applies, from the state Home is presenting
        // (including the initial-load deadline): whether this refresh is a
        // recovery from Unavailable. Presentation only; it feeds Decision 12 Option B's
        // no-lane fallback and nothing about the refresh or its data.
        isRecoveryRefresh = currentBoardState == .unavailable
        // A new refresh supersedes any settle or acknowledgment still pending
        // or showing from an earlier one.
        supersedeRefreshSettle()

        // The refreshed hierarchy resolves from the store as soon as the
        // fetch applies — it is never held back for the settle or the
        // acknowledgment.
        let acknowledgesSuccess = await Self.resolveRefresh(store: store)
        // The settle is begun synchronously, inside this closure and before it
        // can return — SwiftUI ends the native refresh only after the closure
        // returns. Beginning it arms nothing from the displacement seen right now
        // (while the refresh is active that reading is one lane height off); the
        // hold is armed from the first displacement that is real once the refresh
        // has ended, so the handoff has no discontinuity. It is a render-time
        // translation of the dynamic region only; the data is already applied.
        if acknowledgesSuccess {
            beginRefreshSettle()
        }
        isRefreshInFlight = false
        scheduleHierarchyAnimationReset()
    }

    /// Runs the one authoritative reload under the manual-refresh deadline and
    /// reports whether this refresh operation truthfully succeeded.
    ///
    /// HQ decision 8: a user-initiated refresh may remain in the
    /// refreshing presentation for at most `manualRefreshDeadline`.
    /// `awaitWithDeadline` cancels whichever of the fetch/timeout loses the
    /// race, so a fetch that times out here cannot keep running to mutate
    /// state later — it relies entirely on
    /// `RequestStore.fetchRequests()`'s own existing `CancellationError`
    /// handling and `fetchGeneration`/`collectionRevision` fence, not any
    /// new store mechanism, and that same fence is what guarantees a
    /// late/cancelled result from this attempt can never overwrite a
    /// subsequent refresh's result even if cancellation isn't observed
    /// instantly.
    ///
    /// W4-H3: the fetch's own outcome is captured alongside the deadline
    /// race. It is read only when the fetch itself finished before the
    /// deadline (the recorder is written strictly before the race's
    /// `operation` returns), so a timed-out or cancelled attempt can never
    /// contribute one. Success is this refresh's own truthful outcome —
    /// resolved before the deadline, applied by the current fetch generation —
    /// and never inferred from what Home happens to look like afterwards.
    ///
    /// `internal` so the real composition is testable without UI
    /// infrastructure, matching this file's testable-`static` pattern.
    static func resolveRefresh(
        store: RequestStore,
        deadline: Duration = manualRefreshDeadline
    ) async -> Bool {
        let outcomeRecorder = RefreshOutcomeRecorder()
        let didResolveInTime = await Self.awaitWithDeadline(deadline) {
            let outcome = await store.fetchRequests()
            await outcomeRecorder.record(outcome)
        }
        var fetchOutcome: RequestFetchOutcome?
        if didResolveInTime {
            fetchOutcome = await outcomeRecorder.outcome
        }
        return shouldAcknowledgeRefreshSuccess(
            didResolveInTime: didResolveInTime,
            fetchOutcome: fetchOutcome,
            resolvedState: boardState(store: store)
        )
    }

    /// The truthful-success predicate (W4-H3, extending H2 HQ decision 6's
    /// "authoritative result, not merely that HTTP finished" to every
    /// refresh). A refresh is acknowledged only when it resolved before the
    /// deadline, its own fetch reported `.succeeded` under the existing
    /// generation/revision/authority fences, and Home resolves to a healthy
    /// board. Unchanged data does not matter; timeout, cancellation, a stale
    /// or superseded completion, a failed fetch (including one that leaves
    /// stale healthy data on screen), and an Unavailable refresh that stays
    /// Unavailable never qualify.
    static func shouldAcknowledgeRefreshSuccess(
        didResolveInTime: Bool,
        fetchOutcome: RequestFetchOutcome?,
        resolvedState: BoardState
    ) -> Bool {
        guard didResolveInTime else { return false }
        guard fetchOutcome == .succeeded else { return false }
        // Only a resolved healthy state qualifies; `.loading` is unresolved
        // and `.unavailable` is not a successful result.
        switch resolvedState {
        case .empty, .populated: return true
        case .loading, .unavailable: return false
        }
    }

    /// Cosmetic settle only: lets the refresh-driven hierarchy resolution
    /// finish animating before ordinary (unanimated) Home updates resume. It
    /// gates no truth and no refresh outcome.
    private func scheduleHierarchyAnimationReset() {
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            animatesHierarchyResolution = false
        }
    }

    /// Races `operation` against `deadline`, cancelling whichever loses.
    /// Returns whether `operation` itself finished first. This is the only
    /// place H2 imposes the manual-refresh deadline; it invokes no reload
    /// path of its own.
    ///
    /// W4-H4 physical-device FIX — why the race runs inside its own
    /// unstructured `Task` rather than directly in the caller's:
    ///
    /// SwiftUI cancels `.refreshable`'s own action task as soon as the view
    /// that owns the modifier is invalidated, and this refresh necessarily
    /// invalidates Home the moment it starts — `RequestStore.fetchRequests()`
    /// publishes `isRefreshingRequests`, which `HomeExchangeView` observes.
    /// Device and simulator instrumentation measured that cancellation
    /// arriving ~15-40 ms into every pull-to-refresh, before the `GET
    /// /api/requests` response could land.
    ///
    /// A structured child of that task inherits the cancellation, so the real
    /// fetch was being cancelled mid-flight on *every* pull:
    /// `fetchRequests()` correctly treats `CancellationError` as "no answer"
    /// and returns without touching `requests`, so newly available
    /// authoritative requests could never reach the rendered board until a
    /// cold relaunch re-ran the initial `.task` load. Making the race
    /// unstructured decouples the authoritative refresh's lifetime from
    /// SwiftUI's presentation-driven cancellation of the pull gesture, which
    /// is the same reasoning `RequestStore.refreshRequestsAfterClaimConflict`
    /// already documents for its own store-owned reload task.
    ///
    /// Nothing else about the deadline changes. The group still cancels
    /// whichever side loses — so HQ decision 8 still holds exactly: a fetch
    /// that loses to `deadline` is still cancelled and still cannot keep
    /// running to mutate state later. `fetchGeneration` and
    /// `collectionRevision` remain the authority on which result may be
    /// applied, and a caller whose own task is cancelled still simply waits
    /// here rather than being handed a fabricated outcome.
    /// Deliberately `internal` rather than `private` (W4-H4 physical-device
    /// FIX): the caller-cancellation behavior above is exactly the defect
    /// that shipped, and the only non-brittle seam that can prove it without
    /// UI-test infrastructure is calling this directly — matching this file's
    /// existing testable-`static`-member pattern (`boardState`,
    /// `partitionByOwnership`, `ownRequestsPreview`).
    static func awaitWithDeadline(
        _ deadline: Duration,
        operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let race = Task {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await operation()
                    return true
                }
                group.addTask {
                    try? await Task.sleep(for: deadline)
                    return false
                }
                let didOperationFinishFirst = await group.next() ?? false
                group.cancelAll()
                return didOperationFinishFirst
            }
        }
        return await race.value
    }

    /// HQ decision 8.
    static let manualRefreshDeadline: Duration = .seconds(5)

    // MARK: - Authored post-refresh settle and acknowledgment (W4-H3)

    /// Cosmetic timing only, within the accepted opacity-only / no-dwell
    /// constraints — none of it gates Home content or any outcome. The settle's
    /// own parameters live with `HomeRefreshSettle`.
    static let refreshSuccessFadeInSeconds: Double = 0.15
    static let refreshSuccessFadeOutSeconds: Double = 0.25
    /// A takeover (a new pull, a scroll away) retires the settle and a showing
    /// check quickly, so nothing stale lingers or stacks with the next native
    /// indicator.
    static let refreshSuccessRetireSeconds: Double = 0.1

    /// The context-bound acknowledgment rule. Evaluated at the start of the
    /// settle (no settle is begun if it already fails) and again at the moment
    /// the acknowledgment would begin — when the native indicator has cleared
    /// the lane: Home must still be the presented destination, and the scroll
    /// position must still be in the top/header-owned refresh context — which
    /// is exactly the existing `ownsBandHeader` truth, not a second scroll
    /// threshold. A `false` result suppresses the micro-check and the `Updated`
    /// announcement together; the suppressed acknowledgment is dropped, never
    /// queued or replayed. It is presentation-only: the refresh outcome and the
    /// refreshed data have already been applied and are unaffected.
    static func shouldBeginRefreshAcknowledgment(
        isHomePresented: Bool,
        ownsBandHeader: Bool
    ) -> Bool {
        isHomePresented && ownsBandHeader
    }

    /// Starts the authored settle for one truthful successful refresh. Called
    /// only behind `shouldAcknowledgeRefreshSuccess`, from the one refresh
    /// closure.
    ///
    /// Nothing is handed off from the displacement seen at this moment: while the
    /// native refresh is active that reading is one lane height off, and a finger
    /// may still be down (see `HomeRefreshSettle`). The settle waits for the first
    /// displacement that is real once the refresh has ended, arms the hold from it
    /// so the content carries on from where native left it, and begins the check
    /// and `Updated` only once native has carried the content back to the
    /// indicator-clear depth — the spinner being gone (`perform(_:)`).
    private func beginRefreshSettle() {
        guard let plan = HomeRefreshSettle.plan(
            reduceMotion: reduceMotion,
            isHomePresented: isHomePresented,
            ownsBandHeader: ownsBandHeader
        ) else { return }

        refreshSuccessGeneration += 1
        let generation = refreshSuccessGeneration
        // The check's lane is fixed for the whole settle, by the plan, before any
        // path that can show it (the mark is transparent here, and its position
        // never animates).
        refreshSuccessLaneCenter = plan.laneCenter
        perform(refreshSettleMachine.begin(
            plan: plan,
            ownsBandHeader: ownsBandHeader,
            isHomePresented: isHomePresented,
            isRecovery: isRecoveryRefresh
        ))

        Task {
            // The native refresh has ended: if the content is already at rest and
            // nothing displaced has appeared, there is no collapse to wait for.
            try? await Task.sleep(for: HomeRefreshSettle.postEndGrace)
            guard generation == refreshSuccessGeneration else { return }
            perform(refreshSettleMachine.nativeEndGraceElapsed(
                ownsBandHeader: ownsBandHeader,
                isHomePresented: isHomePresented
            ))
            // Bound: a settle whose native collapse never carries the content back
            // to the clear depth is ended, never shown late.
            try? await Task.sleep(for: HomeRefreshSettle.maxWaitForNativeCollapse)
            guard generation == refreshSuccessGeneration else { return }
            if refreshSettleMachine.isAwaitingCollapse { retireRefreshSettle() }
        }
    }

    /// Feeds one passive displacement sample to the settle and performs what it
    /// asks for. The context it is judged in is the accepted `ownsBandHeader`
    /// truth and the presentation flag — read here, not by the ownership writer.
    private func observeRefreshSettle(displacement: CGFloat) {
        perform(refreshSettleMachine.observe(
            displacement: displacement,
            ownsBandHeader: ownsBandHeader,
            isHomePresented: isHomePresented
        ))
    }

    /// Performs what one passive scroll sample (or the start of the settle) asks
    /// for. The check and `Updated` begin here — event-driven, once the native
    /// indicator is clear of the lane — or the settle retires. It reads only
    /// scroll geometry and the presentation context; it neither triggers nor
    /// decides any refresh.
    private func perform(_ effects: [HomeRefreshSettleMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .armHold(let start):
                armRefreshSettleHold(start: start)
            case .startEase:
                startRefreshSettleEase()
            case .beginAcknowledgment:
                beginRefreshAcknowledgment()
            case .retire, .endWithoutAcknowledgment:
                retireRefreshSettle()
            case .releaseHold:
                releaseRefreshSettleHold()
            }
        }
    }

    /// Holds the dynamic region at the displacement native had when the settle
    /// took over (capped at the held lane), un-animated.
    private func armRefreshSettleHold(start: CGFloat) {
        var immediate = Transaction()
        immediate.disablesAnimations = true
        withTransaction(immediate) {
            refreshSettleHold = start
        }
    }

    /// Eases the armed hold to rest. Started only once native has fallen to the
    /// hold, so a pull still being held keeps the hold in reserve rather than
    /// spending its ease while the finger is down.
    private func startRefreshSettleEase() {
        guard let plan = refreshSettleMachine.plan else { return }
        let generation = refreshSuccessGeneration
        Task {
            // Let the held value commit for a frame so the ease starts from it
            // instead of coalescing with it.
            try? await Task.sleep(for: HomeRefreshSettle.commitInterval)
            guard generation == refreshSuccessGeneration else { return }
            withAnimation(plan.animation) {
                refreshSettleHold = 0
            }
            // Bound: an unfinished settle is ended, never left running.
            try? await Task.sleep(for: plan.endsAfter)
            guard generation == refreshSuccessGeneration else { return }
            if !refreshSettleMachine.isAwaitingCollapse { refreshSettleMachine.reset() }
        }
    }

    /// Shows the bare micro-check and posts the one VoiceOver announcement for
    /// one truthful successful refresh. Reached only from the effect above,
    /// which has already applied the context gate at this very moment, so the
    /// two forms of feedback begin together or not at all. The announcement
    /// moves no accessibility focus, and the mark itself is never an
    /// accessibility element.
    private func beginRefreshAcknowledgment() {
        guard let plan = refreshSettleMachine.plan else { return }
        let generation = refreshSuccessGeneration
        withAnimation(.easeOut(duration: Self.refreshSuccessFadeInSeconds)) {
            isShowingRefreshSuccess = true
        }
        AccessibilityNotification.Announcement(Self.refreshSuccessText).post()

        Task {
            try? await Task.sleep(for: plan.checkHold)
            guard generation == refreshSuccessGeneration else { return }
            withAnimation(.easeIn(duration: Self.refreshSuccessFadeOutSeconds)) {
                isShowingRefreshSuccess = false
            }
        }
    }

    /// Releases the hold alone, leaving a begun check to finish its own fade.
    /// The generation is untouched so that fade is not cancelled; the machine
    /// goes idle so nothing further reacts to this settle.
    private func releaseRefreshSettleHold() {
        refreshSettleMachine.reset()
        withAnimation(.easeOut(duration: Self.refreshSuccessRetireSeconds)) {
            refreshSettleHold = HomeRefreshSettle.retiredHold
        }
    }

    /// A new refresh invalidates any older settle and acknowledgment, so none
    /// can appear late or linger across refreshes.
    private func supersedeRefreshSettle() {
        refreshSuccessGeneration += 1
        retireRefreshSettle()
    }

    /// Eases any held displacement and a showing check away quickly. Presentation
    /// only: it touches no store, refresh state, or data, and bumps the
    /// generation so no pending task can revive what it retired.
    private func retireRefreshSettle() {
        refreshSuccessGeneration += 1
        // The hold's state is already at its ease target (0) while it animates,
        // so "is anything running" is read from the stage and the mark, not the
        // hold value.
        let isActive = refreshSettleMachine.stage != .idle || isShowingRefreshSuccess
        refreshSettleMachine.reset()
        guard isActive else { return }
        withAnimation(.easeOut(duration: Self.refreshSuccessRetireSeconds)) {
            refreshSettleHold = HomeRefreshSettle.retiredHold
            isShowingRefreshSuccess = false
        }
    }

    /// Ends the settle with no animation, for when Home leaves the screen.
    private func endRefreshSettleImmediately() {
        refreshSuccessGeneration += 1
        refreshSettleMachine.reset()
        var immediate = Transaction()
        immediate.disablesAnimations = true
        withTransaction(immediate) {
            refreshSettleHold = 0
            isShowingRefreshSuccess = false
        }
    }

    // MARK: - Header ownership (W4-H3 A2 band / in-scroll handoff)

    /// Two technically equivalent header representations exist (one scroll
    /// surface only): the band copy, reserved at the top via a safe-area
    /// inset, which owns rest, pull, active refresh, and collapse; and the
    /// in-scroll copy, drawn exactly over the band copy at rest, which owns
    /// ordinary upward scrolling. Which one is visible, hit-testable, and
    /// accessibility-exposed is one rule — `ownsBandHeader` — derived only
    /// from how far the in-scroll copy has moved from the band copy.
    enum HeaderRepresentation {
        case band
        case scrolling
    }

    /// Small geometry tolerance (points) so sub-point layout noise at rest
    /// never flips ownership.
    static let headerHandoffTolerance: CGFloat = 1

    /// Positive when the content has scrolled up from rest, negative while it
    /// is pulled down. Both anchors are measured in `.global`, so any common
    /// safe-area/window translation cancels out.
    static func headerScrollOffset(bandMinY: CGFloat, scrollingMinY: CGFloat) -> CGFloat {
        bandMinY - scrollingMinY
    }

    /// The band header owns the header at rest and for every pull
    /// (non-positive scroll offset); the in-scroll copy owns it only once
    /// content has scrolled up past the tolerance. This reads no refresh
    /// state, timer, or gesture.
    static func ownsBandHeader(scrollOffset: CGFloat) -> Bool {
        scrollOffset <= headerHandoffTolerance
    }

    /// The one visibility / hit-testing / accessibility rule shared by both
    /// header representations, so exactly one Settings action is usable and
    /// exposed at a time.
    static func isHeaderRepresentationActive(
        _ representation: HeaderRepresentation,
        ownsBandHeader: Bool
    ) -> Bool {
        switch representation {
        case .band: return ownsBandHeader
        case .scrolling: return !ownsBandHeader
        }
    }

    /// What Exchange Unavailable's body area shows: the authored pull cue at
    /// rest, nothing while native refresh occupies the area.
    enum UnavailableAreaPresentation: Equatable {
        case atRest
        case refreshing
    }

    static func unavailableAreaPresentation(isRefreshInFlight: Bool) -> UnavailableAreaPresentation {
        isRefreshInFlight ? .refreshing : .atRest
    }

    private var unavailableAreaPresentation: UnavailableAreaPresentation {
        Self.unavailableAreaPresentation(isRefreshInFlight: isRefreshInFlight)
    }

    /// Identity of which Home categories exist. A change in it is the only
    /// thing the refresh-scoped hierarchy resolution animation reacts to.
    private struct HierarchyKey: Equatable {
        let hasContinueHelping: Bool
        let hasOwnRequests: Bool
        let boardKind: Int
    }

    private var hierarchyKey: HierarchyKey {
        let boardKind: Int
        switch currentBoardState {
        case .loading: boardKind = 0
        case .unavailable: boardKind = 1
        case .empty: boardKind = 2
        case .populated: boardKind = 3
        }
        return HierarchyKey(
            hasContinueHelping: !store.helperContinuationItems().isEmpty,
            hasOwnRequests: !ownRequests.isEmpty,
            boardKind: boardKind
        )
    }

    // MARK: - Exchange content

    /// W4-H4: one coherent vertical scrolling board. The established header/
    /// priorities, `Continue Helping`, the caller-owned ownership partition,
    /// the shared board heading, and `Needs help` all live inside
    /// the *same* refreshable `ScrollView` — superseding H2's prior
    /// composition, which kept that header/priorities/ownership stack
    /// outside a separately refreshable inner `ScrollView` and broke as one
    /// coherent page once ownership content grew past the viewport. The
    /// persistent `Request Food` action is intentionally the one thing kept
    /// outside this scroll, anchored via `.safeAreaInset(edge: .bottom)`
    /// directly on the `ScrollView` itself (not on the enclosing
    /// `GeometryReader`): physical-device verification found that attaching
    /// the inset one level higher, on the `GeometryReader`, does not
    /// reliably reach the `ScrollView`'s underlying `UIScrollView`
    /// `contentInset` — a long `Needs help` board could render its last
    /// visible card partially beneath the button's opaque background instead
    /// of gaining bottom scroll accommodation for it. Attaching the inset to
    /// the `ScrollView` directly makes that accommodation authoritative for
    /// the one view that needs it, still without shrinking `geometry.size`
    /// (safe-area insets never shrink frames) and without creating a
    /// second/nested scroll region.
    private var exchangeContent: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // W4-H3 A2: the in-scroll header copy. Zero layout height,
                    // drawn directly above the content origin — exactly over
                    // the band copy at rest — so it adds no scroll range and
                    // scrolls away naturally once content moves up.
                    scrollingHeader

                    // W4-H3 Decision 11: the whole dynamic Home region — Continue
                    // Helping, Your request(s), `Needs help`, and the board body —
                    // moves as ONE unit under the authored post-refresh settle.
                    // The hold is a render-time translation only (no layout, scroll
                    // range, inset, or scroll-position change); the header band, the
                    // in-scroll header copy, and the persistent CTA sit outside it
                    // and never move. `Needs help` is never animated separately.
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.l) {
                            // W4-D2 physical-device FIX: `header` is the stable
                            // chrome the continuity reveals immediately; every
                            // other card-bearing zone is held back until the
                            // travelling card has landed — see
                            // `isDeferringContinuityHomeContent(hasLiveContinuity:reduceMotion:)`.
                            homeNoticeBanners
                            pickupConfirmationNotice
                            helperPickupConfirmationNotice
                            continueHelpingSection
                                .modifier(ContinuityDeferredReveal(isDeferring: isDeferringContinuityHomeContent))
                            ownRequestsSection
                            VStack(alignment: .leading, spacing: 19) {
                                boardHeadingRow
                                    .modifier(ContinuityDeferredReveal(isDeferring: isDeferringContinuityHomeContent))
                            }
                        }
                        // W4-H4 final reconciliation: the shared Home
                        // content-column authority (see
                        // `CommonPlateStyle.Metrics.homeContentColumnInset`),
                        // not the general-purpose `Spacing.l` step — this margin
                        // must stay identical to `boardSection`'s below and to
                        // the persistent bottom CTA's so ownership cards, `Needs
                        // help` cards, and the persistent action remain one
                        // column.
                        .padding(.horizontal, CommonPlateStyle.Metrics.homeContentColumnInset)
                        // Header-to-content gap: the band's own bottom padding
                        // (`Spacing.s`) plus this equals the `Spacing.l` the
                        // header had above the first section before the band.
                        .padding(.top, Self.contentTopPaddingBelowBand)
                        .padding(.bottom, CommonPlateStyle.Spacing.m)

                        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
                            boardSection(
                                emptyStateMinHeight: Self.emptyStateMinimumHeight(
                                    viewportHeight: geometry.size.height,
                                    headerBandHeight: headerBandHeight,
                                    boardSectionTop: boardSectionTopInContent
                                )
                            )
                        }
                        .padding(.horizontal, CommonPlateStyle.Metrics.homeContentColumnInset)
                        .padding(.bottom, CommonPlateStyle.Spacing.l)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: HomeHeaderAnchorKey.self,
                                    value: HomeHeaderAnchors(
                                        boardSectionMinY: proxy.frame(in: .named("home-scroll-content")).minY
                                    )
                                )
                            }
                        }
                        .modifier(ContinuityDeferredReveal(isDeferring: isDeferringContinuityHomeContent))
                    }
                    .modifier(HomeRefreshSettleHold(
                        hold: refreshSettleHold,
                        restMinY: refreshSettleRestMinY
                    ))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .coordinateSpace(name: "home-scroll-content")
                // Fills the viewport that is actually visible beneath the
                // reserved band, so short content gains no band-created scroll
                // range (the band reduces the visible height by its own).
                .frame(minHeight: max(0, geometry.size.height - headerBandHeight), alignment: .top)
                // W4-H3: when a refresh changes which categories exist, the
                // whole dynamic region resolves into the new hierarchy with
                // one brief fade/settle. Scoped to refresh-driven changes and
                // suppressed under Reduce Motion (an instant swap).
                // The selected pickup collapse owns the one hierarchy change it
                // causes (the retired card, and its heading when it was the
                // only one, leaving); without this the `nil` here would
                // suppress its exit.
                .animation(
                    reduceMotion
                        ? nil
                        : (isPlayingPickupCollapse
                            ? PickupCollapseMotion.exit
                            : (animatesHierarchyResolution ? .easeInOut(duration: 0.25) : nil)),
                    value: hierarchyKey
                )
            }
            // Functional fix, not a motion-polish change: `.frame(
            // minHeight:)` above makes the exchange ScrollView's content
            // exactly fill the visible viewport on every short-content state
            // (Unavailable, Empty, and in practice most Populated/Low
            // Activity boards too, since a handful of request cards rarely
            // exceeds one screen). Without this modifier, UIKit only allows
            // vertical rubber-banding — the drag `.refreshable` itself
            // depends on — when a scroll view's content is taller than its
            // bounds, so a physical pull could not initiate a refresh at all
            // whenever content did not overflow the viewport. `.always` keeps
            // bounce (and therefore the ability to pull) available regardless
            // of content length; it changes no refresh authority or reload
            // path.
            .scrollBounceBehavior(.always, axes: .vertical)
            .refreshable {
                await performAuthoredRefresh()
            }
            // W4-H3 A2: reserved top band. Being a safe-area inset on the
            // ScrollView itself, the one native refresh indicator sits
            // beneath it — below the stationary CommonPlate header and above
            // `Needs help` — while the band header owns rest, pull, active
            // refresh, and collapse. The band has no background or other
            // chrome of its own.
            .safeAreaInset(edge: .top, spacing: 0) {
                bandHeader
            }
            .safeAreaInset(edge: .bottom) {
                requestMealButton
            }
            // Header ownership, band height, and the settle's scroll sample are
            // passive reads of layout; they decide nothing about refresh.
            .onPreferenceChange(HomeHeaderAnchorKey.self) { anchors in
                if let bandHeight = anchors.bandHeight, bandHeight != headerBandHeight {
                    headerBandHeight = bandHeight
                }
                if let boardSectionMinY = anchors.boardSectionMinY,
                   abs(boardSectionMinY - boardSectionTopInContent) > 0.5 {
                    boardSectionTopInContent = boardSectionMinY
                }
                guard let bandMinY = anchors.bandMinY, let scrollingMinY = anchors.scrollingMinY else { return }
                if let bandHeight = anchors.bandHeight {
                    let restMinY = bandMinY + bandHeight
                    if restMinY != refreshSettleRestMinY {
                        refreshSettleRestMinY = restMinY
                    }
                }
                let scrollOffset = Self.headerScrollOffset(bandMinY: bandMinY, scrollingMinY: scrollingMinY)
                let owner = Self.ownsBandHeader(scrollOffset: scrollOffset)
                if owner != ownsBandHeader {
                    ownsBandHeader = owner
                }
                // Displacement below rest, recorded without invalidating the
                // view; the settle acts only when its own stage must change.
                observeRefreshSettle(displacement: -scrollOffset)
            }
            // The micro-check lives in the transient refresh lane, positioned
            // from the same passive anchors, not inside the band's rest gap.
            .overlayPreferenceValue(HomeHeaderAnchorKey.self) { anchors in
                refreshSuccessLayer(anchors)
            }
        }
        .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
    }

    // MARK: - Header (A2)

    /// Gap the dynamic Home content keeps below the band: with the band's own
    /// bottom padding it reproduces the pre-A2 header-to-content spacing.
    static let contentTopPaddingBelowBand = CommonPlateStyle.Spacing.l - headerBandBottomPadding
    /// The band header's own bottom padding.
    static let headerBandBottomPadding = CommonPlateStyle.Spacing.s

    /// The shared header composition both representations render, so the two
    /// copies are identical in content, environment, and geometry.
    private var headerComposition: some View {
        header
            .padding(.horizontal, CommonPlateStyle.Metrics.homeContentColumnInset)
            .padding(.top, CommonPlateStyle.Spacing.l)
            .padding(.bottom, Self.headerBandBottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Applies the single ownership rule to one representation:
    /// visibility, hit testing, and accessibility exposure all follow
    /// `isHeaderRepresentationActive`, and the swap itself is never animated.
    private func ownedHeader(_ representation: HeaderRepresentation) -> some View {
        let isActive = Self.isHeaderRepresentationActive(representation, ownsBandHeader: ownsBandHeader)
        return headerComposition
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: HomeHeaderAnchorKey.self,
                        value: HomeHeaderAnchors(
                            representation: representation,
                            minY: proxy.frame(in: .global).minY,
                            height: proxy.size.height
                        )
                    )
                }
            )
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            .transaction { $0.animation = nil }
    }

    private var bandHeader: some View {
        ownedHeader(.band)
    }

    private var scrollingHeader: some View {
        Color.clear
            .frame(height: 0)
            .overlay(alignment: .bottomLeading) {
                ownedHeader(.scrolling)
                    .fixedSize(horizontal: false, vertical: true)
            }
    }

    /// Places the mark in the transient refresh lane the native spinner occupied:
    /// centered horizontally, and vertically at the center of that lane below the
    /// stationary band — fixed for the whole settle. It is positioned from the
    /// passive band anchors plus the lane center captured when the settle began;
    /// it never follows the settling content, so its opacity is its only motion.
    /// It reads no refresh state and adds no layout: the permanent Home spacing
    /// is untouched, and the layer is non-interactive and hidden from
    /// accessibility.
    @ViewBuilder
    private func refreshSuccessLayer(_ anchors: HomeHeaderAnchors) -> some View {
        if let bandMinY = anchors.bandMinY,
           let bandHeight = anchors.bandHeight {
            GeometryReader { proxy in
                refreshSuccessMark
                    .position(
                        x: proxy.size.width / 2,
                        y: bandMinY + bandHeight
                            + refreshSuccessLaneCenter
                            - proxy.frame(in: .global).minY
                    )
                    // The lane center is captured once, while the mark is
                    // transparent; it must never animate.
                    .transaction(value: refreshSuccessLaneCenter) { $0.animation = nil }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// The bare 18×18 purple check. Always mounted but transparent at rest;
    /// opacity is its only animated property. It is never an accessibility
    /// element or hit target — VoiceOver gets the separate `Updated`
    /// announcement instead.
    private var refreshSuccessMark: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: Self.refreshSuccessMarkSide, height: Self.refreshSuccessMarkSide)
            .opacity(isShowingRefreshSuccess ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    static let refreshSuccessMarkSide: CGFloat = 18

    /// Interactive footprint of the Home Settings gear (visual ring is 38 pt).
    static let settingsGearHitSide: CGFloat = 44

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AppBrand.name)
                    .font(.commonPlateBrandDisplay(.title))
                Text("at \(AppBrand.campus)")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(CommonPlateStyle.Color.campusQualifierCampus)
            }

            Spacer()

            NavigationLink(value: AppRoute.settings) {
                Image(systemName: "gearshape")
                    .font(.body.weight(.semibold))
                    .frame(width: 38, height: 38)
                    .background(Circle().strokeBorder(.secondary.opacity(0.3)))
                    // Explicit hit region: the stroked ring above is only a
                    // background, so without this only glyph/ring pixels
                    // hit-tested reliably. Appearance is unchanged.
                    .frame(width: Self.settingsGearHitSide, height: Self.settingsGearHitSide)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("home-settings")
        }
    }

    // MARK: - Notices (W4-R5)

    /// The one-time Home notices: the requester's own withdrawal / verified
    /// expiry, and the calm (non-safety) head of the claim-notice queue. The
    /// safety reasons stay alerts (`homeNoticeStyle`).
    @ViewBuilder
    private var homeNoticeBanners: some View {
        if store.isParticipantRestricted {
            HomeRestrictionBanner()
        }
        if store.showsOwnerRemovalNotice {
            HomeRemovedRequestBanner(onDismiss: { store.dismissOwnerRemovalNotice() })
        }
        if let notice = store.requesterNotice {
            switch notice {
            case .withdrawn:
                HomeNoticeBanner(
                    icon: .check,
                    title: EditRequestPresentation.requestWithdrawnNotice,
                    identifier: "home-notice-withdrawn",
                    onDismiss: { store.dismissRequesterNotice() }
                )
            case .createdUnavailable:
                HomeNoticeBanner(
                    icon: .none,
                    title: RequestOperationErrorCode.requestCreatedUnavailableMessage,
                    identifier: "home-notice-created-unavailable",
                    onDismiss: { store.dismissRequesterNotice() }
                )
            case .expired(let vendor, let mealSwipes, let diningDollarsCents):
                HomeNoticeBanner(
                    icon: .clock,
                    title: "Your \(vendor) request expired",
                    detail: diningDollarsCents.map { "\(DiningDollarsEntry.formatted(cents: $0)) Dining Dollars" }
                        ?? RequestCardView.mealSwipesText(mealSwipes),
                    identifier: "home-notice-expired",
                    onDismiss: { store.dismissRequesterNotice() }
                )
            }
        }
        if let notice = store.claimUnavailableNotice,
           HelperRequestPresentation.homeNoticeStyle(for: notice.reason) == .banner {
            let text = HelperRequestPresentation.bannerText(for: notice.reason)
            HomeNoticeBanner(
                icon: .none,
                title: text.title,
                detail: text.detail,
                identifier: "home-notice-claim-unavailable",
                onDismiss: { store.acknowledgeClaimUnavailableNotice(id: notice.id) }
            )
        }
    }

    @ViewBuilder
    private var pickupConfirmationNotice: some View {
        if store.hasPickupConfirmationNotice && pickupNoticeRevealed {
            HomeNoticeBanner(
                icon: .check,
                title: "Pickup confirmed. Enjoy your meal!",
                identifier: "home-notice-pickup-confirmed",
                onDismiss: { store.dismissPickupConfirmationNotice() }
            )
            .transition(
                reduceMotion
                    ? .identity
                    : .opacity.combined(with: .offset(y: -PickupCollapseMotion.rise))
            )
        }
    }

    @ViewBuilder
    private var helperPickupConfirmationNotice: some View {
        if store.helperPickupNoticeRequestID != nil {
            HomeNoticeBanner(
                icon: .check,
                title: "Pickup confirmed. Thanks for helping!",
                identifier: "home-notice-helper-pickup-confirmed",
                onDismiss: { store.dismissHelperPickupNotice() }
            )
            .transition(reduceMotion ? .identity : .opacity)
            .onAppear {
                guard isHomePresented else { return }
                presentHelperPickupNoticeOnce()
            }
        }
    }

    private func presentHelperPickupNoticeOnce() {
        onHelperPickupNoticePresentation(store.helperPickupNoticeRequestID)
        guard let id = store.helperPickupNoticeRequestID,
              !hapticedHelperPickupIDs.contains(id) else { return }
        hapticedHelperPickupIDs.insert(id)
        CommonPlateHaptics.success()
        store.markHelperPickupNoticePresented()
    }

    struct PickupSnapshotEntry {
        let request: FoodRequest
        let ownerPhase: OwnerRequestPhase?
        let placed: PlacedOrder?
    }

    private func pickupSnapshot(of requests: [FoodRequest]) -> [PickupSnapshotEntry] {
        requests.map {
            PickupSnapshotEntry(
                request: $0,
                ownerPhase: ownerPhase(for: $0),
                placed: store.placedOrder(requestID: $0.id)
            )
        }
    }

    struct PickupExitHold: Equatable {
        let request: FoodRequest
        let index: Int
        let ownerPhase: OwnerRequestPhase?
        let needsPickupConfirmation: Bool?
    }

    /// Notices the one moment the store reports an authoritative pickup
    /// confirmation (the notice flag turning on) and freezes the retired card.
    private func observePickupConfirmation() {
        let live = liveOwnRequests
        let noticeOn = store.hasPickupConfirmationNotice
        defer {
            ownRequestSnapshot = pickupSnapshot(of: live)
            lastSeenPickupNotice = noticeOn
        }
        guard noticeOn, !lastSeenPickupNotice else { return }
        let liveIDs = Set(live.map(\.id))
        if let index = ownRequestSnapshot.firstIndex(where: {
            $0.request.status == .placed && !liveIDs.contains($0.request.id)
        }) {
            let entry = ownRequestSnapshot[index]
            pickupExit = PickupExitHold(
                request: entry.request,
                index: index,
                ownerPhase: entry.ownerPhase,
                needsPickupConfirmation: entry.placed?.shouldConfirmPickup()
            )
        }
        pickupNoticeRevealed = false
        if isHomePresented { playPickupCollapse() }
    }

    /// Card exits, content settles, then the acknowledgement appears, with the
    /// single success haptic at the moment the exit begins. Never reached for
    /// a failed, ambiguous, withdrawn or expired order: only the confirmed
    /// flag arms it.
    private func playPickupCollapse() {
        guard !pickupNoticeRevealed || pickupExit != nil else { return }
        pickupCollapseTask?.cancel()
        pickupCollapseTask = Task { @MainActor in
            if !reduceMotion {
                try? await Task.sleep(for: PickupCollapseMotion.popSettle)
            }
            guard !Task.isCancelled, isHomePresented else { return }
            CommonPlateHaptics.success()
            isPlayingPickupCollapse = true
            withAnimation(reduceMotion ? nil : PickupCollapseMotion.exit) {
                pickupExit = nil
            }
            if !reduceMotion {
                try? await Task.sleep(for: PickupCollapseMotion.noticeDelay)
            }
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : PickupCollapseMotion.notice) {
                pickupNoticeRevealed = true
            }
            isPlayingPickupCollapse = false
        }
    }

    private func finishPickupCollapseImmediately() {
        pickupCollapseTask?.cancel()
        pickupCollapseTask = nil
        pickupExit = nil
        pickupNoticeRevealed = true
        isPlayingPickupCollapse = false
    }

    private func presentNextClaimUnavailableAlertIfNeeded() {
        let head = store.claimUnavailableNotice.flatMap {
            HelperRequestPresentation.homeNoticeStyle(for: $0.reason) == .alert ? $0 : nil
        }
        presentedClaimUnavailableNotice = HelperRequestPresentation.noticeToPresent(
            presented: presentedClaimUnavailableNotice,
            storeNotice: head,
            isViewVisible: isHomePresented
        )
    }

    // MARK: - Continue Helping

    /// The active-reservation priority state (Section 7 "Attention /
    /// continuation state"). Reads only confirmed `RequestStore` state and
    /// routes into the existing fulfillment continuation flow — no new
    /// reservation state is created here.
    @ViewBuilder
    private var continueHelpingSection: some View {
        let items = store.helperContinuationItems()
        if !items.isEmpty {
            let preview = Self.homePreview(items)
            VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.s) {
                sectionHeadingRow(
                    title: Self.continueHelpingHeading,
                    headingIdentifier: "home-continue-helping-heading",
                    seeAllRoute: preview.seeAllCount == nil ? nil : .helperContinuations,
                    seeAllCount: preview.seeAllCount,
                    seeAllIdentifier: "home-continue-helping-see-all"
                )

                VStack(spacing: CommonPlateStyle.Spacing.m) {
                    ForEach(preview.cards) { item in
                        HelperContinuationCardLink(item: item, isHomePresentation: true)
                    }
                }
            }
        }
    }

    // MARK: - Your request(s) (W4-R2 Home ownership partition)

    /// The single authoritative ownership partition of a populated board:
    /// every owned open request (`FoodRequest.isOwnRequest`, resolved
    /// server-side — never a local ownership heuristic) versus every
    /// remaining `Needs help` request, both in the board's existing
    /// authoritative order. `ownRequests` and `populatedBoard(_:)` below both
    /// derive from this one function rather than each re-filtering the same
    /// `requests` array independently, so the two zones cannot silently
    /// diverge (e.g. an owned request leaking into `Needs help`).
    /// Pure and `static`, matching this file's existing testable-`static-func`
    /// pattern (`ownRequestsPreview`, `boardState`).
    struct BoardOwnershipPartition: Equatable {
        let owned: [FoodRequest]
        let needsHelp: [FoodRequest]
    }

    /// W4-D2: `owned` is newest-created-first (`createdAt` descending),
    /// independent of the board's own shared ASAP-then-scheduled order —
    /// ASAP vs Later must never reorder the requester's own zone. `needsHelp`
    /// is unchanged: still exactly the board's existing authoritative order,
    /// which D2 does not own. `sorted(by:)` is stable, so a tie (identical
    /// `createdAt`) preserves the incoming relative order rather than
    /// reordering unpredictably.
    static func partitionByOwnership(_ requests: [FoodRequest]) -> BoardOwnershipPartition {
        BoardOwnershipPartition(
            owned: requests.filter(\.isOwnRequest).sorted { $0.createdAt > $1.createdAt },
            needsHelp: requests.filter { !$0.isOwnRequest }
        )
    }

    /// The authoritative caller-relative open requests owned by this
    /// participant, in the same order H2's board already carries them, while
    /// the board itself is authoritatively populated.
    ///
    /// W4-D2 2026-09-17 exact-created-request Home continuity contract sync:
    /// while the broader board is still `.loading`/`.unavailable` — so there
    /// is nothing yet to partition — the one exact, ownership-resolved
    /// request this same D2 flow already produced (`store.
    /// createdRequestContinuity`) MAY still render here. This is not a
    /// general Home cache: the source is the live continuity's own trusted
    /// `request`, keyed by that continuity's identity, never a broader/stale
    /// requester, helper, or discovery list. `.empty` is an authoritative
    /// "board fetched, zero requests" result and is deliberately excluded —
    /// only Loading/Unavailable have no authoritative list to consult at all.
    private var ownRequests: [FoodRequest] {
        guard let hold = pickupExit else { return liveOwnRequests }
        var list = liveOwnRequests
        list.insert(hold.request, at: min(hold.index, list.count))
        return list
    }

    private var liveOwnRequests: [FoodRequest] {
        let ongoing = Self.ownRequests(
            displayedBoardState: currentBoardState,
            createdRequestContinuity: store.createdRequestContinuity,
            ownerRequests: store.hasLoadedOwnerRequests ? store.ownerRequests : nil
        )
        guard store.hasLoadedPlacedOrders else { return Self.urgencyOrdered(ongoing, store: store) }
        return Self.urgencyOrdered(
            Self.combinedOwnRequests(ongoing, placedOrders: store.homeVisiblePlacedOrders()),
            store: store
        )
    }

    /// W4-R3 recorded urgency ordering: the one order Home's preview and
    /// `See all` both carry. Groups come from backend-derived truth only.
    static func urgencyOrdered(_ requests: [FoodRequest], store: RequestStore) -> [FoodRequest] {
        OwnRequestUrgency.ordered(requests) { request in
            OwnRequestUrgency.group(
                for: request,
                ownerPhase: store.ownerRequests.first { $0.id == request.id }?.phase,
                needsPickupConfirmation: store.placedOrder(requestID: request.id)?
                    .shouldConfirmPickup() ?? false
            )
        }
    }

    /// The owner snapshot a card opens (W4-R5): the backend's own reading when
    /// the owner list has it, otherwise a provisional one that carries no
    /// authority and is replaced by the detail's own re-read.
    private func ownerSnapshot(for request: FoodRequest) -> OwnerRequest {
        store.ownerRequests.first { $0.id == request.id } ?? OwnerRequest.provisional(from: request)
    }

    private func ownerPhase(for request: FoodRequest) -> OwnerRequestPhase? {
        store.ownerRequests.first { $0.id == request.id }?.phase
    }

    private func ownRequestRoute(for request: FoodRequest) -> AppRoute {
        if request.status == .placed {
            return .placedOrder(requestID: request.id)
        }
        return .ownerRequest(ownerSnapshot(for: request))
    }

    /// Pure form of `ownRequests` above, directly testable without
    /// instantiating a view — matching this file's existing testable-
    /// `static-func` pattern (`partitionByOwnership`, `boardState`).
    static func ownRequests(
        displayedBoardState: BoardState,
        createdRequestContinuity: RequestCreationContinuity?,
        ownerRequests: [OwnerRequest]? = nil
    ) -> [FoodRequest] {
        // W4-R5: once the participant's owner list has been read, it is the
        // authority for *which* requests are theirs — including scheduled and
        // reserved ones the public board never carries. Anything the public
        // board already knows is theirs (for example a request created a moment
        // ago and not yet in an owner read) fills a gap and never duplicates.
        if let ownerRequests {
            let fromOwnerList = ownerRequests.map(\.request)
            let knownIDs = Set(fromOwnerList.map(\.id))
            var gap: [FoodRequest] = []
            if case .populated(let requests) = displayedBoardState {
                gap = partitionByOwnership(requests).owned.filter { !knownIDs.contains($0.id) }
            } else if let continuity = createdRequestContinuity,
                      !knownIDs.contains(continuity.request.id) {
                gap = [continuity.request]
            }
            return (fromOwnerList + gap).sorted { $0.createdAt > $1.createdAt }
        }
        switch displayedBoardState {
        case .populated(let requests):
            return partitionByOwnership(requests).owned
        case .loading, .unavailable:
            guard let continuity = createdRequestContinuity else { return [] }
            return [continuity.request]
        case .empty:
            return []
        }
    }

    /// W4-H4 revised ownership-preview contract: the Home-inline preview is
    /// a bounded, count-sensitive slice of the full authoritative
    /// `ownRequests` set above — never a second ownership source. 0 owned
    /// omits the section; 1-2 owned render every owned request inline; 3+
    /// owned render exactly the first two authoritative-ordered requests
    /// plus a `See all N` count, where `N` is the full authoritative count.
    /// Pure and `static` so it is directly testable without instantiating a
    /// view, matching this file's existing `boardState`/`ownRequestsHeading`
    /// pattern.
    struct OwnRequestsPreview: Equatable {
        let cards: [FoodRequest]
        let seeAllCount: Int?
    }

    /// The one shared Home preview limit (W4-H4): items beyond it are never
    /// dropped, only moved behind `See all`. Helper continuations reuse it.
    static let homePreviewLimit = 2

    static func homePreview<T>(_ items: [T]) -> (cards: [T], seeAllCount: Int?) {
        guard items.count > homePreviewLimit else { return (items, nil) }
        return (Array(items.prefix(homePreviewLimit)), items.count)
    }

    static func ownRequestsPreview(_ owned: [FoodRequest]) -> OwnRequestsPreview {
        let preview = homePreview(owned)
        return OwnRequestsPreview(cards: preview.cards, seeAllCount: preview.seeAllCount)
    }

    private var ownRequestsPreview: OwnRequestsPreview {
        Self.ownRequestsPreview(ownRequests)
    }

    /// W4-R2/H4: zero owned open requests omits this zone entirely; one
    /// shows `Your request`; two or more show `Your requests`. Rendered
    /// alongside `continueHelpingSection`, ahead of `boardHeadingRow` and
    /// `boardSection`, inside the single unified Home `ScrollView` (see
    /// `exchangeContent`) — it retains attention-state priority above the
    /// ordinary `Needs help` board purely through that ordering, matching
    /// `Continue Helping`'s existing higher priority. Renders no Edit/Remove
    /// action; tapping a card preserves the existing `RequestDetailView`
    /// own-request navigation/behavior unchanged. The two-card cap (W4-H4) is
    /// presentation-only on Home — every owned open request, including ones
    /// not shown here, remains excluded from `Needs help` via `populatedBoard`.
    @ViewBuilder
    private var ownRequestsSection: some View {
        if !ownRequests.isEmpty {
            let preview = ownRequestsPreview
            VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.s) {
                ownRequestsHeadingRow(seeAllCount: preview.seeAllCount)

                VStack(spacing: CommonPlateStyle.Spacing.m) {
                    ForEach(Array(preview.cards.enumerated()), id: \.element.id) { index, request in
                        NavigationLink(value: ownRequestRoute(for: request)) {
                            // W4-R2: this section's own heading already
                            // establishes ownership, so the per-card `YOUR
                            // REQUEST` eyebrow is redundant here only.
                            // W4-R5: the card opens the requester-owned detail
                            // and shows the owner's own status.
                            RequestCardView(
                                request: request,
                                kind: .own,
                                showsOwnershipEyebrow: false,
                                ownerPhase: pickupExit?.request.id == request.id
                                    ? pickupExit?.ownerPhase
                                    : ownerPhase(for: request),
                                placedOrderNeedsPickupConfirmation: pickupExit?.request.id == request.id
                                    ? pickupExit?.needsPickupConfirmation
                                    : store.placedOrder(requestID: request.id)?.shouldConfirmPickup(),
                                isHomePresentation: true
                            )
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(pickupExit?.request.id != request.id)
                        // W4-D2 Success→Home continuity: while the continuity
                        // card for this exact request is still in flight above
                        // the navigation stack, this slot renders its own card
                        // invisibly rather than not at all — the layout, and
                        // therefore every other card's position, is identical
                        // before, during, and after the landing, so nothing
                        // reflows and no empty slot opens up. With standard
                        // motion and a usable destination, the in-flight card
                        // lands into this exact geometry and is retired in the
                        // same step this becomes visible; the crossfading
                        // branches instead fade this in during the landing
                        // (see `landingContinuityCardOpacity`).
                        .opacity(landingContinuityCardOpacity(request))
                        // W4-D2 physical-device FIX: every owned card that is
                        // *not* the travelling card's own destination is held
                        // back until the landing is over, keyed by identity so
                        // the destination is never decided by position.
                        .modifier(ContinuityDeferredReveal(
                            isDeferring: !isLandingContinuityCard(request)
                                && isDeferringContinuityHomeContent
                        ))
                        // W4-D2 crossfade handoff: only ever reacts to
                        // `isRevealingLandingContinuityCard`, on the same
                        // `handoffCrossfadeAnimation` the overlay card fades
                        // out on. Standard motion with a usable destination
                        // never sets that flag, so its existing instant,
                        // unanimated swap (imperceptible because the overlay
                        // card occupies this exact same slot at swap time) is
                        // untouched.
                        .animation(
                            RequestCreationContinuityMotionPlan
                                .plan(reduceMotion: reduceMotion)
                                .handoffCrossfadeAnimation,
                            value: isRevealingLandingContinuityCard
                        )
                        // Only the landing destination publishes, and only
                        // its own real frame: the continuity landing geometry
                        // is measured here rather than reconstructed from
                        // assumed insets or heading heights. Urgency ordering
                        // (W4-R3) means a new request is not always first, so
                        // the destination is chosen by identity; when it is
                        // not in the preview nothing publishes and the
                        // landing uses its accepted in-place crossfade.
                        .background(firstOwnedSlotFrameReporter(
                            isFirstSlot: Self.isContinuityLandingSlot(
                                requestID: request.id,
                                index: index,
                                continuityRequestID: store.createdRequestContinuity?.request.id
                            )
                        ))
                        .accessibilityIdentifier("home-own-request-card-\(request.id)")
                        .transition(
                            reduceMotion
                                ? .identity
                                : .opacity.combined(with: .offset(y: -PickupCollapseMotion.rise))
                        )
                    }
                }
            }
            .transition(
                reduceMotion
                    ? .identity
                    : .opacity.combined(with: .offset(y: -PickupCollapseMotion.rise))
            )
        }
    }

    /// W4-H3: `See all` sits beside `Your requests` with no visible count; the
    /// full authoritative count lives in the accessibility label. At
    /// accessibility Dynamic Type sizes it moves below the heading so neither
    /// truncates. The action keeps a 44pt minimum target and the same
    /// destination/complete carried set as before.
    @ViewBuilder
    private func ownRequestsHeadingRow(seeAllCount: Int?) -> some View {
        sectionHeadingRow(
            title: Self.ownRequestsHeading(count: ownRequests.count),
            headingIdentifier: "home-own-requests-heading",
            seeAllRoute: seeAllCount == nil ? nil : .ownRequests(ownRequests),
            seeAllCount: seeAllCount,
            seeAllIdentifier: "home-own-requests-see-all"
        )
    }

    /// The shared heading row: a title with an optional `See all` beside it.
    @ViewBuilder
    private func sectionHeadingRow(
        title: String,
        headingIdentifier: String,
        seeAllRoute: AppRoute?,
        seeAllCount: Int?,
        seeAllIdentifier: String
    ) -> some View {
        let heading = Text(title)
            .font(.title3.weight(.bold))
            .accessibilityIdentifier(headingIdentifier)
        if let seeAllCount, let seeAllRoute {
            let seeAll = NavigationLink(value: seeAllRoute) {
                Text(Self.seeAllOwnRequestsTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CommonPlateStyle.Color.brandText)
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(seeAllIdentifier)
            .accessibilityLabel(Self.seeAllOwnRequestsAccessibilityLabel(count: seeAllCount))
            .modifier(ContinuityDeferredReveal(isDeferring: isDeferringContinuityHomeContent))

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) {
                    heading
                    seeAll
                }
            } else {
                HStack(alignment: .center) {
                    heading
                    Spacer(minLength: CommonPlateStyle.Spacing.s)
                    seeAll
                }
            }
        } else {
            heading
        }
    }

    static func ownRequestsHeading(count: Int) -> String {
        count == 1 ? "Your request" : "Your requests"
    }

    /// The one shared Home content-column width rule: a card inside this
    /// column spans the container minus `homeContentColumnInset` on each
    /// side, exactly as `exchangeContent` applies it. Expressed once, here,
    /// so any surface that must match Home's card width derives it from the
    /// same rule rather than repeating the inset arithmetic — see
    /// `RequestCreationContinuityLayout.cardWidth(containerWidth:homeSlot:)`,
    /// whose fallback path is required to agree with this exactly.
    static func contentCardWidth(containerWidth: CGFloat) -> CGFloat {
        max(0, containerWidth - (CommonPlateStyle.Metrics.homeContentColumnInset * 2))
    }

    /// True while the W4-D2 continuity presentation is still carrying this
    /// exact request's card above the navigation stack.
    private func isLandingContinuityCard(_ request: FoodRequest) -> Bool {
        store.createdRequestContinuity?.request.id == request.id
    }

    /// W4-D2 crossfade handoff: this card's own opacity while the continuity
    /// overlay may still be presenting the same request above it. Delegates
    /// to `landingContinuityCardOpacity(isContinuityCard:isRevealing:)`.
    private func landingContinuityCardOpacity(_ request: FoodRequest) -> Double {
        Self.landingContinuityCardOpacity(
            isContinuityCard: isLandingContinuityCard(request),
            isRevealing: isRevealingLandingContinuityCard
        )
    }

    /// Pure form of the destination card's continuity opacity.
    ///
    /// Only the card whose request identity matches the live continuity is
    /// ever affected; every other owned card is always 1 here (its own
    /// progressive reveal is `ContinuityDeferredReveal`'s concern).
    ///
    /// Standard motion with a usable destination (`isRevealing` never true):
    /// stays invisible for the whole presentation, then becomes visible the
    /// instant the overlay retires — imperceptible because the overlay's own
    /// card occupies this exact slot at that instant.
    ///
    /// Reduce Motion with a usable destination, and the no-usable-target
    /// in-place crossfade: becomes visible the moment `isRevealing` turns
    /// true — the same instant the overlay's own card begins fading out (see
    /// `RequestCreationContinuityLayout.isHomeCardRevealed(phase:reduceMotion:hasLandingDestination:)`)
    /// — and the matching `.animation(...)` above crossfades it in over the
    /// identical animation the overlay fades out on, so there is no interval
    /// where both are invisible and retirement is not its first appearance.
    static func landingContinuityCardOpacity(isContinuityCard: Bool, isRevealing: Bool) -> Double {
        guard isContinuityCard else { return 1 }
        return isRevealing ? 1 : 0
    }

    // MARK: - W4-D2 physical-device FIX: progressive Home reveal

    /// Whether Home is currently holding back everything except the stable
    /// chrome and the continuity card's own destination slot.
    ///
    /// The defect this exists for: the continuity overlay reveals Home by
    /// crossfading its own opaque canvas away at the *start* of the landing,
    /// and Home's only continuity-aware slot was the destination slot. Every
    /// other card — the requester's older owned cards, `See all N`, `Continue
    /// helping`, and the whole `Needs help right now` board — therefore became
    /// visible underneath a card that had not begun travelling yet. The
    /// travelling card settles at roughly the canonical Figma's `y=309` and
    /// lands at `y=164`, while the next owned card sits at `y=297`: the
    /// reveal alone painted an existing request card directly beneath the
    /// travelling one, and the travel then swept across it. Physical-device
    /// acceptance caught exactly that overlap.
    ///
    /// Holding that content back is not a timing workaround; it is the
    /// composition the approved canonical Figma already specifies. In
    /// `Home reveal · card in flight` (node `684:2829`) the brand header,
    /// `Your request(s)`, the destination area, and the persistent CTA are
    /// revealed, while `Needs help right now` and the existing request card
    /// are explicitly hidden; both landing frames (`684:2841`, `684:2853`)
    /// then show the complete board. Because it is applied as opacity, Home's
    /// layout — and therefore the published first-slot geometry the landing is
    /// measured against — is byte-identical before, during, and after, so
    /// nothing reflows, no slot collapses, and no scroll position moves.
    ///
    /// Reduce Motion is deliberately excluded. Its landing performs only the
    /// bounded `reducedMotionMaximumLandingDisplacement` travel, so its card
    /// never sweeps across the cards below it — there is no overlap for this
    /// to prevent — and Faith verified that path on a physical device. Leaving
    /// it on exactly its accepted composition keeps that evidence valid.
    static func isDeferringContinuityHomeContent(
        hasLiveContinuity: Bool,
        reduceMotion: Bool
    ) -> Bool {
        hasLiveContinuity && !reduceMotion
    }

    static func continuityDeferredContentOpacity(
        hasLiveContinuity: Bool,
        reduceMotion: Bool
    ) -> Double {
        isDeferringContinuityHomeContent(
            hasLiveContinuity: hasLiveContinuity,
            reduceMotion: reduceMotion
        ) ? 0 : 1
    }

    private var isDeferringContinuityHomeContent: Bool {
        Self.isDeferringContinuityHomeContent(
            hasLiveContinuity: store.createdRequestContinuity != nil,
            reduceMotion: reduceMotion
        )
    }

    /// Applies the progressive reveal above to one piece of Home content.
    ///
    /// `isDeferring` is passed per call site rather than read from the view so
    /// the destination slot's own card can opt out by identity — see
    /// `ownRequestsSection` — instead of by position.
    private struct ContinuityDeferredReveal: ViewModifier {
        let isDeferring: Bool

        func body(content: Content) -> some View {
            content
                .opacity(isDeferring ? 0 : 1)
                .animation(
                    .easeInOut(duration: RequestCreationContinuityMotionPlan.homeContentRevealSeconds),
                    value: isDeferring
                )
        }
    }

    static func isContinuityLandingSlot(
        requestID: String,
        index: Int,
        continuityRequestID: String?
    ) -> Bool {
        guard let continuityRequestID else { return index == 0 }
        return requestID == continuityRequestID
    }

    @ViewBuilder
    private func firstOwnedSlotFrameReporter(isFirstSlot: Bool) -> some View {
        if isFirstSlot {
            // W4-D2 coordinate-system FIX: `.global` is the one coordinate
            // system this slot's frame and the continuity overlay's own card
            // frame (`RequestCreationContinuityView`'s `ContinuityCardFrameKey`
            // publication) are both actually measured in. A space named above
            // this view — on the app root, outside `NavigationStack` — does
            // not resolve across that hosting boundary, which silently
            // produced two frames in two different origins.
            GeometryReader { proxy in
                Color.clear.preference(
                    key: HomeOwnedRequestSlotFrameKey.self,
                    value: proxy.frame(in: .global)
                )
            }
        } else {
            Color.clear
        }
    }

    static let seeAllOwnRequestsTitle = "See all"

    static func seeAllOwnRequestsAccessibilityLabel(count: Int) -> String {
        "See all \(count) requests"
    }

    // MARK: - Board

    /// The one shared board-heading row, rendered once inside the single
    /// unified Home `ScrollView` (see `exchangeContent`) rather than repeated
    /// inside each state branch — so `Needs help` is structurally guaranteed
    /// present across every board state, including the very first load,
    /// instead of relying on each branch to repeat it.
    private var boardHeadingRow: some View {
        Text(boardHeading)
            .font(.title3.weight(.bold))
            .accessibilityIdentifier("home-board-heading")
    }

    private var boardHeading: String {
        switch currentBoardState {
        case .loading:
            return Self.loadingHeading
        case .unavailable:
            return Self.unavailableHeading
        case .empty:
            return Self.emptyHeading
        case .populated:
            return Self.needsHelpHeading
        }
    }

    /// The presentation-layer board state, folding in the HQ decision 5
    /// initial-load deadline over the store's own authoritative derivation.
    /// Reuses `HelperRequestPresentation.availableRequests` — the same existing
    /// pattern that surface already uses to exclude a request this helper is
    /// actively holding via Continue Helping, so the same request is never
    /// both pinned above and duplicated below on the shared board.
    private var currentBoardState: BoardState {
        Self.boardState(
            hasSuccessfullyFetchedRequests: store.hasSuccessfullyFetchedRequests,
            hasAttemptedRequestFetch: store.hasAttemptedRequestFetch,
            hasFailedInitialFetchAtLeastOnce: store.hasFailedInitialFetchAtLeastOnce,
            isFetching: store.isFetching,
            requests: HelperRequestPresentation.availableRequests(
                store.requests,
                activeClaimRequestID: store.activeClaim?.requestID
            ),
            hasInitialLoadDeadlineElapsed: hasInitialLoadDeadlineElapsed,
            isOwnerTruthUnverified: Self.isOwnerTruthUnverified(store: store)
        )
    }

    @ViewBuilder
    private func boardSection(emptyStateMinHeight: CGFloat) -> some View {
        switch currentBoardState {
        case .loading:
            loadingState
        case .unavailable:
            unavailableState
        case .empty:
            emptyState(minHeight: emptyStateMinHeight)
        case .populated(let requests):
            populatedBoard(requests)
        }
    }

    /// W4-R2: owned requests are rendered exactly once, in `ownRequestsSection`
    /// above — never duplicated here. `needsHelpRequests` uses the same
    /// `partitionByOwnership` split `ownRequests` derives from, so the two
    /// zones cannot diverge, while preserving H2's existing order for the
    /// remainder.
    private func populatedBoard(_ requests: [FoodRequest]) -> some View {
        let needsHelpRequests = Self.partitionByOwnership(requests).needsHelp
        return VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
            if store.refreshError != nil {
                refreshFailureNotice
            }

            VStack(spacing: CommonPlateStyle.Spacing.m) {
                ForEach(needsHelpRequests) { request in
                    NavigationLink(value: AppRoute.requestDetail(request)) {
                        RequestCardView(
                            request: request,
                            kind: .open,
                            isDiscoveryEmphasized: request.id == discoverySelectedRequestID,
                            isHomePresentation: true
                        )
                            .modifier(HelpingDiscoveryTreatment(
                                isActive: request.id == discoverySelectedRequestID,
                                reduceMotion: reduceMotion
                            ))
                    }
                    .buttonStyle(.plain)
                    .modifier(HelpingDiscoveryCardOpenReport(
                        isActive: discoverySelectedRequestID != nil,
                        requestID: request.id,
                        onOpen: onOpenEligibleRequestCard,
                        onAccessibilityActivate: { onActivateEligibleRequestCard(request) }
                    ))
                    .accessibilityIdentifier("home-request-card-\(request.id)")
                }
            }
        }
    }

    /// Only the genuinely first-ever fetch (this store has never once
    /// resolved to success or failure) reaches this case — see
    /// `boardState(...)`. `boardHeadingRow` above already keeps `Needs help`
    /// present on screen through this state, so this content itself is only
    /// the loading indicator.
    private var loadingState: some View {
        HStack {
            Spacer()
            ProgressView("Loading…")
                .padding(.top, CommonPlateStyle.Spacing.xl)
            Spacer()
        }
    }

    /// E1. Contract-exact heading ("Needs help") and body copy — see
    /// `docs/week-4-ios-testflight-spec.md` W4-H2 Section 8.
    ///
    /// The supporting explanation and `Request Alerts` action are shown only
    /// when CommonPlate Push request-alert delivery is not effectively/
    /// stably enabled for this installation — the existing accepted
    /// `PushSubscriptionStore.state` authority (never Apple/iOS permission
    /// alone, never Email alert state). Stable Push On hides both; H2 reads
    /// this state directly and creates no second local boolean.
    private func emptyState(minHeight: CGFloat) -> some View {
        VStack(spacing: CommonPlateStyle.Spacing.l) {
            VStack(spacing: CommonPlateStyle.Spacing.m) {
                Image(systemName: "tray")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(CommonPlateStyle.Color.brandText.opacity(0.62))
                    .accessibilityHidden(true)

                Text(Self.emptyTitle)
                    .font(.headline.weight(.bold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: CommonPlateStyle.Metrics.stateContentWidth)
                    .accessibilityIdentifier("home-empty-title")
            }
            .frame(maxWidth: CommonPlateStyle.Metrics.stateContentWidth)

            if Self.showsRequestAlertsPromotion(pushState: pushSubscriptionStore.state) {
                VStack(spacing: CommonPlateStyle.Spacing.m) {
                    Text(Self.emptyBody)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: CommonPlateStyle.Metrics.stateContentWidth)

                    PushNotificationSection(
                        store: pushSubscriptionStore,
                        isHomePromotion: true,
                        onHomeEnableRequested: { isAwaitingHomeRequestAlertsResult = true }
                    )
                    .frame(maxWidth: CommonPlateStyle.Metrics.stateContentWidth)
                }
            } else if showsRequestAlertsOnConfirmation {
                Label(Self.requestAlertsOnTitle, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CommonPlateStyle.Color.brandText)
                    .frame(maxWidth: CommonPlateStyle.Metrics.stateContentWidth)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("home-request-alerts-on")
                    .transition(.opacity)
                    .task {
                        try? await Task.sleep(for: Self.requestAlertsConfirmationDuration)
                        guard !Task.isCancelled else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            showsRequestAlertsOnConfirmation = false
                        }
                    }
                    .onDisappear { showsRequestAlertsOnConfirmation = false }
            }
        }
        .onChange(of: pushSubscriptionStore.state) { _, state in
            switch Self.homeRequestAlertsResult(awaiting: isAwaitingHomeRequestAlertsResult, state: state) {
            case .confirmOn:
                isAwaitingHomeRequestAlertsResult = false
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    showsRequestAlertsOnConfirmation = true
                }
                UIAccessibility.post(notification: .announcement, argument: Self.requestAlertsOnTitle)
            case .stopAwaiting:
                isAwaitingHomeRequestAlertsResult = false
                showsRequestAlertsOnConfirmation = false
            case .keepWaiting:
                if state != .on { showsRequestAlertsOnConfirmation = false }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, CommonPlateStyle.Spacing.xl)
        .padding(.horizontal, CommonPlateStyle.Spacing.l)
        .frame(minHeight: minHeight, alignment: .center)
    }

    /// U4. No blue slab, status icon, or request-card-like container. Per
    /// the HQ Exchange Unavailable recovery decision, this state shows no
    /// visible Try Again action and no other explanatory body copy; native
    /// pull-to-refresh on the enclosing `.refreshable` scroll view (see
    /// `exchangeContent`) is the sole recovery interaction, driving the same
    /// `store.fetchRequests()` reload/state path used by every other Home
    /// refresh. The visible `PullToRefreshCue` beneath the title is
    /// presentation/discoverability only — it never implements, replaces, or
    /// simulates refresh.
    private var unavailableState: some View {
        let isBodyYielding = unavailableAreaPresentation == .refreshing
        return VStack(spacing: CommonPlateStyle.Spacing.m) {
            Text(Self.unavailableTitle)
                .font(.headline.weight(.bold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: CommonPlateStyle.Metrics.stateContentWidth)
                .accessibilityIdentifier("home-unavailable-title")

            PullRefreshCue()
                .accessibilityIdentifier("home-unavailable-refresh-cue")
        }
        // While native refresh is active the title and cue yield. They keep
        // their layout space, so nothing reflows when they return after a
        // failure or timeout; on success the refreshed hierarchy replaces
        // this state outright (it is never held back).
        .opacity(isBodyYielding ? 0 : 1)
        .accessibilityHidden(isBodyYielding)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isBodyYielding)
        .frame(maxWidth: .infinity)
        .padding(.vertical, CommonPlateStyle.Spacing.xl)
        .padding(.horizontal, CommonPlateStyle.Spacing.l)
    }

    /// Stale-content notice only — not a second recovery mechanism. Native
    /// pull-to-refresh, already available on this same scroll view, is the
    /// sole recovery interaction; this carries no retry button per HQ
    /// decision 3's "no visible refresh button" boundary.
    private var refreshFailureNotice: some View {
        Text("Couldn’t refresh. Some meals shown may no longer be available.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    // MARK: - Request a Meal

    /// W4-H4 persistent-CTA visual completion (soft floating, column-
    /// aligned). Two changes from the prior structural-only H4 button:
    ///
    /// 1. *Soft floating transition.* A restrained, static transparent-to-
    ///    canvas `LinearGradient` sits above the button, inside the same
    ///    `.safeAreaInset(edge: .bottom)` region `exchangeContent` already
    ///    anchors this view in. It is presentation only — it adds no scroll
    ///    clearance of its own and drives no scroll-position/animation state;
    ///    the structural guarantee that `Needs help` content can fully clear
    ///    the CTA remains the ScrollView-level safe-area inset itself (see
    ///    `exchangeContent`), which this gradient never substitutes for. It
    ///    replaces the previous flat, hard-edged `baseCanvas` background that
    ///    made the boundary against scrolling content read as an abrupt
    ///    opaque cutoff.
    /// 2. *Content-column alignment.* `commonPlateMajorActionFrame()`'s
    ///    narrower, centered R1 major-action width (capped at
    ///    `Control.majorActionMaximumWidth`) does not line up with the
    ///    request-card column, so this CTA now instead reuses the exact same
    ///    `CommonPlateStyle.Metrics.homeContentColumnInset` horizontal margin
    ///    the header/ownership/board content already applies in
    ///    `exchangeContent` — the one shared W4-H4 column authority, not a
    ///    separate CTA-only width — with `commonPlateMajorPrimaryAction()`'s
    ///    own `maxWidth: .infinity` label layout filling that column
    ///    edge-to-edge like a request card does.
    @ViewBuilder
    private var requestMealButton: some View {
        if RestrictedAccountPresentation.offersRequestAMeal(
            isRestricted: store.isParticipantRestricted
        ) {
            requestMealButtonContent
        }
    }

    private var requestMealButtonContent: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [
                    CommonPlateStyle.Color.baseCanvas.opacity(0),
                    CommonPlateStyle.Color.baseCanvas
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: CommonPlateStyle.Spacing.xl)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            Button(action: onRequestMeal) {
                Text("＋  Request a Meal")
            }
            // `.commonPlateMajorPrimaryAction()` already sets the approved
            // `.title3.weight(.semibold)` (~20pt) major-action label font on
            // `configuration.label`; a `.font()` set directly on this Text, as
            // an inner modifier, would win over that outer style and silently
            // shrink the CTA to `.body` (~17pt) instead.
            .commonPlateMajorPrimaryAction()
            .padding(.horizontal, CommonPlateStyle.Metrics.homeContentColumnInset)
            // W4-H4 physical-device FIX: an explicit `.padding(.bottom,
            // Spacing.s)` here previously stacked on top of the native
            // home-indicator clearance `.safeAreaInset(edge: .bottom)`
            // already reserves (measured ~34pt), producing a combined ~42pt
            // gap that read on device as the CTA floating too far above the
            // bottom edge. `.safeAreaInset` itself remains the only source
            // of bottom clearance now — still fully safe-area aware and
            // still never clipped by the home indicator — so the CTA sits
            // exactly at that native boundary instead of an authored amount
            // beyond it.
            .background(CommonPlateStyle.Color.baseCanvas)
            .accessibilityIdentifier("home-request-a-meal")
        }
    }

    // MARK: - Copy

    static let continueHelpingHeading = "Continue helping"
    static let needsHelpHeading = "Needs help"
    static let emptyHeading = "Needs help"
    static let unavailableHeading = "Needs help"
    static let loadingHeading = "Needs help"

    static let emptyTitle = "No open requests right now."
    static let emptyBody = "When someone needs a meal, their request will appear here."
    static let requestAlertsActionTitle = "Request Alerts"
    static let requestAlertsOnTitle = "Request Alerts are on"
    static let requestAlertsConfirmationDuration: Duration = .seconds(4)

    enum HomeRequestAlertsResult: Equatable { case confirmOn, stopAwaiting, keepWaiting }

    /// Only a Home tap that reaches On confirms; denied, failed or ambiguous
    /// results are already explained by the promotion that stays visible.
    static func homeRequestAlertsResult(awaiting: Bool, state: PushPreferenceState) -> HomeRequestAlertsResult {
        guard awaiting else { return .keepWaiting }
        switch state {
        case .on: return .confirmOn
        case .settingUp: return .keepWaiting
        case .off, .denied, .failed, .ambiguous: return .stopAwaiting
        }
    }

    static let unavailableTitle = "Helping is\ntemporarily unavailable"
    static let refreshCueText = "Pull down to refresh"
    static let unavailableArrowPulseCount = 2
    static let unavailableArrowTravel: CGFloat = 4
    static let unavailableArrowPulseDuration: TimeInterval = 0.26
    static let unavailableArrowRestDuration: Duration = .milliseconds(140)
    static let emptyStateFooterClearance =
        CommonPlateStyle.Spacing.xl + CommonPlateStyle.Control.majorActionMinimumHeight

    static func emptyStateMinimumHeight(
        viewportHeight: CGFloat,
        headerBandHeight: CGFloat,
        boardSectionTop: CGFloat
    ) -> CGFloat {
        max(
            0,
            viewportHeight - headerBandHeight - boardSectionTop - emptyStateFooterClearance
        )
    }

    static let refreshSuccessText = "Updated"

    // MARK: - Board state derivation

    enum BoardState: Equatable {
        case loading
        case unavailable
        case empty
        case populated([FoodRequest])
    }

    /// Pure derivation from `RequestStore`'s existing published fetch state —
    /// the signals `RequestStore` publishes
    /// (`hasSuccessfullyFetchedRequests`, `hasAttemptedRequestFetch`,
    /// `isFetching`, `requests`), plus `hasFailedInitialFetchAtLeastOnce` — so
    /// Home never invents a fetch/error model of its own. Unavailable (U4) is
    /// reached once a fetch has been attempted, has finished, and has never
    /// yet succeeded, and it is held there through any later retry: without
    /// `hasFailedInitialFetchAtLeastOnce`, a pull-to-refresh retry from
    /// Unavailable is indistinguishable from the very first attempt (both
    /// publish `hasAttemptedRequestFetch: true, isFetching: true,
    /// hasSuccessfullyFetchedRequests: false`), which regressed Home to the
    /// bare `.loading` presentation — dropping `Needs help` and everything
    /// else — on every retry. A request the helper is actively reserving is
    /// excluded from `requests` already, by the backend's own availability
    /// rule, so it never doubles as a board row here.
    static func boardState(store: RequestStore) -> BoardState {
        boardState(
            hasSuccessfullyFetchedRequests: store.hasSuccessfullyFetchedRequests,
            hasAttemptedRequestFetch: store.hasAttemptedRequestFetch,
            hasFailedInitialFetchAtLeastOnce: store.hasFailedInitialFetchAtLeastOnce,
            isFetching: store.isFetching,
            requests: HelperRequestPresentation.availableRequests(
                store.requests,
                activeClaimRequestID: store.activeClaim?.requestID
            ),
            isOwnerTruthUnverified: isOwnerTruthUnverified(store: store)
        )
    }

    /// W4-R5: the participant's own requests were asked for and could not be
    /// established. Until a read succeeds, Home cannot truthfully say it holds
    /// none, so it must not present an empty (or healthy) exchange. Not set
    /// while the read has not been attempted or is still running, and never set
    /// for a participant whose list was already loaded (a failed refresh keeps
    /// the loaded list, like the board).
    static func isOwnerTruthUnverified(store: RequestStore) -> Bool {
        store.ownerRequestsError != nil
            && !store.hasLoadedOwnerRequests
            && !store.isLoadingOwnerRequests
    }

    /// `hasInitialLoadDeadlineElapsed` (HQ decision 5) is presentation-only:
    /// it never changes what a resolved fetch means, only whether an
    /// *unresolved* one keeps presenting Loading past 5 seconds. Once
    /// `hasSuccessfullyFetchedRequests` or `hasFailedInitialFetchAtLeastOnce`
    /// is true, this parameter is irrelevant — the authoritative result
    /// already determines the state, so a same-still-current fetch that
    /// resolves after the deadline still recovers Home normally.
    static func boardState(
        hasSuccessfullyFetchedRequests: Bool,
        hasAttemptedRequestFetch: Bool,
        hasFailedInitialFetchAtLeastOnce: Bool,
        isFetching: Bool,
        requests: [FoodRequest],
        hasInitialLoadDeadlineElapsed: Bool = false,
        isOwnerTruthUnverified: Bool = false
    ) -> BoardState {
        // W4-R5: owner truth that could not be established makes an otherwise
        // resolved board Exchange Unavailable — never Empty Exchange.
        if isOwnerTruthUnverified && hasSuccessfullyFetchedRequests {
            return .unavailable
        }
        if !hasSuccessfullyFetchedRequests {
            if hasFailedInitialFetchAtLeastOnce {
                return .unavailable
            }
            if hasAttemptedRequestFetch && !isFetching {
                return .unavailable
            }
            if hasInitialLoadDeadlineElapsed {
                return .unavailable
            }
            return .loading
        }
        return requests.isEmpty ? .empty : .populated(requests)
    }

    // MARK: - Empty Exchange conditional Request Alerts promotion

    /// Pure predicate over the existing accepted `PushSubscriptionStore.state`
    /// authority (HQ decision 2): the supporting explanation and `Request
    /// Alerts` action show whenever Push request-alert delivery is not
    /// effectively/stably enabled for this installation. Stable Push On
    /// (`.on`) is the only state that hides them; every other case —
    /// including the transitional `.settingUp` and `.ambiguous` — keeps them
    /// visible. This reads existing Push truth only; it is not a second
    /// source of truth.
    static func showsRequestAlertsPromotion(pushState: PushPreferenceState) -> Bool {
        pushState != .on
    }
}

/// W4-H3 A2 header anchors: the global top of each header representation, plus
/// the band's height. Passively read from layout — never written by a custom
/// gesture, and used only to derive header ownership (scroll position) and the
/// band-reduced short-content height. It never decides whether refresh fires.
private struct HomeHeaderAnchors: Equatable {
    var bandMinY: CGFloat?
    var scrollingMinY: CGFloat?
    var bandHeight: CGFloat?
    var boardSectionMinY: CGFloat?

    init() {}

    init(representation: HomeExchangeView.HeaderRepresentation, minY: CGFloat, height: CGFloat) {
        switch representation {
        case .band:
            bandMinY = minY
            bandHeight = height
        case .scrolling:
            scrollingMinY = minY
        }
    }

    init(boardSectionMinY: CGFloat) {
        self.boardSectionMinY = boardSectionMinY
    }
}

private struct HomeHeaderAnchorKey: PreferenceKey {
    static var defaultValue = HomeHeaderAnchors()
    static func reduce(value: inout HomeHeaderAnchors, nextValue: () -> HomeHeaderAnchors) {
        let next = nextValue()
        if let bandMinY = next.bandMinY { value.bandMinY = bandMinY }
        if let scrollingMinY = next.scrollingMinY { value.scrollingMinY = scrollingMinY }
        if let bandHeight = next.bandHeight { value.bandHeight = bandHeight }
        if let boardSectionMinY = next.boardSectionMinY { value.boardSectionMinY = boardSectionMinY }
    }
}

/// Exchange Unavailable's resting discoverability cue (HQ decision 1): the
/// sole authored refresh cue, with its single arrow. Presentation only — it
/// never implements, replaces, or simulates refresh, and no pull/release
/// state exists. Once native refresh activates the cue yields (see
/// `HomeExchangeView.unavailableState`).
private struct PullRefreshCue: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrowOffset: CGFloat = 0

    var body: some View {
        HStack(spacing: CommonPlateStyle.Spacing.xs) {
            Image(systemName: "arrow.down")
                .font(.body.weight(.semibold))
                .offset(y: arrowOffset)
                .accessibilityHidden(true)
            Text(HomeExchangeView.refreshCueText)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(CommonPlateStyle.Color.brandText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(HomeExchangeView.refreshCueText)
        .task(id: reduceMotion) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { arrowOffset = 0 }
            guard !reduceMotion else { return }
            for _ in 0..<HomeExchangeView.unavailableArrowPulseCount {
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: HomeExchangeView.unavailableArrowPulseDuration)) {
                    arrowOffset = HomeExchangeView.unavailableArrowTravel
                }
                try? await Task.sleep(for: .seconds(HomeExchangeView.unavailableArrowPulseDuration))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: HomeExchangeView.unavailableArrowPulseDuration)) {
                    arrowOffset = 0
                }
                try? await Task.sleep(for: HomeExchangeView.unavailableArrowRestDuration)
            }
        }
        .onDisappear {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { arrowOffset = 0 }
        }
    }
}

/// Carries one refresh's own `fetchRequests()` outcome out of the deadline
/// race's `@Sendable` operation. Written strictly before the operation
/// returns, so it is read only when the fetch itself finished first.
private actor RefreshOutcomeRecorder {
    private(set) var outcome: RequestFetchOutcome?

    func record(_ outcome: RequestFetchOutcome) {
        self.outcome = outcome
    }
}

/// W4-O1 temporary first-use discovery treatment (Figma P4). The whole card
/// and its attached `View request` cue move together as one unit: lavender
/// emphasis (drawn by `RequestCardView` from existing helping tokens), an overlapping cue, and a restrained
/// ~3 pt float over ~2.8 s with rest. Reduce Motion shows the same emphasized
/// state statically. Adds no hit target and no layout change (overlay only),
/// and the cue is hidden from accessibility so the card's canonical label and
/// trait are unchanged.
private struct HelpingDiscoveryTreatment: ViewModifier {
    let isActive: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if isActive {
            let withCue = content
                .overlay(alignment: .topLeading) {
                    Text("View request")
                        .font(.caption.weight(.semibold))
                        // Decorative teaching cue, hidden from VoiceOver: capped so
                        // accessibility sizes cannot grow it over the card's text.
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, CommonPlateStyle.Spacing.m)
                        .padding(.vertical, CommonPlateStyle.Spacing.xs)
                        .background(Color.accentColor, in: Capsule())
                        .offset(x: CommonPlateStyle.Spacing.m, y: -12)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            if reduceMotion {
                withCue
            } else {
                withCue.keyframeAnimator(initialValue: CGFloat(0), repeating: true) { view, lift in
                    view.offset(y: lift)
                } keyframes: { _ in
                    KeyframeTrack {
                        LinearKeyframe(0, duration: 1.2)
                        CubicKeyframe(-3, duration: 0.8)
                        CubicKeyframe(0, duration: 0.8)
                    }
                }
            }
        } else {
            content
        }
    }
}

/// W4-O1: observes the existing card open without adding a hit target or
/// a second visible action. A touch tap is observed alongside the link's own
/// action; an accessibility activation (VoiceOver double-tap) never reaches
/// that gesture, so the same card's default accessibility action reports and
/// opens instead. Attached only while the treatment is active, so ordinary
/// cards carry neither.
private struct HelpingDiscoveryCardOpenReport: ViewModifier {
    let isActive: Bool
    let requestID: String
    let onOpen: (String) -> Void
    let onAccessibilityActivate: () -> Void

    func body(content: Content) -> some View {
        if isActive {
            content
                .simultaneousGesture(TapGesture().onEnded { onOpen(requestID) })
                .accessibilityAction(.default) { onAccessibilityActivate() }
        } else {
            content
        }
    }
}

/// Faith-selected shared pickup collapse (Figma `1603:7208`, native 5.6 s
/// timeline): the card exits over ~0.37 s on `cubic-bezier(0.2, 0.8, 0.25, 1)`
/// with a 10 pt rise, the content below settles over ~0.47 s, and the
/// acknowledgement enters ~0.52 s in over ~0.31 s. `popSettle` lets the
/// navigation pop finish so the exit is seen on Home.
enum PickupCollapseMotion {
    static let rise: CGFloat = 10
    static let popSettle: Duration = .milliseconds(300)
    static let noticeDelay: Duration = .milliseconds(250)
    static let exit = Animation.timingCurve(0.2, 0.8, 0.25, 1, duration: 0.47)
    static let notice = Animation.timingCurve(0.2, 0.8, 0.25, 1, duration: 0.31)
}

private struct PickupObservationKey: Equatable {
    let noticeOn: Bool
    let ids: [String]
}
