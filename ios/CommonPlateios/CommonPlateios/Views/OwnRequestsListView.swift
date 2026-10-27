//
//  OwnRequestsListView.swift
//  CommonPlateios
//
// W4-H4's `See all N` destination: an ordinary subordinate expansion of
// Home's ownership preview, not a second ownership authority. Renders the
// exact authoritative currently-open owned-request set Home's `See all N`
// action was tapped with, preserving that same authoritative ordering. It is
// not request history, not completed requests, not V2 My Requests, and
// offers no management affordance itself; each card opens the requester-owned
// detail (W4-R5), which re-reads owner truth and owns Edit and Withdraw.
import SwiftUI

struct OwnRequestsListView: View {
    let requests: [FoodRequest]
    let placedOrders: [PlacedOrder]

    init(requests: [FoodRequest], placedOrders: [PlacedOrder] = []) {
        self.requests = requests
        self.placedOrders = placedOrders
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: CommonPlateStyle.Spacing.m) {
                ForEach(requests) { request in
                    NavigationLink(value: route(for: request)) {
                        RequestCardView(
                            request: request,
                            kind: .own,
                            showsOwnershipEyebrow: false,
                            placedOrderNeedsPickupConfirmation: placedOrders
                                .first { $0.id == request.id }?
                                .shouldConfirmPickup()
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("own-requests-list-card-\(request.id)")
                }
            }
            .padding(CommonPlateStyle.Spacing.l)
        }
        .navigationTitle(HomeExchangeView.ownRequestsHeading(count: requests.count))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("own-requests-list")
    }

    private func route(for request: FoodRequest) -> AppRoute {
        if request.status == .placed {
            return .placedOrder(requestID: request.id)
        }
        return .ownerRequest(OwnerRequest.provisional(from: request))
    }
}
