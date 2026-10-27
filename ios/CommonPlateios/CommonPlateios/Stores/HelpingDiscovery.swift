//
//  HelpingDiscovery.swift
//  CommonPlateios
//
// W4-O1 first-eligible-request discovery selection. Pure, presentation-only
// derivation over existing Home board truth; it reorders nothing, fabricates
// nothing, and owns no backend or identity state.

import Foundation

enum HelpingDiscovery {
    /// Requests rendered as ordinary open cards in the populated `Needs help`
    /// board, in Home's existing authoritative order. Empty for loading,
    /// unavailable, and empty board states; own requests are excluded.
    @MainActor
    static func eligibleRequests(store: RequestStore) -> [FoodRequest] {
        eligibleRequests(boardState: HomeExchangeView.boardState(store: store))
    }

    static func eligibleRequests(boardState: HomeExchangeView.BoardState) -> [FoodRequest] {
        guard case .populated(let requests) = boardState else { return [] }
        return HomeExchangeView.partitionByOwnership(requests).needsHelp
    }

    /// The first eligible request, or nil when discovery is inactive or the
    /// student holds an active helping reservation. When the selected request
    /// leaves the board the next eligible one is selected automatically.
    @MainActor
    static func selectedRequestID(
        isPending: Bool,
        hasActiveReservation: Bool,
        store: RequestStore
    ) -> String? {
        selectedRequestID(
            isPending: isPending,
            hasActiveReservation: hasActiveReservation,
            eligible: eligibleRequests(store: store)
        )
    }

    static func selectedRequestID(
        isPending: Bool,
        hasActiveReservation: Bool,
        eligible: [FoodRequest]
    ) -> String? {
        guard isPending, !hasActiveReservation else { return nil }
        return eligible.first?.id
    }

    /// Whether a navigation-path change completes discovery. Completion
    /// requires that the student tapped an eligible Home `Needs help` card
    /// (`openedFromHomeCardID`, reported only by that card's tap while the
    /// treatment is active) and that the path is now exactly that request's
    /// detail. Any other route to the same detail (a notification tap, a
    /// deep link) carries no card marker and does not complete discovery.
    static func shouldComplete(
        isPending: Bool,
        openedFromHomeCardID: String?,
        newPath: [AppRoute],
        eligible: [FoodRequest]
    ) -> Bool {
        guard isPending,
              let cardID = openedFromHomeCardID,
              newPath.count == 1,
              case .requestDetail(let opened) = newPath[0],
              opened.id == cardID,
              eligible.contains(where: { $0.id == opened.id })
        else { return false }
        return true
    }
}
