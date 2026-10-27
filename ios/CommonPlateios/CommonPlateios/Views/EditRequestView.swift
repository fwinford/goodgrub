//
//  EditRequestView.swift
//  CommonPlateios
//
// W4-R5 Edit Request: the Request a Meal form's fields, prefilled from the
// confirmed saved request, saved with `Save Changes`. Edit never creates a
// request and never consumes a daily slot; it changes the same request
// identity, guarded by the content revision the saved copy was read at.
//
// Optional Screenshot Assistance (D-R5-4) reuses the accepted R4.2 domain layer
// through `EditScreenshotAssistanceState`; prior screenshots and provenance are
// never restored. What is deliberately not here: the create flow's D2
// create-recovery machinery. Edit has its own recovery — one unresolved
// update, replayed under the same identity only when the student taps Save
// Changes again (`RequestStore.retryUnresolvedUpdate`). While such an update is
// unconfirmed the form is read-only and shows the content that is awaiting
// confirmation, so a replay can never apply content the form no longer shows.
import SwiftUI
import PhotosUI

struct EditRequestView: View {
    @ObservedObject var store: RequestStore
    @ObservedObject var screenshotProposalStore: ScreenshotProposalStore
    @ObservedObject var identityStore: ParticipantIdentityStore
    @Binding var path: [AppRoute]
    /// The saved request this edit starts from. Its `contentRevision` is the
    /// compare-and-swap authority a save is sent with.
    @State private var owner: OwnerRequest
    @State private var draft: RequestFoodFormDraft
    @State private var outcome: EditRequestPresentation.SaveOutcome?
    @State private var showsDiscardConfirmation = false
    @State private var isSaving = false
    @State private var showsFieldErrors = false
    @State private var assist: EditScreenshotAssistanceState
    @State private var selectedScreenshotItems: [PhotosPickerItem] = []
    @State private var isPresentingScreenshotPicker = false
    @State private var expandedMealIndex: Int?
    @State private var isPresentingTimingInfo = false
    @State private var isPresentingScreenshotHelp = false
    @State private var isPresentingScreenshotDisclosure = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        store: RequestStore,
        screenshotProposalStore: ScreenshotProposalStore,
        identityStore: ParticipantIdentityStore,
        owner: OwnerRequest,
        path: Binding<[AppRoute]>
    ) {
        self.store = store
        self.screenshotProposalStore = screenshotProposalStore
        self.identityStore = identityStore
        self._path = path
        self._owner = State(initialValue: owner)
        // An unconfirmed edit for this request: show the exact content that is
        // awaiting confirmation, not the saved copy.
        if let pending = store.unresolvedUpdate,
           pending.kind == .edit,
           pending.requestID == owner.id,
           let payload = pending.editPayload {
            let initial = EditRequestPresentation.draft(from: payload, original: owner)
            self._draft = State(initialValue: initial)
            self._assist = State(initialValue: .seeded(from: initial))
        } else {
            let initial = EditRequestPresentation.draft(from: owner)
            self._draft = State(initialValue: initial)
            self._assist = State(initialValue: .seeded(from: initial))
        }
    }

    // MARK: State derivation

    private var pendingEdit: PendingRequestUpdate? {
        guard let pending = store.unresolvedUpdate,
              pending.kind == .edit, pending.requestID == owner.id else { return nil }
        return pending
    }

    private var isLockedByUnconfirmedEdit: Bool { pendingEdit != nil }

    /// A save in flight has already captured the draft; no screenshot result
    /// may change what was sent.
    private var screenshotsBlocked: Bool {
        isLockedByUnconfirmedEdit || isSaving || store.isUpdatingRequest
    }

    private var now: Date { Date() }

    private var horizon: EditRequestPresentation.Horizon {
        EditRequestPresentation.horizon(owner: owner, now: now)
    }

    private var hasChanges: Bool {
        EditRequestPresentation.hasChanges(draft: draft, owner: owner, now: now)
    }

    private var canSave: Bool {
        guard !isSaving, !store.isUpdatingRequest else { return false }
        if isLockedByUnconfirmedEdit { return true }
        return hasChanges && RequestFoodFormValidator.hasRequiredInput(draft)
    }

    /// The message shown above Save: an unconfirmed edit always (it is the
    /// state of the world), otherwise the last save outcome.
    private var visibleOutcome: EditRequestPresentation.SaveOutcome? {
        if isLockedByUnconfirmedEdit { return .unconfirmedEdit }
        if let unresolved = store.unresolvedUpdate, unresolved.kind == .withdraw,
           unresolved.requestID == owner.id { return .unconfirmedWithdraw }
        return outcome
    }

    private var errors: [RequestFoodFieldError] {
        RequestFoodFormValidator.validate(
            draft: draft,
            isScheduledWindowValid: true,
            isScheduledTimingAvailable: true
        )
        .filter { !$0.error.isIncompleteEntry || showsFieldErrors }
        .filter { $0.field != .pickupSchedule }
    }

    // MARK: Body

    var body: some View {
        ZStack {
            formBody
                .overlay(alignment: .top) {
                    if assist.preservedEntryFeedback.isShowing {
                        Text(RequestFoodView.preservedEntryFeedbackMessage)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.vertical, CommonPlateStyle.Spacing.s)
                            .padding(.horizontal, CommonPlateStyle.Spacing.m)
                            .background(
                                CommonPlateStyle.Color.warmSurface,
                                in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                            )
                            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                            .padding(.top, CommonPlateStyle.Spacing.s)
                            .accessibilityIdentifier("edit-request-screenshot-preserved-feedback")
                            .transition(.opacity)
                    }
                }
                .accessibilityHidden(isPresentingScreenshotHelp || isPresentingScreenshotDisclosure)
            if isPresentingScreenshotHelp { screenshotHelpOverlay }
            if isPresentingScreenshotDisclosure { screenshotDisclosureOverlay }
        }
        .navigationTitle(EditRequestPresentation.screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            if !isPresentingScreenshotHelp && !isPresentingScreenshotDisclosure {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: attemptBack) {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("edit-request-back")
                }
            }
        }
        .onDisappear {
            screenshotProposalStore.invalidateCurrentSelection()
            assist.clearResults()
        }
        .onChange(of: screenshotProposalStore.isAIAssistanceEnabled) { _, isEnabled in
            if !isEnabled { assist.clearResults() }
        }
        .onChange(of: isLockedByUnconfirmedEdit) { _, isLocked in
            // The locked form shows exactly the content awaiting confirmation;
            // no screenshot result may reach it.
            if isLocked {
                screenshotProposalStore.invalidateCurrentSelection()
                assist.clearResults()
            }
        }
        .onChange(of: selectedScreenshotItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            guard !screenshotsBlocked else {
                selectedScreenshotItems = []
                return
            }
            // Minted synchronously: the last selection wins from the moment it
            // is chosen, not from when its preprocessing finishes.
            let token = screenshotProposalStore.beginSelection(
                clearing: &draft,
                manualEdits: assist.manualEdits
            )
            assist.beginSelection()
            Task { await processSelectedScreenshots(newItems, token: token) }
        }
        .photosPicker(
            isPresented: $isPresentingScreenshotPicker,
            selection: $selectedScreenshotItems,
            maxSelectionCount: ScreenshotProposalStore.maxScreenshotSelection,
            matching: .images,
            photoLibrary: .shared()
        )
    }

    private var formBody: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
                    Text(RequestFoodView.yourOrderEyebrow)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)

                    if screenshotProposalStore.isAssistanceAvailable {
                        EditScreenshotAssistanceRow(
                            isEnabled: screenshotProposalStore.isAIAssistanceEnabled,
                            isApplying: screenshotProposalStore.isApplying,
                            checked: assist.checked,
                            notice: screenshotProposalStore.notice,
                            onTurnOn: { isPresentingScreenshotDisclosure = true },
                            onChoose: beginScreenshotAssistanceFlow
                        )
                    }

                    if let recovery = assist.venueRecovery.recovery {
                        venueRecoveryCallout(recovery)
                    }

                    if !assist.venueRecoveryIsUnresolved {
                        diningLocation
                    }
                    menuPath

                    switch draft.menuPath {
                    case .mealExchange: mealExchangeFields
                    case .diningDollars: diningDollarsOnlyFields
                    }

                    timingSection
                }
                .padding(.horizontal, CommonPlateStyle.Metrics.homeContentColumnInset)
                .padding(.vertical, CommonPlateStyle.Spacing.m)
                .disabled(isLockedByUnconfirmedEdit)
            }
            .scrollDismissesKeyboard(.interactively)

            saveBar
        }
        .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
        .environment(\.timeZone, NYUCampusTime.timeZone)
        .environment(\.calendar, NYUCampusTime.calendar)
        .alert(
            EditRequestPresentation.discardTitle,
            isPresented: $showsDiscardConfirmation
        ) {
            Button(EditRequestPresentation.keepEditingTitle, role: .cancel) {}
            Button(EditRequestPresentation.discardChangesTitle, role: .destructive) {
                dismiss()
            }
        } message: {
            Text(EditRequestPresentation.discardMessage)
        }
        .onChange(of: store.ownerRequests) { _, latest in
            // A fresher read of this request never rewrites the draft; it only
            // keeps the revision a later Save is sent with current.
            if let fresh = latest.first(where: { $0.id == owner.id }),
               fresh.contentRevision != owner.contentRevision,
               outcome == .conflict {
                owner = fresh
            }
        }
    }

    // MARK: Fields

    private var diningSpots: [DiningSpot] {
        var spots = SupportedVendorCatalog.diningSpots
        // An unchanged vendor is preserved exactly even if the catalog no longer
        // lists it; nothing is fabricated for it (no address).
        if let current = draft.selectedDiningSpot, !spots.contains(where: { $0.name == current.name }) {
            spots.insert(current, at: 0)
        }
        return spots
    }

    private var diningSpotMenu: some View {
        Menu {
            ForEach(diningSpots) { spot in
                Button(spot.name) { assist.setLocation(spot, in: &draft) }
            }
        } label: {
            HStack {
                Text(draft.selectedDiningSpot?.name ?? RequestFoodView.selectDiningLocationPlaceholder)
                    .font(.subheadline)
                    .foregroundStyle(draft.selectedDiningSpot == nil ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("edit-request-dining-spot-picker")
        .tint(Color("AccentColor"))
    }

    private var diningLocation: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
            RequesterFormFieldContainer(
                label: RequestFoodView.diningLocationLabel,
                manualProvenanceLabel: assist.venueRecovery.showsManualLocationProvenance
                    ? RequestFoodView.manuallySelectedLabel : nil,
                showsProvenance: assist.provenance.location,
                isGlowing: false,
                provenanceIdentifier: "edit-request-dining-spot-provenance"
            ) {
                diningSpotMenu
            }
            fieldError(.diningSpot, identifier: "edit-request-dining-spot-error")
        }
    }

    private var menuPath: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.s) {
            Text(RequestFoodView.menuPathLabel)
                .font(.subheadline.weight(.semibold))
            if let conflict = assist.menuPathConflict.suggestion {
                EditScreenshotSuggestionInset(
                    message: "We found \(RequestFoodView.menuPathTitle(conflict.proposedPath))",
                    actionTitle: "Switch",
                    onAction: {
                        assist.switchMenuPath(conflict, store: screenshotProposalStore, to: &draft)
                    },
                    onDismiss: {
                        assist.dismissMenuPathConflict(conflict, store: screenshotProposalStore)
                    },
                    dismissLabel: "Dismiss menu suggestion",
                    identifier: "edit-request-menu-path-conflict"
                )
            }
            HStack(spacing: CommonPlateStyle.Spacing.xs) {
                ForEach(RequestFoodView.menuPathOptions, id: \.self) { option in
                    let isSelected = draft.menuPath == option
                    Button {
                        assist.setMenuPath(option, in: &draft)
                    } label: {
                        Text(RequestFoodView.menuPathTitle(option))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, CommonPlateStyle.Spacing.s)
                            .background(
                                isSelected ? CommonPlateStyle.Color.baseCanvas : Color.clear,
                                in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard - 3, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                    .accessibilityIdentifier(
                        option == .mealExchange
                            ? "edit-request-menu-path-meal-exchange"
                            : "edit-request-menu-path-dining-dollars"
                    )
                }
            }
            .padding(CommonPlateStyle.Spacing.xs)
            .background(
                CommonPlateStyle.Color.requestCardSurface,
                in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                    .strokeBorder(CommonPlateStyle.Color.requestCardBorder)
            )
        }
    }

    private var mealExchangeFields: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
            diningDollarsField(label: "Dining Dollars", trailing: "Optional")

            RequesterFormFieldContainer(
                label: RequestFoodView.mealSwipesLabel,
                manualProvenanceLabel: assist.manualEdits.hasManuallyEditedMealSwipes
                    && assist.mealSwipeMismatch.showsManualProvenance ? RequestFoodView.manuallySelectedLabel : nil,
                showsProvenance: assist.provenance.mealSwipes,
                isGlowing: false,
                provenanceIdentifier: "edit-request-meal-swipes-provenance",
                assistance: assist.mealSwipeMismatch.suggestion.map { mismatch in
                    AnyView(EditScreenshotSuggestionInset(
                        message: mismatch.message,
                        actionTitle: mismatch.action,
                        onAction: {
                            assist.adoptSuggestedMealSwipes(mismatch, store: screenshotProposalStore, to: &draft)
                        },
                        onDismiss: {
                            assist.dismissMealSwipeMismatch(mismatch, store: screenshotProposalStore, in: &draft)
                        },
                        dismissLabel: "Dismiss meal swipe suggestion",
                        identifier: "edit-request-meal-swipe-mismatch"
                    ))
                }
            ) {
                RequesterMealSwipesMenu(
                    count: mealSwipesBinding,
                    label: RequestFoodView.mealSwipesLabel,
                    identifier: "edit-request-meal-swipes"
                )
            }

            VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.s) {
                Text("Order details")
                    .font(.subheadline.weight(.semibold))
                ForEach(Array(draft.activeMealEntryIndices), id: \.self) { index in
                    let meal = draft.mealEntries[index]
                    VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
                        RequesterMealEntryControl(
                            label: RequestFoodView.mealDetailLabel(index: index),
                            index: index,
                            identifierPrefix: "edit-request-meal",
                            isExpanded: expandedMealIndex == index,
                            mealName: meal.name,
                            mealDetails: meal.details,
                            hasError: errors.contains { $0.field == .mealDetail(index: index) },
                            onExpand: { expandedMealIndex = index },
                            onDone: { expandedMealIndex = nil },
                            trailing: { EmptyView() },
                            item: {
                                TextField("e.g. Chicken Wings", text: mealName(index), axis: .vertical)
                                    .font(RequestFoodView.mealEditorValueFont)
                                    .lineLimit(2)
                                    .accessibilityIdentifier("edit-request-meal-name-\(index)")
                            },
                            details: {
                                TextField(RequestFoodView.mealDetailsPlaceholder, text: mealDetails(index), axis: .vertical)
                                    .font(RequestFoodView.mealEditorValueFont)
                                    .lineLimit(3)
                                    .accessibilityIdentifier("edit-request-meal-details-\(index)")
                            }
                        )
                        fieldError(.mealDetail(index: index), identifier: "edit-request-meal-error-\(index)")
                    }
                }
            }
        }
    }

    private var diningDollarsOnlyFields: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
            RequesterFormFieldContainer(label: RequestFoodView.orderDetailsLabel) {
                TextField(RequestFoodView.orderDetailsPlaceholder, text: orderDetailsBinding, axis: .vertical)
                    .font(.subheadline)
                    .accessibilityIdentifier("edit-request-order-details")
            }
            fieldError(.orderDetails, identifier: "edit-request-order-details-error")
            diningDollarsField(label: "Dining Dollars", trailing: nil)
        }
    }

    private func diningDollarsField(label: String, trailing: String?) -> some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
            RequesterFormFieldContainer(label: label, trailingLabel: trailing) {
                TextField("$0.00", text: Binding(
                    get: { draft.diningDollarsText },
                    set: { assist.setDiningDollars($0, in: &draft) }
                ))
                .keyboardType(.decimalPad)
                .font(.subheadline)
                .accessibilityIdentifier("edit-request-dining-dollars")
            }
            fieldError(.diningDollars, identifier: "edit-request-dining-dollars-error")
        }
    }

    /// The bordered control box of `RequesterFormFieldContainer`, without its
    /// label row, for fields that already sit under a heading.
    private func boxed<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CommonPlateStyle.Color.baseCanvas)
            .overlay(
                RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                    .strokeBorder(CommonPlateStyle.Color.requestCardBorder)
            )
            .clipShape(RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous))
    }

    private var mealSwipesBinding: Binding<Int> {
        Binding(
            get: { draft.mealSwipes },
            set: { assist.setMealSwipes($0, in: &draft) }
        )
    }

    private var orderDetailsBinding: Binding<String> {
        Binding(
            get: { draft.orderDetails },
            set: { assist.setOrderDetails($0, in: &draft) }
        )
    }

    private func mealName(_ index: Int) -> Binding<String> {
        Binding(
            get: { draft.mealEntries[index].name },
            set: { assist.setMealName($0, at: index, in: &draft) }
        )
    }

    private func mealDetails(_ index: Int) -> Binding<String> {
        Binding(
            get: { draft.mealEntries[index].details ?? "" },
            set: { assist.setMealDetails($0, at: index, in: &draft) }
        )
    }

    @ViewBuilder
    private func fieldError(_ field: RequestFoodFormField, identifier: String) -> some View {
        if let error = errors.first(where: { $0.field == field }) {
            Text(error.message)
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier(identifier)
        }
    }

    // MARK: Timing

    private var timingSection: some View {
        let horizon = horizon
        return VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
            RequesterTimingHeader(
                isPresentingInfo: $isPresentingTimingInfo,
                infoIdentifier: "edit-request-timing-info"
            )

            HStack(spacing: CommonPlateStyle.Spacing.xs) {
                ForEach(RequestTiming.allCases) { option in
                    let isSelected = draft.timing == option
                    // Neither option can be newly chosen once no start remains
                    // inside the original creation day; the option the request
                    // already has stays selected (an unchanged timing is never
                    // held to the horizon).
                    let isOffered = horizon.canSchedule || isSelected
                    Button {
                        select(option, horizon: horizon)
                    } label: {
                        Text(option.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, CommonPlateStyle.Spacing.s)
                            .background(
                                isSelected ? CommonPlateStyle.Color.baseCanvas : Color.clear,
                                in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard - 3, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!isOffered)
                    .opacity(isOffered ? 1 : 0.4)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                    .accessibilityIdentifier("edit-request-timing-\(option == .asap ? "asap" : "later")")
                }
            }
            .padding(CommonPlateStyle.Spacing.xs)
            .background(
                CommonPlateStyle.Color.requestCardSurface,
                in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
            )

            if draft.timing == .later && horizon.canSchedule {
                // The limit itself is explained in the Timing info; only a start
                // outside it is flagged here.
                if EditRequestPresentation.timingChange(draft: draft, original: owner).timing == .scheduled,
                   !EditRequestPresentation.isSelectableStart(draft.preferredPickupTime, now: now, horizon: horizon) {
                    Text(EditRequestPresentation.horizonMessage(horizon: horizon))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("edit-request-horizon-message")
                }

                // The picker cannot offer an invalid start: its range is "from
                // now" to the original creation day's 11:30 PM.
                DatePicker(
                    "Start",
                    selection: $draft.preferredPickupTime,
                    in: pickerRange(horizon: horizon),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .font(.subheadline)
                .accessibilityIdentifier("edit-request-start-picker")
            }

            if !horizon.canSchedule {
                Text(EditRequestPresentation.horizonPassedMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("edit-request-horizon-passed")
            }
        }
    }

    private func pickerRange(horizon: EditRequestPresentation.Horizon) -> ClosedRange<Date> {
        let lower = min(now, horizon.latestStart)
        return lower...horizon.latestStart
    }

    private func select(_ option: RequestTiming, horizon: EditRequestPresentation.Horizon) {
        guard draft.timing != option else { return }
        draft.timing = option
        guard option == .later else { return }
        // The first valid start inside the horizon; a student's earlier saved
        // Later start is kept when it is still selectable.
        let saved = owner.request.windowStart
        let candidate = saved ?? now.addingTimeInterval(30 * 60)
        draft.preferredPickupTime = min(max(candidate, now), horizon.latestStart)
    }

    // MARK: Screenshot Assistance

    private func venueRecoveryCallout(_ recovery: ScreenshotVenueRecovery) -> some View {
        RequesterVenueRecoveryCallout(
            recovery: recovery,
            isAutofillEnabled: draft.selectedDiningSpot != nil,
            canTryOtherScreenshots: screenshotProposalStore.isAssistanceAvailable
                && screenshotProposalStore.isAIAssistanceEnabled
                && !screenshotProposalStore.isApplying,
            onConfirm: {
                let generation = assist.confirmVenueRecovery(recovery, store: screenshotProposalStore, to: &draft)
                schedulePreservedFeedbackTimeout(generation)
            },
            onDismiss: { assist.dismissVenueRecovery(recovery, store: screenshotProposalStore) },
            onTryOtherScreenshots: {
                guard screenshotProposalStore.isAIAssistanceEnabled,
                      !screenshotProposalStore.isApplying else { return }
                beginScreenshotAssistanceFlow()
            }
        ) {
            diningSpotMenu
        }
    }

    private func beginScreenshotAssistanceFlow() {
        guard screenshotProposalStore.isAssistanceAvailable,
              screenshotProposalStore.isAIAssistanceEnabled,
              !screenshotProposalStore.isApplying,
              !screenshotsBlocked else { return }
        proceedToScreenshotSelection()
    }

    private func proceedToScreenshotSelection() {
        if screenshotProposalStore.hasCompletedScreenshotHelp {
            isPresentingScreenshotPicker = true
        } else {
            isPresentingScreenshotHelp = true
        }
    }

    @MainActor
    private func processSelectedScreenshots(
        _ items: [PhotosPickerItem],
        token: ScreenshotSelectionToken
    ) async {
        selectedScreenshotItems = []
        let bounded = Array(items.prefix(ScreenshotProposalStore.maxScreenshotSelection))
        guard bounded.count == items.count else { return }

        // Every stage re-checks currency and consent: a newer selection, or
        // Screenshot Assistance turned Off, stops this exact attempt.
        var inputs: [ScreenshotPreparedImage] = []
        for item in bounded {
            guard let data = try? await item.loadTransferable(type: Data.self) else { return }
            guard screenshotProposalStore.isCurrent(token),
                  screenshotProposalStore.isAIAssistanceEnabled else { return }
            guard let input = ScreenshotInputPreparer.prepare(
                imageData: data,
                isStillCurrent: {
                    screenshotProposalStore.isCurrent(token) && screenshotProposalStore.isAIAssistanceEnabled
                }
            ) else { return }
            inputs.append(input)
        }
        guard !inputs.isEmpty else { return }

        let outcome = await screenshotProposalStore.analyzeScreenshot(
            images: inputs,
            participantAuthority: { identityStore.currentAuthority() },
            token: token
        )
        guard let outcome,
              screenshotProposalStore.isCurrent(token),
              !screenshotsBlocked else { return }
        let generation = assist.apply(outcome, token: token, store: screenshotProposalStore, to: &draft)
        schedulePreservedFeedbackTimeout(generation)
    }

    private var screenshotHelpOverlay: some View {
        ZStack {
            Color.black.opacity(0.34).accessibilityHidden(true)
            ScreenshotHelpView {
                screenshotProposalStore.recordScreenshotHelpCompleted()
                isPresentingScreenshotHelp = false
                isPresentingScreenshotPicker = true
            }
            .modalCard(dynamicTypeSize: dynamicTypeSize)
            .accessibilityIdentifier("edit-request-screenshot-help-modal")
        }
        .ignoresSafeArea()
    }

    private var screenshotDisclosureOverlay: some View {
        ZStack {
            Color.black.opacity(0.34).accessibilityHidden(true)
            ScreenshotAssistanceDisclosureView(
                onTurnOn: {
                    isPresentingScreenshotDisclosure = false
                    screenshotProposalStore.setAIAssistanceEnabled(true)
                    proceedToScreenshotSelection()
                },
                onNotNow: { isPresentingScreenshotDisclosure = false }
            )
            .modalCard(dynamicTypeSize: dynamicTypeSize)
            .accessibilityIdentifier("edit-request-screenshot-disclosure-modal")
        }
        .ignoresSafeArea()
    }

    // MARK: Save

    private var saveBar: some View {
        VStack(spacing: CommonPlateStyle.Spacing.s) {
            if let visible = visibleOutcome,
               let message = EditRequestPresentation.message(for: visible) {
                CommonPlateInlineStatus(
                    kind: EditRequestPresentation.statusKind(for: visible),
                    message: message
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("edit-request-outcome")
            }

            Button {
                Task { await save() }
            } label: {
                Text(EditRequestPresentation.saveChangesTitle)
                    .frame(maxWidth: .infinity)
            }
            .commonPlateMajorPrimaryAction()
            .disabled(!canSave)
            .accessibilityIdentifier("edit-request-save")
        }
        .padding(.horizontal, CommonPlateStyle.Metrics.homeContentColumnInset)
        .padding(.top, CommonPlateStyle.Spacing.s)
        .padding(.bottom, CommonPlateStyle.Spacing.s)
        .background(CommonPlateStyle.Color.baseCanvas)
    }

    private func attemptBack() {
        // An unconfirmed edit is not a draft the student can discard by leaving:
        // it stays durable and is shown again. Only unsaved edits ask first.
        if hasChanges && !isLockedByUnconfirmedEdit {
            showsDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    /// Fenced only by the feedback's own generation, as on the create form.
    private func schedulePreservedFeedbackTimeout(_ generation: Int?) {
        guard let generation else { return }
        Task { @MainActor in
            try? await Task.sleep(for: RequestFoodView.preservedEntryFeedbackDuration)
            assist.preservedEntryFeedback.clearAfterTimeout(ifCurrent: generation)
        }
    }

    @MainActor
    private func save() async {
        guard canSave else { return }
        showsFieldErrors = true
        outcome = nil
        isSaving = true
        screenshotProposalStore.invalidateCurrentSelection()
        // Every held suggestion's token is now stale; leaving it visible would
        // present actions that silently do nothing.
        assist.clearResults()
        defer { isSaving = false }
        let attemptedAt = Date()
        do {
            let result: EditOutcome?
            if let pending = pendingEdit {
                // User-initiated recovery: the same identity and stored payload,
                // named explicitly so it can only replay this very operation.
                result = try await store.retryUnresolvedUpdate(matching: pending)
            } else {
                let payload = try EditRequestPresentation.makePayload(
                    draft: draft,
                    owner: owner,
                    now: attemptedAt
                )
                result = try await store.editRequest(requestID: owner.id, payload: payload)
            }
            if result != nil {
                finishSaved()
            }
        } catch let error as EditRequestPresentation.PayloadError {
            outcome = payloadOutcome(error)
        } catch {
            handle(error, at: attemptedAt)
        }
    }

    private func payloadOutcome(_ error: EditRequestPresentation.PayloadError) -> EditRequestPresentation.SaveOutcome? {
        switch error {
        case .unusableTiming:
            return .horizon(tonight: horizon.canSchedule && horizon.creationDayIsToday)
        case .invalid:
            // Field errors are already presented beside their fields.
            return nil
        }
    }

    private func handle(_ error: Error, at attemptedAt: Date) {
        let result = EditRequestPresentation.saveOutcome(
            for: error,
            unresolved: store.unresolvedUpdate,
            owner: owner,
            now: attemptedAt
        )
        switch result {
        case .withdrawn:
            store.reportOwnRequestWithdrawn(requestID: owner.id)
            path = []
        case .expired:
            store.reportOwnRequestExpired(owner)
            path = []
        case .conflict:
            outcome = .conflict
            // Re-read so a deliberate second Save is sent against the latest
            // revision; the student's draft is never replaced.
            Task {
                if let fresh = try? await store.fetchOwnerRequest(id: owner.id) {
                    owner = fresh
                }
            }
        default:
            outcome = result
        }
    }

    private func finishSaved() {
        // The route is removed; the detail beneath re-reads and shows
        // `Changes saved` once (`RequestStore.changesSavedRequestID`).
        if let index = path.lastIndex(where: {
            if case .editRequest(let value) = $0 { return value.id == owner.id }
            return false
        }) {
            path.removeSubrange(index...)
        } else {
            dismiss()
        }
    }
}

private extension View {
    /// The same centered modal shell Request a Meal uses for Screenshot Help
    /// and the Screenshot Assistance disclosure.
    func modalCard(dynamicTypeSize: DynamicTypeSize) -> some View {
        frame(width: 314)
            .frame(maxHeight: dynamicTypeSize.isAccessibilitySize ? 480 : nil)
            .background(
                CommonPlateStyle.Color.baseCanvas,
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: Color.black.opacity(0.12), radius: 18, y: 8)
            .padding(.horizontal, CommonPlateStyle.Spacing.l)
            .accessibilityAddTraits(.isModal)
    }
}
