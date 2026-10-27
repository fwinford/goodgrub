import SwiftUI

struct ContentView: View {
    /// What the connected claim-to-placement flow does. Placement records an
    /// external order the helper has already completed; notification is a
    /// separate email attempt and is never described as delivery or reading.
    /// Retained as a non-UI source of truth for the existing lifecycle tests;
    /// the student-facing explainer is now `OnboardingExperienceView`.
    static let howItWorksSteps = [
        "1. A student posts a food request from an NYU dining spot.",
        "2. A helper with extra meal swipes chooses a request to help with.",
        "3. The helper places the Grubhub order, then records the order number and pickup time.",
        "4. CommonPlate attempts to email the student the pickup details."
    ]

    @StateObject private var requestStore: RequestStore
    /// Alert signup keeps its own state owner. Its lifecycle, responses, and
    /// failures have nothing in common with the request flow's, and holding it
    /// here — rather than inside the screen — lets the accepted state survive
    /// leaving and reopening the screen. Across launches it survives instead
    /// through the store's own presentation storage, which remembers that the
    /// accepted response was seen and nothing about subscription status.
    @StateObject private var alertSubscriptionStore: AlertSubscriptionStore
    /// Push keeps its own state owner, independent of
    /// `alertSubscriptionStore`: per the Week 3 Day 6 cross-slice contract,
    /// email alerts and push notifications are separate controls with no
    /// shared state or error semantics.
    @StateObject private var pushSubscriptionStore: PushSubscriptionStore
    /// The participant-authorized "Turn off email alerts" action keeps its
    /// own state owner (W3-N2). It shares no state with
    /// `alertSubscriptionStore`: signup presentation history establishes no
    /// Subscriber truth, and this store's confirmed Off result is session-only
    /// and establishes no future On.
    @StateObject private var participantEmailUnsubscribeStore: ParticipantEmailUnsubscribeStore
    /// The one state owner for the W4-N0 authoritative Email Request Alert
    /// state read (`GET /api/participant/email-alerts/state`). Entirely
    /// separate from `alertSubscriptionStore` (signup presentation history)
    /// and `participantEmailUnsubscribeStore` (the Off mutation): this is the
    /// only source Settings' Email toggle may read On/Off from.
    @StateObject private var emailAlertStateStore: EmailAlertStateStore
    /// The one W4-S1 state owner for AI screenshot proposals. Entirely
    /// separate from `requestStore`: it never mutates a `Request`, mints an
    /// operation identity, or otherwise touches D1/create lifecycle — only
    /// the in-progress `RequestFoodFormDraft` it is handed.
    @StateObject private var screenshotProposalStore: ScreenshotProposalStore
    /// The bounded in-memory owner for one unfinished Request Food draft.
    /// Unlike D1's operation storage, this has no durable representation and
    /// exists only for this ContentView/app-process lifetime. Holding it above
    /// `.requestFood` lets an ordinary route pop/re-push restore the same task.
    @StateObject private var requestFoodDraftSession: RequestFoodDraftSession
    /// Local presentation preference only. It deliberately has no connection
    /// to participant identity, credentials, or backend authority.
    @StateObject private var onboardingStore: OnboardingPresentationStore
    @StateObject private var onboardingFlowCoordinator: OnboardingFlowCoordinator
    @StateObject private var participantDeletionStore: ParticipantDeletionStore
    /// Participant identity keeps its own state owner (W3-I1). It is not
    /// subscription state and not installation state: it is the one thing in
    /// the app that represents a person, every participant action reads it, and
    /// holding it here is what lets a verified identity survive leaving and
    /// reopening any screen.
    @StateObject private var participantIdentityStore: ParticipantIdentityStore
    /// The one operation-scoped verification continuation owner (W3-I1).
    /// Request and helper views report their lifecycle signals to this same
    /// production object, so a competing screen cannot manufacture or consume
    /// a continuation by observing global identity publication.
    @StateObject private var participantActionVerificationCoordinator:
        ParticipantActionVerificationCoordinator
    /// Shared with `PushAppDelegate`, which wires it as
    /// `UNUserNotificationCenter`'s delegate before this view exists — see
    /// `CommonPlateiosApp.swift`. Observed here, not owned, so a tap captured
    /// before launch or while another screen was showing is still picked up
    /// once this view is ready to navigate.
    @ObservedObject private var notificationRouter: HelperNotificationRouter
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestMessaging) private var requestMessaging
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The one navigation stack in the app, owned here so any screen inside it
    /// can leave a finished flow by rewriting the path rather than by asking a
    /// view below it to dismiss.
    @State private var path: [AppRoute] = []
    /// W4-O1: the request whose Home card was just tapped while the first-use
    /// discovery treatment was active. Consumed by the next path change; never
    /// set by notification or other non-card navigation.
    @State private var homeCardOpenedRequestID: String?
    /// A presentation-only handoff for major actions that start a task. Unlike
    /// `path` and onboarding completion, this never establishes app truth.
    @State private var flowPresentation: FlowPresentation?

    /// W4-H1: owns the helper success presentation's active-scene-aware
    /// progression and its exactly-once haptic, announcement, and Home
    /// return. Presentation only — never persisted and never consulted by any
    /// lifecycle decision.
    @StateObject private var helperSuccessCoordinator = HelperSuccessPresentationCoordinator()

    /// W4-D2 Success→Home continuity: Home's own first requester-owned slot
    /// frame, relayed from its layout to the continuity overlay below so the
    /// in-flight card lands in the real slot rather than at an assumed
    /// position. `nil` whenever Home renders no owned slot right now.
    @State private var homeOwnedRequestSlotFrame: CGRect?

    /// W4-D2 crossfade handoff (Reduce Motion with a usable destination, and
    /// the no-usable-target in-place crossfade): relayed from the
    /// continuity overlay's `RequestCreationContinuityHandoffKey`, exactly
    /// like `homeOwnedRequestSlotFrame` above, so Home's own destination card
    /// fades in on the identical signal and timing the overlay's card fades
    /// out on — never a second, independently guessed reveal timeline.
    @State private var isRevealingLandingContinuityCard = false

    /// `remoteNotificationRegistrar` must be the same instance
    /// `PushAppDelegate` forwards APNs callbacks into — see
    /// `CommonPlateiosApp.swift` — so, matching every other injected
    /// dependency here, it has no default: no caller can reach a
    /// disconnected registrar by omission. `notificationRouter` has no
    /// default for the same reason: a fresh, disconnected router would never
    /// see the tap `PushAppDelegate`'s instance actually captured.
    init(
        configuration: APIConfiguration,
        remoteNotificationRegistrar: RemoteNotificationRegistering,
        notificationRouter: HelperNotificationRouter,
        onAccountDeletionHandoff: @escaping () -> Void = {}
    ) {
        self.notificationRouter = notificationRouter
        let deletionFence = ParticipantDeletionNetworkFence(
            isFrozen: ParticipantDeletionFreeze(defaults: .standard).isPresent
        )
        let client = APIClient(configuration: configuration, deletionFence: deletionFence)
        let service = RequestService(client: client)
        // The app's real installation-identity storage, shared by
        // `RequestStore` (which only ever reads the stable credential) and
        // `PushSubscriptionStore` (which owns the rest of the push-preference
        // lifecycle). One instance so both read the same credential a fresh
        // one per store could not guarantee.
        let installationStorage = UserDefaultsPushInstallationStorage(defaults: .standard)
        // Built before `RequestStore`, which reads its credential on every
        // participant action. `identityStore` is captured by the two closures
        // below rather than by the store itself, so `RequestStore` still knows
        // nothing about verification beyond "here is a credential, and here is
        // what to do when the backend refuses it".
        let identityStore = ParticipantIdentityStore(
            service: ParticipantVerificationService(client: client),
            // The app's real preferences. Tests inject an isolated suite or an
            // in-memory double instead, which is why this argument has no
            // default.
            storage: UserDefaultsParticipantIdentityStorage(defaults: .standard)
        )
        _participantIdentityStore = StateObject(wrappedValue: identityStore)
        _participantActionVerificationCoordinator = StateObject(
            wrappedValue: ParticipantActionVerificationCoordinator(
                identityStore: identityStore
            )
        )
        let requestStore = RequestStore(
            service: service,
            installationCredentialProvider: installationStorage.installationCredential,
            participantAuthorityProvider: { identityStore.currentAuthority() },
            participantAuthorityRejected: { identityStore.discardRejectedIdentity() },
            reservationWarningScheduler: UNUserNotificationCenterReservationWarningScheduler(),
            // The app's real durable storage (W3-D1), so an unresolved
            // request-create operation survives app/process termination.
            // Tests inject an isolated suite or an in-memory double
            // instead, matching every other real-storage argument here.
            operationStorage: UserDefaultsPendingRequestOperationStorage(defaults: .standard),
            reportOperationStorage: UserDefaultsPendingReportOperationStorage(defaults: .standard),
            updateStorage: UserDefaultsPendingRequestUpdateStorage(defaults: .standard),
            participantPrincipalProvider: { identityStore.identity?.principal },
            pendingPlacedPickupStorage: UserDefaultsPendingPlacedPickupStorage(defaults: .standard)
        )
        _requestStore = StateObject(wrappedValue: requestStore)
        let alertStore = AlertSubscriptionStore(
                service: AlertSubscriptionService(client: client),
                // The app's real preferences. Tests inject an isolated suite or
                // an in-memory double instead, which is why this argument has
                // no default.
                presentationStorage: UserDefaultsAlertSignupPresentationStorage(defaults: .standard)
        )
        _alertSubscriptionStore = StateObject(wrappedValue: alertStore)
        let pushStore = PushSubscriptionStore(
                service: InstallationPushService(
                    client: client, nextMutationVersion: { installationStorage.nextMutationVersion() },
                    participantIdentityStore: identityStore
                ),
                installationStorage: installationStorage,
                authorizationCoordinator: UNUserNotificationCenterAuthorizationCoordinator(),
                remoteNotificationRegistrar: remoteNotificationRegistrar,
                settingsOpener: UIApplicationPushSettingsOpener(),
                participantAuthorityProvider: { identityStore.currentAuthority() }
            )
        identityStore.configureInstallationAssociation(
            pendingReplacementEmail: { pushStore.pendingReplacementEmail },
            prepareReplacement: { pushStore.prepareParticipantReplacement(email: $0) },
            onIdentityCommitted: { pushStore.completeParticipantAssociationChange() }
        ) { authority in
            try await pushStore.synchronizeParticipantAssociation(authority: authority)
        }
        pushStore.configureAssociationRecovery { [weak identityStore, weak requestStore, weak pushStore] in
            guard let identityStore, let requestStore, let pushStore else { return }
            if pushStore.pendingReplacementEmail != nil {
                identityStore.resumePendingInstallationReplacement()
            } else {
                await identityStore.removeIdentity(ifSafe: {
                    requestStore.hasEstablishedRemovalSafety &&
                    requestStore.activeClaim == nil &&
                    !requestStore.hasUnresolvedCreateAmbiguity &&
                    !requestStore.isCreating &&
                    identityStore.currentAuthority() != nil
                })
            }
        }
        _pushSubscriptionStore = StateObject(wrappedValue: pushStore)
        let unsubscribeStore = ParticipantEmailUnsubscribeStore(
                service: ParticipantEmailUnsubscribeService(client: client)
        )
        _participantEmailUnsubscribeStore = StateObject(wrappedValue: unsubscribeStore)
        let emailStateStore = EmailAlertStateStore(
                service: EmailAlertStateService(client: client),
                participantAuthorityProvider: { identityStore.currentAuthority() },
                participantAuthorityRejected: { identityStore.discardRejectedIdentity() }
        )
        _emailAlertStateStore = StateObject(wrappedValue: emailStateStore)
        let screenshotStore = ScreenshotProposalStore(
                // V1.0 excludes requester Screenshot Assistance in every
                // shipping configuration; see RequesterScreenshotAssistanceAvailability.
                availability: .shipping,
                service: ScreenshotProposalService(availability: .shipping, client: client),
                // The app's real preferences. Tests inject an isolated suite
                // or an in-memory double instead, matching every other
                // real-storage argument here.
                preferences: UserDefaultsScreenshotProposalPreferencesStorage(defaults: .standard)
        )
        _screenshotProposalStore = StateObject(wrappedValue: screenshotStore)
        let draftSession = RequestFoodDraftSession()
        _requestFoodDraftSession = StateObject(wrappedValue: draftSession)
        let onboardingStore = OnboardingPresentationStore(
            storage: UserDefaultsOnboardingPresentationStorage(defaults: .standard)
        )
        _onboardingStore = StateObject(wrappedValue: onboardingStore)
        _onboardingFlowCoordinator = StateObject(
            wrappedValue: OnboardingFlowCoordinator(presentationStore: onboardingStore)
        )
        _participantDeletionStore = StateObject(
            wrappedValue: ParticipantDeletionStore(
                service: service, identity: identityStore,
                secureStorage: KeychainParticipantDeletionStorage(), defaults: .standard,
                networkFence: deletionFence, onboarding: onboardingStore,
                fenceNotificationIntents: notificationRouter.fenceForCompletedDeletion,
                retirePresentation: {
                    requestStore.retireForCompletedDeletion()
                    screenshotStore.invalidateCurrentSelection()
                    draftSession.retireForCompletedDeletion()
                    alertStore.retireForCompletedDeletion()
                    unsubscribeStore.reset()
                    emailStateStore.retireForCompletedDeletion()
                    pushStore.retireForCompletedDeletion()
                },
                handoff: onAccountDeletionHandoff
            )
        )
    }

    var body: some View {
        applicationBody
            .allowsHitTesting(!participantDeletionStore.isPresented)
            .accessibilityHidden(participantDeletionStore.isPresented)
            .overlay {
                if participantDeletionStore.isPresented {
                    ParticipantDeletionView(
                        store: participantDeletionStore,
                        onViewCurrentRequest: navigateToDeletionBlocker
                    )
                }
            }
            .task { await participantDeletionStore.reconcile() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await participantDeletionStore.reconcile() }
            }
    }

    /// Navigation only (Faith 2026-10-25): the existing request/helping
    /// screens own any withdrawal. Ambiguous or unloaded goes Home.
    private func navigateToDeletionBlocker() {
        let owned = requestStore.ownerRequests
        if owned.count == 1, let only = owned.first {
            path = [.ownerRequest(only)]
        } else if owned.isEmpty, let activeClaim = requestStore.activeClaim {
            path = [.fulfillment(activeClaim.request)]
        } else {
            path = []
        }
    }

    private var requestLifecycleBody: some View {
        ZStack {
            NavigationStack(path: $path) {
                Group {
                    if onboardingStore.hasCompletedOnboarding {
                        verifiedHomeOrGate(brandHasSettled: true)
                    } else {
                        OnboardingWelcomeView(onContinue: completeOnboardingFromWelcome)
                    }
                }
                .navigationDestination(for: AppRoute.self) { route in
                    SoftFlowEnterDestination(
                        reduceMotion: reduceMotion,
                        shouldAnimate: flowPresentation == .route(route),
                        // W4-R2 2026-09-05 sync item 8: Request Food owns its
                        // own local Bottom Continuity settle
                        // (`RequestFoodEntryView`'s `hasSettled`), which never
                        // gates hit testing. This shared wrapper's own
                        // opacity/offset settle and hit-testing gate would
                        // otherwise duplicate that cue and reintroduce a
                        // decorative delay to interactivity for this route
                        // specifically. Every other route keeps this
                        // wrapper's existing entrance exactly as it is today.
                        playsOwnSettle: route != .requestFood
                    ) {
                        destination(for: route)
                    } onFinished: {
                        finishSoftFlowEntrance(.route(route))
                    }
                }
            }

            if onboardingFlowCoordinator.isCompletingOnboarding {
                SoftBrandSettlePresentation(
                    reduceMotion: reduceMotion,
                    home: { brandHasSettled in
                        verifiedHomeOrGate(brandHasSettled: brandHasSettled)
                    },
                    onFinished: onboardingFlowCoordinator.finishCompletionPresentation
                )
                .zIndex(1)
            }

            // W4-D2 Success→Home continuity: presented only while
            // `RequestStore` holds a live continuity for an operation it
            // authoritatively confirmed CREATED under the authority current
            // now. Keyed by that continuity's identity, so a later create
            // starts its own presentation and can never inherit this one's
            // phase or acknowledgement; retired through the store's
            // identity-scoped retirement, so an interrupted presentation
            // leaves nothing behind. Sits above the stack (not inside it) so
            // Home is already revealed beneath the card as it lands.
            if let continuity = requestStore.createdRequestContinuity {
                let guidanceLedger = FirstRequestGuidanceLedger(defaults: .standard)
                RequestCreationContinuityView(
                    continuity: continuity,
                    homeSlotFrame: homeOwnedRequestSlotFrame,
                    reduceMotion: reduceMotion,
                    onFinished: { id in
                        _ = guidanceLedger.recordGuidanceShown(
                            forAuthority: continuity.participantAuthority,
                            currentAuthority: participantIdentityStore.currentAuthority(),
                            deletionFrozen: participantDeletionStore.hasRecord ||
                                ParticipantDeletionFreeze(defaults: .standard).isPresent
                        )
                        requestStore.retireCreationContinuity(id: id)
                    },
                    ownerPhase: requestStore.ownerRequests.first { $0.id == continuity.request.id }?.phase,
                    isFirstRequest: guidanceLedger.showsGuidance(
                        forAuthority: continuity.participantAuthority,
                        currentAuthority: participantIdentityStore.currentAuthority(),
                        deletionFrozen: participantDeletionStore.hasRecord ||
                            ParticipantDeletionFreeze(defaults: .standard).isPresent
                    )
                )
                .id(continuity.id)
                .zIndex(3)
            }

            // W4-H1: shown only while an in-process, authoritatively confirmed
            // placement exists. Relaunch never restores a confirmation, so it
            // never reconstructs this presentation, its haptic, or its Home
            // return.
            if let confirmation = requestStore.fulfillmentConfirmation {
                HelperSuccessView(
                    confirmation: confirmation,
                    phase: helperSuccessPhase(for: confirmation),
                    reduceMotion: reduceMotion,
                    isAnnouncementPending: helperSuccessCoordinator
                        .isAnnouncementPending(for: confirmation.id)
                )
                .id(confirmation.id)
                .transition(.opacity)
                .zIndex(2)
            }
        }
        // W4-D2 coordinate-system FIX: Home's published first-slot frame and
        // the continuity overlay's own card frame are both measured in
        // `.global` now, not in a space named here. A name declared on this
        // container does not resolve across `NavigationStack`'s own hosting
        // boundary (Home renders inside it; this overlay is a sibling of it),
        // which silently compared two frames in two different origins — see
        // `RequestCreationContinuityLayout.landingSlot` and
        // `HomeExchangeView.firstOwnedSlotFrameReporter`.
        .onPreferenceChange(HomeOwnedRequestSlotFrameKey.self) { frame in
            homeOwnedRequestSlotFrame = frame
        }
        .onPreferenceChange(RequestCreationContinuityHandoffKey.self) { isRevealing in
            isRevealingLandingContinuityCard = isRevealing
        }
        // Cold-launch and relaunch-after-termination continuation (W3-H1):
        // reconstructs "do I have an active reservation" from backend truth,
        // since a terminated process discarded whatever `RequestStore` held
        // in memory. Runs once at this view's first appearance; a no-op on
        // every call after the first successfully resolves one, and a no-op
        // immediately if `RequestStore` already holds a claim from `claim()`
        // in the same process.
        .task {
            let isActive = scenePhase == .active
            installHelperSuccessHomeReturn()
            helperSuccessCoordinator.updateSceneActivity(isActive: isActive)
            notificationRouter.updateApplicationSceneActivity(isActive: isActive)
            requestStore.updateApplicationVisibility(isVisible: isActive)
        }
        // W4-B1: protected reads and reconciliation wait for verified
        // authority and run when it first exists (launch with a usable
        // identity, or right after verification). Nothing here reaches the
        // R5-enforcing backend while the root gate is showing.
        .task(id: participantIdentityStore.isVerified) {
            guard participantIdentityStore.isVerified else { return }
            _ = try? await requestStore.continueActiveReservationIfNeeded()
            // W3-D1 cold-launch/relaunch reconciliation: resumes and
            // reconciles an unresolved request-create operation left over
            // from a previous process, using the exact same operation
            // identity and submitted fields as the original attempt. A no-op
            // whenever nothing durable remains.
            _ = await requestStore.reconcilePendingCreateOperationIfNeeded()
            await requestStore.reconcilePendingPlacedPickupIfNeeded()
            async let reportRecovery: Void = requestStore.reconcilePendingReportOperationSilently()
            async let restrictionRefresh: Void = requestStore.refreshParticipantRestriction()
            _ = await (reportRecovery, restrictionRefresh)
        }
        // W4-D2: whose unresolved create operation blocks creation and
        // Remove Email depends on the participant current now, so the block
        // is re-derived whenever that identity changes. Local only: an
        // identity arriving never triggers a reconciliation by itself.
        .onChange(of: participantIdentityStore.identity) { _, _ in
            requestStore.refreshPendingCreateState()
            Task {
                await requestStore.reconcilePendingReportOperationSilently()
                await requestStore.refreshParticipantRestriction()
            }
        }
        // W4-R5 `R5-IR-1`: the previous participant's request data is retired
        // in the same turn a *different* participant becomes current. Retiring
        // the board is the store's decision (it compares credentials); this
        // view only retires the request snapshots its own navigation stack
        // carries, for a direct replacement (Change Email) or a retirement
        // with no replacement (`D-R5-2`). A first verification keeps the stack,
        // so a claim continuation that triggered it is not unwound.
        .onChange(of: participantIdentityStore.identity) { previous, current in
            requestStore.invalidateRequestDataIfIdentityReplaced()
            Task { await requestStore.reconcilePendingPlacedPickupIfNeeded() }
            if let previous, let current, previous.principal != current.principal {
                path = AppRoute.afterIdentityReplacement(from: path)
            } else if previous != nil, current == nil {
                // W4-R5 `D-R5-2`: a retired identity's request snapshots go
                // with it, and cannot come back for whoever verifies next.
                // W4-B1: with no identity the root is the verification gate,
                // so nothing may remain pushed above it.
                path = []
            }
        }
        // A notification tap or fulfillment notice that arrived while the
        // root gate was showing was deliberately left pending; the first
        // verified moment is when it can resolve against backend truth.
        .onChange(of: participantIdentityStore.isVerified) { _, isVerified in
            guard isVerified else { return }
            Task { await routePendingHelperNotification() }
            Task { await routePendingReservationWarning() }
            Task { await routePendingRequesterFulfillmentNotification() }
            routePendingPickupConfirmedNotification()
        }
    }

    private var applicationBody: some View {
        requestLifecycleBody
        .onChange(of: scenePhase) { (_: ScenePhase, phase: ScenePhase) in
            let isActive = phase == .active
            // W4-H1: success progression counts only active time.
            helperSuccessCoordinator.updateSceneActivity(isActive: isActive)
            notificationRouter.updateApplicationSceneActivity(isActive: isActive)
            requestStore.updateApplicationVisibility(isVisible: isActive)
            if phase == .active {
                Task {
                    await requestStore.reconcilePendingReportOperationSilently()
                    await requestStore.refreshParticipantRestriction()
                }
                // Detects a notification permission changed in Settings, and
                // silently re-registers an installation that was previously
                // confirmed on. Never shows Apple's permission prompt.
                Task { await pushSubscriptionStore.refreshAuthorizationStatus() }
                // The second chance a launch-time tap needs. The `.task`
                // below is the normal trigger, but on a cold launch the tap
                // is captured before this view exists and its first routing
                // attempt can be cancelled while SwiftUI is still building
                // the scene — the attempt then, correctly, leaves the tap
                // pending rather than dropping it. The scene actually
                // becoming active is a real readiness signal (not a guessed
                // delay) and the point at which retrying is guaranteed to
                // find a live view, so a tap that survived an unfinished
                // attempt is routed here. With nothing pending this is an
                // immediate no-op, and running alongside the `.task` is safe
                // — see `HelperNotificationRouteDriver.routeIfNeeded`.
                Task { await routePendingHelperNotification() }
                // Same second-chance reasoning for a reservation-warning tap
                // (W3-H1).
                Task { await routePendingReservationWarning() }
                // Requester-fulfillment taps remain pending until the exact
                // request id can enter R3's verified placed-order route.
                Task { await routePendingRequesterFulfillmentNotification() }
                routePendingPickupConfirmedNotification()
            }
        }
        // Reruns whenever a *new* tap intent is captured, including the
        // first one on the initial run — which is what makes a tap captured
        // before this view existed (a cold launch) reach here the first time
        // it can — and again whenever this view is rebuilt, which is what
        // lets a cold launch's cancelled first attempt be retried. Keyed on
        // `routingGeneration`, not `pendingRequestID`: retiring a routed
        // intent clears the pending value, but that clear does not advance
        // the generation, so it cannot rewrite this task's own id and cancel
        // the resolution the task just started. A later unrelated rerun
        // replays nothing, because an already-applied tap is no longer
        // pending and nothing but a fresh tap advances the generation.
        .task(id: notificationRouter.routingGeneration) {
            await routePendingHelperNotification()
        }
        // The reservation-warning tap's own trigger (W3-H1), independent of
        // `routingGeneration` above for the identical self-cancellation
        // reason `HelperNotificationRouter.reservationWarningRoutingGeneration`
        // documents.
        .task(id: notificationRouter.reservationWarningRoutingGeneration) {
            await routePendingReservationWarning()
        }
        // The foreground half of the same warning (W3-H1): no notification
        // tap is involved when CommonPlate is already visible when the
        // five-minute mark arrives, so this is the one place that path
        // still has to land on the reservation screen. A no-op if already
        // there — `AppRoute.appending` only pushes when it is not already on
        // top — so this cannot duplicate the destination if the helper had
        // already navigated there themselves.
        .onChange(of: requestStore.isShowingReservationWarning) { _, isWarning in
            guard isWarning, let activeClaim = requestStore.activeClaim else { return }
            // W4-R5 (retiring Active Requests also retires the 2026-10-15
            // deferred defect): the foreground warning lands on Helping *in
            // place*. If Helping for this reservation is already on the stack
            // the path is unchanged; otherwise it is entered above whatever
            // Home-rooted path exists, so Back returns Home, never to a legacy
            // list.
            path = AppRoute.enteringHeldRequest(activeClaim, from: path)
        }
        // A requester-fulfillment tap resolves through R3's placed-order
        // detail view. Its captured sequence fences stale attempts.
        .task(id: notificationRouter.requesterFulfillmentRoutingGeneration) {
            await routePendingRequesterFulfillmentNotification()
        }
        .task(id: notificationRouter.pickupConfirmedRoutingGeneration) {
            routePendingPickupConfirmedNotification()
        }
        .sheet(isPresented: isPresentingIdentityFlow) {
            ParticipantVerificationView(store: participantIdentityStore)
        }
        .fullScreenCover(
            item: Binding(
                get: { requestStore.reportPopup },
                set: { if $0 == nil { requestStore.dismissReportPopup() } }
            )
        ) { popup in
            ParticipantReportView(
                requestID: popup.requestID,
                store: requestStore,
                offersBlockAfter: popup.offersBlockAfter,
                discloseConversationContext: requestMessaging.isEnabled,
                onFinished: {
                    requestStore.dismissReportPopup()
                    if popup.returnsHome {
                        path = []
                    }
                },
                onBlockRequested: {
                    requestStore.dismissReportPopup()
                    Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        requestStore.requestBlockAfterReport()
                    }
                }
            )
            .presentationBackground(.clear)
        }
        .alert(
            "Would you also like to report this student?",
            isPresented: Binding(
                get: { requestStore.postBlockReportOffer != nil },
                set: { isPresented in
                    guard !isPresented,
                          let offer = requestStore.dismissPostBlockReportOffer() else {
                        return
                    }
                    if offer.returnsHome {
                        path = []
                    }
                }
            )
        ) {
            Button("Not now", role: .cancel) {
                if let offer = requestStore.dismissPostBlockReportOffer(),
                   offer.returnsHome {
                    path = []
                }
            }
            Button("Report student") {
                guard let offer = requestStore.consumePostBlockReportOffer() else { return }
                if offer.returnsHome {
                    path = []
                }
                requestStore.presentReportPopup(
                    requestID: offer.requestID,
                    returnsHome: offer.returnsHome,
                    offersBlockAfter: false
                )
            }
        }
        // W4-H1: an authoritative confirmation — including one recorded while
        // inactive — begins its presentation; retiring it ends it.
        .onChange(of: requestStore.fulfillmentConfirmation?.id) { _, _ in
            helperSuccessCoordinator.update(
                confirmation: requestStore.fulfillmentConfirmation,
                reduceMotion: reduceMotion
            )
        }
        .onChange(of: path) { _, newPath in
            if case .route(let route)? = flowPresentation, newPath.last != route {
                flowPresentation = nil
            }
            completeHelpingDiscoveryIfEligibleRequestOpened(newPath: newPath)
        }
    }

    /// W4-H2: the live CommonPlate exchange supersedes R1's recurring static
    /// launcher as Home's recurring content. The completion presentation is
    /// deliberately independent of the coordinator's synchronous completion
    /// state — the wrapper begins Home's arrival as the outgoing walkthrough
    /// fades, so the user sees one soft settle rather than a navigation pop
    /// followed by a second transition; that fade-in behavior is preserved
    /// here unchanged, now applied to the exchange view instead of a single
    /// brand header.
    /// W4-B1 root gate: Home exists only for a participant with usable
    /// verification. Without one the root is the verification entry itself —
    /// never Home — and Home's protected reads simply never begin.
    @ViewBuilder
    private func verifiedHomeOrGate(brandHasSettled: Bool) -> some View {
        if participantIdentityStore.isVerified {
            recurringHome(brandHasSettled: brandHasSettled)
        } else {
            ParticipantVerificationView(store: participantIdentityStore, isRootGate: true)
                .task(id: participantIdentityStore.flow == nil) {
                    participantIdentityStore.beginVerificationIfNeeded()
                }
                .opacity(brandHasSettled ? 1 : 0)
        }
    }

    private func recurringHome(brandHasSettled: Bool) -> some View {
        HomeExchangeView(
            store: requestStore,
            identityStore: participantIdentityStore,
            alertSubscriptionStore: alertSubscriptionStore,
            pushSubscriptionStore: pushSubscriptionStore,
            unsubscribeStore: participantEmailUnsubscribeStore,
            isRevealingLandingContinuityCard: isRevealingLandingContinuityCard,
            onRequestMeal: { startRouteFlow(.requestFood) },
            discoverySelectedRequestID: HelpingDiscovery.selectedRequestID(
                isPending: onboardingStore.isHelpingDiscoveryPending,
                hasActiveReservation: requestStore.activeClaim != nil,
                store: requestStore
            ),
            onOpenEligibleRequestCard: { homeCardOpenedRequestID = $0 },
            onActivateEligibleRequestCard: { request in
                // Accessibility activation of the highlighted Home card: the
                // same marker a touch tap records, then the same route push
                // the card's NavigationLink performs. Only from Home itself.
                guard path.isEmpty else { return }
                homeCardOpenedRequestID = request.id
                path.append(.requestDetail(request))
            },
            onHelperPickupNoticePresentation: {
                notificationRouter.updateHelperPickupNoticePresentation(requestID: $0)
            }
        )
        .opacity(brandHasSettled ? 1 : 0)
        .offset(y: brandHasSettled || reduceMotion ? 0 : 2)
        .animation(brandLandingAnimation, value: brandHasSettled)
    }

    private var brandLandingAnimation: Animation {
        if reduceMotion {
            return .easeInOut(duration: 0.17)
        }
        return .timingCurve(0.22, 0.78, 0.24, 1, duration: 0.47)
    }

    /// A completion-only overlay that keeps the outgoing walkthrough and the
    /// already-correct Home alive in the same render pass. Navigation and
    /// persistence finish before this appears; it owns only the visible handoff.
    private struct SoftBrandSettlePresentation<Home: View>: View {
        let reduceMotion: Bool
        @ViewBuilder let home: (Bool) -> Home
        let onFinished: () -> Void

        @State private var hasArrived = false

        var body: some View {
            ZStack {
                home(hasArrived)
                    .opacity(hasArrived ? 1 : 0)
                    .offset(y: hasArrived || reduceMotion ? 0 : 9)
                    .animation(homeArrivalAnimation, value: hasArrived)

                OnboardingWelcomeView(onContinue: {})
                    .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
                    .opacity(hasArrived ? 0 : 1)
                    .offset(y: hasArrived || reduceMotion ? 0 : -7)
                    .animation(walkthroughExitAnimation, value: hasArrived)
            }
            .allowsHitTesting(false)
            .onAppear {
                guard !hasArrived else { return }
                withAnimation(completionAnimation, completionCriteria: .logicallyComplete) {
                    hasArrived = true
                } completion: {
                    onFinished()
                }
            }
        }

        private var homeArrivalAnimation: Animation {
            if reduceMotion {
                return .easeInOut(duration: 0.17)
            }
            return .timingCurve(0.22, 0.78, 0.24, 1, duration: 0.43)
        }

        private var walkthroughExitAnimation: Animation {
            reduceMotion
                ? .easeInOut(duration: 0.17)
                : .easeInOut(duration: 0.31)
        }

        private var completionAnimation: Animation {
            reduceMotion
                ? .easeInOut(duration: 0.17)
                : .timingCurve(0.22, 0.78, 0.24, 1, duration: 0.47)
        }
    }

    private enum FlowPresentation: Hashable {
        case route(AppRoute)
    }

    private func startRouteFlow(_ route: AppRoute) {
        guard flowPresentation == nil else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            flowPresentation = .route(route)
            path = AppRoute.appending(route, to: path)
        }
    }

    private func finishSoftFlowEntrance(_ presentation: FlowPresentation) {
        guard flowPresentation == presentation else { return }
        flowPresentation = nil
    }

    /// A lighter sibling to Soft Brand Settle for actions that begin work.
    /// The real in-stack destination is inserted before this runs. It is never
    /// rendered as a temporary overlay and exchanged for a second copy.
    private struct SoftFlowEnterDestination<Destination: View>: View {
        let reduceMotion: Bool
        let shouldAnimate: Bool
        /// W4-R2 2026-09-05 sync item 8: defaults to `true`, preserving this
        /// shared wrapper's existing opacity/offset settle and hit-testing
        /// gate for every route unrelated to that sync's Request Food fix —
        /// only `.requestFood`'s own call site passes `false`.
        var playsOwnSettle: Bool = true
        @ViewBuilder let destination: () -> Destination
        let onFinished: () -> Void

        @State private var hasEntered: Bool

        init(
            reduceMotion: Bool,
            shouldAnimate: Bool,
            playsOwnSettle: Bool = true,
            @ViewBuilder destination: @escaping () -> Destination,
            onFinished: @escaping () -> Void
        ) {
            self.reduceMotion = reduceMotion
            self.shouldAnimate = shouldAnimate
            self.playsOwnSettle = playsOwnSettle
            self.destination = destination
            self.onFinished = onFinished
            _hasEntered = State(initialValue: !shouldAnimate)
        }

        var body: some View {
            ZStack {
                CommonPlateStyle.Color.baseCanvas.ignoresSafeArea()
                destination()
                    .opacity(playsOwnSettle ? (hasEntered ? 1 : 0) : 1)
                    .offset(y: playsOwnSettle && !hasEntered && !reduceMotion ? 6 : 0)
                    .animation(playsOwnSettle ? animation : nil, value: hasEntered)
                    .allowsHitTesting(playsOwnSettle ? hasEntered : true)
                    .onAppear {
                        guard shouldAnimate, !hasEntered else { return }
                        guard playsOwnSettle else {
                            // This route owns its own local settle cue
                            // instead (never gated on hit testing); this
                            // wrapper only still needs to retire
                            // `flowPresentation` via `onFinished()` exactly
                            // once, with no animation or gating of its own.
                            hasEntered = true
                            onFinished()
                            return
                        }
                        withAnimation(animation, completionCriteria: .logicallyComplete) {
                            hasEntered = true
                        } completion: {
                            onFinished()
                        }
                    }
            }
        }

        private var animation: Animation {
            reduceMotion
                ? .easeInOut(duration: 0.17)
                : .timingCurve(0.22, 0.78, 0.24, 1, duration: 0.28)
        }
    }

    /// The pure predicate behind Settings' Remove Email blocked-status
    /// presentation (`SettingsView`, W4-H2), kept here as a `static func` so
    /// it is directly testable without instantiating a full store dependency
    /// graph — matching the existing `ParticipantVerificationView`
    /// pure-predicate pattern. Precedence: while the cold/relaunch readiness
    /// check is actively in flight, it reads as in-progress work (`.loading`);
    /// once that check has ended without establishing removal safety (W4-R2
    /// 2026-09-06 sync), it reads as this action being temporarily
    /// unavailable, not still loading (`.unavailable`) — the same kind an
    /// active reservation/request already uses; otherwise (an unresolved
    /// W3-D1 create) is exactly a mutation-outcome-uncertain state
    /// (`.uncertain`).
    static func removeEmailBlockedStatusKind(
        hasEstablishedRemovalSafety: Bool,
        isResolvingReservationStateForRemoval: Bool,
        hasActiveClaim: Bool
    ) -> CommonPlateStatusKind {
        if !hasEstablishedRemovalSafety {
            return isResolvingReservationStateForRemoval ? .loading : .unavailable
        }
        if hasActiveClaim {
            return .unavailable
        }
        return .uncertain
    }

    /// Open while a flow is running and Home or Settings — W4-H2's own
    /// entry point for Change Email — is the surface presenting it. The
    /// request and reservation screens present their own gates, so this
    /// stays scoped to exactly the two surfaces that actually start this
    /// flow: nothing pushed (Home) or Settings alone with nothing pushed
    /// past it, so a gate opened deeper in the stack still does not also
    /// raise a sheet here.
    private var isPresentingIdentityFlow: Binding<Bool> {
        Binding(
            get: {
                participantIdentityStore.flow?.purpose == .emailReplacement
                    && (path.isEmpty || path == [.settings])
            },
            set: { isPresented in
                if !isPresented { participantIdentityStore.cancelVerification() }
            }
        )
    }

    /// Applies whatever helper new-request tap is currently pending, if any.
    /// All of the decision-making — resolving `requestId` against backend
    /// truth, tap-order fencing, the recovery notices, and when the tap may
    /// finally be retired — lives in `HelperNotificationRouteDriver`, which
    /// is testable without SwiftUI; this only owns the one thing that cannot
    /// leave the view, writing `path`.
    ///
    /// A `nil` result never means Home. It means this attempt produced no
    /// navigation outcome — nothing pending, cancelled, or superseded by a
    /// later tap — and in every one of those cases leaving `path` exactly as
    /// it is, is the correct answer. A tap that was cancelled mid-attempt is
    /// still pending afterwards and gets applied by the next attempt.
    private func routePendingHelperNotification() async {
        guard participantIdentityStore.isVerified else { return }
        guard let resolvedPath = await HelperNotificationRouteDriver.routeIfNeeded(
            router: notificationRouter,
            resolver: requestStore
        ) else {
            return
        }
        path = resolvedPath
    }

    /// The reservation-warning equivalent (W3-H1): applies whatever
    /// reservation-warning notification tap is currently pending, if any. See
    /// `ReservationWarningRouteDriver` for the decision-making this only
    /// applies the result of.
    private func routePendingReservationWarning() async {
        guard participantIdentityStore.isVerified else { return }
        guard let resolvedPath = await ReservationWarningRouteDriver.routeIfNeeded(
            router: notificationRouter,
            resolver: requestStore
        ) else {
            return
        }
        path = resolvedPath
    }

    /// Applies the captured requester-fulfillment destination once. The
    /// destination performs the current R3 backend read; the push payload
    /// supplies routing context only.
    private func routePendingRequesterFulfillmentNotification() async {
        guard participantIdentityStore.isVerified else { return }
        guard let resolvedPath = await RequesterFulfillmentNotificationRouteDriver.routeIfNeeded(
            router: notificationRouter, resolver: requestStore
        ) else { return }
        path = resolvedPath
    }

    private func routePendingPickupConfirmedNotification() {
        guard participantIdentityStore.isVerified,
              let resolvedPath = notificationRouter.consumePickupConfirmedRoute() else { return }
        path = resolvedPath
    }

    /// The single place a route becomes a screen. The two helper-flow screens
    /// receive the path itself: both of them have to be able to end the flow,
    /// and neither can do that by dismissing only itself.
    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
        case .requestFood:
            // W4-R2: pushed on this same root stack (superseding the former
            // Home-owned sheet), analogous to `.settings`. `onExit` truncates
            // exactly this route via `finishPrimaryRoute`, so ordinary Back,
            // D1 "Go to Home", and the Success dwell's native dismissal all
            // return to Home the same way.
            RequestFoodEntryView(
                store: requestStore,
                screenshotProposalStore: screenshotProposalStore,
                draftSession: requestFoodDraftSession,
                identityStore: participantIdentityStore,
                verificationCoordinator: participantActionVerificationCoordinator,
                path: $path,
                onExit: { finishPrimaryRoute(.requestFood) }
            )
        case .alerts:
            AlertSignupView(
                store: alertSubscriptionStore,
                pushStore: pushSubscriptionStore,
                unsubscribeStore: participantEmailUnsubscribeStore,
                identityStore: participantIdentityStore
            )
            .navigationTitle(AlertSignupView.title)
            .navigationBarTitleDisplayMode(.inline)
        case .howCommonPlateWorks:
            HowCommonPlateWorksHubView()
        case .howRequestingWorks:
            HowCommonPlateWorksDetailView(
                title: HowCommonPlateWorksCopy.requestingDestinationTitle,
                lede: HowCommonPlateWorksCopy.requestingLede,
                steps: HowCommonPlateWorksCopy.requestingSteps,
                identifier: "how-works-requesting-detail",
                onReturnHome: returnHomeFromHowCommonPlateWorks
            )
        case .howHelpingWorks:
            HowCommonPlateWorksDetailView(
                title: HowCommonPlateWorksCopy.helpingDestinationTitle,
                lede: HowCommonPlateWorksCopy.helpingLede,
                steps: HowCommonPlateWorksCopy.helpingSteps,
                identifier: "how-works-helping-detail",
                onReturnHome: returnHomeFromHowCommonPlateWorks
            )
        case .privacySafety:
            PrivacySafetyView(
                participantIdentityStore: participantIdentityStore,
                deletionRow: participantDeletionStore.rowState,
                onDeleteAccount: { Task { await participantDeletionStore.begin() } },
                onOpenDeletion: { Task { _ = await participantDeletionStore.openExisting() } }
            )
            .task { await participantDeletionStore.reconcile() }
        case .settings:
            SettingsView(
                requestStore: requestStore,
                participantIdentityStore: participantIdentityStore,
                pushSubscriptionStore: pushSubscriptionStore,
                screenshotProposalStore: screenshotProposalStore,
                onViewActivity: { block in
                    path = EmailReplacementNavigation.path(
                        for: block,
                        activeClaim: requestStore.activeClaim,
                        ownerRequests: requestStore.ownerRequests
                    )
                }
            )
        case .support:
            SupportView()
        case .blockedStudents:
            BlockedStudentsView(
                store: requestStore,
                identityStore: participantIdentityStore
            )
        case .requestDetail(let request):
            RequestDetailView(
                request: request,
                store: requestStore,
                identityStore: participantIdentityStore,
                verificationCoordinator: participantActionVerificationCoordinator,
                path: $path
            )
        case .fulfillment(let request):
            FulfillRequestView(request: request, store: requestStore, path: $path)
        case .ownerRequest(let owned):
            OwnerRequestDetailView(store: requestStore, owner: owned, path: $path)
        case .placedOrder(let requestID):
            PlacedOrderDetailView(
                requestID: requestID,
                store: requestStore,
                identityStore: participantIdentityStore,
                path: $path
            )
        case .editRequest(let owned):
            EditRequestView(
                store: requestStore,
                screenshotProposalStore: screenshotProposalStore,
                identityStore: participantIdentityStore,
                owner: owned,
                path: $path
            )
        case .ownRequests(let requests):
            OwnRequestsListView(requests: requests, placedOrders: requestStore.placedOrders)
        case .helperContinuations:
            HelperContinuationsListView(store: requestStore)
        case .helperWaiting(let requestID):
            HelperWaitingDetailView(requestID: requestID, store: requestStore, path: $path)
        case .requestConversation(let requestID, let role):
            if requestMessaging.isEnabled {
                RequestConversationHostView(
                    requestID: requestID,
                    role: role,
                    composition: requestMessaging,
                    store: requestStore,
                    identityStore: participantIdentityStore,
                    path: $path
                )
            } else {
                ConversationUnavailableState()
            }
        }
    }

    private func returnHomeFromHowCommonPlateWorks() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            path = []
        }
    }

    /// W4-O1: discovery completes when the student successfully opens any
    /// eligible request's detail *from a Home card* while the treatment is
    /// active. The card tap records the marker; the resulting path change
    /// consumes it. Presentation-only: it reads existing board truth and
    /// writes only the local discovery record.
    private func completeHelpingDiscoveryIfEligibleRequestOpened(newPath: [AppRoute]) {
        let cardID = homeCardOpenedRequestID
        homeCardOpenedRequestID = nil
        guard HelpingDiscovery.shouldComplete(
            isPending: onboardingStore.isHelpingDiscoveryPending,
            openedFromHomeCardID: cardID,
            newPath: newPath,
            eligible: HelpingDiscovery.eligibleRequests(store: requestStore)
        ) else { return }
        onboardingStore.completeHelpingDiscovery()
    }

    private func completeOnboardingFromWelcome() {
        // Product truth changes now, independently of the presentation-only
        // Soft Brand Settle. Disabling native stack animation prevents a pop
        // from taking ownership while the overlay performs the visible exit.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            onboardingFlowCoordinator.continueFromWelcome()
            path = []
        }
    }

    private func helperSuccessPhase(
        for confirmation: FulfillmentConfirmation
    ) -> HelperSuccessProgression.Phase {
        guard let progression = helperSuccessCoordinator.progression,
              progression.confirmationID == confirmation.id else {
            return .ticket
        }
        return progression.phase
    }

    /// The one automatic Home return after a complete foreground success
    /// presentation, whatever the helper's entry point, then retirement of the
    /// presentation. The path is replaced without a native pop so Home is
    /// simply revealed as the presentation fades.
    private func installHelperSuccessHomeReturn() {
        let pathBinding = $path
        let store = requestStore
        helperSuccessCoordinator.returnHome = { confirmation in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                pathBinding.wrappedValue = AppRoute.afterHelperSuccess(from: pathBinding.wrappedValue)
            }
            withAnimation(.easeOut(duration: 0.2)) {
                store.dismissFulfillmentConfirmation(id: confirmation.id)
            }
        }
    }

    /// Request Food owns a vertical Soft Flow transition. Removing its typed
    /// route without a native pop keeps Home stable beneath that one motion.
    private func finishPrimaryRoute(_ route: AppRoute) {
        guard path.last == route else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            _ = path.removeLast()
        }
    }
}

#if DEBUG
#Preview {
    ContentView(
        configuration: .localSimulator,
        remoteNotificationRegistrar: UIKitRemoteNotificationRegistrar(),
        notificationRouter: HelperNotificationRouter()
    )
}
#endif
