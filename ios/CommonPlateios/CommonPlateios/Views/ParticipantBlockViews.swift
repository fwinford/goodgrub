//
//  ParticipantBlockViews.swift
//  CommonPlateios
//
// Functional participant-blocking surfaces (W4-U1.3): shared copy and failure
// mapping, the contextual `•••` safety-menu entry used by Request Detail
// (before helping) and Helping (while the reservation is held), and the
// blocked-student management list reachable from Settings → Privacy & Safety.
// Final visual presentation belongs downstream (T1 / H1 / R3); everything here
// reuses existing CommonPlate patterns and invents no new hierarchy.
//
// Nothing in this file can display another student's identity: the only data
// it ever holds is `BlockedStudent`, which is interaction context.
import SwiftUI

enum ParticipantBlockCopy {
    static let blockActionTitle = "Block this student"
    static let safetyMenuAccessibilityLabel = "More options"

    static let blockConfirmationTitle = "Block this student?"
    static let blockConfirmationMessage =
        "You won’t see each other’s future requests, and neither of you will be able to start helping the other."
    static let blockConfirmButtonTitle = "Block student"
    static let cancelTitle = "Cancel"

    /// The external-order question asked while the helper holds the
    /// reservation. The choices are neutral and nothing is explained below
    /// them.
    static let externalOrderQuestionTitle = "Have you already placed the Grubhub order?"
    static let externalOrderYesTitle = "Yes, already placed"
    static let externalOrderNoTitle = "No, not yet"
    /// Shown once, before the choices, only when a Message draft exists.
    static let messageNotSharedWarning = "Your message won’t be shared."
    /// Immediately below `After you order` once the caller's own Block is
    /// active: a compact status pill and one muted supporting line.
    static let blockActivePill = "BLOCK ACTIVE"
    static let blockActiveSupporting = "You can continue or stop helping."
    /// The same position when restriction was reconstructed from the backend
    /// and who holds the Block is not known to this client.
    static let directContactUnavailableNotice =
        "Direct contact is unavailable. You can still finish this order."

    static let failureTitle = "Couldn’t block"
    static let failureDismissTitle = "OK"

    static let managementTitle = "Blocked Students"
    static let managementRowTitle = "Blocked Students"
    static let managementEmpty = "You haven’t blocked anyone."
    static let unblockTitle = "Unblock"
    /// Unblock is not behind the operational pause, so one failure sentence
    /// covers every way it can fail.
    static let unblockFailed = "We couldn’t unblock this student right now. Try again in a moment."
    static let loadFailed = "We couldn’t load your blocked students. Try again in a moment."
    static let retryTitle = "Try Again"
}

enum HelpingQuestion: Equatable {
    case block
    case stop

    var title: String {
        ParticipantBlockCopy.externalOrderQuestionTitle
    }
}

/// User-facing failure text for a block attempt. Never states or implies who
/// blocked whom, and never suggests anything about a placed order.
enum ParticipantBlockPresentationError: Equatable {
    case helpingFlowRequired
    case reservationChanged
    case unconfirmed
    case paused
    case rateLimited
    case unavailable
    case couldNotBlock

    var message: String {
        switch self {
        case .helpingFlowRequired:
            return "You’re helping with this request. Block this student from the Helping page."
        case .reservationChanged:
            return "Your reservation changed. Check its status and try again."
        case .unconfirmed:
            return "We couldn’t confirm the block. Check Blocked Students in Settings before trying again."
        case .paused:
            // Blocking itself is never paused; only ending the reservation is,
            // and only the "No order placed" answer needs that.
            return "Ending your reservation is temporarily unavailable. Try again later."
        case .rateLimited:
            return "Too many tries. Wait a moment and try again."
        case .unavailable:
            return "This request is no longer available."
        case .couldNotBlock:
            return "We couldn’t block this student right now. Try again in a moment."
        }
    }

    static func map(_ error: RequestServiceError?) -> ParticipantBlockPresentationError? {
        guard let error else { return nil }
        switch error {
        case .ambiguousBlockOutcome:
            return .unconfirmed
        case .serverError(let code, _):
            switch code {
            case ParticipantBlockErrorCode.externalOrderAnswerRequired:
                return .helpingFlowRequired
            case ParticipantBlockErrorCode.reservationStateChanged:
                return .reservationChanged
            case ClaimErrorCode.publicActionsPaused:
                return .paused
            case ClaimErrorCode.rateLimited:
                return .rateLimited
            case ClaimErrorCode.requestNotFound, ClaimErrorCode.invalidRequestID:
                return .unavailable
            default:
                return .couldNotBlock
            }
        default:
            return .couldNotBlock
        }
    }
}

/// Which surfaces may offer Block. Presentation only: the backend is the
/// authority and refuses every non-contextual target regardless of what any
/// view offers.
enum ParticipantBlockAvailability {
    /// Request Detail offers Block only to a verified participant looking at
    /// somebody else's request. A request the helper holds is never presented
    /// there (H1 redirects it to Helping), and a requester never gets a
    /// helper-directed Block from their own request.
    static func requestDetailOffersBlock(
        ownership: RequestOwnership,
        hasVerifiedIdentity: Bool,
        holdsReservationForRequest: Bool
    ) -> Bool {
        hasVerifiedIdentity && ownership == .notOwn && !holdsReservationForRequest
    }

    /// Helping offers the `•••` Block entry only while the reservation is
    /// truthfully held and no Block is already active for it. Once active the
    /// menu has no remaining action and is removed.
    static func helpingOffersBlock(
        canBlockHelpedRequester: Bool,
        blockIsActive: Bool
    ) -> Bool {
        canBlockHelpedRequester && !blockIsActive
    }

    /// `Your message won’t be shared.` exactly when the live Helping draft
    /// carries entered content; never otherwise.
    static func messageWarning(forDraft draftMessage: String) -> String? {
        draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : ParticipantBlockCopy.messageNotSharedWarning
    }
}

enum ParticipantReportAvailability {
    static func requestDetailOffersReport(
        requestStatus: RequestStatus,
        ownership: RequestOwnership,
        hasVerifiedIdentity: Bool,
        holdsReservationForRequest: Bool
    ) -> Bool {
        hasVerifiedIdentity
            && requestStatus == .open
            && ownership == .notOwn
            && !holdsReservationForRequest
    }

    static func helpingOffersReport(
        requestStatus: RequestStatus,
        hasVerifiedIdentity: Bool,
        holdsReservation: Bool
    ) -> Bool {
        hasVerifiedIdentity && requestStatus == .claimed && holdsReservation
    }

    /// W4-R3 pickup interaction (Option A): the requester's Report entry lives
    /// exactly as long as the continuation's pickup is still pending. The
    /// backend remains authoritative at submission time.
    /// Requester reservation-start window (accepted MSG1 / U1.2): a live
    /// reservation, which the backend reports as the `reserved` phase.
    static func reservedRequesterOffersReport(
        isReserved: Bool,
        hasVerifiedIdentity: Bool
    ) -> Bool {
        hasVerifiedIdentity && isReserved
    }

    static func placedOrderOffersReport(
        isPickupPending: Bool,
        hasVerifiedIdentity: Bool
    ) -> Bool {
        hasVerifiedIdentity && isPickupPending
    }
}

/// Request Detail's contextual safety menu (`•••` → `Block this student`),
/// with the normal confirmation. A confirmed Block resets navigation to Home.
struct RequestDetailBlockMenu: ViewModifier {
    @ObservedObject var store: RequestStore
    let requestID: String
    let isOffered: Bool
    let onBlocked: () -> Void
    var isReportOffered = false
    var onReport: () -> Void = {}
    /// True while the request's private chat is on top of this screen: the
    /// chat owns the Block failure alert and the Block-after-Report prompt.
    var isSuppressed = false

    @State private var isConfirming = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                if isOffered || isReportOffered {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if isReportOffered {
                                Button("Report student", action: onReport)
                                    .accessibilityIdentifier("request-detail-report")
                            }
                            if isOffered {
                                Button(role: .destructive) {
                                    store.clearBlockError()
                                    isConfirming = true
                                } label: {
                                    Text(ParticipantBlockCopy.blockActionTitle)
                                }
                                .disabled(store.isBlockingParticipant)
                                .accessibilityIdentifier("request-detail-block")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .accessibilityLabel(ParticipantBlockCopy.safetyMenuAccessibilityLabel)
                        .accessibilityIdentifier("request-detail-safety-menu")
                    }
                }
            }
            .alert(
                ParticipantBlockCopy.blockConfirmationTitle,
                isPresented: $isConfirming
            ) {
                Button(ParticipantBlockCopy.blockConfirmButtonTitle, role: .destructive) {
                    Task {
                        let result = await store.blockRequesterOfViewedRequest(requestID: requestID)
                        if case .blocked = result {
                            onBlocked()
                        }
                    }
                }
                Button(ParticipantBlockCopy.cancelTitle, role: .cancel) {}
            } message: {
                Text(ParticipantBlockCopy.blockConfirmationMessage)
            }
            .participantBlockFailureAlert(store: store, isSuppressed: isSuppressed)
            .onChange(of: store.isBlockAfterReportPending) { _, isPending in
                guard isPending, isOffered, !isSuppressed, store.consumeBlockAfterReport() else { return }
                store.clearBlockError()
                isConfirming = true
            }
    }
}

/// Helping's contextual safety menu (`•••` → `Block this student`), with the
/// active-reservation question. The Message warning comes from the live
/// Helping draft handed in by the host; nothing about it is stored here.
struct HelpingBlockMenu: ViewModifier {
    @ObservedObject var store: RequestStore
    let isOffered: Bool
    let draftMessage: String
    let onBlockedAndReleased: () -> Void
    /// Confirmed Block with the reservation kept (`Yes, already placed`).
    let onBlockedKeepingReservation: () -> Void
    var isReportOffered = false
    var onReport: () -> Void = {}
    var isSuppressed = false
    @Binding var activeQuestion: HelpingQuestion?
    let onStopReleased: () -> Void

    func body(content: Content) -> some View {
        content
            .toolbar {
                if isOffered || isReportOffered {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if isReportOffered {
                                Button("Report student", action: onReport)
                                    .accessibilityIdentifier("helping-report")
                            }
                            if isOffered {
                                Button(role: .destructive) {
                                    store.clearBlockError()
                                    activeQuestion = .block
                                } label: {
                                    Text(ParticipantBlockCopy.blockActionTitle)
                                }
                                .accessibilityIdentifier("helping-block")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .accessibilityLabel(ParticipantBlockCopy.safetyMenuAccessibilityLabel)
                        .accessibilityIdentifier("helping-safety-menu")
                    }
                }
            }
            .alert(
                activeQuestion?.title ?? "",
                isPresented: Binding(
                    get: { activeQuestion != nil },
                    set: { if !$0 { activeQuestion = nil } }
                )
            ) {
                if activeQuestion == .block {
                    Button(ParticipantBlockCopy.externalOrderYesTitle) {
                        Task {
                            let result = await store.blockHelpedRequester(externalOrderPlaced: true)
                            if case .blocked = result {
                                onBlockedKeepingReservation()
                            }
                        }
                    }
                    Button(ParticipantBlockCopy.externalOrderNoTitle) {
                        Task {
                            let result = await store.blockHelpedRequester(externalOrderPlaced: false)
                            if case .blocked(let released) = result, released {
                                onBlockedAndReleased()
                            }
                        }
                    }
                    Button(ParticipantBlockCopy.cancelTitle, role: .cancel) {}
                } else if activeQuestion == .stop {
                    Button(ParticipantBlockCopy.externalOrderYesTitle) {
                        Task {
                            if await store.answerStopOrderQuestion(externalOrderPlaced: true) == .released {
                                onStopReleased()
                            }
                        }
                    }
                    Button(ParticipantBlockCopy.externalOrderNoTitle) {
                        Task {
                            if await store.answerStopOrderQuestion(externalOrderPlaced: false) == .released {
                                onStopReleased()
                            }
                        }
                    }
                    Button(ParticipantBlockCopy.cancelTitle, role: .cancel) {}
                }
            } message: {
                if activeQuestion == .block,
                   let warning = ParticipantBlockAvailability.messageWarning(forDraft: draftMessage) {
                    Text(warning)
                }
            }
            .participantBlockFailureAlert(store: store, isSuppressed: isSuppressed)
            .onChange(of: store.isBlockAfterReportPending) { _, isPending in
                guard isPending, isOffered, !isSuppressed, store.consumeBlockAfterReport() else { return }
                store.clearBlockError()
                activeQuestion = .block
            }
    }
}

extension View {
    /// Truthful, sourced failure text for a Block that did not commit.
    func participantBlockFailureAlert(
        store: RequestStore,
        isSuppressed: Bool = false,
        onDismiss: @escaping () -> Void = {}
    ) -> some View {
        alert(
            ParticipantBlockCopy.failureTitle,
            isPresented: Binding(
                get: { store.blockError != nil && !isSuppressed },
                set: { if !$0 { store.clearBlockError() } }
            )
        ) {
            Button(ParticipantBlockCopy.failureDismissTitle, role: .cancel) {
                store.clearBlockError()
                onDismiss()
            }
        } message: {
            if let error = ParticipantBlockPresentationError.map(store.blockError) {
                Text(error.message)
            }
        }
    }
}

/// The minimal blocked-student management list. Rows are interaction context
/// only; the single action is Unblock, and only for a block this participant
/// owns (the backend refuses anything else).
struct BlockedStudentsView: View {
    @ObservedObject var store: RequestStore
    @ObservedObject var identityStore: ParticipantIdentityStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
                content
            }
            .padding(.horizontal, CommonPlateStyle.Metrics.settingsPageInset)
            .padding(.top, CommonPlateStyle.Spacing.l)
            .padding(.bottom, CommonPlateStyle.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
        .navigationTitle(ParticipantBlockCopy.managementTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: identityStore.identity) {
            await store.loadBlockedStudents()
        }
    }

    @ViewBuilder
    private var content: some View {
        let students = store.currentBlockedStudents
        switch store.blockedStudentsLoadState {
        case .notLoaded, .loading where students.isEmpty:
            ProgressView()
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("blocked-students-loading")
        case .failed where students.isEmpty:
            VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.s) {
                Text(ParticipantBlockCopy.loadFailed)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("blocked-students-load-failed")
                Button(ParticipantBlockCopy.retryTitle) {
                    Task { await store.loadBlockedStudents() }
                }
                .accessibilityIdentifier("blocked-students-retry")
            }
        default:
            if students.isEmpty {
                Text(ParticipantBlockCopy.managementEmpty)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("blocked-students-empty")
            } else {
                VStack(spacing: 0) {
                    ForEach(students) { student in
                        row(for: student)
                        if student.id != students.last?.id {
                            Rectangle()
                                .fill(CommonPlateStyle.Color.requestCardBorder)
                                .frame(height: 1)
                        }
                    }
                }
            }
            if store.unblockError != nil {
                Text(ParticipantBlockCopy.unblockFailed)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("blocked-students-unblock-error")
            }
        }
    }

    /// Role, then location and timestamp (one line when they fit, otherwise
    /// the timestamp on its own line; nothing is truncated), with a reserved
    /// trailing lane for the direct Unblock action, vertically centered.
    ///
    /// The vertical padding belongs to the text column, not the whole row, so
    /// the comfortable Unblock interaction target (see `unblockLane`) sits
    /// inside a normal row instead of making every row taller.
    private func row(for student: BlockedStudent) -> some View {
        HStack(alignment: .center, spacing: CommonPlateStyle.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(BlockedStudentPresentation.roleTitle(for: student))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("blocked-student-role")
                locationAndTimestamp(for: student)
                    .accessibilityIdentifier("blocked-student-label")
            }
            .padding(.vertical, CommonPlateStyle.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)

            unblockLane(for: student)
        }
    }

    /// One semantic hierarchy on both layout paths: the dining location is
    /// primary and semibold, the timestamp is secondary and regular. The
    /// compact path concatenates differently styled runs instead of one
    /// uniformly styled string, and the fallback stacks the same two runs.
    private func locationAndTimestamp(for student: BlockedStudent) -> some View {
        let timestamp = BlockedStudentPresentation.timestamp(for: student)
        return ViewThatFits(in: .horizontal) {
            (locationRun(student.diningLocation) + timestampRun(" · \(timestamp)"))
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 2) {
                locationRun(student.diningLocation)
                    .fixedSize(horizontal: false, vertical: true)
                timestampRun(timestamp)
            }
        }
    }

    private func locationRun(_ text: String) -> Text {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
    }

    private func timestampRun(_ text: String) -> Text {
        Text(text)
            .font(.subheadline.weight(.regular))
            .foregroundStyle(.secondary)
    }

    /// `Unblock` and the in-flight spinner share one footprint: the button is
    /// always laid out (hidden and non-interactive while removing) and the
    /// spinner is centered over it, so changing state never widens the text
    /// column or re-wraps a long location. The visible label stays compact; the
    /// interaction target is at least the project's minimum control height.
    private func unblockLane(for student: BlockedStudent) -> some View {
        let isRemoving = store.removingBlockedStudentIDs.contains(student.id)
        return ZStack {
            Button {
                Task { await store.unblockStudent(id: student.id) }
            } label: {
                Text(ParticipantBlockCopy.unblockTitle)
                    .font(.subheadline.weight(.semibold))
                    .frame(
                        minWidth: CommonPlateStyle.Control.minimumHeight,
                        minHeight: CommonPlateStyle.Control.minimumHeight
                    )
                    .contentShape(Rectangle())
            }
            .disabled(isRemoving)
            .opacity(isRemoving ? 0 : 1)
            .accessibilityHidden(isRemoving)
            .accessibilityIdentifier("blocked-student-unblock")

            if isRemoving {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("blocked-student-unblock-progress")
            }
        }
    }
}
