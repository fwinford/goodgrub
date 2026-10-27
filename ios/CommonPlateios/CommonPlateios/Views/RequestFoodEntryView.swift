//
//  RequestFoodEntryView.swift
//  CommonPlateios
//
// The screen `AppRoute.requestFood` actually opens (W3-I2). An unverified
// installation sees the existing participant-verification screen before it
// ever sees the Request Food form; a verified one — freshly, or restored from
// a previous launch — goes straight to `RequestFoodView`. This supersedes only
// W3-I1's entry sequencing: the identity, credential, storage, and lifetime it
// consumes are unchanged, and `RequestFoodView` keeps its own submit-time
// gate for the residual case where identity is lost after this screen already
// let the form through (a mid-form backend rejection).
import SwiftUI

enum RequestFoodEntryPresentation: Equatable {
    case verification
    /// W4-R2: the one authoritative-as-of-read W4-Q1 eligibility check this
    /// screen performs before the requester may enter Request Food at all.
    case checkingEligibility
    /// `message`/`retryable` reuse `RequestFoodView`'s own already-accepted
    /// copy: `postingLimitReachedNotice` (exhausted, not retryable — another
    /// attempt now would answer identically) or `availabilityUnknownNotice`
    /// (unknown/error, retryable — the read itself failed, not the quota).
    case unavailable(message: String, retryable: Bool)
    case form
}

/// The three states `RequestFoodEntryView`'s own W4-Q1 read can settle in.
/// Never inferred from Home, local counts, or a prior call's result — see
/// `RequestFoodEntryView.performEligibilityCheckIfNeeded()`.
enum RequestFoodEligibilityCheck: Equatable {
    case notStarted
    case checking
    case resolved(RequestStore.RequestCreationEligibility)
}

struct RequestFoodEntryView: View {
    @ObservedObject var store: RequestStore
    @ObservedObject var screenshotProposalStore: ScreenshotProposalStore
    /// Owned above this pushed destination by ContentView, so an unfinished
    /// process/session draft survives an ordinary pop and later re-entry.
    @ObservedObject var draftSession: RequestFoodDraftSession
    /// Observed, not owned: the same identity every other participant action
    /// reads, so a verification completed here is immediately visible to the
    /// form this screen reveals.
    @ObservedObject var identityStore: ParticipantIdentityStore
    @ObservedObject var verificationCoordinator: ParticipantActionVerificationCoordinator
    @Binding var path: [AppRoute]
    let onExit: () -> Void

    /// Sticky once set (W3-I2 review correction): this session already
    /// legitimately admitted a verified requester into `RequestFoodView`. A
    /// later `PARTICIPANT_AUTHORITY_INVALID` (`identityStore.discardRejectedIdentity()`)
    /// clears `isVerified`, but that is a mid-form authority loss, not a
    /// reason to tear this screen's `.form` case down and destroy the mounted
    /// `RequestFoodView`'s draft — `RequestFoodView` already owns recovering
    /// from exactly that loss through its own submit-time gate and
    /// `verificationCoordinator`-driven continuation sheet. Never reset once
    /// true: this screen is not re-created without a fresh navigation to
    /// `.requestFood`, which starts a new instance with this back at `false`.
    @State private var hasEnteredForm = false
    @State private var hasRequestedExit = false
    /// W4-R2 item 20: the current entry's own W4-Q1 read. Reset to
    /// `.notStarted` only by a fresh instance of this screen (a new
    /// navigation to `.requestFood`), so every requester-entry attempt
    /// performs its own current read rather than reusing a stale result.
    @State private var eligibilityCheck: RequestFoodEligibilityCheck = .notStarted
    /// Owns the Screenshot Help overlay's presentation truth so
    /// `backToolbarItem` can be removed from the toolbar entirely while it is
    /// showing — see `RequestFoodView.isPresentingScreenshotHelp`'s
    /// declaration for why disabling in place is not enough.
    @State private var isPresentingScreenshotHelp = false
    /// W4-S3 consent-authority revision: the `Turn on Screenshot Assistance?`
    /// disclosure is a local centered overlay like Screenshot Help, so it
    /// needs the same toolbar Back suppression for the same
    /// competing-Back-control reason — see `isPresentingScreenshotHelp`'s
    /// declaration above.
    @State private var isPresentingScreenshotAssistanceDisclosure = false
    /// W4-R2 2026-08-31 round-2 sync: true exactly while `RequestFoodView`'s
    /// internal presentation is the transient Posting/Success submission
    /// sequence, so `backToolbarItem` can be removed from the toolbar
    /// entirely for that sequence too — mirroring why
    /// `isPresentingScreenshotHelp` is a binding rather than local state.
    @State private var isSuppressingBackNavigation = false
    /// W4-R2 2026-08-31 sync "Bottom Continuity": a brief, bounded settle-in
    /// played once when this pushed destination first appears — not a
    /// literal CTA-to-screen morph, no navigation-topology change, and no
    /// delay to interactivity (the form beneath is fully usable immediately;
    /// only its own opacity/offset are still animating in). `Back` never
    /// replays this: it is set once per pushed instance and this screen is
    /// recreated fresh by a later navigation to `.requestFood`, not reused.
    @State private var hasSettled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// W4-R2 2026-08-31 round-2 sync "Normal Request Food Back reliability":
    /// `backToolbarItem`'s action now asks SwiftUI's own navigation
    /// authority to pop this pushed destination instead of reaching up
    /// through `onExit` into `ContentView`'s manually-mutated `path` with a
    /// `disablesAnimations` transaction — the exact "competing/fragile
    /// parallel exit mechanism" the walkthrough flagged. A push transition
    /// (this destination's own Bottom Continuity settle included) still
    /// briefly in flight when Back is tapped could leave that manual
    /// `path.removeLast()` silently dropped, which is what an intermittently
    /// unresponsive Back looks like; `dismiss()` is SwiftUI's documented,
    /// transition-safe way to pop the current destination on a
    /// path-driven `NavigationStack` and needs no competing transaction of
    /// its own. `onExit`/`beginExit` remain exactly as before for D1's
    /// `Go to Home` and Success's automatic dwell-dismissal, neither of
    /// which this sync flagged.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch Self.presentation(
                isVerified: identityStore.isVerified,
                hasEnteredForm: hasEnteredForm,
                eligibilityCheck: eligibilityCheck
            ) {
            // `ParticipantVerificationView` wraps its own `NavigationStack`
            // (needed for its own title/toolbar when it is the app's one
            // in-form sheet). Pushing it as this destination's own body — a
            // `NavigationStack` nested directly inside another
            // `NavigationStack`'s `.navigationDestination` content — corrupted
            // this app's typed `[AppRoute]` path comparison on a physical
            // device (`AnyNavigationPath.Error.comparisonTypeMismatch`),
            // reachable only through real interactive navigation state that
            // an `XCTest` run never mounts. Presenting it as a sheet instead
            // reuses the exact modal-presentation pattern `RequestFoodView`'s
            // own defensive gate already relies on, so nothing here is a new
            // verification implementation — the destination itself is never
            // more than this placeholder while unverified, and the sheet is
            // what the requester actually sees.
            case .verification:
                CommonPlateStyle.Color.baseCanvas
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            // W4-R2 item 20: a verified requester (fresh or already) sees
            // this before Request Food is ever built, so an exhausted
            // requester never invests in the form. No fields, no draft —
            // there is nothing here yet to protect.
            case .checkingEligibility:
                eligibilityCheckingView
                    .navigationBarBackButtonHidden(true)
                    .toolbar { backToolbarItem }
            case .unavailable(let message, let retryable):
                eligibilityUnavailableView(message: message, retryable: retryable)
                    .navigationBarBackButtonHidden(true)
                    .toolbar { backToolbarItem }
            case .form:
                // W4-R2: this destination is now pushed directly on the root
                // `NavigationStack` (`ContentView`'s `.requestFood` case), so
                // it must not wrap itself in a second nested `NavigationStack`
                // — nesting one here previously produced a real physical-device
                // `AnyNavigationPath.Error.comparisonTypeMismatch` crash (see
                // the sheet-based rationale this superseded, above). The
                // toolbar/back-button modifiers below apply directly to the
                // root stack's own navigation bar for this destination.
                RequestFoodView(
                    store: store,
                    screenshotProposalStore: screenshotProposalStore,
                    draftSession: draftSession,
                    identityStore: identityStore,
                    verificationCoordinator: verificationCoordinator,
                    path: $path,
                    onExit: beginExit,
                    isPresentingScreenshotHelp: $isPresentingScreenshotHelp,
                    isPresentingScreenshotAssistanceDisclosure: $isPresentingScreenshotAssistanceDisclosure,
                    isSuppressingBackNavigation: $isSuppressingBackNavigation
                )
                .navigationBarBackButtonHidden(true)
                .toolbar {
                    if !isPresentingScreenshotHelp && !isPresentingScreenshotAssistanceDisclosure && !isSuppressingBackNavigation {
                        backToolbarItem
                    }
                }
            }
        }
        // W4-R2 2026-08-31 sync "Bottom Continuity": the destination
        // establishes immediately — hit testing/interactivity are never
        // gated on `hasSettled` — only this brief opacity/offset settle
        // plays on top of the already-complete native push. Reduce Motion
        // skips the cue entirely rather than merely shortening it.
        .opacity(hasSettled || reduceMotion ? 1 : 0)
        .offset(y: hasSettled || reduceMotion ? 0 : 10)
        .onAppear {
            guard !hasSettled, !reduceMotion else {
                hasSettled = true
                return
            }
            withAnimation(.easeOut(duration: 0.22)) {
                hasSettled = true
            }
        }
        // W4-R2 item 20: the current entry's own W4-Q1 read. Runs once per
        // `isVerified` becoming `true` — covering both a freshly-completed
        // verification and an already-verified/restored identity present at
        // first appearance, since `.task(id:)` also runs for the initial
        // value. Never reruns merely because this view rebuilds: `id`
        // (`identityStore.isVerified`) is unchanged in that case.
        .task(id: identityStore.isVerified) {
            await performEligibilityCheckIfNeeded()
        }
        // Entry-owned admission only: once `hasEnteredForm` is set, a later
        // appearance (e.g. returning from backgrounding after a mid-form
        // `PARTICIPANT_AUTHORITY_INVALID` cleared identity) must not start
        // another `.firstVerification` flow here. `beginVerification(for:)`
        // refuses a second flow while one already exists, so a stray entry
        // flow left running by this call would silently block
        // `RequestFoodView`'s own coordinator-owned recovery flow from ever
        // starting — the exact rereview finding. Before admission this
        // remains `beginVerificationIfNeeded()`'s own idempotent guard: a
        // no-op when already verified, and a no-op that resumes rather than
        // restarts when a flow this same gate opened is still running.
        .onAppear {
            guard Self.shouldBeginEntryVerificationOnAppear(hasEnteredForm: hasEnteredForm) else {
                return
            }
            identityStore.beginVerificationIfNeeded()
        }
        // W4-R2 2026-09-05 sync item 2: a live `PARTICIPANT_AUTHORITY_INVALID`
        // during this entry's own Q1 read (`performEligibilityCheckIfNeeded()`)
        // retires identity through `RequestStore.applyParticipantVerdict`,
        // flipping `identityStore.isVerified` to `false` while this view is
        // already mounted showing `.checkingEligibility` — a state `.onAppear`
        // above never refires for, since the view was not just created. This
        // starts the same verification flow `.onAppear` starts, under the
        // identical `!hasEnteredForm` guard, so the sequence becomes verified →
        // Q1 → authority invalid → verification → successful verification →
        // fresh Q1 → eligible/exhausted instead of a blank canvas with no
        // active recovery path. Does not fire on the reverse transition
        // (`false` → `true`, an ordinary successful verification) or once this
        // session has legitimately admitted the form.
        .onChange(of: identityStore.isVerified) { wasVerified, isVerified in
            Self.handleVerifiedTransition(
                wasVerified: wasVerified,
                isVerified: isVerified,
                hasEnteredForm: hasEnteredForm,
                identityStore: identityStore
            )
        }
        .sheet(isPresented: isPresentingEntryVerification) {
            ParticipantVerificationView(
                store: identityStore,
                cancel: cancelEntryVerification
            )
        }
    }

    /// W4-R2 item 20: performs one current W4-Q1 read and latches
    /// `hasEnteredForm` only from an `.eligible` result — covering both a
    /// fresh verification finishing here and an already-verified/restored
    /// identity present at first appearance, since `.task(id:)` also runs for
    /// the initial value. A no-op once `hasEnteredForm` is already latched
    /// (mid-form authority loss must not restart this early-boundary check)
    /// or while unverified (cancelled/failed verification never queries
    /// W4-Q1). The second guard after `await` discards a result that arrived
    /// after this session was legitimately admitted or lost verification
    /// while the read was in flight, matching
    /// `RequestStore.resolveRequestCreationEligibility`'s own stale-response
    /// fence one layer up.
    private func performEligibilityCheckIfNeeded() async {
        guard identityStore.isVerified, !hasEnteredForm else { return }
        eligibilityCheck = .checking
        let result = await store.resolveRequestCreationEligibility()
        guard identityStore.isVerified, !hasEnteredForm else { return }
        eligibilityCheck = .resolved(result)
        hasEnteredForm = Self.nextHasEnteredForm(
            previousHasEnteredForm: hasEnteredForm,
            eligibility: result
        )
    }

    /// Abandoning verification here has no filled draft to protect — unlike
    /// the in-form sheet, nothing has been shown yet — so Cancel also leaves
    /// Request Food rather than reopening the same empty gate.
    private func cancelEntryVerification() {
        Self.cancelEntryVerification(identityStore: identityStore, onExit: beginExit)
    }

    /// Keeps `ParticipantVerificationView`'s local `NavigationStack` on the
    /// accepted modal boundary instead of nesting it inside ContentView's
    /// typed root stack. The identity flow is the presentation authority:
    /// entry starts it on appear, completion retires it and reveals the form,
    /// and either dismissal path cancels it and pops this still-empty route.
    private var isPresentingEntryVerification: Binding<Bool> {
        Binding(
            get: {
                Self.shouldPresentEntryVerification(
                    hasEnteredForm: hasEnteredForm,
                    verificationPurpose: identityStore.flow?.purpose
                )
            },
            set: { isPresented in
                if !isPresented {
                    cancelEntryVerification()
                }
            }
        )
    }

    /// Entry cancellation retires verification, then asks ContentView to pop
    /// the pushed `.requestFood` route. There is no draft to preserve yet.
    static func cancelEntryVerification(
        identityStore: ParticipantIdentityStore,
        onExit: () -> Void
    ) {
        identityStore.cancelVerification()
        onExit()
    }

    private func beginExit() {
        guard !hasRequestedExit else { return }
        hasRequestedExit = true
        // ContentView owns the typed root path and removes `.requestFood`.
        // This entry owns no parallel route or presentation truth.
        onExit()
    }

    /// `hasEnteredForm` defaults to `false` and `eligibilityCheck` defaults
    /// to an already-`.eligible` result, so every existing call site not
    /// concerned with the W4-R2 early quota boundary is unaffected — passing
    /// no eligibility value reproduces the exact presentation this function
    /// returned before W4-Q1 consumption existed. `hasEnteredForm` outranks
    /// everything else: once this session has legitimately admitted the
    /// form, a later unverified/exhausted/unknown read (mid-form authority
    /// loss, or simply an unrelated later call) must not revert away from it
    /// — recovery from that loss is `RequestFoodView`'s own submit-time gate,
    /// not this entry screen re-litigating admission.
    static func presentation(
        isVerified: Bool,
        hasEnteredForm: Bool = false,
        eligibilityCheck: RequestFoodEligibilityCheck = .resolved(.eligible)
    ) -> RequestFoodEntryPresentation {
        if hasEnteredForm {
            return .form
        }
        guard isVerified else {
            return .verification
        }
        switch eligibilityCheck {
        case .notStarted, .checking:
            return .checkingEligibility
        case .resolved(.eligible):
            return .form
        case .resolved(.exhausted):
            // Not retryable: another read now would answer identically.
            return .unavailable(message: RequestFoodView.postingLimitReachedNotice, retryable: false)
        case .resolved(.unknown):
            // The read itself failed/was inconclusive — never the quota
            // itself — so this is retryable and uses the distinct notice
            // that says so, matching `RequestFoodView.availabilityUnknownNotice`'s
            // own "couldn't check, not 'no'" framing.
            return .unavailable(message: RequestFoodView.availabilityUnknownNotice, retryable: true)
        }
    }

    /// The latch itself, pulled out as pure logic so the exact rule
    /// `performEligibilityCheckIfNeeded()` applies is independently
    /// testable: sticky once an `.eligible` read is ever seen, and otherwise
    /// unchanged — a later `.exhausted`/`.unknown` (which cannot occur after
    /// latching, since the check never reruns once admitted) does not clear
    /// an existing `true`.
    static func nextHasEnteredForm(
        previousHasEnteredForm: Bool,
        eligibility: RequestStore.RequestCreationEligibility
    ) -> Bool {
        previousHasEnteredForm || eligibility == .eligible
    }

    /// The exact predicate `onAppear` applies (rereview correction): entry
    /// owns starting `.firstVerification` only before this session has ever
    /// admitted the form. Once admitted, a later appearance — e.g. returning
    /// from backgrounding after a mid-form authority loss — must leave
    /// verification ownership to `RequestFoodView`'s own coordinator-owned
    /// recovery. Calling `beginVerificationIfNeeded()` here after admission
    /// would open a hidden `.firstVerification` flow that
    /// `ParticipantIdentityStore.beginVerification(for:)` — the entry point
    /// `RequestFoodView`'s recovery actually needs — then refuses to
    /// replace, silently blocking that recovery from ever starting.
    static func shouldBeginEntryVerificationOnAppear(hasEnteredForm: Bool) -> Bool {
        !hasEnteredForm
    }

    /// The single production-owned decision behind
    /// `.onChange(of: identityStore.isVerified)`, above: a live
    /// `PARTICIPANT_AUTHORITY_INVALID` retirement (`true` → `false`) while
    /// this entry has not yet admitted the form restarts the same
    /// first-verification flow `.onAppear` starts, under the identical
    /// `shouldBeginEntryVerificationOnAppear` guard. Never fires on the
    /// reverse transition (`false` → `true`, an ordinary successful
    /// verification) or once this session has legitimately admitted the
    /// form. Extracted so the real view's `.onChange` and its regression
    /// proof both call this exact function rather than the test
    /// reconstructing its condition independently.
    static func handleVerifiedTransition(
        wasVerified: Bool,
        isVerified: Bool,
        hasEnteredForm: Bool,
        identityStore: ParticipantIdentityStore
    ) {
        guard wasVerified, !isVerified,
              shouldBeginEntryVerificationOnAppear(hasEnteredForm: hasEnteredForm) else {
            return
        }
        identityStore.beginVerificationIfNeeded()
    }

    /// Entry presents only its own first-verification flow. A later in-form
    /// authority-loss flow remains owned by `RequestFoodView` and its
    /// operation-scoped continuation coordinator.
    static func shouldPresentEntryVerification(
        hasEnteredForm: Bool,
        verificationPurpose: ParticipantVerificationPurpose?
    ) -> Bool {
        !hasEnteredForm && verificationPurpose == .firstVerification
    }

    /// W4-R2 item 20: no fields, no draft, no submit — this state exists only
    /// while the one current W4-Q1 read this entry performs is in flight.
    private var eligibilityCheckingView: some View {
        ProgressView()
            .controlSize(.large)
            .tint(Color.accentColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
            .accessibilityIdentifier("request-food-entry-checking-eligibility")
    }

    /// W4-R2 item 20: the pre-form stop for both an exhausted quota and an
    /// inconclusive/failed read. `message` is always one of
    /// `RequestFoodView`'s own already-accepted notices — this screen invents
    /// no new copy. `retryable` offers `Try Again` only when the read itself,
    /// not the quota, is what did not resolve; that same flag also selects the
    /// 2026-09-06 title/body/action presentation (retryable) versus the
    /// unchanged single-sentence exhausted presentation (not retryable), so
    /// the two states remain visibly distinct.
    private func eligibilityUnavailableView(message: String, retryable: Bool) -> some View {
        VStack(spacing: CommonPlateStyle.Spacing.l) {
            if retryable {
                Text("Requesting is temporarily unavailable")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: CommonPlateStyle.Metrics.stateContentWidth)
                    .accessibilityIdentifier("request-food-entry-eligibility-title")
            } else {
                dailyLimitContent
            }

            if retryable {
                Button("Try Again") {
                    Task { await performEligibilityCheckIfNeeded() }
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(CommonPlateStyle.Color.baseCanvas)
        .accessibilityIdentifier("request-food-entry-eligibility-unavailable")
    }

    static let dailyLimitTitle = "Today’s request limit reached"
    static let dailyLimitBody =
        "Still need food today? Explore meal assistance at NYU and other free food resources around\u{00A0}NYC."
    static let findFoodSupportLabel = "Find food support"

    /// The approved R5 daily-limit presentation: the exhausted state points to
    /// the Food Resources already in Settings instead of a bare refusal.
    private var dailyLimitContent: some View {
        VStack(spacing: CommonPlateStyle.Spacing.l) {
            Image(systemName: "fork.knife")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(CommonPlateStyle.Color.brandText)
                .frame(width: 96, height: 96)
                .background(Circle().fill(CommonPlateStyle.Color.warmSurface))
                .accessibilityHidden(true)

            VStack(spacing: CommonPlateStyle.Spacing.s) {
                Text(Self.dailyLimitTitle)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("request-food-entry-eligibility-notice")
                Text(Self.dailyLimitBody)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("request-food-entry-daily-limit-body")
            }
            .frame(maxWidth: CommonPlateStyle.Metrics.stateContentWidth)

            Button {
                path.append(.settings)
            } label: {
                HStack(spacing: CommonPlateStyle.Spacing.m) {
                    Image(systemName: "hand.raised")
                        .foregroundStyle(CommonPlateStyle.Color.brandText)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(CommonPlateStyle.Color.warmSurface)
                        )
                        .accessibilityHidden(true)
                    Text(Self.findFoodSupportLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: CommonPlateStyle.Spacing.s)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(CommonPlateStyle.Color.brandText)
                        .accessibilityHidden(true)
                }
                .padding(CommonPlateStyle.Spacing.m)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                .commonPlateCard()
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens Food Resources in Settings")
            .accessibilityIdentifier("request-food-entry-find-food-support")
        }
        // Optical centering: the approved frame sits above the midpoint.
        .padding(.bottom, 120)
    }

    @ToolbarContentBuilder
    private var backToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("Back")
        }
    }
}
