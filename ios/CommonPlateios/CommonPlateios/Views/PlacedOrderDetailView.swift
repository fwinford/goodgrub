//
//  PlacedOrderDetailView.swift
//  CommonPlateios
//
// W4-R3 requester-private continuation of a placed request.
//
import SwiftUI
import UIKit

struct PlacedOrderDetailView: View {
    let requestID: String
    @ObservedObject var store: RequestStore
    @ObservedObject var identityStore: ParticipantIdentityStore
    @Binding var path: [AppRoute]
    @Environment(\.scenePhase) private var scenePhase

    @State private var detail: PlacedOrderDetail?
    @State private var loadState: LoadState = .loading
    @State private var evidenceData: Data?
    @State private var isShowingEvidence = false
    @State private var isShowingMapsChooser = false
    @State private var googleMapsURL: URL?
    @State private var mapsUnavailableForPresentation = false
    @State private var readinessTask: Task<Void, Never>?
    @State private var readinessRevision = 0
    @State private var loadGeneration = 0

    private enum LoadState {
        case loading
        case loaded
        case unavailable
    }

    private var isPickupPending: Bool {
        guard let detail else { return false }
        if case .pending = detail.pickupConfirmation { return true }
        return false
    }

    private var needsPickupAttention: Bool {
        _ = readinessRevision
        return detail?.placedOrder.shouldConfirmPickup() == true
    }

    private var appleMapsURL: URL? {
        guard let detail else { return nil }
        return R3MapsDestination(
            diningSpot: detail.placedOrder.request.diningSpot
        )?.appleMapsURL
    }

    var body: some View {
        Group {
            if let detail {
                orderContent(detail)
            } else if loadState == .loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading placed order")
            } else {
                unavailableContent
            }
        }
        .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
        .navigationTitle("Your request")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if isPickupPending {
                pickupAction
            }
        }
        .task { await reload() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await reload() }
        }
        .onChange(of: identityStore.identity) { _, _ in
            loadGeneration += 1
            readinessTask?.cancel()
            readinessTask = nil
            detail = nil
            loadState = .loading
            evidenceData = nil
            Task { await reload() }
        }
        .onDisappear {
            readinessTask?.cancel()
            readinessTask = nil
            if !isShowingEvidence {
                evidenceData = nil
            }
        }
        .fullScreenCover(isPresented: $isShowingEvidence) {
            evidenceViewer
        }
        .modifier(RequestDetailBlockMenu(
            store: store,
            requestID: requestID,
            isOffered: isPickupPending && identityStore.identity != nil,
            onBlocked: { Task { await reload() } },
            isReportOffered: ParticipantReportAvailability.placedOrderOffersReport(
                isPickupPending: isPickupPending,
                hasVerifiedIdentity: identityStore.identity != nil
            ) && !store.hasReportedRequest(requestID: requestID),
            onReport: {
                store.presentReportPopup(
                    requestID: requestID,
                    returnsHome: false,
                    offersBlockAfter: isPickupPending && identityStore.identity != nil
                )
            },
            isSuppressed: AppRoute.hasOpenConversation(in: path)
        ))
    }

    private func orderContent(_ detail: PlacedOrderDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
                statusRow(detail.placedOrder)
                if store.isPickupRecoveryNeeded(requestID: requestID) {
                    pickupRecoveryRow
                }
                pickupInformation(detail.placedOrder)
                evidenceEntry
                requestContext(detail.request)
                if isPickupPending {
                    RequestConversationEntryRow(
                        requestID: requestID,
                        role: .requester,
                        path: $path
                    )
                }
                if let email = detail.contactHelperEmail,
                   let mailURL = Self.mailURL(email) {
                    Link(destination: mailURL) {
                        HStack(spacing: CommonPlateStyle.Spacing.m) {
                            Image(systemName: "bubble.left")
                                .foregroundStyle(CommonPlateStyle.Color.brandText)
                            Text("Contact helper")
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
                    .accessibilityIdentifier("placed-order-contact-helper")
                }
            }
            .padding(.horizontal, CommonPlateStyle.Metrics.settingsPageInset)
            .padding(.top, CommonPlateStyle.Spacing.m)
            .padding(.bottom, CommonPlateStyle.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("placed-order-detail")
    }

    @ViewBuilder
    private func statusRow(_ order: PlacedOrder) -> some View {
        Group {
            if needsPickupAttention {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .accessibilityHidden(true)
                    Text("Confirm pickup")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RequestCardView.pickupAttentionColor)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("placed-order-confirm-pickup-status")
            } else {
                Label("Your meal was ordered", systemImage: "circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RequestCardView.orderedColor)
                    .labelStyle(PlacedOrderStatusLabelStyle())
                    .accessibilityIdentifier("placed-order-meal-ordered-status")
            }
        }
        .onAppear { scheduleReadinessRefresh(order) }
        .onChange(of: order.serverNow) { _, _ in scheduleReadinessRefresh(order) }
    }

    private func pickupInformation(_ order: PlacedOrder) -> some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
            Text("Pickup information")
                .font(.headline)
            informationRow("Order number", value: "#\(order.orderNumber)")
            if let estimatedReadyAt = order.estimatedReadyAt {
                informationRow("Estimated ready", value: Self.timeText(estimatedReadyAt))
            }
            informationRow("Dining hall", value: order.request.diningSpot.name)
            HStack(alignment: .firstTextBaseline) {
                Text("Address")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: CommonPlateStyle.Spacing.s)
                if let address = R3MapsDestination.displayAddress(for: order.request.diningSpot) {
                    if let destination = R3MapsDestination(diningSpot: order.request.diningSpot),
                       !mapsUnavailableForPresentation {
                        Button {
                            googleMapsURL = destination.googleMapsURL.flatMap {
                                UIApplication.shared.canOpenURL($0) ? $0 : nil
                            }
                            isShowingMapsChooser = true
                        } label: {
                            HStack(spacing: CommonPlateStyle.Spacing.xs) {
                                Text(address)
                                    .font(.subheadline.weight(.semibold))
                                    .multilineTextAlignment(.trailing)
                                Image(systemName: "arrow.up.right")
                                    .font(.caption.weight(.semibold))
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
                            if let appleMapsURL {
                                Button("Apple Maps") { openMaps(appleMapsURL) }
                            }
                            if let googleMapsURL {
                                Button("Google Maps") { openMaps(googleMapsURL) }
                            }
                            Button("Cancel", role: .cancel) {}
                        }
                        .accessibilityLabel("Open \(address) in Maps")
                    } else {
                        Text(address)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(CommonPlateStyle.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            CommonPlateStyle.Color.requestCardSurface,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(CommonPlateStyle.Color.requestCardBorder, lineWidth: 1)
        }
        .accessibilityIdentifier("placed-order-pickup-information")
    }

    private func informationRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: CommonPlateStyle.Spacing.s)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private var evidenceEntry: some View {
        Button {
            guard evidenceData != nil else { return }
            isShowingEvidence = true
        } label: {
            HStack(spacing: CommonPlateStyle.Spacing.m) {
                Group {
                    if let image = evidenceImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
                    Text("Grubhub order confirmation")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Screenshot uploaded by your helper")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if evidenceData != nil {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(CommonPlateStyle.Spacing.m)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(
                CommonPlateStyle.Color.requestCardSurface,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(CommonPlateStyle.Color.requestCardBorder, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(evidenceData == nil)
        .accessibilityIdentifier("placed-order-evidence-entry")
    }

    private func requestContext(_ request: FoodRequest) -> some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.s) {
            Text("What you requested")
                .font(.headline)
            Text(RequestCardView.quantityText(for: request))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(RequestCardView.mealLines(for: request))
                .font(.subheadline)
                .textSelection(.enabled)
        }
        .padding(CommonPlateStyle.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            CommonPlateStyle.Color.requestCardSurface,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(CommonPlateStyle.Color.requestCardBorder, lineWidth: 1)
        }
        .accessibilityIdentifier("placed-order-request-context")
    }

    private var pickupAction: some View {
        let isRetry = store.isPickupRecoveryNeeded(requestID: requestID)
        return Button {
            Task {
                let result = await store.confirmPlacedOrderPickup(
                    requestID: requestID,
                    userInitiatedRetry: isRetry
                )
                switch result {
                case .confirmed, .notFound:
                    path = []
                case .unresolved:
                    break
                }
            }
        } label: {
            Text(isRetry ? "Try Again" : "I picked it up")
                .frame(maxWidth: .infinity)
        }
        .commonPlateMajorPrimaryAction()
        .disabled(store.confirmingPickupRequestIDs.contains(requestID))
        .padding(.horizontal, CommonPlateStyle.Metrics.settingsPageInset)
        .padding(.top, CommonPlateStyle.Spacing.s)
        .padding(.bottom, CommonPlateStyle.Spacing.s)
        .background(CommonPlateStyle.Color.baseCanvas)
        .accessibilityIdentifier(isRetry ? "placed-order-pickup-try-again" : "placed-order-pickup-confirm")
    }

    private var pickupRecoveryRow: some View {
        Label {
            Text("We couldn’t confirm your pickup.")
                .font(.subheadline.weight(.semibold))
        } icon: {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(Color(uiColor: .systemPink))
        .padding(CommonPlateStyle.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .systemPink).opacity(0.09),
            in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard)
        )
        .overlay {
            RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard)
                .strokeBorder(Color(uiColor: .systemPink).opacity(0.3), lineWidth: 1)
        }
        .accessibilityIdentifier("placed-order-pickup-recovery")
    }

    private var unavailableContent: some View {
        VStack(spacing: CommonPlateStyle.Spacing.m) {
            CommonPlateInlineStatus(
                kind: .unavailable,
                message: "Couldn’t open this request. Please try again."
            )
            Button("Try again") {
                Task { await reload() }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("placed-order-read-retry")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(CommonPlateStyle.Spacing.l)
    }

    private var evidenceViewer: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = evidenceImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(CommonPlateStyle.Spacing.m)
                    .accessibilityLabel("Grubhub order confirmation screenshot")
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                isShowingEvidence = false
            } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
            }
            .padding(CommonPlateStyle.Spacing.l)
            .accessibilityLabel("Close screenshot")
            .accessibilityIdentifier("placed-order-evidence-close")
        }
    }

    private var evidenceImage: UIImage? {
        evidenceData.flatMap(UIImage.init(data:))
    }

    private func openMaps(_ url: URL) {
        UIApplication.shared.open(url, options: [:]) { succeeded in
            guard !succeeded else { return }
            Task { @MainActor in mapsUnavailableForPresentation = true }
        }
    }

    @MainActor
    private func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        if detail == nil { loadState = .loading }
        do {
            let fetched = try await store.fetchPlacedOrder(id: requestID)
            guard generation == loadGeneration else { return }
            if store.applyPlacedOrderDetail(fetched) {
                detail = nil
                path = []
                return
            }
            detail = fetched
            loadState = .loaded
            scheduleReadinessRefresh(fetched.placedOrder)
            await fetchEvidence(generation: generation)
        } catch is CancellationError {
            return
        } catch let error as RequestServiceError {
            guard generation == loadGeneration else { return }
            if case .serverError(let code, _) = error,
               code == "PLACED_ORDER_NOT_FOUND" {
                detail = nil
                evidenceData = nil
                path = []
                return
            }
            if detail == nil {
                loadState = .unavailable
            } else {
                detail = detail.map {
                    PlacedOrderDetail(
                        placedOrder: $0.placedOrder,
                        pickupConfirmation: $0.pickupConfirmation,
                        contactHelperEmail: nil
                    )
                }
                evidenceData = nil
            }
        } catch {
            guard generation == loadGeneration else { return }
            if detail == nil {
                loadState = .unavailable
            } else {
                detail = detail.map {
                    PlacedOrderDetail(
                        placedOrder: $0.placedOrder,
                        pickupConfirmation: $0.pickupConfirmation,
                        contactHelperEmail: nil
                    )
                }
                evidenceData = nil
            }
        }
    }

    @MainActor
    private func fetchEvidence(generation: Int) async {
        do {
            let evidence = try await store.fetchPlacedOrderEvidence(requestID: requestID)
            guard generation == loadGeneration else { return }
            evidenceData = evidence.data
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            evidenceData = nil
            // The diagnostic is intentionally content-free: no request id,
            // credential, contact value, order number, or screenshot data.
            print("[R3] Placed-order evidence unavailable")
        }
    }

    @MainActor
    private func scheduleReadinessRefresh(_ order: PlacedOrder) {
        readinessTask?.cancel()
        guard let remaining = order.secondsUntilPickupAttention(), remaining > 0 else {
            readinessTask = nil
            return
        }
        let expectedID = order.id
        readinessTask = Task {
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled, detail?.request.id == expectedID else { return }
            self.readinessRevision += 1
        }
    }

    @MainActor
    private static func timeText(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(
                date: .omitted,
                time: .shortened,
                timeZone: NYUCampusTime.timeZone
            )
        )
    }

    static func mailURL(_ email: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        return components.url
    }
}

private struct PlacedOrderStatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: CommonPlateStyle.Spacing.s) {
            configuration.icon
                .font(.system(size: 8, weight: .bold))
            configuration.title
        }
    }
}
