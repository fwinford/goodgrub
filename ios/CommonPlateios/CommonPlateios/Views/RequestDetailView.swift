//
//  RequestDetailView.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
import SwiftUI

/// Keys the W3-H2 stale-detail eligibility `.task` so SwiftUI cancels and
/// restarts the read whenever the request changes, or whenever the
/// authoritative participant identity changes (e.g. Change Email completing
/// while this screen is open) — a result resolved for a superseded identity
/// must never be applied to the replacement one. Not `private`: shared with
/// `RequestDetailView.renderedEligibility(resolved:currentKey:)` below and
/// exercised directly by focused tests, matching this file's existing
/// pattern of testable `static func` helpers (`opensClaimedFlow`,
/// `shouldDismiss`).
struct StaleParticipationTaskKey: Equatable {
    let requestID: String
    let identity: ParticipantIdentityPresentation?
}

/// A `StaleParticipationEligibility` result, bound to the exact
/// `(requestID, verified identity)` key it was resolved for. Storing the key
/// alongside the result — rather than the result alone — is what lets
/// rendering itself, not just the async read, refuse to honor a result that
/// belongs to a principal that is no longer current: the moment
/// `identityStore.identity` changes, `RequestDetailView` recomputes the
/// current key on its very next render and this stored result stops
/// matching it, synchronously and before the replacement identity's own
/// `.task` read has even had a chance to complete.
struct ResolvedStaleParticipation: Equatable {
    let key: StaleParticipationTaskKey
    let eligibility: RequestStore.StaleParticipationEligibility
}

/// A caller-relative ownership answer bound to the exact
/// `(requestID, verified identity)` key it was resolved for (W4-H2) — the
/// direct analogue of `ResolvedStaleParticipation` above, and for the same
/// reason.
///
/// The `FoodRequest` this screen renders arrives as a navigation value, so it
/// carries whatever ownership was resolved when it was materialized. That may
/// have been an anonymous browse (`.notOwn` — correct while anonymous) or a
/// participant since replaced. Storing the key alongside the answer is what
/// lets rendering itself refuse to honor ownership belonging to a principal
/// who is no longer current.
struct ResolvedRequestOwnership: Equatable {
    let key: StaleParticipationTaskKey
    let ownership: RequestOwnership
}

/// How a claim attempt is presented to the helper. Backend codes are mapped
/// deliberately, with a fallback for anything unrecognized, per the error
/// contract in docs/system-contract.md. The stable code itself stays on
/// the request-scoped `RequestStore` event; only the copy lives here.
enum ClaimPresentationError: Equatable {
    /// HTTP 409 `REQUEST_ALREADY_CLAIMED`. Locked message.
    case alreadyClaimed
    /// Expired, out of claimable time, already placed, or missing — one calm
    /// "no longer available" register rather than four error states.
    case noLongerAvailable
    /// `REQUEST_NOT_YET_AVAILABLE`. Deliberately not folded into
    /// `noLongerAvailable`: a scheduled request that has not started yet is the
    /// opposite situation, and the helper can come back for this one.
    case notYetAvailable
    /// `PUBLIC_ACTIONS_PAUSED`.
    case publicActionsPaused
    /// `RATE_LIMITED`.
    case rateLimited
    /// The claim POST may have been applied server-side without iOS seeing the
    /// credentials. Never retried automatically.
    case ambiguous
    /// A claim on *this* request is already in flight for this helper.
    case operationInProgress
    /// A claim on a *different* request is in flight. Nothing has been started
    /// for this one and nothing is held yet — it is a short wait, not a
    /// commitment made elsewhere.
    case otherClaimInProgress
    /// A confirmed reservation on a different request is already held.
    case existingActiveClaim
    // W4-H1 removes the former `pendingPlacementAcknowledgement` case with the
    // gate it explained. A confirmed placement completes the helper
    // relationship, so there is no longer any refusal to present for it.
    /// A definitive claim failure that does not have a more specific mapping.
    case couldNotStart

    var message: String {
        switch self {
        case .alreadyClaimed:
            // Locked race-conflict copy. Must match the backend's own message
            // for HTTP 409 REQUEST_ALREADY_CLAIMED exactly.
            return RequestDetailView.alreadyClaimedNotice
        case .noLongerAvailable:
            return RequestDetailView.noLongerAvailableNotice
        case .notYetAvailable:
            return RequestDetailView.notYetAvailableNotice
        case .publicActionsPaused:
            // Single source for the backend-confirmed helper-pause sentence.
            return RequestDetailView.helperPauseNotice
        case .rateLimited:
            return "Too many attempts. Please wait a moment and try again."
        case .ambiguous:
            return "We couldn’t confirm whether your reservation succeeded. Don’t place a Grubhub order. \(AppBrand.name) can’t recover this result in the current session, and the request may disappear from the public list until an unresolved reservation expires."
        case .operationInProgress:
            return "You’re already starting to help with this request."
        case .otherClaimInProgress:
            return RequestDetailView.otherClaimInProgressTitle
                + ". " + RequestDetailView.otherClaimInProgressNotice
        case .existingActiveClaim:
            return "You’re already helping with another request. Finish that one or wait for its reservation to end."
        case .couldNotStart:
            return "We couldn’t start helping with this request. Please try again in a moment."
        }
    }

    static func map(_ error: Error) -> ClaimPresentationError {
        guard let serviceError = error as? RequestServiceError else {
            return .couldNotStart
        }

        switch serviceError {
        case .notFound:
            return .noLongerAvailable
        case .serverError(let code, _):
            switch code {
            case ClaimErrorCode.requestAlreadyClaimed:
                return .alreadyClaimed
            case ClaimErrorCode.requestExpired,
                 ClaimErrorCode.requestWithdrawn,
                 ClaimErrorCode.requestInsufficientTime,
                 ClaimErrorCode.requestAlreadyPlaced,
                 ClaimErrorCode.requestNotFound,
                 // W3-H2: a stale Reserve tap on a request this participant
                 // already successfully held once before. Reuses this exact
                 // presentation — no new copy — per the accepted
                 // marketplace-presentation contract.
                 ClaimErrorCode.requestAlreadyParticipated:
                return .noLongerAvailable
            case ClaimErrorCode.requestNotYetAvailable:
                return .notYetAvailable
            case ClaimErrorCode.publicActionsPaused:
                return .publicActionsPaused
            case ClaimErrorCode.rateLimited:
                return .rateLimited
            default:
                // Includes INVALID_REQUEST_ID and other definitive codes that
                // do not have a specific helper action. Claim INTERNAL_FAILURE
                // is translated to ambiguousClaimOutcome before this mapping.
                return .couldNotStart
            }
        case .ambiguousClaimOutcome:
            return .ambiguous
        case .operationInProgress:
            return .operationInProgress
        case .otherClaimInProgress:
            return .otherClaimInProgress
        case .existingActiveClaim:
            return .existingActiveClaim
        default:
            return .couldNotStart
        }
    }
}

struct RequestDetailView: View {
    /// Shown when claiming is refused with `PUBLIC_ACTIONS_PAUSED`.
    static let helperPauseNotice = "Helping with this meal is temporarily unavailable."

    /// Locked race-conflict copy, identical to the backend's HTTP 409
    /// `REQUEST_ALREADY_CLAIMED` message.
    static let alreadyClaimedNotice = "Someone else just started helping with this request."

    /// Shared "unavailable" register for expired, out-of-time, already-placed,
    /// and missing requests. Matches the backend's own `REQUEST_EXPIRED` message.
    static let noLongerAvailableNotice = "This request is no longer available."

    /// Matches the backend's own `REQUEST_NOT_YET_AVAILABLE` message. Reachable
    /// only for a scheduled request opened before its start — the public list
    /// does not carry one — so it says what to do rather than treating it as a
    /// failure.
    static let notYetAvailableNotice = "This request is not available to help with yet."

    /// Shown when a helper new-request notification tap could not be
    /// resolved against current backend truth (transport, timeout, server,
    /// or decoding failure). Never used when the backend has confirmed the
    /// request is actually gone — that is `noLongerAvailableNotice`.
    static let temporarilyUnavailableNotice = "This request is temporarily unavailable. Try again."

    /// W4-H2: shown in place of Reserve on the requester's own request.
    static let ownRequestNotice = "This is your request. You can’t help with your own request."

    let request: FoodRequest
    @ObservedObject var store: RequestStore
    /// Observed, not owned. Browsing this screen needs no identity; reserving
    /// does, and the gate below has to see the same verified identity every
    /// other participant action does.
    @ObservedObject var identityStore: ParticipantIdentityStore
    @ObservedObject var verificationCoordinator:
        ParticipantActionVerificationCoordinator
    @Binding var path: [AppRoute]

    /// The last W3-H2 stale-detail eligibility result the `.task` below
    /// actually resolved, bound to the exact key it was resolved for. `nil`
    /// before any read completes. Never read directly by the body — see
    /// `staleParticipationEligibility` below, which is what actually gates
    /// rendering and is what refuses to honor a result once it no longer
    /// matches the current request/identity key.
    @State private var resolvedStaleParticipation: ResolvedStaleParticipation?

    /// The last W4-H2 ownership answer resolved under the current authority,
    /// bound to its key. `nil` until an authoritative detail read completes.
    @State private var resolvedOwnership: ResolvedRequestOwnership?

    /// The key in effect when this screen's `request` navigation value was
    /// materialized, captured once on appearance. Its ownership is honored
    /// only while this key is still current.
    @State private var materializedOwnershipKey: StaleParticipationTaskKey?

    /// A helper tapped Help before verifying, and verification has since
    /// succeeded. The claim may not simply proceed on the anonymous session's
    /// `.notOwn`: ownership and participation must first be re-established for
    /// the participant that now exists. This records the intent so the flow
    /// continues once they are — or stops, if the newly verified participant
    /// turns out to be this request's own requester.
    @State private var isAwaitingPostVerificationClaim = false

    /// The rendered W4-H2 ownership for this screen — see
    /// `renderedOwnership(resolved:materializedKey:materializedOwnership:currentKey:)`.
    private var currentOwnership: RequestOwnership {
        Self.renderedOwnership(
            resolved: resolvedOwnership,
            materializedKey: materializedOwnershipKey,
            materializedOwnership: request.ownership,
            currentKey: staleParticipationKey
        )
    }

    /// This screen's current W3-H2 stale-detail eligibility key: exactly the
    /// request and the verified participant identity currently in effect.
    /// Recomputed on every render, so a change to `identityStore.identity`
    /// (e.g. Change Email completing) invalidates a stored result the very
    /// next render — synchronously, without waiting for a new `.task` read.
    private var staleParticipationKey: StaleParticipationTaskKey {
        StaleParticipationTaskKey(requestID: request.id, identity: identityStore.identity)
    }

    /// The rendered W3-H2 stale-detail eligibility: `.unresolved` — never
    /// actionable — unless `resolvedStaleParticipation` was resolved for
    /// exactly the current `staleParticipationKey`. This is what keeps a
    /// result resolved for one verified principal from ever exposing Reserve
    /// under a different one, even transiently: no asynchronous coordination
    /// is required for correctness here, because this check runs on every
    /// render, including the very first one after identity changes and
    /// before its own `.task` read has had a chance to complete. Only a
    /// confirmed `.eligible` answer, for the current key, ever exposes
    /// Reserve; a failed, superseded, or mismatched-key read reads as
    /// `.unresolved` rather than being treated as permission.
    /// `claimRequest`'s own conditional grant remains the authoritative
    /// backstop regardless of this state.
    private var staleParticipationEligibility: RequestStore.StaleParticipationEligibility {
        Self.renderedEligibility(resolved: resolvedStaleParticipation, currentKey: staleParticipationKey)
    }

    /// The pure identity-key gate itself, factored out of the computed
    /// property above so it can be exercised directly by focused tests
    /// (`RequestDetailStaleParticipationTests.swift`) rather than only
    /// through source inspection — the same testable-`static-func` pattern
    /// this file already uses for `opensClaimedFlow` and `shouldDismiss`.
    /// `.unresolved` whenever `resolved` is `nil` or was resolved for a
    /// different key than `currentKey`; otherwise the resolved eligibility
    /// itself.
    static func renderedEligibility(
        resolved: ResolvedStaleParticipation?,
        currentKey: StaleParticipationTaskKey
    ) -> RequestStore.StaleParticipationEligibility {
        guard let resolved, resolved.key == currentKey else {
            return .unresolved
        }
        return resolved.eligibility
    }

    /// The W3-H2 stale-detail action boundary: `startClaim()` below must
    /// consult this — not merely trust that an already-materialized Reserve
    /// button implies permission — before starting verification or a claim.
    /// Deliberately calls `renderedEligibility(resolved:currentKey:)` above,
    /// not a separately reimplemented comparison: the render gate and the
    /// action gate must always agree, and `currentKey` is derived fresh from
    /// live state at the moment of the call, not a value captured when the
    /// button was drawn. This is what makes a button materialized for
    /// principal A harmless the instant identity changes to principal B —
    /// SwiftUI's next render, `.task` cancellation, and any async read are
    /// all irrelevant to this property; only the synchronous key comparison
    /// at the moment of the tap is.
    static func canStartClaim(
        resolved: ResolvedStaleParticipation?,
        currentKey: StaleParticipationTaskKey
    ) -> Bool {
        renderedEligibility(resolved: resolved, currentKey: currentKey) == .eligible
    }

    /// The W4-H2 ownership gate, in the same shape as
    /// `renderedEligibility(resolved:currentKey:)` and for the same reason.
    ///
    /// The materialized `request.ownership` is honored only while the identity
    /// it was resolved under is still current. That is what preserves the
    /// accepted anonymous browse-then-verify funnel — an anonymous browser
    /// keeps seeing `.notOwn` and can still tap Help — while guaranteeing that
    /// the same `.notOwn` cannot survive into the verified authority that
    /// replaces it. Anything else is `.unresolved` until an authoritative
    /// reload answers for whoever is current.
    static func renderedOwnership(
        resolved: ResolvedRequestOwnership?,
        materializedKey: StaleParticipationTaskKey?,
        materializedOwnership: RequestOwnership,
        currentKey: StaleParticipationTaskKey
    ) -> RequestOwnership {
        if let resolved, resolved.key == currentKey { return resolved.ownership }
        if let materializedKey, materializedKey == currentKey { return materializedOwnership }
        return .unresolved
    }

    /// The action-boundary form of the gate above: only an ownership
    /// established as `.notOwn` for the identity current *at the moment of
    /// the call* may reach the claim mutation. `.own` and `.unresolved` both
    /// refuse. The backend's atomic self-claim guard remains the final
    /// mutation authority; this stops the client from ever attempting it.
    static func canClaimForOwnership(
        resolved: ResolvedRequestOwnership?,
        materializedKey: StaleParticipationTaskKey?,
        materializedOwnership: RequestOwnership,
        currentKey: StaleParticipationTaskKey
    ) -> Bool {
        renderedOwnership(
            resolved: resolved,
            materializedKey: materializedKey,
            materializedOwnership: materializedOwnership,
            currentKey: currentKey
        ) == .notOwn
    }

    /// The single rule for entering the claimant-only flow: a confirmed claim
    /// for *this* request exists in memory. There is no loading, optimistic, or
    /// error path into it.
    static func opensClaimedFlow(
        activeClaim: ActiveClaimPresentation?,
        requestID: String
    ) -> Bool {
        activeClaim?.requestID == requestID
    }

    /// The Helping route for the active claim: always the active claim's own
    /// request, never this screen's pre-claim value-type copy. (A confirmed
    /// claim on *this* request replaces the screen through
    /// `AppRoute.enteringHeldRequest`, which applies the same rule.) Any field
    /// confirmed or set at claim time — W3-C1's meal-swipe quantity included —
    /// must come from here, not from a value captured before the claim existed.
    static func fulfillmentDestination(activeClaim: ActiveClaimPresentation) -> AppRoute {
        .fulfillment(activeClaim.request)
    }

    static func shouldDismiss(
        for notice: ClaimUnavailableNotice?,
        requestID: String
    ) -> Bool {
        notice?.requestID == requestID
    }

    /// A request detail follows its own newest queued terminal event, not the
    /// FIFO head Active Requests presents. The head may belong to an unrelated
    /// request whose notice was produced earlier and is still unacknowledged.
    private var matchingClaimUnavailableNotice: ClaimUnavailableNotice? {
        store.claimUnavailableNotice(for: request.id)
    }

    /// Suppressed once the helper is being sent back to Active Requests: the
    /// notice belongs on the list they land on, not on the screen leaving view.
    private var inlineClaimError: ClaimPresentationError? {
        guard matchingClaimUnavailableNotice == nil,
              let claimError = store.claimError(for: request.id) else {
            return nil
        }
        return ClaimPresentationError.map(claimError)
    }

    var body: some View {
        ScrollView {
            if store.updatedSinceNotificationRequestID == request.id {
                // W4-R5: the backend verified this request changed since the
                // notification that opened it was sent.
                CommonPlateInlineStatus(
                    kind: .success,
                    message: EditRequestPresentation.updatedSinceNotificationNotice
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, CommonPlateStyle.Metrics.homeContentColumnInset)
                .padding(.top, CommonPlateStyle.Spacing.s)
                .accessibilityIdentifier("request-detail-updated-notice")
                .onAppear {
                    // Spoken once, because the notice leaves on its own timer.
                    AccessibilityNotification.Announcement(
                        EditRequestPresentation.updatedSinceNotificationNotice
                    ).post()
                    // Shown once for the tap that earned it.
                    Task {
                        try? await Task.sleep(for: .seconds(6))
                        store.acknowledgeUpdatedSinceNotification(requestID: request.id)
                    }
                }
            }
            requestSummary
        }
        .modifier(RequestDetailBlockMenu(
            store: store,
            requestID: request.id,
            isOffered: ParticipantBlockAvailability.requestDetailOffersBlock(
                ownership: currentOwnership,
                hasVerifiedIdentity: identityStore.identity != nil,
                holdsReservationForRequest: store.activeClaim?.requestID == request.id
            ),
            onBlocked: leaveAfterBlock,
            isReportOffered: ParticipantReportAvailability.requestDetailOffersReport(
                requestStatus: request.status,
                ownership: currentOwnership,
                hasVerifiedIdentity: identityStore.identity != nil,
                holdsReservationForRequest: store.activeClaim?.requestID == request.id
            ) && !store.hasReportedRequest(requestID: request.id),
            onReport: {
                store.presentReportPopup(
                    requestID: request.id,
                    returnsHome: false,
                    offersBlockAfter: ParticipantBlockAvailability.requestDetailOffersBlock(
                        ownership: currentOwnership,
                        hasVerifiedIdentity: identityStore.identity != nil,
                        holdsReservationForRequest: store.activeClaim?.requestID == request.id
                    )
                )
            }
        ))
        .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
        // W4-H1 (Figma 357:1085): the helper action lives in a pinned bottom
        // area beneath the flat request summary. Every gate below is
        // unchanged; only its placement moved. The surface reuses Home's
        // production `Request a Meal` bottom-action geometry
        // (`HomeExchangeView.requestMealButton`): the shared
        // `homeContentColumnInset` column, the major primary action style, a
        // `Spacing.xl` canvas fade above, and `.safeAreaInset` as the only
        // bottom clearance.
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
                if Self.opensClaimedFlow(activeClaim: store.activeClaim, requestID: request.id) {
                    // W4-H1: Request Detail is pre-claim only. A request this
                    // helper holds is never presented here — the `.onChange`
                    // below replaces this screen with Helping — so there is no
                    // continuation state, reservation control, or claim action
                    // to render for it, even for the frame before that lands.
                    EmptyView()
                } else if currentOwnership == .own {
                    // W4-H2: authoritative backend ownership truth. The owner
                    // of a request can never expose or execute Reserve/Help
                    // for it — the backend's atomic self-claim guard is the
                    // authority; this is defense-in-depth presentation.
                    Text(Self.ownRequestNotice)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("own-request-notice")
                } else if currentOwnership == .unresolved {
                    // W4-H2 fail-closed: no current-authority server evidence
                    // establishes whether this is the caller's own request —
                    // the response carried no ownership metadata, or the
                    // authority that produced it is no longer current. That is
                    // never permission to Reserve. Nothing renders here rather
                    // than inventing new "checking…" copy, exactly as the
                    // `.unresolved` participation case below already does; the
                    // `.task` that re-resolves on identity/request change
                    // settles it.
                    EmptyView()
                } else {
                    switch staleParticipationEligibility {
                    case .unresolved:
                        // Not yet known, or a failed/superseded read — never
                        // treated as permission to Reserve. Nothing renders
                        // here rather than inventing new "checking…" copy;
                        // the `.task` below re-resolves this whenever the
                        // request or the authoritative identity changes.
                        EmptyView()
                    case .alreadyParticipated:
                        // W3-H2 stale detail Reserve truth: this verified
                        // participant already successfully held this exact
                        // request once before and can never reacquire it.
                        // Reuses the existing refused-reservation copy — no
                        // new explanatory text — per the accepted
                        // marketplace-presentation contract.
                        Text(Self.noLongerAvailableNotice)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("claim-error")
                    case .eligible:
                        claimSection
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CommonPlateStyle.Metrics.homeContentColumnInset)
            .background(CommonPlateStyle.Color.baseCanvas)
            .padding(.top, CommonPlateStyle.Spacing.xl)
            .background(alignment: .top) {
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
            }
        }
        .navigationTitle("Request")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: staleParticipationKey) {
            // The key is captured before the asynchronous read starts, and
            // re-derived (not reused) after it completes: `identityStore` is
            // a live reference, so re-reading `staleParticipationKey` below
            // reflects whatever is authoritative *now*, not what it was when
            // this task began. A result is only ever written for the exact
            // key it was resolved for.
            let key = staleParticipationKey
            let result = await store.resolveStaleParticipationEligibility(for: request.id)
            guard !Task.isCancelled, key == staleParticipationKey else { return }
            resolvedStaleParticipation = ResolvedStaleParticipation(key: key, eligibility: result)
            continuePostVerificationClaimIfReady()
        }
        // W4-H2 ownership, resolved on exactly the same key and with exactly
        // the same fencing discipline as the participation read above. This is
        // what re-establishes "is this my own request?" for the participant
        // who is current now — after a verification, a Change Email, or a
        // Remove Email — rather than carrying an answer resolved for someone
        // else. A result is written only for the key it was resolved for, so a
        // late answer for a superseded identity can never become current
        // truth.
        .task(id: staleParticipationKey) {
            // Ownership is only knowable for a participant. Leaving this
            // unresolved while anonymous would suppress Reserve for every
            // anonymous browser and break the accepted browse-then-verify
            // funnel; the materialized anonymous `.notOwn` already covers
            // that case, and stops applying the moment identity changes.
            guard identityStore.identity != nil else { return }
            let key = staleParticipationKey
            let ownership = await store.resolveOwnership(requestID: request.id)
            guard !Task.isCancelled, key == staleParticipationKey else { return }
            resolvedOwnership = ResolvedRequestOwnership(key: key, ownership: ownership)
            continuePostVerificationClaimIfReady()
        }
        .onAppear {
            // The identity this screen's navigation value was materialized
            // under. Captured once; its ownership is honored only while this
            // key is still current.
            if materializedOwnershipKey == nil {
                materializedOwnershipKey = staleParticipationKey
            }
        }
        // Confirmed claim success is the only thing that opens the flow, and it
        // opens it by rewriting the path rather than by flipping a presentation
        // flag this screen would then have to keep in sync with store state.
        //
        // W4-H1 active-reservation navigation: Helping *replaces* this detail
        // (`AppRoute.enteringHeldRequest`), so Back from Helping returns to
        // whatever preceded the detail — normally Home — never to a stale
        // detail for a request the helper now holds. `initial: true` applies
        // the same rule if this screen is ever opened for an already-held
        // request, so no entry can present one here. Closing the flow belongs
        // to the claimant screen itself: a manual Back leaves `activeClaim`
        // untouched and the reservation survives the navigation.
        .onChange(of: store.activeClaim?.requestID, initial: true) { _, _ in
            if let activeClaim = store.activeClaim,
               Self.opensClaimedFlow(activeClaim: activeClaim, requestID: request.id),
               path.contains(.requestDetail(request)) {
                path = AppRoute.enteringHeldRequest(activeClaim, from: path)
            }
        }
        // A stale detail screen must never outlive the backend's verdict. The
        // whole helper flow is unwound, not just this level: the claimant screen
        // this detail opened may still be above it, and the notice belongs on
        // the list the helper lands on.
        // A sheet, so this screen stays mounted and the helper returns to the
        // same request they were looking at.
        .sheet(isPresented: isPresentingVerification) {
            ParticipantVerificationView(
                store: identityStore,
                cancel: { verificationCoordinator.helperCancelled(requestID: request.id) }
            )
        }
        .onChange(of: identityStore.identity) { previous, current in
            guard case .claim(let requestID)? =
                    verificationCoordinator.helperIdentityDidChange(
                        requestID: request.id,
                        from: previous,
                        to: current,
                        path: path,
                        claimAlreadyActive: Self.opensClaimedFlow(
                            activeClaim: store.activeClaim,
                            requestID: request.id
                        )
                    ),
                  requestID == request.id else {
                return
            }
            // The coordinator clears before returning the exact request ID.
            //
            // W4-H2: this is the same-principal reverification hole. The
            // helper may have browsed anonymously — where `.notOwn` was a
            // correct reading — and then verified as the very participant who
            // owns this request. Claiming straight from that stale anonymous
            // conclusion asks the backend to let someone reserve their own
            // meal. `currentOwnership` is already `.unresolved` on this render
            // (the identity key just changed), so record the intent and let
            // the re-resolution below decide.
            isAwaitingPostVerificationClaim = true
        }
        .onChange(of: path) { _, currentPath in
            verificationCoordinator.helperNavigationChanged(
                requestID: request.id,
                path: currentPath
            )
        }
        .onChange(of: matchingClaimUnavailableNotice?.id) { _, noticeID in
            if let noticeID,
               let notice = matchingClaimUnavailableNotice,
               notice.id == noticeID,
               Self.shouldDismiss(for: notice, requestID: request.id) {
                path = AppRoute.returningHome(from: path)
            }
        }
        .onDisappear {
            verificationCoordinator.helperDisappeared(requestID: request.id)
        }
    }

    /// Open exactly while the identity store has a flow running. Dismissing
    /// goes through `cancelVerification()`, so an abandoned flow is abandoned in
    /// one place — and abandoning it reserves nothing.
    private var isPresentingVerification: Binding<Bool> {
        Binding(
            get: {
                verificationCoordinator.isPresentingClaimVerification(
                    requestID: request.id
                )
            },
            set: { isPresented in
                if !isPresented {
                    verificationCoordinator.helperSheetDismissed(
                        requestID: request.id
                    )
                }
            }
        )
    }

    /// The helper's own requester was blocked, so this request is unreachable:
    /// navigation resets to Home (not Active Requests).
    private func leaveAfterBlock() {
        path = AppRoute.afterParticipantBlock(from: path)
    }

    /// The approved flat H1 request summary (Figma `Helper / Request Summary`,
    /// 360:1104): the commitment first — meal swipes with the request's timing
    /// — then dining location, then the meal request. No card treatment.
    private var requestSummary: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                RequestDetailEyebrow(text: "Meal swipes")
                // V1 meal-swipe requirement (W3-C1), shown before the helper
                // action so the exact requirement is known before committing.
                Text(RequestCardView.quantityText(for: request))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.primary)
                    .accessibilityIdentifier("request-meal-swipes")
                Text(request.requestExpiresAtLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("request-expires-at")
            }
            .accessibilityElement(children: .combine)

            RequestDetailDivider()
                .padding(.top, 18)
                .padding(.bottom, 22)

            VStack(alignment: .leading, spacing: 7) {
                RequestDetailEyebrow(text: "Dining location")
                Text(request.diningSpot.name)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                if let address = request.diningSpot.address {
                    Text(address)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            RequestDetailDivider()
                .padding(.vertical, 23)

            // One labelled row per meal so each swipe maps to exactly one meal,
            // matching the Helping screen (`Meal 1`, `Meal 2`, …).
            let meals = Self.mealRows(for: request)
            if !meals.isEmpty {
                ForEach(Array(meals.enumerated()), id: \.offset) { index, meal in
                    if index > 0 {
                        RequestDetailDivider()
                            .padding(.vertical, 18)
                    }
                    RequestMealView(
                        entry: RequestMealEntry(label: meal.label, name: meal.name, details: meal.details),
                        density: .detail
                    )
                    .accessibilityIdentifier("request-meal-\(index + 1)")
                }
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    RequestDetailEyebrow(text: "Meal request")
                    Text(request.resource.orderDetails ?? request.foodDescription)
                        .font(.callout)
                        .foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CommonPlateStyle.Metrics.settingsPageInset)
        .padding(.top, 40)
        .padding(.bottom, CommonPlateStyle.Spacing.l)
    }

    @ViewBuilder
    private var claimSection: some View {
        let inlineClaimError = self.inlineClaimError

        if let inlineClaimError {
            Text(inlineClaimError.message)
                .foregroundStyle(
                    inlineClaimError == .publicActionsPaused
                        ? Color.secondary
                        : Color.red
                )
                .accessibilityIdentifier("claim-error")
        }

        // Rather than leave the helper tapping an action that can only be
        // refused, send them to the reservation that is blocking this one.
        if inlineClaimError == .existingActiveClaim, let activeClaim = store.activeClaim {
            // The claimant screen this pushes sits on top of a *different*
            // request's detail. Leaving it truncates the path back to Active
            // Requests, so both levels come off at once and the helper is not
            // returned to a stale detail for a request they never claimed —
            // the same exit the other two entry points get.
            NavigationLink(value: Self.fulfillmentDestination(activeClaim: activeClaim)) {
                Text(Self.goToActiveReservationTitle)
                    .frame(maxWidth: .infinity)
            }
            .commonPlateMajorSecondaryAction()
            .accessibilityIdentifier("go-to-active-reservation")
        }

        if Self.showsPauseRecoveryAction(for: inlineClaimError) {
            Button {
                startClaim()
            } label: {
                if store.isClaiming(requestID: request.id) {
                    HStack {
                        ProgressView()
                        Text("Reserving…")
                    }
                } else {
                    Text(Self.pauseRecoveryActionTitle)
                }
            }
            .disabled(store.isClaiming(requestID: request.id))
            .accessibilityIdentifier("claim-pause-recovery")
        }

        // The ordinary action stays withdrawn for a confirmed pause because its
        // accepted recovery is named separately above. An unconfirmed claim also
        // withdraws it because the POST may already have been applied.
        if !RestrictedAccountPresentation.offersNewClaim(isRestricted: store.isParticipantRestricted) {
            Text(RestrictedAccountPresentation.helpingNotice)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("claim-restricted-notice")
        } else if Self.showsClaimAction(for: inlineClaimError) {
            // W4-H1 physical acceptance: no explanatory reservation copy sits
            // above `Start helping`. W4-H1a (Faith D-A2): that includes the
            // retired verification prerequisite note — there is no replacement
            // paragraph. Verification itself is unchanged: an unverified helper
            // still taps `Start helping`, which enters the existing verification
            // flow before any claim is made (see `startClaim`).

            Button {
                startClaim()
            } label: {
                if store.isClaiming(requestID: request.id) {
                    HStack {
                        ProgressView()
                        Text("Reserving…")
                    }
                } else {
                    Text(Self.claimActionTitle)
                }
            }
            // W4-H1: the same major primary action Home's `Request a Meal`
            // uses, so the two pinned CTAs share height, radius, and width.
            .commonPlateMajorPrimaryAction()
            // Request-scoped: an in-flight claim on another request must
            // not silently grey out this one. The store's own mutex
            // stays authoritative and refuses the duplicate with
            // `operationInProgress`, which explains itself in copy
            // rather than leaving a dead control on screen.
            .disabled(store.isClaiming(requestID: request.id))
            .accessibilityIdentifier("claim-action")
        }
    }

    struct MealRow: Equatable {
        let label: String
        let name: String
        let details: String?
    }

    /// Meal Exchange requests list each meal under its own label; a single meal
    /// keeps the `Meal request` label. Other requests return no rows and fall
    /// back to their order details.
    static func mealRows(for request: FoodRequest) -> [MealRow] {
        RequestMealEntry.entries(for: request).map {
            MealRow(label: $0.label, name: $0.name, details: $0.details)
        }
    }

    /// Locked action title (W4-H1 `Start helping`): tapping it claims
    /// immediately, with no confirmation step in between.
    static let claimActionTitle = "Start helping"

    /// Re-entry for the *other* request whose reservation is blocking this one.
    static let goToActiveReservationTitle = "Go to your current request"

    /// A claim already in flight for a different request. The action stays on
    /// screen: unlike a held reservation this clears itself in a moment, so the
    /// helper is asked to wait rather than sent somewhere else.
    static let otherClaimInProgressTitle = "Please wait"
    static let otherClaimInProgressNotice =
        "We’re still reserving another request. Try this one again in a moment."

    static let pauseRecoveryActionTitle = "Check again"

    static func showsPauseRecoveryAction(for error: ClaimPresentationError?) -> Bool {
        error == .publicActionsPaused
    }

    /// The claim action is withheld only where offering it would be untruthful:
    /// a paused backend uses its explicit recovery action instead, an unconfirmed
    /// claim may already have succeeded, and an existing reservation elsewhere
    /// makes this claim impossible until that one ends.
    ///
    /// W4-H1: a confirmed placement is deliberately absent from this list. The
    /// helper relationship it ended is complete, so it withholds nothing.
    static func showsClaimAction(for error: ClaimPresentationError?) -> Bool {
        error != .publicActionsPaused
            && error != .ambiguous
            && error != .existingActiveClaim
    }

    private func startClaim() {
        // W3-H2 stale-detail action boundary: an already-materialized Reserve
        // button is not itself permission. Re-derives the current key and
        // re-checks it against whatever was actually resolved, at the exact
        // moment of the tap — synchronously, independent of whether SwiftUI
        // has committed a re-render since identity last changed. A button
        // drawn for a principal who has since been replaced (Change Email
        // completing) becomes a no-op the instant that replacement happens,
        // not merely once the next render or `.task` catches up.
        guard Self.canStartClaim(resolved: resolvedStaleParticipation, currentKey: staleParticipationKey) else {
            return
        }

        // The helper gate. Nothing is reserved and no request is sent for an
        // unverified helper: the reservation would be refused by the backend
        // anyway, and taking a real student's meal out of everyone else's reach
        // is not something to attempt on an identity that does not exist yet.
        guard identityStore.isVerified else {
            _ = verificationCoordinator.beginClaim(
                requestID: request.id,
                path: path
            )
            return
        }
        performClaim()
    }

    /// The last gate before the claim mutation. Deliberately re-derives both
    /// gates from live state rather than trusting that an already-materialized
    /// Reserve button, or an earlier UI path, implies permission.
    private func performClaim() {
        guard Self.canClaimForOwnership(
            resolved: resolvedOwnership,
            materializedKey: materializedOwnershipKey,
            materializedOwnership: request.ownership,
            currentKey: staleParticipationKey
        ) else {
            // `.own` or `.unresolved`. No request is sent: the backend would
            // refuse a self-claim anyway, and an unresolved answer is not
            // permission. The owner treatment renders instead.
            isAwaitingPostVerificationClaim = false
            return
        }
        isAwaitingPostVerificationClaim = false
        Task {
            // The store owns duplicate-submit protection and error state; a
            // rejected duplicate never reaches the network.
            try? await store.claim(requestID: request.id)
        }
    }

    /// Resumes a Help tap that was interrupted by verification, once — and
    /// only once — ownership and participation have both been re-established
    /// for the participant who now exists.
    private func continuePostVerificationClaimIfReady() {
        guard isAwaitingPostVerificationClaim else { return }
        switch currentOwnership {
        case .unresolved:
            // Still waiting on an authoritative answer; keep the intent.
            return
        case .own:
            // The newly verified participant owns this request. The flow ends
            // here — no claim is attempted, and the owner treatment renders.
            isAwaitingPostVerificationClaim = false
        case .notOwn:
            guard Self.canStartClaim(
                resolved: resolvedStaleParticipation,
                currentKey: staleParticipationKey
            ) else { return }
            performClaim()
        }
    }
}

/// A flat request-summary label (Figma eyebrow): uppercase, tracked, secondary.
private struct RequestDetailEyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

private struct RequestDetailDivider: View {
    var body: some View {
        Rectangle()
            .fill(CommonPlateStyle.Color.requestCardBorder)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}
