//
//  ParticipantActionVerificationCoordinator.swift
//  CommonPlateios
//
// Owns the operation-scoped continuation lifecycle that bridges participant
// verification to one exact requester/helper mutation (W3-I1).
import Combine
import Foundation

enum ParticipantActionVerificationResume: Equatable {
    case requestCreation(draft: RequestFoodFormDraft)
    case claim(requestID: String)
}

/// One production transition owner shared by the request and helper views.
///
/// SwiftUI reports lifecycle signals (identity publication, path replacement,
/// sheet dismissal, disappearance) through the operation-specific entry points
/// below. This object owns the snapshot, exact request/operation identity,
/// matching-destination checks, retirement, and one-use consumption. Tests call
/// these same entry points; no continuation behavior is reconstructed in a test.
@MainActor
final class ParticipantActionVerificationCoordinator: ObservableObject {
    private enum PendingAction: Equatable {
        case requestCreation(
            continuation: ParticipantVerificationContinuation,
            draft: RequestFoodFormDraft
        )
        case claim(
            continuation: ParticipantVerificationContinuation,
            requestID: String
        )

        var continuation: ParticipantVerificationContinuation {
            switch self {
            case .requestCreation(let continuation, _),
                 .claim(let continuation, _):
                return continuation
            }
        }
    }

    @Published private var pendingAction: PendingAction?

    private let identityStore: ParticipantIdentityStore
    private let operationID: () -> UUID

    init(
        identityStore: ParticipantIdentityStore,
        operationID: @escaping () -> UUID = UUID.init
    ) {
        self.identityStore = identityStore
        self.operationID = operationID
    }

    var pendingContinuation: ParticipantVerificationContinuation? {
        pendingAction?.continuation
    }

    var isPresentingRequestCreationVerification: Bool {
        guard case .requestCreation(let continuation, _)? = pendingAction else {
            return false
        }
        return ownsRunningVerification(continuation)
    }

    func isPresentingClaimVerification(requestID: String) -> Bool {
        guard case .claim(let continuation, let pendingRequestID)? = pendingAction,
              pendingRequestID == requestID else {
            return false
        }
        return ownsRunningVerification(continuation)
    }

    @discardableResult
    func beginRequestCreation(
        draft: RequestFoodFormDraft,
        path: [AppRoute]
    ) -> Bool {
        guard path.last == .requestFood, pendingAction == nil else { return false }
        let continuation = ParticipantVerificationContinuation.requestCreation(
            operationID: operationID()
        )
        guard identityStore.beginVerification(for: continuation) else { return false }
        pendingAction = .requestCreation(
            continuation: continuation,
            draft: draft
        )
        return true
    }

    @discardableResult
    func beginClaim(requestID: String, path: [AppRoute]) -> Bool {
        guard Self.isMatchingClaimDestination(path: path, requestID: requestID),
              pendingAction == nil else {
            return false
        }
        let continuation = ParticipantVerificationContinuation.claim(
            requestID: requestID,
            operationID: operationID()
        )
        guard identityStore.beginVerification(for: continuation) else { return false }
        pendingAction = .claim(
            continuation: continuation,
            requestID: requestID
        )
        return true
    }

    /// Called by `RequestFoodView`'s real identity-publication callback.
    /// A helper view cannot use this entry point to consume its own pending
    /// claim, and a second publication finds no pending action.
    func requesterIdentityDidChange(
        from previous: ParticipantIdentityPresentation?,
        to current: ParticipantIdentityPresentation?,
        path: [AppRoute]
    ) -> ParticipantActionVerificationResume? {
        guard previous == nil, current != nil,
              case .requestCreation(let continuation, let draft)? = pendingAction else {
            return nil
        }
        guard path.last == .requestFood else {
            retire(.requestCreation(continuation: continuation, draft: draft))
            return nil
        }
        guard identityStore.consumeContinuation(continuation) else { return nil }
        // Both owners clear on the main actor before the mutation is returned
        // to the view. Duplicate publications/taps therefore have nothing left
        // to enqueue.
        pendingAction = nil
        return .requestCreation(draft: draft)
    }

    /// Called by one exact `RequestDetailView`. The caller's request ID must
    /// equal both the pending operation and the current destination.
    func helperIdentityDidChange(
        requestID: String,
        from previous: ParticipantIdentityPresentation?,
        to current: ParticipantIdentityPresentation?,
        path: [AppRoute],
        claimAlreadyActive: Bool = false
    ) -> ParticipantActionVerificationResume? {
        guard previous == nil, current != nil,
              case .claim(let continuation, let pendingRequestID)? = pendingAction,
              pendingRequestID == requestID else {
            return nil
        }
        guard !claimAlreadyActive,
              Self.isMatchingClaimDestination(path: path, requestID: requestID) else {
            retire(.claim(continuation: continuation, requestID: pendingRequestID))
            return nil
        }
        guard identityStore.consumeContinuation(continuation) else { return nil }
        pendingAction = nil
        return .claim(requestID: requestID)
    }

    func requesterCancelled() {
        guard case .requestCreation? = pendingAction else { return }
        cancelOwnedVerification()
    }

    func helperCancelled(requestID: String) {
        guard case .claim(_, let pendingRequestID)? = pendingAction,
              pendingRequestID == requestID else { return }
        cancelOwnedVerification()
    }

    /// SwiftUI also sets a sheet binding to false when successful verification
    /// ends its flow. In that success race, identity publication still owns the
    /// consume, so dismissal retires only while no verified identity exists.
    func requesterSheetDismissed() {
        guard !identityStore.isVerified,
              case .requestCreation(let continuation, let draft)? = pendingAction else {
            return
        }
        retire(.requestCreation(continuation: continuation, draft: draft))
    }

    func helperSheetDismissed(requestID: String) {
        guard !identityStore.isVerified,
              case .claim(let continuation, let pendingRequestID)? = pendingAction,
              pendingRequestID == requestID else {
            return
        }
        retire(.claim(continuation: continuation, requestID: pendingRequestID))
    }

    func requesterNavigationChanged(path: [AppRoute]) {
        guard path.last != .requestFood,
              case .requestCreation(let continuation, let draft)? = pendingAction else {
            return
        }
        retire(.requestCreation(continuation: continuation, draft: draft))
    }

    func helperNavigationChanged(requestID: String, path: [AppRoute]) {
        guard case .claim(let continuation, let pendingRequestID)? = pendingAction,
              pendingRequestID == requestID,
              !Self.isMatchingClaimDestination(path: path, requestID: requestID) else {
            return
        }
        retire(.claim(continuation: continuation, requestID: pendingRequestID))
    }

    func requesterDisappeared() {
        guard case .requestCreation(let continuation, let draft)? = pendingAction else {
            return
        }
        retire(.requestCreation(continuation: continuation, draft: draft))
    }

    func helperDisappeared(requestID: String) {
        guard case .claim(let continuation, let pendingRequestID)? = pendingAction,
              pendingRequestID == requestID else {
            return
        }
        retire(.claim(continuation: continuation, requestID: pendingRequestID))
    }

    private func ownsRunningVerification(
        _ continuation: ParticipantVerificationContinuation
    ) -> Bool {
        identityStore.pendingContinuation == continuation
            && identityStore.flow?.purpose == .firstVerification
    }

    private func cancelOwnedVerification() {
        identityStore.cancelVerification()
        pendingAction = nil
    }

    private func retire(_ action: PendingAction) {
        guard pendingAction == action else { return }
        identityStore.retireContinuation(action.continuation)
        pendingAction = nil
    }

    private static func isMatchingClaimDestination(
        path: [AppRoute],
        requestID: String
    ) -> Bool {
        guard case .requestDetail(let request)? = path.last else { return false }
        return request.id == requestID
    }
}
