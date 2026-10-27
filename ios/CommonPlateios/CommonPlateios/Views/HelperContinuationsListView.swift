//
//  HelperContinuationsListView.swift
//  CommonPlateios
//
// W4-R3: the helper's `Continue helping` set. Home previews the top cards by
// the shared Home limit and `See all` opens this list with every valid
// continuation: the active claimed/unplaced request first, then each passive
// `Waiting for pickup` request. It is rendered from the store's live set, so a
// requester pickup or helper cutoff retires exactly that card in place.
import SwiftUI

struct HelperContinuationCardLink: View {
    let item: HelperContinuationItem
    var isHomePresentation = false

    var body: some View {
        switch item {
        case .active(let claim):
            NavigationLink(value: AppRoute.fulfillment(claim.request)) {
                RequestCardView(
                    request: claim.request,
                    kind: .helping(claimExpiresAt: claim.claimExpiresAt),
                    isHomePresentation: isHomePresentation
                )
            }
            .buttonStyle(HelperContinuationCardButtonStyle())
            .accessibilityHint("Open your helping reservation")
            .accessibilityIdentifier("home-continue-helping-card")
        case .waiting(let placement):
            NavigationLink(value: AppRoute.helperWaiting(requestID: placement.id)) {
                RequestCardView(
                    request: placement.request,
                    kind: .waitingForPickup(
                        orderNumber: placement.orderNumber,
                        etaText: placement.etaText
                    ),
                    isHomePresentation: isHomePresentation
                )
            }
            .buttonStyle(HelperContinuationCardButtonStyle())
            .accessibilityIdentifier("home-helper-waiting-card-\(placement.id)")
        }
    }
}

private struct HelperContinuationCardButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct HelperContinuationsListView: View {
    @ObservedObject var store: RequestStore

    var body: some View {
        ScrollView {
            LazyVStack(spacing: CommonPlateStyle.Spacing.m) {
                ForEach(store.helperContinuationItems()) { item in
                    HelperContinuationCardLink(item: item)
                }
            }
            .padding(CommonPlateStyle.Spacing.l)
        }
        .navigationTitle(HomeExchangeView.continueHelpingHeading)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("helper-continuations-list")
    }
}
