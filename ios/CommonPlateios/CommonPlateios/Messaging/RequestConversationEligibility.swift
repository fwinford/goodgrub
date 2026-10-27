//
//  RequestConversationEligibility.swift
//  CommonPlateios
//
// W4-MSG1 CP6 (iOS, dormant). Re-derives, from the same backend reads the
// request screens already use, whether the caller still has the live request
// relationship that chat hangs off. This is a client-side *closing* signal
// only: `.eligible` never authorizes anything (the conversation endpoints do),
// and `.unknown` (transport, 5xx, cancellation) never closes or opens chat.
import Foundation

nonisolated enum RequestConversationEligibility: Equatable {
    case eligible
    case ineligible
    case unknown
}

/// Which existing moderation flows this conversation may offer. Derived only
/// from the same predicates the request screens already use; the target
/// participant is always resolved by the backend from the request and the
/// caller's authority, never named by this client.
nonisolated struct ConversationActionAvailability: Equatable {
    enum BlockKind: Equatable {
        /// Normal Block with a confirmation (requester, or a helper whose order is placed).
        case viewedRequest
        /// Active reservation: the external-order Yes/No question.
        case helpingReservation
    }

    var report = false
    var block: BlockKind?

    static let none = ConversationActionAvailability()
}

@MainActor
protocol ConversationEntryVerifying: AnyObject {
    func verify(requestID: String, role: RequestConversationRole) async -> RequestConversationEligibility

    /// Synchronous denial from already-published store state (Block, restriction,
    /// lost authority, helper claim/placement gone). `true` means close now.
    func isLocallyDenied(requestID: String, role: RequestConversationRole) -> Bool

    /// Fail-closed: nothing is offered until the relationship stage is known.
    func availableActions(requestID: String, role: RequestConversationRole) -> ConversationActionAvailability
}

@MainActor
final class StoreConversationEntryVerifier: ConversationEntryVerifying {
    private let store: RequestStore
    /// Last verified requester stage per request: true only while a live
    /// reservation or a placed order with pickup pending exists. Absent or
    /// false offers no requester action.
    private var requesterActionsOpen: [String: Bool] = [:]

    init(store: RequestStore) {
        self.store = store
    }

    func isLocallyDenied(requestID: String, role: RequestConversationRole) -> Bool {
        if !store.hasVerifiedParticipantAuthority || store.isParticipantRestricted {
            return true
        }
        if store.contactSuppressedRequestIDs.contains(requestID) {
            return true
        }
        if role == .helper {
            return !store.helperContinuationItems().contains { $0.id == requestID }
        }
        return false
    }

    func availableActions(requestID: String, role: RequestConversationRole) -> ConversationActionAvailability {
        guard !isLocallyDenied(requestID: requestID, role: role) else { return .none }
        let verified = store.hasVerifiedParticipantAuthority
        let notYetReported = !store.hasReportedRequest(requestID: requestID)
        switch role {
        case .requester:
            guard requesterActionsOpen[requestID] == true else { return .none }
            return ConversationActionAvailability(
                report: verified && notYetReported,
                block: verified ? .viewedRequest : nil
            )
        case .helper:
            if let claim = store.activeClaim, claim.requestID == requestID {
                let blockable = ParticipantBlockAvailability.helpingOffersBlock(
                    canBlockHelpedRequester: store.canBlockHelpedRequester,
                    blockIsActive: store.contactSuppressedRequestIDs.contains(requestID)
                )
                return ConversationActionAvailability(
                    report: ParticipantReportAvailability.helpingOffersReport(
                        requestStatus: claim.request.status,
                        hasVerifiedIdentity: verified,
                        holdsReservation: true
                    ) && notYetReported,
                    block: blockable ? .helpingReservation : nil
                )
            }
            let waiting = store.helperContinuationItems().contains {
                if case .waiting(let placement) = $0 { return placement.id == requestID }
                return false
            }
            return ConversationActionAvailability(report: false, block: waiting && verified ? .viewedRequest : nil)
        }
    }

    func verify(requestID: String, role: RequestConversationRole) async -> RequestConversationEligibility {
        switch role {
        case .requester: return await verifyRequester(requestID: requestID)
        case .helper: return await verifyHelper(requestID: requestID)
        }
    }

    private func verifyRequester(requestID: String) async -> RequestConversationEligibility {
        do {
            let owner = try await store.fetchOwnerRequest(id: requestID)
            requesterActionsOpen[requestID] = owner.phase == .reserved
            return owner.phase == .reserved ? .eligible : .ineligible
        } catch is CancellationError {
            return .unknown
        } catch RequestServiceError.serverError(let code, _) {
            if code == RequestUpdateErrorCode.requestAlreadyPlaced {
                return await verifyPlacedOrder(requestID: requestID)
            }
            return Self.isTerminalCode(code) ? .ineligible : .unknown
        } catch RequestServiceError.notFound {
            return .unknown
        } catch {
            return .unknown
        }
    }

    private func verifyPlacedOrder(requestID: String) async -> RequestConversationEligibility {
        do {
            let detail = try await store.fetchPlacedOrder(id: requestID)
            if case .pending = detail.pickupConfirmation {
                requesterActionsOpen[requestID] = true
                return .eligible
            }
            requesterActionsOpen[requestID] = false
            return .ineligible
        } catch is CancellationError {
            return .unknown
        } catch RequestServiceError.serverError(let code, _) {
            return Self.isTerminalCode(code) ? .ineligible : .unknown
        } catch {
            return .unknown
        }
    }

    private func verifyHelper(requestID: String) async -> RequestConversationEligibility {
        await store.refreshHelperContinuations()
        if Task.isCancelled { return .unknown }
        return isLocallyDenied(requestID: requestID, role: .helper) ? .ineligible : .eligible
    }

    private static func isTerminalCode(_ code: String) -> Bool {
        code == RequestRemovedPresentation.errorCode
            || code == RequestUpdateErrorCode.requestExpired
            || code == RequestUpdateErrorCode.requestWithdrawn
            || code == RequestUpdateErrorCode.requestNotFound
            || code == "PLACED_ORDER_NOT_FOUND"
    }
}
