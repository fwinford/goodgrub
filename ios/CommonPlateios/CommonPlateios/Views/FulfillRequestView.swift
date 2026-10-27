//
//  FulfillRequestView.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
import PhotosUI
import SwiftUI
import UIKit

/// Copy for a failed extension attempt. The reservation itself is never
/// shortened by a failure, and none of these states offer an automatic retry —
/// only one extension is ever granted, so a second attempt could only be
/// refused or double-counted.
enum ClaimExtensionPresentationError: Equatable {
    /// `CLAIM_EXTENSION_INSUFFICIENT_TIME` — a full five minutes does not fit
    /// before the request's own expiration. Partial extensions do not exist.
    case insufficientTime
    /// `CLAIM_EXTENSION_ALREADY_USED`.
    case alreadyUsed
    /// `PUBLIC_ACTIONS_PAUSED`.
    case publicActionsPaused
    /// `RATE_LIMITED`.
    case rateLimited
    /// The extension may or may not have been applied server-side, so the
    /// earlier known deadline is kept.
    case ambiguous
    /// `INTERNAL_FAILURE`, transport loss before submission, or an unmapped code.
    case couldNotExtend

    var message: String {
        switch self {
        case .insufficientTime:
            return "Five more minutes weren’t added because there isn’t enough time left on this request. Work from the reservation time shown above."
        case .alreadyUsed:
            return "Another extension wasn’t added. Work from the reservation time shown above."
        case .publicActionsPaused:
            return "The extension wasn’t added because helping is temporarily unavailable. Work from the reservation time shown above."
        case .rateLimited:
            return "The extension wasn’t added. Work from the reservation time shown above."
        case .ambiguous:
            return "We couldn’t confirm the extra time. Work from the reservation time shown above."
        case .couldNotExtend:
            return "We couldn’t add more time. Work from the reservation time shown above."
        }
    }

    /// Returns `nil` for failures the store resolves by ending the flow
    /// entirely (expired claim, invalid token, request gone) — those are
    /// announced on Active Requests, not on a screen that is being dismissed.
    static func map(_ error: RequestServiceError?) -> ClaimExtensionPresentationError? {
        guard let error else {
            return nil
        }

        switch error {
        case .serverError(let code, _):
            switch code {
            case ClaimErrorCode.claimExtensionInsufficientTime:
                return .insufficientTime
            case ClaimErrorCode.claimExtensionAlreadyUsed:
                return .alreadyUsed
            case ClaimErrorCode.publicActionsPaused:
                return .publicActionsPaused
            case ClaimErrorCode.rateLimited:
                return .rateLimited
            case ClaimErrorCode.claimExpired,
                 ClaimErrorCode.invalidClaimToken,
                 ClaimErrorCode.requestNotClaimed,
                 ClaimErrorCode.requestAlreadyPlaced,
                 ClaimErrorCode.requestExpired,
                 ClaimErrorCode.requestNotFound:
                return nil
            default:
                return .couldNotExtend
            }
        case .ambiguousExtensionOutcome:
            return .ambiguous
        default:
            return .couldNotExtend
        }
    }
}

/// The choices offered for the Helping page's required `Pickup ETA`.
///
/// This is a presentation control over an unchanged backend contract: `eta` is
/// still a required free-form string on `POST /api/request/:id/fulfill`, and the
/// selected choice encodes into it verbatim. Same text both ways on purpose —
/// the student reads this value in the order-details email, so what the helper
/// picked is exactly what the student is told.
enum FulfillmentReadyTime: String, CaseIterable, Identifiable, Hashable {
    case asap
    case fifteenMinutes
    case thirtyMinutes
    case fortyFiveMinutes
    case sixtyMinutes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .asap:
            return "ASAP"
        case .fifteenMinutes:
            return "15 minutes"
        case .thirtyMinutes:
            return "30 minutes"
        case .fortyFiveMinutes:
            return "45 minutes"
        case .sixtyMinutes:
            return "60 minutes"
        }
    }

    /// What is sent as the backend `eta` field.
    var etaValue: String { label }

    /// The option a stored `eta` string came from, or nil if it was not one of
    /// these choices — a request placed before this control existed can carry
    /// any free text, and that must not be silently rewritten into a choice.
    static func option(forETA eta: String) -> FulfillmentReadyTime? {
        let trimmed = eta.trimmingCharacters(in: .whitespacesAndNewlines)
        return allCases.first {
            $0.etaValue.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

}

/// Copy for a failed explicit release (W3-H1). Release is always safe to
/// retry — a repeat of an already-ended claim is refused, never duplicated —
/// so none of these states end the flow on their own; the reservation stays
/// exactly as it was and the helper may try again.
enum ReleasePresentationError: Equatable {
    case publicActionsPaused
    case rateLimited
    case couldNotRelease

    var message: String {
        switch self {
        case .publicActionsPaused:
            return "The reservation wasn’t released because helping is temporarily unavailable."
        case .rateLimited:
            return "Too many attempts. Please wait a moment and try again."
        case .couldNotRelease:
            return "We couldn’t release this reservation right now. Please try again."
        }
    }

    static func map(_ error: RequestServiceError?) -> ReleasePresentationError? {
        guard let error else { return nil }
        switch error {
        case .serverError(let code, _):
            switch code {
            case ClaimErrorCode.publicActionsPaused:
                return .publicActionsPaused
            case ClaimErrorCode.rateLimited:
                return .rateLimited
            default:
                return .couldNotRelease
            }
        default:
            return .couldNotRelease
        }
    }
}

enum FulfillmentPresentationError: Equatable {
    case invalidDetails
    case rateLimited
    case temporarilyUnavailable
    case couldNotRecord

    var message: String {
        switch self {
        case .invalidDetails:
            // The envelope has no field attribution. Ask the helper to recheck
            // both locally validated fields and never suggest placing another
            // external order.
            return "We couldn’t save these details. Check the order number, then tap “Finish helping” again. Don’t place another Grubhub order."
        case .rateLimited:
            return "Too many tries. Wait a moment, then tap “Finish helping” again. Don’t place another Grubhub order."
        case .temporarilyUnavailable:
            return "\(AppBrand.name) can’t save the order right now. Stay on this screen and try again in a moment. Don’t place another Grubhub order."
        case .couldNotRecord:
            // `INTERNAL_FAILURE` can follow an unknown commit. Repeating the
            // CommonPlate write is safe; placing a second Grubhub order is not.
            return "\(AppBrand.name) may not have saved your order. Tap “Finish helping” again. Trying again here only updates \(AppBrand.name). It does not place another Grubhub order."
        }
    }

    static func map(_ error: RequestServiceError?) -> FulfillmentPresentationError? {
        guard let error else { return nil }
        switch error {
        case .serverError(let code, _):
            switch code {
            case "INVALID_FULFILLMENT_PAYLOAD":
                return .invalidDetails
            // W4-H1a: a definitive refusal of the screenshot is explained at the
            // screenshot chooser (`PlacedOrderScreenshotNotice`), in its own
            // words — never as a form-level "couldn't record" message, which
            // would be false (nothing was committed) and would point at the
            // wrong field.
            case ClaimErrorCode.invalidPlacedOrderScreenshot:
                return nil
            case ClaimErrorCode.rateLimited:
                return .rateLimited
            case "TRANSACTIONS_UNAVAILABLE":
                return .temporarilyUnavailable
            case ClaimErrorCode.claimExpired,
                 ClaimErrorCode.invalidClaimToken,
                 ClaimErrorCode.requestNotClaimed,
                 ClaimErrorCode.requestAlreadyPlaced,
                 ClaimErrorCode.requestNotFound:
                return nil
            default:
                return .couldNotRecord
            }
        case .ambiguousFulfillmentOutcome, .unresolvedFulfillment:
            return nil
        default:
            return .couldNotRecord
        }
    }
}

/// The one inline explanation the order-screenshot chooser can show (W4-H1a).
///
/// A screenshot that has simply not been chosen yet is NOT represented here: it
/// is an incomplete state, communicated by the right-side `Required` label, the
/// chooser itself, and a disabled `Finish helping` — never a red message.
enum PlacedOrderScreenshotNotice: Equatable {
    /// The chosen image could not be used: it could not be decoded, could not
    /// be normalized within the size cap, or the backend definitively refused
    /// it before committing anything.
    case invalid

    var message: String {
        switch self {
        case .invalid:
            return FulfillRequestView.invalidScreenshotNotice
        }
    }

    /// What the chooser explains right now. Only an unattached chooser ever
    /// shows a notice, and only after a failed attempt. A restored
    /// reservation with no screenshot shows no notice (Faith, R3 recheck).
    static func resolve(
        hasAttachedScreenshot: Bool,
        lastSelectionWasInvalid: Bool,
        reservationWasRestoredByContinuation: Bool
    ) -> PlacedOrderScreenshotNotice? {
        guard !hasAttachedScreenshot else { return nil }
        return lastSelectionWasInvalid ? .invalid : nil
    }
}

/// The Helping page's single extension control state (W4-H1). Derived only
/// from backend-confirmed reservation truth; the one extension is never
/// offered twice.
enum HelpingExtensionControlState: Equatable {
    /// The one extension is still offered: unused, and a full five minutes
    /// fits before the request's own expiry.
    case available
    /// The backend confirmed the one extension.
    case added
    /// No confirmed extension, and none can be offered — either a full five
    /// minutes no longer fits before the request's expiry, or the one offer
    /// was already consumed by an attempt that did not confirm.
    case cantExtend
}

/// External Grubhub handoff (W4-H1). Opening Grubhub is navigation out of the
/// app only: this type has no access to `RequestStore`, so it cannot mark
/// placement, end the reservation, or change fulfillment state.
enum GrubhubHandoff {
    /// Asks the system to open Grubhub and reports only whether it did.
    /// `open` is the SwiftUI `openURL` action in production.
    static func open(
        destination: URL,
        using open: @escaping (URL, @escaping (Bool) -> Void) -> Void,
        completion: @escaping (_ didOpen: Bool) -> Void
    ) {
        guard GrubhubRestaurantDestination.validatedURL(destination.absoluteString) != nil else {
            completion(false)
            return
        }
        open(destination, completion)
    }
}

/// The claimant-only continuous Helping page (W4-H1), reachable only from a
/// confirmed backend claim. It is the single place the pickup name is
/// readable, the one place the reservation is extended or released, and it
/// never holds the raw claim token — every mutation goes through
/// `RequestStore`, which owns the token.
struct FulfillRequestView: View {
    let request: FoodRequest
    @ObservedObject var store: RequestStore
    @Binding var path: [AppRoute]

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Presentation only: a backend-confirmed extension observed on this
    /// screen shows `5 minutes added` briefly before the control leaves.
    @State private var isShowingExtensionAddedConfirmation = false
    @State private var extensionAddedConfirmationTask: Task<Void, Never>?
    /// The encoded backend `eta` string is written only from `readyTime`, so the
    /// value the helper picked and the value the requester reads are the same
    /// text.
    @State private var draft = FulfillmentFormDraft()

    /// A field revalidates live only after its own error has appeared. This is
    /// intentionally view-local and independent from request creation.
    @State private var validationPresentation = FulfillmentValidationPresentation()
    @FocusState private var focusedField: FulfillmentFormField?

    /// Presentation only: the most recent Open Grubhub attempt was not
    /// accepted by the system. Changes no lifecycle state.
    @State private var isShowingGrubhubOpenFailure = false

    /// W4-H1a: the native photo picker's transient selection, consumed (and
    /// reset) as soon as it is handled so the same photo can be chosen again.
    @State private var screenshotPickerItem: PhotosPickerItem?
    /// Identifies the latest selection, so a slower earlier decode can never
    /// overwrite a later choice.
    @State private var screenshotSelectionToken = UUID()
    /// True while a chosen image is being read and normalized. Finish helping
    /// stays unavailable meanwhile, so a half-replaced attachment is never sent.
    @State private var isPreparingScreenshot = false
    /// The last chosen image could not be used (local or backend refusal).
    @State private var lastScreenshotChoiceWasInvalid = false
    @State private var isShowingScreenshotInfo = false
    /// The requester address for the live reservation, when the backend
    /// authorizes it; nil hides the contact row.
    @State private var reservationContactEmail: String?

    /// W4-U1.3: set for the duration of a Stop helping attempt made while the
    /// pair's direct contact is restricted, or on a reservation the backend
    /// holds the post-`Yes` lifecycle authority for (even after this helper's
    /// own Unblock, or a relaunch). A confirmed Stop then leaves for Home,
    /// never for Active Requests, whatever order the store's published claim
    /// change and this view's own result handling arrive in. Presentation only;
    /// it is cleared again if the reservation was not actually ended.
    @State private var stopEndsAtHome = false
    @State private var activeHelpingQuestion: HelpingQuestion?
    /// Bumped only by a confirmed `Yes, already placed` Block; drives the
    /// one-time orientation scroll.
    @State private var blockYesScrollRequest = 0

    /// The claim this screen is showing. Nil once the store ends the flow, so
    /// the body never renders claimant-private data without a live claim
    /// behind it.
    private var claim: ActiveClaimPresentation? {
        guard let activeClaim = store.activeClaim,
              activeClaim.requestID == request.id else {
            return nil
        }
        return activeClaim
    }

    /// The Block for this request's pair is active (confirmed by the backend,
    /// including after relaunch): the restricted completion state.
    private var isBlockActive: Bool {
        store.contactSuppressedRequestIDs.contains(request.id)
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
        ScrollView {
            if let claim {
                VStack(alignment: .leading, spacing: 0) {
                    reservationStatus(claim: claim)
                    // W4-U1.3: the extension and Stop helping stay in both the
                    // unrestricted and the restricted state, composed the same
                    // way, so the control set reveals nothing about a Block or
                    // whose it is. A restricted page drops only direct contact
                    // (Message) and the redundant safety menu.
                    reservationControls(claim: claim)
                        .padding(.top, 16)
                    RequestConversationEntryRow(
                        requestID: request.id,
                        role: .helper,
                        isSuppressed: isBlockActive,
                        path: $path
                    )
                    .padding(.top, 16)
                    placeOrderSection(claim: claim)
                        .padding(.top, 20)
                    afterYouOrderSection
                        .padding(.top, 28)
                        .id(Self.afterYouOrderScrollID)
                }
                .padding(.horizontal, CommonPlateStyle.Metrics.settingsPageInset)
                .padding(.top, 24)
                .padding(.bottom, CommonPlateStyle.Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        // Orientation only, after a confirmed `Yes, already placed` Block:
        // bring the status and `After you order` into view. No focus, picker
        // or navigation change.
        .task(id: request.id) {
            let email = await store.fetchHelperReservationContact(requestID: request.id)
            if !Task.isCancelled { reservationContactEmail = email }
        }
        .onChange(of: blockYesScrollRequest) { _, _ in
            withAnimation(.easeInOut(duration: 0.4)) {
                scrollProxy.scrollTo(Self.afterYouOrderScrollID, anchor: .top)
            }
        }
        .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            if claim != nil {
                finishHelpingBar
            }
        }
        .navigationTitle(Self.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        // W4-U1.3: the contextual safety menu while the reservation is held.
        // The Message warning reads this page's live draft; nothing about the
        // draft is kept for Block.
        .modifier(HelpingBlockMenu(
            store: store,
            isOffered: ParticipantBlockAvailability.helpingOffersBlock(
                canBlockHelpedRequester: claim != nil && store.canBlockHelpedRequester,
                blockIsActive: isBlockActive
            ),
            draftMessage: draft.contactMessage,
            onBlockedAndReleased: {
                path = AppRoute.afterParticipantBlock(from: path)
            },
            onBlockedKeepingReservation: {
                path = AppRoute.afterParticipantBlockKeepingHelping(from: path)
                // The only scroll trigger: a confirmed Yes. Reconstruction,
                // Cancel, No and failure never reach this closure.
                blockYesScrollRequest += 1
            },
            isReportOffered: ParticipantReportAvailability.helpingOffersReport(
                requestStatus: request.status,
                hasVerifiedIdentity: store.hasVerifiedParticipantAuthority,
                holdsReservation: store.activeClaim?.requestID == request.id
            ) && !store.hasReportedRequest(requestID: request.id),
            onReport: {
                store.presentReportPopup(
                    requestID: request.id,
                    returnsHome: false,
                    offersBlockAfter: ParticipantBlockAvailability.helpingOffersBlock(
                        canBlockHelpedRequester: claim != nil && store.canBlockHelpedRequester,
                        blockIsActive: isBlockActive
                    )
                )
            },
            isSuppressed: AppRoute.hasOpenConversation(in: path),
            activeQuestion: $activeHelpingQuestion,
            onStopReleased: {
                stopEndsAtHome = true
                synchronizeClaimedFlowPath()
            }
        ))
        .onChange(of: focusedField) { previousField, currentField in
            validationPresentation.handleFocusTransition(
                from: previousField,
                to: currentField,
                errors: currentFieldErrors
            )
        }
        // A non-success end to this claim removes the entire request-scoped
        // flow. A confirmed placement is left to the success presentation,
        // which owns the one automatic Home return.
        .onChange(of: store.activeClaim?.requestID) { _, _ in
            synchronizeClaimedFlowPath()
        }
        // Observe confirmation directly as well as the cleared claim so the
        // navigation result does not depend on SwiftUI's publication order.
        .onChange(of: store.fulfillmentConfirmation?.id) { _, _ in
            synchronizeClaimedFlowPath()
        }
        // The failure notice belongs to an Open Grubhub that is still offered.
        .onChange(of: isOpenGrubhubAvailable) { _, isAvailable in
            if !isAvailable {
                isShowingGrubhubOpenFailure = false
            }
        }
        }
    }

    private func synchronizeClaimedFlowPath() {
        path = Self.claimedFlowPath(
            path,
            activeRequestID: store.activeClaim?.requestID,
            confirmationRequestID: store.fulfillmentConfirmation?.requestID,
            requestID: request.id,
            endsAtHome: stopEndsAtHome
        )
    }

    /// Keeps request-scoped destinations while this exact reservation is
    /// active. A non-success end (release, expiry, a lost reservation)
    /// unwinds to Active Requests, where its safety notice is presented.
    ///
    /// W4-H1: a confirmed placement for this request leaves the path alone.
    /// The success presentation covers it and performs the single automatic
    /// Home return (`AppRoute.afterHelperSuccess`); truncating here as well
    /// would be a second, competing destination.
    ///
    /// A path that no longer holds a helper destination for this request has
    /// already been unwound (for example by the Home return, whose dismissal of
    /// the confirmation re-enters here), so it is left exactly as it is.
    ///
    /// W4-U1.3: `endsAtHome` is a confirmed Stop helping taken while direct
    /// contact was restricted, or on a post-`Yes` reservation (including after
    /// the helper's own Unblock). That non-success end is not a lost reservation to
    /// be explained on Active Requests — the helper chose to leave — so it
    /// resolves to Home, with no Active Requests destination beneath it.
    static func claimedFlowPath(
        _ path: [AppRoute],
        activeRequestID: String?,
        confirmationRequestID: String?,
        requestID: String,
        endsAtHome: Bool = false
    ) -> [AppRoute] {
        if confirmationRequestID == requestID {
            return path
        }
        guard activeRequestID == requestID else {
            if endsAtHome {
                return AppRoute.afterParticipantBlock(from: path)
            }
            guard AppRoute.containsHelperDestination(
                in: path,
                requestID: requestID
            ) else {
                return path
            }
            return AppRoute.returningHome(from: path)
        }
        return path
    }

    private var matchingAmbiguity: FulfillmentAmbiguityPresentation? {
        guard let ambiguity = store.fulfillmentAmbiguity,
              ambiguity.requestID == request.id else { return nil }
        return ambiguity
    }

    // MARK: - Reservation

    private func reservationStatus(claim: ActiveClaimPresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                HelpingEyebrow(text: Self.reservedUntilLabel)
                Text(Self.reservedUntilTime(claim.claimExpiresAt))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(HelpingPalette.primaryText)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(HelperRequestPresentation.reservedUntilText(claim.claimExpiresAt))
            .accessibilityIdentifier("claim-reservation-notice")

            // The accepted in-app half of the W3-H1 warning. It is a status
            // line only: the controls it concerns are the ones directly below.
            if store.isShowingReservationWarning {
                Text(Self.reservationWarningTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HelpingPalette.stopText)
                    .accessibilityIdentifier("reservation-warning")
            }
        }
    }

    private func reservationControls(claim: ActiveClaimPresentation) -> some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.s) {
            HStack(alignment: .top, spacing: CommonPlateStyle.Spacing.m) {
                if Self.showsExtensionSlot(
                    for: claim,
                    isExtending: store.isExtendingClaim,
                    isShowingAddedConfirmation: isShowingExtensionAddedConfirmation
                ) {
                    extensionControl(claim: claim)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                }
                stopHelpingControl
                    .frame(maxWidth: .infinity)
            }
            .onChange(of: claim.hasUsedExtension) { wasUsed, isUsed in
                guard !wasUsed, isUsed else { return }
                showExtensionAddedConfirmationBriefly()
            }

            if let extensionError = ClaimExtensionPresentationError.map(store.claimExtensionError) {
                Text(extensionError.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("claim-extension-error")
            }

            if let releaseError = ReleasePresentationError.map(store.releaseClaimError) {
                Text(releaseError.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("reservation-warning-release-error")
            }
        }
    }

    @ViewBuilder
    private func extensionControl(claim: ActiveClaimPresentation) -> some View {
        switch Self.extensionControlState(for: claim, isExtending: store.isExtendingClaim) {
        case .available:
            Button {
                Task {
                    await store.extendActiveClaim()
                }
            } label: {
                HStack(spacing: 6) {
                    if store.isExtendingClaim {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "plus")
                            .font(.caption.weight(.bold))
                            .accessibilityHidden(true)
                    }
                    Text(Self.addFiveMinutesTitle)
                }
            }
            .buttonStyle(HelpingReservationControlStyle(role: .extend))
            .disabled(!store.canExtendActiveClaim)
            .accessibilityIdentifier("reservation-warning-extend")
        case .added:
            HelpingReservationStatusLabel(text: Self.fiveMinutesAddedTitle)
                .accessibilityIdentifier("reservation-extension-added")
        case .cantExtend:
            HelpingReservationStatusLabel(text: Self.cantExtendTitle)
                .accessibilityIdentifier("reservation-extension-unavailable")
        }
    }

    private var stopHelpingControl: some View {
        Button {
            if store.stopAsksOrderQuestion(requestID: request.id) {
                activeHelpingQuestion = .stop
            } else {
                // Captured at the tap: the restricted state and the post-Yes
                // lifecycle are cleared together with the reservation, so they
                // cannot be read afterwards. Neither reads Block ownership.
                let endsAtHome = store.stopHelpingEndsAtHome(requestID: request.id)
                Task {
                    stopEndsAtHome = endsAtHome
                    await store.releaseActiveClaim()
                    if store.activeClaim?.requestID == request.id {
                        // The reservation was not ended (failure, ambiguity, or a
                        // lost race): nothing about navigation changes.
                        stopEndsAtHome = false
                    } else {
                        synchronizeClaimedFlowPath()
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if store.isReleasingClaim {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .accessibilityHidden(true)
                }
                Text(Self.stopHelpingTitle)
            }
        }
        .buttonStyle(HelpingReservationControlStyle(role: .stop))
        .disabled(!store.canReleaseActiveClaim)
        .accessibilityIdentifier("reservation-warning-release")
    }

    /// The one mapping from confirmed reservation truth to the extension
    /// control. A confirmed extension always reads as added. The store
    /// consumes the single offer the moment an attempt starts, so an attempt
    /// still in flight keeps the (disabled, in-progress) extension control
    /// rather than momentarily reading `Can't extend`; otherwise the store's
    /// single-offer flag decides between offering it and `Can't extend`.
    static func extensionControlState(
        for claim: ActiveClaimPresentation,
        isExtending: Bool = false
    ) -> HelpingExtensionControlState {
        if claim.hasUsedExtension {
            return .added
        }
        if isExtending {
            return .available
        }
        return claim.isExtensionAvailable ? .available : .cantExtend
    }

    /// After a backend-confirmed extension the control shows `5 minutes added`
    /// only briefly, then leaves so `Stop helping` takes the full width. Every
    /// unconfirmed state (available, in flight, failed, ambiguous, can't
    /// extend) keeps the side-by-side pair and its existing feedback.
    static func showsExtensionSlot(
        for claim: ActiveClaimPresentation,
        isExtending: Bool,
        isShowingAddedConfirmation: Bool
    ) -> Bool {
        extensionControlState(for: claim, isExtending: isExtending) != .added
            || isShowingAddedConfirmation
    }

    static let extensionAddedConfirmationDuration: Duration = .seconds(2.5)

    private func showExtensionAddedConfirmationBriefly() {
        isShowingExtensionAddedConfirmation = true
        UIAccessibility.post(notification: .announcement, argument: Self.fiveMinutesAddedTitle)
        extensionAddedConfirmationTask?.cancel()
        extensionAddedConfirmationTask = Task { @MainActor in
            try? await Task.sleep(for: Self.extensionAddedConfirmationDuration)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                isShowingExtensionAddedConfirmation = false
            }
        }
    }

    // MARK: - Place the order

    private func placeOrderSection(claim: ActiveClaimPresentation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.placeOrderHeading)
                .font(.title3.weight(.bold))
                .foregroundStyle(HelpingPalette.primaryText)
                .accessibilityAddTraits(.isHeader)

            // 1. Dining hall and ordering context: only what placing the order needs.
            HelpingDetailRow(label: Self.diningHallLabel) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.diningSpot.name)
                        .font(.headline)
                        .foregroundStyle(HelpingPalette.primaryText)
                    Text(Self.orderingContextText(for: request))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(HelpingPalette.primaryText)
                        .accessibilityIdentifier("fulfillment-ordering-context")
                }
            }
            .padding(.top, 16)

            // 2. The one Grubhub action, right after where to order.
            if isOpenGrubhubAvailable {
                VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.s) {
                    Button(action: openGrubhub) {
                        HStack(spacing: 6) {
                            Text(Self.openGrubhubTitle)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .bold))
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(OpenGrubhubButtonStyle())
                    .accessibilityHint(Text(Self.openGrubhubAccessibilityHint))
                    .accessibilityIdentifier("fulfillment-open-grubhub")

                    if isShowingGrubhubOpenFailure {
                        Text(Self.grubhubOpenFailureNotice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("fulfillment-open-grubhub-failure")
                    }
                }
                .padding(.top, 16)
            }

            HelpingDivider()

            // 3. The order to reproduce: `Meal item` plus optional `Details`,
            // exactly as entered (shared W4-N1 meal presentation rule).
            let meals = RequestMealEntry.entries(for: request)
            if !meals.isEmpty {
                ForEach(Array(meals.enumerated()), id: \.offset) { index, meal in
                    if index > 0 { HelpingDivider() }
                    RequestMealView(entry: meal, density: .execution)
                        .accessibilityIdentifier("fulfillment-meal-\(index + 1)")
                }
            } else {
                HelpingDetailRow(label: Self.mealRequestLabel) {
                    Text(request.resource.orderDetails ?? request.foodDescription)
                        .font(.callout)
                        .foregroundStyle(HelpingPalette.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // 4. Secondary, exception-only action below the order details
            // (Faith, W4-N1 walkthrough): no subtitle.
            if !isBlockActive, let email = reservationContactEmail,
               let mailURL = PlacedOrderDetailView.mailURL(email) {
                Link(destination: mailURL) {
                    HStack(spacing: CommonPlateStyle.Spacing.m) {
                        Image(systemName: "bubble.left")
                            .foregroundStyle(CommonPlateStyle.Color.brandText)
                        Text(Self.contactRequesterTitle)
                            .font(.headline)
                            .foregroundStyle(HelpingPalette.primaryText)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 16)
                .accessibilityIdentifier("fulfillment-contact-requester")
            }

            // W4-R4 narrow compatibility adaptation: the `Name on order` row
            // is removed because the field it rendered no longer exists
            // anywhere in the request contract — pickup name is gone from the
            // schema, the create payload, every projection, and the claim
            // response. This is the row removal H1's own third READY repair
            // already accepted ("removes `Name on order` / `pickupName`
            // reliance from the Helping-page hierarchy"), not an R4 redesign
            // of H1: no other row, label, ordering, interaction, reservation,
            // fulfillment, or success behaviour on this screen is touched,
            // and no replacement text is added in its place.

        }
    }

    /// The Open Grubhub safety gate for this screen's live state.
    private var isOpenGrubhubAvailable: Bool {
        Self.isOpenGrubhubAvailable(
            requestID: request.id,
            activeClaimRequestID: store.activeClaim?.requestID,
            isFulfilling: store.isFulfilling,
            hasFulfillmentAmbiguity: store.fulfillmentAmbiguity != nil,
            confirmationRequestID: store.fulfillmentConfirmation?.requestID
        )
    }

    private var grubhubDestination: URL {
        GrubhubRestaurantDestination.destination(
            restaurantID: request.diningSpot.id,
            menuPath: request.resource.menuPath
        )
    }

    /// W4-H1 Open Grubhub availability safety gate: offered only while this
    /// helper holds the confirmed active reservation for this request, no
    /// fulfillment submission is in flight, no fulfillment ambiguity/recovery
    /// exists, and no placement has been confirmed. Anything else could read
    /// as an invitation to place a second external order.
    static func isOpenGrubhubAvailable(
        requestID: String,
        activeClaimRequestID: String?,
        isFulfilling: Bool,
        hasFulfillmentAmbiguity: Bool,
        confirmationRequestID: String?
    ) -> Bool {
        activeClaimRequestID == requestID
            && !isFulfilling
            && !hasFulfillmentAmbiguity
            && confirmationRequestID != requestID
    }

    /// External handoff only. Re-checks the safety gate at the tap, and on
    /// failure stays in CommonPlate with the accepted inline notice. Nothing
    /// here reaches `RequestStore`.
    private func openGrubhub() {
        guard isOpenGrubhubAvailable else { return }
        let destination = grubhubDestination
        isShowingGrubhubOpenFailure = false
        GrubhubHandoff.open(
            destination: destination,
            using: { url, completion in openURL(url, completion: completion) },
            completion: { didOpen in
                guard !didOpen, isOpenGrubhubAvailable else { return }
                isShowingGrubhubOpenFailure = true
                UIAccessibility.post(
                    notification: .announcement,
                    argument: Self.grubhubOpenFailureNotice
                )
            }
        )
    }

    // MARK: - After you order

    @ViewBuilder
    private var afterYouOrderSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.afterYouOrderHeading)
                .font(.title3.weight(.bold))
                .foregroundStyle(HelpingPalette.primaryText)
                .accessibilityAddTraits(.isHeader)

            if isBlockActive {
                if store.callerBlockedRequestIDs.contains(request.id) {
                    blockActiveStatus
                        .padding(.top, 8)
                } else {
                    Text(ParticipantBlockCopy.directContactUnavailableNotice)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                        .accessibilityIdentifier("helping-block-active-notice")
                }
            }

            // No email field (W3-I1): the helper is the verified participant
            // this reservation is bound to. The V1 email-sharing / Reply-To
            // disclosure is presented by W4-T1, not on this page.

            if let ambiguity = matchingAmbiguity {
                ambiguitySection(ambiguity)
                    .padding(.top, 16)
            } else {
                fulfillmentFields
                    .padding(.top, 16)

                if let fulfillmentError = FulfillmentPresentationError.map(store.fulfillError) {
                    Text(fulfillmentError.message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, CommonPlateStyle.Spacing.m)
                        .accessibilityIdentifier("fulfillment-error")
                }
            }
        }
    }

    /// The caller-known Block status: a compact tint pill and one muted line.
    /// No icon, and no warning or error styling.
    private var blockActiveStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ParticipantBlockCopy.blockActivePill)
                .font(.caption.weight(.bold))
                .foregroundStyle(HelpingPalette.extendTint)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(HelpingPalette.extendTint.opacity(0.14), in: Capsule())
                .accessibilityIdentifier("helping-block-active-pill")

            Text(ParticipantBlockCopy.blockActiveSupporting)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("helping-block-active-supporting")
        }
    }

    private var fulfillmentFields: some View {
        VStack(alignment: .leading, spacing: 15) {
            // W4-H1a: the first item. Required for every new fulfillment.
            placedOrderScreenshotField

            VStack(alignment: .leading, spacing: 7) {
                HelpingFieldLabel(text: Self.orderNumberLabel)
                // A digits-only contract, so the keypad matches it. The
                // binding stays a `String` and nothing filters or reformats
                // it: a paste that carries letters keeps them on screen and is
                // explained by the field's own message. Leading zeroes survive
                // to the wire intact.
                TextField(Self.orderNumberPlaceholder, text: $draft.orderNumber)
                    .keyboardType(.numberPad)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .orderNumber)
                    .font(.subheadline)
                    .modifier(HelpingFieldChrome(minHeight: 44))
                    .accessibilityLabel(Text(Self.orderNumberLabel))
                    .accessibilityHint(Text(fieldError(.orderNumber) ?? ""))
                    .accessibilityIdentifier("fulfillment-order-number")

                fieldErrorText(.orderNumber, identifier: "fulfillment-order-number-error")
            }

            VStack(alignment: .leading, spacing: 7) {
                HelpingFieldLabel(text: Self.pickupETALabel)
                Menu {
                    Picker(Self.pickupETALabel, selection: readyTimeSelection) {
                        ForEach(FulfillmentReadyTime.allCases) { option in
                            Text(option.label).tag(Optional(option))
                        }
                    }
                } label: {
                    HStack {
                        Text(draft.readyTime?.label ?? Self.pickupETAPlaceholder)
                            .font(.subheadline)
                            .foregroundStyle(
                                draft.readyTime == nil ? Color.secondary : HelpingPalette.primaryText
                            )
                        Spacer(minLength: CommonPlateStyle.Spacing.s)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(CommonPlateStyle.Color.brandText.opacity(0.72))
                            .accessibilityHidden(true)
                    }
                    .modifier(HelpingFieldChrome(minHeight: 44))
                }
                .accessibilityLabel(Text(Self.pickupETALabel))
                .accessibilityValue(Text(draft.readyTime?.label ?? Self.pickupETAPlaceholder))
                .accessibilityIdentifier("fulfillment-eta")
            }

            // W4-U1.3: once this helper has blocked the requester they are
            // helping, the optional Message is not offered — it would be
            // withheld by the backend anyway.
            if !store.contactSuppressedRequestIDs.contains(request.id) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        HelpingFieldLabel(text: Self.messageLabel)
                        Spacer()
                        Text(Self.messageOptionalLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextField(
                        Self.messagePlaceholder,
                        text: $draft.contactMessage,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                    .font(.subheadline)
                    .modifier(HelpingFieldChrome(minHeight: 80, alignment: .topLeading))
                    .accessibilityLabel(Text(Self.messageLabel))
                    .accessibilityIdentifier("fulfillment-contact-message")
                }
            }
        }
    }

    // MARK: - Order screenshot (W4-H1a)

    private var screenshotNotice: PlacedOrderScreenshotNotice? {
        PlacedOrderScreenshotNotice.resolve(
            hasAttachedScreenshot: isScreenshotAttached,
            lastSelectionWasInvalid: lastScreenshotChoiceWasInvalid,
            reservationWasRestoredByContinuation: claim?.wasRestoredByContinuation ?? false
        )
    }

    /// Whether the store currently holds a selected screenshot for this
    /// reservation. Identity only; the bytes are never visible to the view.
    private var isScreenshotAttached: Bool {
        store.hasPlacedOrderScreenshot(requestID: request.id)
    }

    private var isScreenshotPickerEnabled: Bool {
        !store.isFulfilling && !isPreparingScreenshot
    }

    private var placedOrderScreenshotField: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Same quiet info affordance and alert as the requester's Timing
            // header (`RequesterTimingHeader`), right-aligned after Required.
            HStack(alignment: .firstTextBaseline) {
                Text(Self.orderScreenshotLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HelpingPalette.primaryText)
                Spacer()
                HStack(alignment: .center, spacing: 4) {
                    Text(Self.requiredLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        isShowingScreenshotInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            // ~44pt tap target that adds no layout space, so
                            // the glyph sits right after Required, flush trailing.
                            .padding(14)
                            .contentShape(Rectangle())
                            .padding(-14)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(Self.screenshotInfoAccessibilityLabel))
                    .accessibilityIdentifier("fulfillment-screenshot-info")
                }
            }
            .alert(Self.screenshotInfoTitle, isPresented: $isShowingScreenshotInfo) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(Self.screenshotInfo)
            }

            if isScreenshotAttached {
                attachedScreenshotRow
            } else {
                screenshotChooser

                if let notice = screenshotNotice {
                    Text(notice.message)
                        .font(.footnote)
                        .foregroundStyle(notice == .invalid ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fulfillment-screenshot-notice")
                }
            }
        }
        .onChange(of: screenshotPickerItem) { _, item in
            guard let item else { return }
            handlePickedScreenshot(item)
        }
        // A definitive backend refusal of the screenshot (before anything was
        // committed): the store has already discarded the refused selection, so
        // the helper is back at a chooser that can pick another.
        .onChange(of: Self.isPlacedOrderScreenshotRefusal(store.fulfillError)) { _, isRefusal in
            guard isRefusal else { return }
            lastScreenshotChoiceWasInvalid = true
        }
    }

    private var screenshotChooser: some View {
        PlacedOrderScreenshotControl(
            isAttached: false,
            isEnabled: isScreenshotPickerEnabled,
            selection: $screenshotPickerItem
        )
    }

    private var attachedScreenshotRow: some View {
        PlacedOrderScreenshotControl(
            isAttached: true,
            isEnabled: isScreenshotPickerEnabled,
            selection: $screenshotPickerItem
        )
    }

    /// Reads and normalizes the chosen image off the main thread. Only the
    /// latest selection may apply its result; a failure at any step fails
    /// closed to an unattached, chooser-capable state.
    private func handlePickedScreenshot(_ item: PhotosPickerItem) {
        let token = UUID()
        screenshotSelectionToken = token
        screenshotPickerItem = nil
        isPreparingScreenshot = true
        Task {
            let data = try? await item.loadTransferable(type: Data.self)
            let normalized: PlacedOrderScreenshot? = if let data {
                await Task.detached(priority: .userInitiated) {
                    PlacedOrderScreenshotNormalizer.normalize(data)
                }.value
            } else {
                nil
            }
            guard token == screenshotSelectionToken else { return }
            isPreparingScreenshot = false
            applyPickedScreenshot(normalized)
        }
    }

    /// Replaces the store's selection (or, for an unusable image, clears it).
    /// Touches nothing else: the Order number, Pickup ETA, and Message are never
    /// cleared or rewritten by choosing or changing the screenshot.
    private func applyPickedScreenshot(_ screenshot: PlacedOrderScreenshot?) {
        store.selectPlacedOrderScreenshot(screenshot, requestID: request.id)
        lastScreenshotChoiceWasInvalid = screenshot == nil
    }

    /// Whether `error` is the backend's definitive refusal of the screenshot —
    /// the only service error that maps back to the "choose another" message.
    static func isPlacedOrderScreenshotRefusal(_ error: RequestServiceError?) -> Bool {
        guard case .serverError(let code, _)? = error else { return false }
        return code == ClaimErrorCode.invalidPlacedOrderScreenshot
    }

    /// Writes the backend `eta` string only from the chosen option, so the
    /// helper's choice and the requester's email carry the same text.
    private var readyTimeSelection: Binding<FulfillmentReadyTime?> {
        Binding(
            get: { draft.readyTime },
            set: { selection in
                draft.readyTime = selection
                draft.eta = selection?.etaValue ?? ""
            }
        )
    }

    private func ambiguitySection(_ ambiguity: FulfillmentAmbiguityPresentation) -> some View {
        let isShowingRecovery = Self.showsAmbiguityRecoveryCopy(
            isRecoveryAvailable: ambiguity.isRecoveryAvailable,
            isRecovering: ambiguity.isRecovering
        )
        return VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.s) {
            // Before the question, not after it: the helper needs the state
            // they are in before they read what the action does about it.
            if isShowingRecovery {
                Text(Self.ambiguityRecoveryContext)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fulfillment-ambiguity-recovery-context")
            }
            Text(isShowingRecovery
                 ? Self.ambiguityRecoveryTitle
                 : Self.ambiguousTitle(isCheckingStatus: ambiguity.isCheckingStatus))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(isShowingRecovery
                 ? Self.ambiguityRecoveryDetail
                 : Self.ambiguousDetail(isCheckingStatus: ambiguity.isCheckingStatus))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("fulfillment-ambiguous-detail")
            if ambiguity.isCheckingStatus {
                HStack {
                    ProgressView()
                    Text("Checking…")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if ambiguity.isRecovering {
                HStack {
                    ProgressView()
                    Text("Saving…")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if Self.showsAmbiguityRecoveryAction(
                isCheckingStatus: ambiguity.isCheckingStatus,
                isRecoveryAvailable: ambiguity.isRecoveryAvailable
            ) {
                Button(Self.ambiguityRecoveryActionTitle) {
                    let ambiguityID = ambiguity.id
                    Task {
                        try? await store.resubmitAmbiguousFulfillment(
                            ambiguityID: ambiguityID,
                            requestID: request.id
                        )
                    }
                }
                .commonPlateSecondaryAction()
                .disabled(store.isFulfilling || store.isReleasingClaim)
                .accessibilityIdentifier("fulfillment-ambiguity-recovery")
            }
            // Navigation only — nothing here resolves the ambiguity or
            // unblocks a second submission.
            if Self.showsAmbiguityReturnAction(
                isCheckingStatus: ambiguity.isCheckingStatus
            ) {
                Button(Self.returnTitle) {
                    Self.returnHome(from: store) {
                        path = AppRoute.returningHome(from: path)
                    }
                }
                .commonPlateTertiaryAction()
                .accessibilityIdentifier("fulfillment-ambiguous-return")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("fulfillment-ambiguous-state")
    }

    // MARK: - Finish helping

    private var finishHelpingBar: some View {
        let isSubmitting = Self.showsSubmittingState(
            isFulfilling: store.isFulfilling,
            hasMatchingAmbiguity: matchingAmbiguity != nil
        )
        return Button {
            submitFulfillment()
        } label: {
            Text(isSubmitting ? Self.submittingTitle : Self.submitTitle)
        }
        .buttonStyle(HelperPrimaryActionButtonStyle(isInFlight: isSubmitting))
        .disabled(!isSubmissionEnabled)
        .accessibilityIdentifier("fulfillment-submit")
        .padding(.horizontal, CommonPlateStyle.Metrics.settingsPageInset)
        .padding(.top, CommonPlateStyle.Spacing.m)
        .padding(.bottom, CommonPlateStyle.Spacing.s)
        .frame(maxWidth: .infinity)
        .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea(edges: .bottom))
    }

    /// `Submitting…` is only the in-flight state of an ordinary submission.
    /// The single ambiguity resend has its own recovery progress copy.
    static func showsSubmittingState(isFulfilling: Bool, hasMatchingAmbiguity: Bool) -> Bool {
        isFulfilling && !hasMatchingAmbiguity
    }

    private var currentFieldErrors: [FulfillmentFieldError] {
        FulfillmentFormValidator.validate(orderNumber: draft.orderNumber)
    }

    private func fieldError(_ field: FulfillmentFormField) -> String? {
        validationPresentation
            .visibleErrors(from: currentFieldErrors)
            .first { $0.field == field }?
            .message
    }

    /// The message sits immediately below the field it names, so the invalid
    /// field is identified where the helper is already looking.
    @ViewBuilder
    private func fieldErrorText(
        _ field: FulfillmentFormField,
        identifier: String
    ) -> some View {
        if let message = fieldError(field) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier(identifier)
        }
    }

    private var isSubmissionEnabled: Bool {
        Self.isSubmissionEnabled(
            draft: draft,
            hasPlacedOrderScreenshot: isScreenshotAttached,
            isOperationallyAvailable: store.canSubmitFulfillment(requestID: request.id)
                && !isPreparingScreenshot
        )
    }

    /// `Finish helping` is enabled only when every required field is valid
    /// under the existing fulfillment validation — including the attached
    /// placed-order screenshot (W4-H1a) — and the store permits a submission.
    /// There is no tap-to-validate path on a disabled button.
    static func isSubmissionEnabled(
        draft: FulfillmentFormDraft,
        hasPlacedOrderScreenshot: Bool,
        isOperationallyAvailable: Bool
    ) -> Bool {
        guard isOperationallyAvailable else { return false }

        return FulfillmentFormValidator.validate(orderNumber: draft.orderNumber).isEmpty
            && hasPlacedOrderScreenshot
            && draft.readyTime != nil
            && !draft.eta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitFulfillment() {
        focusedField = nil
        let submittedDraft = draft
        let currentPresentation = validationPresentation
        Task {
            do {
                let result = try await Self.orchestrateSubmission(
                    draft: submittedDraft,
                    hasPlacedOrderScreenshot: isScreenshotAttached,
                    presentation: currentPresentation
                ) { values in
                    try await store.fulfill(
                        requestID: request.id,
                        orderNumber: values.orderNumber,
                        eta: values.eta,
                        contactMessage: values.contactMessage
                    )
                }
                validationPresentation = result.presentation
                if !result.didSubmit {
                    focusedField = result.firstInvalidTextField
                }
            } catch {
                // RequestStore owns and publishes backend/lifecycle failures.
                // The draft remains untouched for correction or retry.
            }
        }
    }

    /// The production submit seam. Form validation and normalization complete
    /// before the injected closure can reach `RequestStore`; lifecycle and
    /// duplicate protection remain entirely store-owned.
    static func orchestrateSubmission(
        draft: FulfillmentFormDraft,
        hasPlacedOrderScreenshot: Bool,
        presentation: FulfillmentValidationPresentation,
        submission: (FulfillmentSubmissionValues) async throws -> Void
    ) async throws -> FulfillmentSubmissionResult {
        let number = draft.orderNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let eta = draft.eta.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = draft.contactMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let errors = FulfillmentFormValidator.validate(orderNumber: number)
        var updatedPresentation = presentation
        updatedPresentation.presentAll(errors)

        // W4-H1a: defense in depth beside the disabled button. Without an
        // attached screenshot nothing is submitted — and there is no message:
        // a missing screenshot is an incomplete state, not a validation error.
        guard hasPlacedOrderScreenshot else {
            return FulfillmentSubmissionResult(
                presentation: updatedPresentation,
                firstInvalidTextField: errors.first?.field,
                didSubmit: false
            )
        }

        guard errors.isEmpty else {
            return FulfillmentSubmissionResult(
                presentation: updatedPresentation,
                firstInvalidTextField: errors.first?.field,
                didSubmit: false
            )
        }

        try await submission(FulfillmentSubmissionValues(
            orderNumber: number,
            eta: eta,
            contactMessage: message.isEmpty ? nil : message
        ))
        return FulfillmentSubmissionResult(
            presentation: updatedPresentation,
            firstInvalidTextField: nil,
            didSubmit: true
        )
    }

    // MARK: - Copy

    static let navigationTitle = "Helping"

    static let reservedUntilLabel = "Reserved until"

    /// The authoritative reservation deadline as a static `HH:MM`. Deliberately
    /// not a live countdown: the backend owns expiration.
    static func reservedUntilTime(_ claimExpiresAt: Date) -> String {
        claimExpiresAt.formatted(date: .omitted, time: .shortened)
    }

    /// The accepted W3-H1 warning copy, reused verbatim.
    static let reservationWarningTitle = "5 minutes remain"

    static let addFiveMinutesTitle = "Add 5 minutes"
    static let fiveMinutesAddedTitle = "5 minutes added"
    static let cantExtendTitle = "Can't extend"
    static let stopHelpingTitle = "Stop helping"

    static let placeOrderHeading = "Place the order"
    static let diningHallLabel = "Dining hall"
    /// What to pay with, read before leaving for Grubhub: `4 meal swipes`
    /// (plus any Dining Dollars top-up) or `Dining Dollars · $12.50`.
    static func orderingContextText(for request: FoodRequest) -> String {
        switch request.resource.menuPath {
        case .mealExchange:
            return RequestCardView.quantityText(for: request)
        case .diningDollars:
            guard let cents = request.resource.estimatedDiningDollarsCents else { return "Dining Dollars" }
            return "Dining Dollars · \(DiningDollarsEntry.formatted(cents: cents))"
        }
    }

    static let mealRequestLabel = "Meal request"

    static let openGrubhubTitle = "Open in Grubhub"
    static let openGrubhubAccessibilityHint = "Opens this restaurant's ordering menu in Grubhub or your browser."
    static let grubhubOpenFailureNotice =
        "Couldn't open Grubhub. Open the Grubhub app to place the order."

    static let afterYouOrderHeading = "After you order"
    static let afterYouOrderScrollID = "helping-after-you-order"

    // W4-H1a order screenshot (Faith D-A1, 2026-10-15). Exact approved copy.
    static let orderScreenshotLabel = "Order confirmation"
    static let screenshotInfoTitle = "Order confirmation"
    static let screenshotInfoAccessibilityLabel = "About the order confirmation screenshot"
    static let screenshotInfo =
        "After you place the order, take a screenshot of Grubhub’s order confirmation screen and attach it here."
    static let requiredLabel = "Required"
    static let contactRequesterTitle = "Contact requester"
    static let chooseScreenshotTitle = "Choose Grubhub screenshot"
    static let screenshotAttachedTitle = "Screenshot attached"
    static let changeScreenshotTitle = "Change"
    static let changeScreenshotAccessibilityLabel = "Change order screenshot"
    static let invalidScreenshotNotice =
        "This image can’t be used. Choose another screenshot to continue."

    static let orderNumberLabel = "Order number"
    static let orderNumberPlaceholder = "Enter order number"
    static let pickupETALabel = "Pickup ETA"
    static let pickupETAPlaceholder = "Choose time"
    static let messageLabel = "Message"
    static let messageOptionalLabel = "Optional"
    static let messagePlaceholder = "Anything they should know?"

    static let submitTitle = "Finish helping"
    static let submittingTitle = "Submitting…"

    /// While the single read-only status check is still running.
    static let ambiguousCheckingTitle = "We’re checking your order"
    static let ambiguousCheckingDetail =
        "Your order may already be saved. Don’t tap again or place another Grubhub order while we check."

    /// Settled unresolved state after the read-only status check. A one-time
    /// repeat may still be offered, but no second external order is safe.
    static let ambiguousUnresolvedTitle = "\(AppBrand.name) still can’t confirm the order details."
    static let ambiguousUnresolvedDetail =
        "The original save or the one-time retry may have worked. Don’t place another Grubhub order. You can’t try saving again from this screen."

    /// Restates that the first write may have committed before offering the one
    /// repeat.
    static let ambiguityRecoveryContext =
        "\(AppBrand.name) still can’t confirm whether the first save worked, so these order details may already be recorded."

    static let ambiguityRecoveryTitle = "Try saving to \(AppBrand.name) once more?"
    static let ambiguityRecoveryDetail =
        "This sends the same order details to \(AppBrand.name) one more time. It will not place another Grubhub order or charge you again. Don’t place another Grubhub order."
    static let ambiguityRecoveryActionTitle = "Send details to \(AppBrand.name) once more"

    static func ambiguousTitle(isCheckingStatus: Bool) -> String {
        isCheckingStatus ? ambiguousCheckingTitle : ambiguousUnresolvedTitle
    }

    static func ambiguousDetail(isCheckingStatus: Bool) -> String {
        isCheckingStatus ? ambiguousCheckingDetail : ambiguousUnresolvedDetail
    }

    static func showsAmbiguityRecoveryAction(
        isCheckingStatus: Bool,
        isRecoveryAvailable: Bool
    ) -> Bool {
        !isCheckingStatus && isRecoveryAvailable
    }

    /// Keeps recovery framing visible while the one repeat is offered or running.
    static func showsAmbiguityRecoveryCopy(
        isRecoveryAvailable: Bool,
        isRecovering: Bool
    ) -> Bool {
        isRecoveryAvailable || isRecovering
    }

    /// The settled state names an exit, so it has to offer one. Withheld while
    /// the single check is still running: leaving mid-read would invite a tap
    /// on a state that is about to answer itself.
    static func showsAmbiguityReturnAction(isCheckingStatus: Bool) -> Bool {
        !isCheckingStatus
    }

    /// The settled unresolved state's only action, isolated so it is provable
    /// that leaving is *purely* navigation: it resolves nothing, clears no
    /// claim, re-enables no submission, and sends no request. The reservation
    /// stays held and blocked until it expires, exactly as the copy says.
    static func returnHome(
        from store: RequestStore,
        navigate: () -> Void
    ) {
        _ = store
        navigate()
    }

    static let returnTitle = "Back to Home"
}

// MARK: - Helping page presentation

/// Approved W4-H1 Figma colors for the Helping page, with dark-appearance
/// counterparts so the narrow Grubhub-orange exception and the destructive
/// control stay legible on the dark canvas.
private enum HelpingPalette {
    static let primaryText = Color.primary
    static let eyebrowText = Color.secondary
    static let divider = CommonPlateStyle.Color.requestCardBorder

    /// W4-B1 decision 9: an ordinary brand action, so the brand-text role
    /// (it is used as label text and a low-opacity tint, never as a solid
    /// fill under white text).
    static let extendTint = CommonPlateStyle.Color.brandText
    static let stopText = dynamic(
        light: UIColor(red: 180 / 255, green: 67 / 255, blue: 73 / 255, alpha: 1),
        dark: UIColor(red: 240 / 255, green: 130 / 255, blue: 135 / 255, alpha: 1)
    )

    /// Grubhub orange (`rgba(255, 128, 0, …)`) — a restrained third-party
    /// brand treatment used only by Open Grubhub.
    static let grubhubOrange = Color(red: 1, green: 128 / 255, blue: 0)
    static let grubhubText = dynamic(
        light: UIColor(red: 156 / 255, green: 71 / 255, blue: 0, alpha: 1),
        dark: UIColor(red: 1, green: 170 / 255, blue: 90 / 255, alpha: 1)
    )

    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

private struct HelpingEyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(HelpingPalette.eyebrowText)
    }
}

/// One labelled fact in `Place the order`. Flat by design: no card per fact.
private struct HelpingDetailRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HelpingEyebrow(text: label)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct HelpingDivider: View {
    var body: some View {
        Rectangle()
            .fill(HelpingPalette.divider)
            .frame(height: 1)
            .padding(.vertical, 18)
            .accessibilityHidden(true)
    }
}

private struct HelpingFieldLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(HelpingPalette.primaryText)
            .accessibilityHidden(true)
    }
}

private struct HelpingFieldChrome: ViewModifier {
    let minHeight: CGFloat
    var alignment: Alignment = .leading
    var verticalPadding: CGFloat = 11

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 13)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: alignment)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(CommonPlateStyle.Color.baseCanvas)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(CommonPlateStyle.Color.requestCardBorder)
            )
            .contentShape(Rectangle())
    }
}

/// The helper's order-screenshot control. The empty chooser and the attached
/// row share one full-width, fixed-height field so attaching a screenshot never
/// changes the control's geometry (Faith, W4-R3 walkthrough).
struct PlacedOrderScreenshotControl: View {
    let isAttached: Bool
    let isEnabled: Bool
    @Binding var selection: PhotosPickerItem?

    /// Shared height of the control in both states.
    static let height: CGFloat = 44

    var body: some View {
        if isAttached { attachedRow } else { chooser }
    }

    private var chooser: some View {
        PhotosPicker(
            selection: $selection,
            matching: .images,
            photoLibrary: .shared()
        ) {
            HStack(spacing: CommonPlateStyle.Spacing.xs) {
                Text(FulfillRequestView.chooseScreenshotTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CommonPlateStyle.Color.brandText)
            }
            .frame(maxWidth: .infinity)
            .modifier(ScreenshotControlChrome(verticalPadding: 0))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityIdentifier("fulfillment-screenshot-choose")
    }

    private var attachedRow: some View {
        let attached = HStack(spacing: 6) {
            Text("✓ \(FulfillRequestView.screenshotAttachedTitle)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fulfillment-screenshot-attached")

        let change = PhotosPicker(
            selection: $selection,
            matching: .images,
            photoLibrary: .shared()
        ) {
            Text(FulfillRequestView.changeScreenshotTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isEnabled ? CommonPlateStyle.Color.brandText : Color.secondary)
                .frame(minHeight: Self.height)
        }
        .disabled(!isEnabled)
        .accessibilityLabel(Text(FulfillRequestView.changeScreenshotAccessibilityLabel))
        .accessibilityIdentifier("fulfillment-screenshot-change")

        // Side by side when it fits; stacked at the largest accessibility sizes
        // so neither the status nor the action is ever truncated.
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: CommonPlateStyle.Spacing.s) {
                attached
                Spacer(minLength: CommonPlateStyle.Spacing.s)
                change
            }
            VStack(alignment: .leading, spacing: 2) {
                attached
                change
            }
        }
        // The 44-pt `Change` target supplies the height, so the chrome adds no
        // vertical padding: attaching must not grow the control past the empty
        // chooser's height.
        .modifier(ScreenshotControlChrome(verticalPadding: 0))
    }
}

/// Same surface, radius and border as the requester's `Choose Grubhub
/// screenshot` control, at the helper control's fixed 44pt minimum height.
private struct ScreenshotControlChrome: ViewModifier {
    var verticalPadding: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, CommonPlateStyle.Spacing.m)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, minHeight: PlacedOrderScreenshotControl.height)
            .commonPlateCard()
            .contentShape(Rectangle())
    }
}

/// Noninteractive `5 minutes added` / `Can't extend`, occupying the extension
/// control's slot so the pair stays side by side.
private struct HelpingReservationStatusLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, CommonPlateStyle.Spacing.s)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(CommonPlateStyle.Color.requestCardBorder)
            )
    }
}

private struct HelpingReservationControlStyle: ButtonStyle {
    enum Role {
        case extend
        case stop
    }

    let role: Role
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let tint = role == .extend ? HelpingPalette.extendTint : HelpingPalette.stopText
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isEnabled ? tint : Color.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, CommonPlateStyle.Spacing.s)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isEnabled ? tint.opacity(role == .extend ? 0.08 : 0.07) : Color.gray.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isEnabled ? tint.opacity(role == .extend ? 0.16 : 0.14) : Color.gray.opacity(0.2))
            )
            .opacity(configuration.isPressed && isEnabled ? 0.82 : 1)
    }
}

/// Centered label with a trailing external arrow on a restrained
/// Grubhub-orange surface — the one narrow third-party-brand exception.
private struct OpenGrubhubButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(HelpingPalette.grubhubText)
            .padding(.horizontal, CommonPlateStyle.Spacing.m)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(HelpingPalette.grubhubOrange.opacity(0.13))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(HelpingPalette.grubhubOrange.opacity(0.38), lineWidth: 1.25)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

/// The Helping page's pinned `Finish helping` action: filled purple when
/// enabled, neutral when disabled, and a dimmed purple while in flight.
private struct HelperPrimaryActionButtonStyle: ButtonStyle {
    let isInFlight: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let isActive = isEnabled || isInFlight
        configuration.label
            .font(.title3.weight(.semibold))
            .foregroundStyle(isActive ? Color.white : Color.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, CommonPlateStyle.Spacing.m)
            .frame(maxWidth: .infinity, minHeight: CommonPlateStyle.Control.majorActionMinimumHeight)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isActive ? Color.accentColor : Color.gray.opacity(0.28))
            )
            .opacity(isInFlight ? 0.72 : (configuration.isPressed && isEnabled ? 0.88 : 1))
    }
}
