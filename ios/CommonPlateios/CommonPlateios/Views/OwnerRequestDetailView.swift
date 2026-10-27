//
//  OwnerRequestDetailView.swift
//  CommonPlateios
//
// W4-R5 requester-owned request detail (Figma `Request detail` Available,
// Scheduled and Being helped; Withdraw stacked confirmation; Changes saved;
// Your request expired).
//
// The pushed snapshot is only a starting point. On appearance the screen
// re-reads current owner truth from the backend, so the actions it offers —
// Edit, Withdraw — are the backend's reading *now*, and a stale card can never
// authorize anything: both mutations re-check atomically on the backend and a
// stale `true` can only earn a definitive refusal.
//
// Nothing here fabricates an outcome. A Withdraw whose result is unknown is
// shown as exactly that, and the student's next Withdraw confirmation replays
// the *same* operation identity; it is never presented as withdrawn or as
// failed, and never started as a second operation.
import SwiftUI

struct OwnerRequestDetailView: View {
    @ObservedObject var store: RequestStore
    @Binding var path: [AppRoute]
    @State private var owner: OwnerRequest
    @State private var loadState: LoadState = .idle
    @State private var withdrawOutcome: EditRequestPresentation.WithdrawOutcome?
    @State private var showsWithdrawConfirmation = false
    @State private var isExpired = false
    @State private var isRemoved = false
    @State private var isWithdrawing = false

    enum LoadState: Equatable {
        case idle
        case loading
        /// The fresh read could not be established. The pushed snapshot stays on
        /// screen, but its actions are not offered as current.
        case unverified
        case loaded
    }

    init(store: RequestStore, owner: OwnerRequest, path: Binding<[AppRoute]>) {
        self.store = store
        self._path = path
        self._owner = State(initialValue: owner)
    }

    // MARK: Pure presentation (testable)

    /// One owner-phase status, using the backend's availability or start time.
    static func statusLine(for owner: OwnerRequest) -> String {
        switch owner.phase {
        case .available: return "Available to helpers until \(clockText(owner.request.expiresAt))"
        case .reserved: return "Being helped"
        case .scheduled:
            guard let start = owner.request.windowStart else { return "Scheduled" }
            return "Scheduled for \(clockText(start))"
        }
    }

    static func showsStatusDot(for owner: OwnerRequest) -> Bool {
        owner.phase != .scheduled
    }

    static func clockText(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, timeZone: NYUCampusTime.timeZone)
        )
    }

    static let detailsHeading = "Request details"
    static let withdrawLinkTitle = "Withdraw request"
    static let withdrawConfirmationTitle = "Withdraw this request?"
    static let withdrawConfirmationMessage =
        "It will no longer be available to helpers. This request will still count toward today’s limit."
    static let keepRequestTitle = "Keep request"
    static let expiredTitle = "Your request expired"
    static let expiredBody = "This request is no longer active.\nIf you still need a meal, you can try again."

    // MARK: Derived

    private var pendingForThisRequest: PendingRequestUpdate? {
        guard let pending = store.unresolvedUpdate, pending.requestID == owner.id else { return nil }
        return pending
    }

    /// The message state for an update whose outcome is unknown, else the last
    /// withdraw outcome.
    private var visibleOutcome: EditRequestPresentation.WithdrawOutcome? {
        if let pending = pendingForThisRequest {
            return pending.kind == .withdraw ? .unconfirmedWithdraw : .unconfirmedEdit
        }
        return withdrawOutcome
    }

    private var isReserved: Bool { owner.phase == .reserved }

    /// Actions are the backend's current reading, and only once that reading
    /// has been established (or the snapshot was pushed from a read this
    /// session made): an unverified detail offers none as current.
    private var offersActions: Bool { loadState != .unverified }

    /// Requester Block from reservation start (accepted MSG1 / U1.3). The
    /// backend resolves the live reserved helper and refuses otherwise.
    private var offersReservedRequesterSafety: Bool {
        isReserved && offersActions && store.hasVerifiedParticipantAuthority
    }

    private var canEdit: Bool {
        offersActions && owner.canEdit && pendingForThisRequest?.kind != .withdraw
    }

    private var canWithdraw: Bool {
        offersActions && owner.canWithdraw && !isWithdrawing && !store.isUpdatingRequest
    }

    // MARK: Body

    var body: some View {
        Group {
            if isExpired {
                expiredOutcome
            } else if isRemoved {
                removedOutcome
            } else {
                detail
            }
        }
        .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
        .task { await reload() }
        .onChange(of: store.changesSavedRequestID) { _, saved in
            if saved == owner.id { Task { await reload() } }
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
                    statusRow

                    if store.changesSavedRequestID == owner.id {
                        savedBanner
                    }

                    if let message = visibleOutcome.flatMap({ EditRequestPresentation.message(for: $0) }) {
                        outcomeBanner(message)
                    }

                    if loadState == .unverified {
                        CommonPlateInlineStatus(
                            kind: .unavailable,
                            message: "Couldn’t open this request. Please try again."
                        )
                        .accessibilityIdentifier("owner-request-unverified")
                    }

                    detailsCard

                    if isReserved && offersActions {
                        RequestConversationEntryRow(
                            requestID: owner.id,
                            role: .requester,
                            path: $path
                        )
                    }

                    if canWithdraw && !isReserved {
                        Button {
                            showsWithdrawConfirmation = true
                        } label: {
                            Text(Self.withdrawLinkTitle)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Self.destructiveColor)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                // The whole 44pt row is the target, not just the
                                // glyphs.
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("owner-request-withdraw")
                    }
                }
                .padding(.horizontal, CommonPlateStyle.Metrics.homeContentColumnInset)
                .padding(.vertical, CommonPlateStyle.Spacing.m)
            }

            editBar
        }
        .navigationTitle("Your request")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(RequestDetailBlockMenu(
            store: store,
            requestID: owner.id,
            isOffered: offersReservedRequesterSafety,
            onBlocked: { path = AppRoute.afterParticipantBlock(from: path) },
            isReportOffered: ParticipantReportAvailability.reservedRequesterOffersReport(
                isReserved: isReserved && offersActions,
                hasVerifiedIdentity: store.hasVerifiedParticipantAuthority
            ) && !store.hasReportedRequest(requestID: owner.id),
            onReport: {
                store.presentReportPopup(
                    requestID: owner.id,
                    returnsHome: false,
                    offersBlockAfter: offersReservedRequesterSafety
                )
            },
            isSuppressed: AppRoute.hasOpenConversation(in: path)
        ))
        .alert(Self.withdrawConfirmationTitle, isPresented: $showsWithdrawConfirmation) {
            Button(Self.keepRequestTitle, role: .cancel) {}
            Button(Self.withdrawLinkTitle, role: .destructive) {
                Task { await withdraw() }
            }
        } message: {
            Text(Self.withdrawConfirmationMessage)
        }
    }

    private var statusRow: some View {
        HStack(spacing: CommonPlateStyle.Spacing.s) {
            if Self.showsStatusDot(for: owner) {
                Circle()
                    .fill(isReserved ? Self.beingHelpedColor : CommonPlateStyle.Color.timing)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
            Text(Self.statusLine(for: owner))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isReserved ? Self.beingHelpedColor : CommonPlateStyle.Color.timing)
                .accessibilityIdentifier("owner-request-status")
        }
    }

    private var savedBanner: some View {
        Label(EditRequestPresentation.changesSavedNotice, systemImage: "checkmark")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(CommonPlateStyle.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                CommonPlateStyle.Color.helpingCardSurface,
                in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
            )
            .accessibilityIdentifier("owner-request-changes-saved")
            .accessibilityAddTraits(.isStaticText)
            .onAppear {
                // Spoken once, because the notice leaves on its own timer.
                AccessibilityNotification.Announcement(EditRequestPresentation.changesSavedNotice).post()
                // Shown once: it is a fact about the save that just committed.
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    store.acknowledgeChangesSaved(requestID: owner.id)
                }
            }
    }

    private func outcomeBanner(_ message: String) -> some View {
        let kind: CommonPlateStatusKind = {
            guard let outcome = visibleOutcome else { return .error }
            switch outcome {
            case .reserved: return .conflict
            case .unconfirmedWithdraw, .unconfirmedEdit: return .uncertain
            default: return .error
            }
        }()
        return CommonPlateInlineStatus(kind: kind, message: message)
            .padding(CommonPlateStyle.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Self.bannerSurface,
                in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
            )
            .accessibilityIdentifier("owner-request-outcome")
    }

    private var detailsCard: some View {
        let request = owner.request
        return VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
            Text(Self.detailsHeading)
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 2) {
                Text(RequestCardView.quantityText(for: request))
                    .font(.headline)
                Text(request.diningSpot.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch request.resource.menuPath {
            case .mealExchange:
                ForEach(Array(RequestMealEntry.entries(for: request).enumerated()), id: \.offset) { index, meal in
                    Divider()
                    RequestMealView(entry: meal, density: .detail)
                        .accessibilityIdentifier("owner-request-meal-\(index + 1)")
                }
            case .diningDollars:
                Divider()
                Text(request.resource.orderDetails ?? request.foodDescription)
                    .font(.footnote.weight(.semibold))
            }

        }
        .padding(CommonPlateStyle.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            CommonPlateStyle.Color.requestCardSurface,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(CommonPlateStyle.Color.requestCardBorder)
        )
        .accessibilityIdentifier("owner-request-details")
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.footnote.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }

    private var editBar: some View {
        VStack(spacing: CommonPlateStyle.Spacing.xs) {
            if isReserved {
                Text(EditRequestPresentation.editDisabledWhileHelpedNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("owner-request-edit-disabled-note")
            }
            Button {
                path.append(.editRequest(owner))
            } label: {
                Text(EditRequestPresentation.screenTitle)
                    .frame(maxWidth: .infinity)
            }
            .commonPlateMajorPrimaryAction()
            .disabled(!canEdit)
            .accessibilityIdentifier("owner-request-edit")
        }
        .padding(.horizontal, CommonPlateStyle.Metrics.homeContentColumnInset)
        .padding(.vertical, CommonPlateStyle.Spacing.s)
        .background(CommonPlateStyle.Color.baseCanvas)
    }

    // MARK: Expired outcome (Figma `Your request expired`)

    private var expiredOutcome: some View {
        VStack(spacing: CommonPlateStyle.Spacing.l) {
            HStack {
                Spacer()
                CommonPlateCloseControl(action: leaveExpired)
                    .accessibilityIdentifier("owner-request-expired-close")
            }
            Spacer()
            VStack(spacing: CommonPlateStyle.Spacing.s) {
                Image(systemName: "fork.knife.circle")
                    .font(.system(size: 56))
                    .foregroundStyle(CommonPlateStyle.Color.brandFill)
                    .accessibilityHidden(true)
                Text(Self.expiredTitle)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("owner-request-expired")
                Text(Self.expiredBody)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: CommonPlateStyle.Metrics.stateContentWidth)
            Spacer()
            if RestrictedAccountPresentation.offersRequestAMeal(
                isRestricted: store.isParticipantRestricted
            ) {
                Button {
                    requestAMeal()
                } label: {
                    Text("Request a Meal")
                        .frame(maxWidth: .infinity)
                }
                .commonPlateMajorPrimaryAction()
                .accessibilityIdentifier("owner-request-expired-request-meal")
            }
        }
        .padding(CommonPlateStyle.Spacing.l)
        .navigationBarBackButtonHidden(true)
    }

    // MARK: Removed outcome (moderation removal, neutral notice)

    private var removedOutcome: some View {
        VStack(spacing: CommonPlateStyle.Spacing.l) {
            HStack {
                Spacer()
                CommonPlateCloseControl(action: leaveRemoved)
                    .accessibilityIdentifier("owner-request-removed-close")
            }
            Spacer()
            VStack(spacing: CommonPlateStyle.Spacing.s) {
                Image(systemName: "fork.knife.circle")
                    .font(.system(size: 56))
                    .foregroundStyle(CommonPlateStyle.Color.brandFill)
                    .accessibilityHidden(true)
                Text(RequestRemovedPresentation.message)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("owner-request-removed")
                CommonPlateSupportAction(title: RequestRemovedPresentation.supportActionTitle)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("owner-request-removed-contact-support")
            }
            .frame(maxWidth: CommonPlateStyle.Metrics.stateContentWidth)
            Spacer()
        }
        .padding(CommonPlateStyle.Spacing.l)
        .navigationBarBackButtonHidden(true)
    }

    private func leaveRemoved() {
        path = []
    }

    private func leaveExpired() {
        store.reportOwnRequestExpired(owner)
        path = []
    }

    private func requestAMeal() {
        store.reportOwnRequestExpired(owner)
        path = [.requestFood]
    }

    // MARK: Actions

    /// A fresh read of this request's current owner truth. A decoded terminal
    /// answer leaves the screen truthfully; anything else that cannot be
    /// established leaves the snapshot but withholds actions as current.
    @MainActor
    private func reload() async {
        loadState = .loading
        do {
            let fresh = try await store.fetchOwnerRequest(id: owner.id)
            owner = fresh
            loadState = .loaded
        } catch is CancellationError {
            loadState = .idle
        } catch let error as RequestServiceError {
            if RequestRemovedPresentation.isRemoval(error) {
                // Verified by the decoded code on this owner's own read: the
                // card is no longer ongoing work, and nothing else is inferred.
                store.reportOwnRequestNoLongerOngoing(requestID: owner.id)
                isRemoved = true
                loadState = .loaded
                return
            }
            if case .serverError(let code, _) = error {
                switch code {
                case RequestUpdateErrorCode.requestExpired:
                    isExpired = true
                    loadState = .loaded
                    return
                case RequestUpdateErrorCode.requestWithdrawn:
                    store.reportOwnRequestWithdrawn(requestID: owner.id)
                    path = []
                    return
                case RequestUpdateErrorCode.requestAlreadyPlaced:
                    // R5's owner read deliberately excludes placements. The
                    // exact R3 destination resolves its private continuation.
                    store.reportOwnRequestNoLongerOngoing(requestID: owner.id)
                    path = Array(path.dropLast()) + [.placedOrder(requestID: owner.id)]
                    return
                default:
                    break
                }
            }
            loadState = .unverified
        } catch {
            loadState = .unverified
        }
    }

    @MainActor
    private func withdraw() async {
        guard !isWithdrawing else { return }
        isWithdrawing = true
        withdrawOutcome = nil
        defer { isWithdrawing = false }
        do {
            if let pending = pendingForThisRequest, pending.kind == .withdraw {
                // The student's own tap replays the SAME identity.
                _ = try await store.retryUnresolvedUpdate(matching: pending)
            } else {
                try await store.withdrawRequest(requestID: owner.id)
            }
            // Decided: the store queued the one-time Home notice.
            path = []
        } catch {
            let outcome = EditRequestPresentation.withdrawOutcome(
                for: error,
                unresolved: store.unresolvedUpdate
            )
            switch outcome {
            case .withdrawn:
                store.reportOwnRequestWithdrawn(requestID: owner.id)
                path = []
            case .expired:
                isExpired = true
            case .reserved:
                withdrawOutcome = .reserved
                // The request is now being helped; re-read so the screen says so.
                await reload()
            default:
                withdrawOutcome = outcome
            }
        }
    }

    // MARK: Colors (adaptive; Figma light values, dark counterparts)

    private static let destructiveColor = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 235 / 255, green: 140 / 255, blue: 158 / 255, alpha: 1)
            : UIColor(red: 182 / 255, green: 91 / 255, blue: 113 / 255, alpha: 1)
    })

    private static let beingHelpedColor = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 214 / 255, green: 170 / 255, blue: 84 / 255, alpha: 1)
            : UIColor(red: 166 / 255, green: 123 / 255, blue: 45 / 255, alpha: 1)
    })

    private static let bannerSurface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.08)
            : UIColor(red: 246 / 255, green: 234 / 255, blue: 234 / 255, alpha: 1)
    })
}
