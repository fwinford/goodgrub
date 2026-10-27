//
//  HelperWaitingDetailView.swift
//  CommonPlateios
//
// W4-R3: the helper's own continuation for a request they already placed.
// A placed request is no longer publicly available, so this screen resolves
// the store's helper-owned placement and never the public request path. It
// shows the context the helper authored (request, order number, ETA) and the
// requester's address only through the authorized contact read (email
// fallback); no other requester identity, no pickup timestamp, no action.
// In-app messaging stays deferred (MSG1). Layout mirrors the requester
// placed-order detail and is PROVISIONAL: Figma has no helper frame yet.
import SwiftUI

struct HelperWaitingDetailView: View {
    let requestID: String
    @ObservedObject var store: RequestStore
    @Binding var path: [AppRoute]
    @State private var contactEmail: String?
    @State private var isShowingMapsChooser = false
    @State private var appleMapsURL: URL?
    @State private var googleMapsURL: URL?
    @State private var mapsUnavailable = false

    static func placement(
        requestID: String,
        in items: [HelperContinuationItem]
    ) -> PlacedReservationOutcome? {
        for case .waiting(let placement) in items where placement.id == requestID {
            return placement
        }
        return nil
    }

    private var placement: PlacedReservationOutcome? {
        Self.placement(requestID: requestID, in: store.helperContinuationItems())
    }

    var body: some View {
        Group {
            if let placement {
                content(placement)
            } else {
                // Retired (requester picked up, or the helper window ended):
                // leave in place rather than show a stale screen.
                Color.clear.onAppear { path.removeAll { $0 == .helperWaiting(requestID: requestID) } }
            }
        }
        .modifier(RequestDetailBlockMenu(
            store: store,
            requestID: requestID,
            isOffered: placement != nil,
            onBlocked: { path = AppRoute.afterParticipantBlock(from: path) },
            isSuppressed: AppRoute.hasOpenConversation(in: path)
        ))
        .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
        .navigationTitle("Helping")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("helper-waiting-detail")
    }

    private func content(_ placement: PlacedReservationOutcome) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
                HStack(spacing: 5) {
                    Circle().fill(RequestCardView.orderedColor).frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(RequestCardView.waitingForPickupLabel)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RequestCardView.orderedColor)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("helper-waiting-status")

                card(title: "Pickup information") {
                    row("Order number", value: "#\(placement.orderNumber)")
                    row("Estimated ready", value: readyText(placement))
                    row("Dining hall", value: placement.request.diningSpot.name)
                    if let address = address(for: placement) {
                        addressRow(address, spot: placement.request.diningSpot)
                    }
                }

                card(title: "What was requested", spacing: CommonPlateStyle.Spacing.s) {
                    Text(RequestCardView.quantityText(for: placement.request))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(RequestCardView.mealLines(for: placement.request))
                        .font(.subheadline)
                }

                RequestConversationEntryRow(
                    requestID: placement.id,
                    role: .helper,
                    isSuppressed: store.contactSuppressedRequestIDs.contains(placement.id),
                    path: $path
                )

                if let email = contactEmail, let mailURL = PlacedOrderDetailView.mailURL(email) {
                    Link(destination: mailURL) {
                        HStack(spacing: CommonPlateStyle.Spacing.m) {
                            Image(systemName: "bubble.left")
                                .foregroundStyle(CommonPlateStyle.Color.brandText)
                            Text("Contact requester")
                                .font(.headline)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("helper-waiting-contact")
                }
            }
            .padding(.horizontal, CommonPlateStyle.Metrics.settingsPageInset)
            .padding(.top, CommonPlateStyle.Spacing.m)
            .padding(.bottom, CommonPlateStyle.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { contactEmail = await store.fetchHelperPlacementContact(requestID: requestID) }
    }

    private func readyText(_ placement: PlacedReservationOutcome) -> String {
        guard let readyAt = placement.estimatedReadyAt else { return placement.etaText }
        return readyAt.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, timeZone: NYUCampusTime.timeZone)
        )
    }

    // The wire request carries only the vendor name; the address is catalog data.
    private func address(for placement: PlacedReservationOutcome) -> String? {
        let spot = placement.request.diningSpot
        let catalog = SupportedVendorCatalog.diningSpots.first { $0.name == spot.name }
        return R3MapsDestination.displayAddress(for: catalog ?? spot)
    }

    private func mapsSpot(_ spot: DiningSpot) -> DiningSpot {
        SupportedVendorCatalog.diningSpots.first { $0.name == spot.name } ?? spot
    }

    @ViewBuilder
    private func addressRow(_ address: String, spot: DiningSpot) -> some View {
        let destination = R3MapsDestination(diningSpot: mapsSpot(spot))
        HStack(alignment: .firstTextBaseline) {
            Text("Address").font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: CommonPlateStyle.Spacing.s)
            if let destination, !mapsUnavailable {
                Button {
                    appleMapsURL = destination.appleMapsURL
                    googleMapsURL = destination.googleMapsURL.flatMap {
                        UIApplication.shared.canOpenURL($0) ? $0 : nil
                    }
                    isShowingMapsChooser = true
                } label: {
                    HStack(spacing: CommonPlateStyle.Spacing.xs) {
                        Text(address)
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.trailing)
                        Image(systemName: "arrow.up.right").font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(CommonPlateStyle.Color.brandText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .confirmationDialog(
                    "Open location in Maps?",
                    isPresented: $isShowingMapsChooser,
                    titleVisibility: .visible
                ) {
                    if let appleMapsURL { Button("Apple Maps") { openMaps(appleMapsURL) } }
                    if let googleMapsURL { Button("Google Maps") { openMaps(googleMapsURL) } }
                    Button("Cancel", role: .cancel) {}
                }
                .accessibilityLabel("Open \(address) in Maps")
            } else {
                Text(address).font(.subheadline.weight(.semibold)).multilineTextAlignment(.trailing)
            }
        }
    }

    private func openMaps(_ url: URL) {
        UIApplication.shared.open(url, options: [:]) { succeeded in
            guard !succeeded else { return }
            Task { @MainActor in mapsUnavailable = true }
        }
    }

    private func card<Content: View>(
        title: String,
        spacing: CGFloat = CommonPlateStyle.Spacing.m,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(title).font(.headline)
            content()
        }
        .padding(CommonPlateStyle.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .commonPlateCard(cornerRadius: 16)
    }

    private func row(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: CommonPlateStyle.Spacing.s)
            Text(value).font(.subheadline.weight(.semibold)).multilineTextAlignment(.trailing)
        }
    }
}
