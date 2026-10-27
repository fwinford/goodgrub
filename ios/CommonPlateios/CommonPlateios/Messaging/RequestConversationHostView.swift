//
//  RequestConversationHostView.swift
//  CommonPlateios
//
// W4-MSG1 CP6 (iOS, dormant). Hosts one `ConversationScreen` for exactly one
// (request, role, participant-authority) binding. The coordinator is created
// when this route is pushed and is never re-pointed; any change to the
// request relationship, the participant identity or the route stack retires
// it and renders a closed state with no transcript. There is no "last
// conversation" memory and no list of conversations.
import SwiftUI
import Combine

@MainActor
final class RequestConversationSession: ObservableObject {
    enum State: Equatable {
        case open
        case closed
    }

    let requestID: String
    let role: RequestConversationRole
    let coordinator: ConversationCoordinator
    @Published private(set) var state: State = .open
    @Published private(set) var verificationFailed = false
    @Published private(set) var actions = ConversationActionAvailability.none

    private let verifier: ConversationEntryVerifying
    private let unread: MessagingUnreadStore?
    private var verifyTask: Task<Void, Never>?
    private var started = false

    init(
        requestID: String,
        role: RequestConversationRole,
        coordinator: ConversationCoordinator,
        verifier: ConversationEntryVerifying,
        unread: MessagingUnreadStore? = nil
    ) {
        self.requestID = requestID
        self.role = role
        self.coordinator = coordinator
        self.verifier = verifier
        self.unread = unread
    }

    deinit {
        verifyTask?.cancel()
    }

    func begin(isForeground: Bool) {
        guard !started, state == .open else { return }
        started = true
        if verifier.isLocallyDenied(requestID: requestID, role: role) {
            retire()
            return
        }
        coordinator.start(isForeground: isForeground)
        refreshActions()
        verify(resumeOnEligible: false)
    }

    func sceneDidBecomeActive() {
        guard state == .open, started else { return }
        // Authorization is re-proven before the coordinator is allowed to
        // refresh from the server; a stale foreground never reads history.
        verify(resumeOnEligible: true)
    }

    func sceneDidEnterBackground() {
        guard state == .open else { return }
        coordinator.sceneDidEnterBackground()
    }

    func relationshipStateChanged() {
        guard state == .open else { return }
        if verifier.isLocallyDenied(requestID: requestID, role: role) {
            retire()
        } else {
            refreshActions()
        }
    }

    private func refreshActions() {
        guard state == .open else { return }
        let next = verifier.availableActions(requestID: requestID, role: role)
        if next != actions { actions = next }
    }

    /// A confirmed Block ends this conversation for good: purge it and offer
    /// nothing further. Nothing here ever reopens it.
    func blockSucceeded() {
        retire()
    }

    func identityChanged() {
        guard state == .open else { return }
        coordinator.identityDidChange()
        unread?.authorityMayHaveChanged()
        retire()
    }

    func retire() {
        verifyTask?.cancel()
        verifyTask = nil
        guard state == .open else { return }
        coordinator.dismiss()
        actions = .none
        state = .closed
        // Leaving, Block, closure or revocation: the cached count is unknown
        // until the server projection, requested now, says otherwise.
        unread?.invalidate(requestId: requestID)
        unread?.refresh()
    }

    func retryVerification() {
        guard state == .open else { return }
        verify(resumeOnEligible: true)
    }

    private func verify(resumeOnEligible: Bool) {
        verifyTask?.cancel()
        let requestID = requestID
        let role = role
        verifyTask = Task { [weak self] in
            guard let verifier = self?.verifier else { return }
            let result = await verifier.verify(requestID: requestID, role: role)
            guard !Task.isCancelled, let self, self.state == .open else { return }
            switch result {
            case .ineligible:
                self.retire()
            case .eligible:
                self.verificationFailed = false
                self.refreshActions()
                if resumeOnEligible { self.coordinator.sceneDidBecomeActive() }
            case .unknown:
                self.verificationFailed = resumeOnEligible
            }
        }
    }
}

enum RequestConversationCopy {
    static let reportTitle = "Report participant"
    static let blockTitle = "Block participant"
    static let closedTitle = ConversationCopy.unavailableTitle
    static let verificationFailed = "Couldn't confirm this request is still active."
}

struct RequestConversationHostView: View {
    let requestID: String
    let role: RequestConversationRole
    @ObservedObject var store: RequestStore
    @ObservedObject var identityStore: ParticipantIdentityStore
    @Binding var path: [AppRoute]
    @StateObject private var session: RequestConversationSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var isConfirmingBlock = false
    @State private var isAskingExternalOrder = false

    init(
        requestID: String,
        role: RequestConversationRole,
        composition: RequestMessagingComposition,
        store: RequestStore,
        identityStore: ParticipantIdentityStore,
        verifier: ConversationEntryVerifying? = nil,
        path: Binding<[AppRoute]>,
        onSessionCreated: ((RequestConversationSession) -> Void)? = nil
    ) {
        self.requestID = requestID
        self.role = role
        self.store = store
        self.identityStore = identityStore
        _path = path
        let verifier = verifier ?? StoreConversationEntryVerifier(store: store)
        _session = StateObject(wrappedValue: {
            let created = RequestConversationSession(
                requestID: requestID,
                role: role,
                coordinator: composition.makeCoordinator!(
                    requestID,
                    { [weak identityStore] in identityStore?.currentAuthority() },
                    { [weak identityStore] in identityStore?.discardRejectedIdentity() }
                ),
                verifier: verifier,
                unread: composition.unread
            )
            onSessionCreated?(created)
            return created
        }())
    }

    var body: some View {
        Group {
            switch session.state {
            case .open:
                VStack(spacing: 0) {
                    if session.verificationFailed {
                        HStack {
                            Text(RequestConversationCopy.verificationFailed)
                                .font(.footnote)
                            Spacer()
                            Button(ConversationCopy.retry) { session.retryVerification() }
                                .font(.footnote.weight(.semibold))
                        }
                        .padding(CommonPlateStyle.Spacing.s)
                        .accessibilityIdentifier("request-conversation-verification-failed")
                    }
                    ConversationScreen(
                        coordinator: session.coordinator,
                        menuActions: menuActions
                    )
                }
            case .closed:
                ConversationUnavailableState()
                    .accessibilityIdentifier("request-conversation-closed")
            }
        }
        .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
        .navigationTitle(ConversationCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { session.begin(isForeground: scenePhase == .active) }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: session.sceneDidBecomeActive()
            case .background: session.sceneDidEnterBackground()
            default: break
            }
        }
        .onChange(of: identityStore.identity) { _, _ in session.identityChanged() }
        .onReceive(store.objectWillChange) { _ in
            // objectWillChange fires before the value lands; re-evaluate next turn.
            DispatchQueue.main.async { session.relationshipStateChanged() }
        }
        .alert(
            ParticipantBlockCopy.blockConfirmationTitle,
            isPresented: $isConfirmingBlock
        ) {
            Button(ParticipantBlockCopy.blockConfirmButtonTitle, role: .destructive) {
                Task { await blockViewedRequest() }
            }
            Button(ParticipantBlockCopy.cancelTitle, role: .cancel) {}
        } message: {
            Text(ParticipantBlockCopy.blockConfirmationMessage)
        }
        .alert(
            HelpingQuestion.block.title,
            isPresented: $isAskingExternalOrder
        ) {
            Button(ParticipantBlockCopy.externalOrderYesTitle) {
                Task { await blockHelpingReservation(externalOrderPlaced: true) }
            }
            Button(ParticipantBlockCopy.externalOrderNoTitle) {
                Task { await blockHelpingReservation(externalOrderPlaced: false) }
            }
            Button(ParticipantBlockCopy.cancelTitle, role: .cancel) {}
        }
        .participantBlockFailureAlert(store: store)
        .onChange(of: path) { _, newPath in
            if !newPath.contains(.requestConversation(requestID: requestID, role: role)) {
                session.retire()
            }
        }
    }

    private var actions: RequestConversationActions {
        RequestConversationActions(
            requestID: requestID, session: session, store: store, path: $path
        )
    }

    private var menuActions: [ConversationMenuAction] {
        var items: [ConversationMenuAction] = []
        if session.actions.report {
            items.append(ConversationMenuAction(
                id: "report", title: RequestConversationCopy.reportTitle, isDestructive: false
            ) { actions.report() })
        }
        if session.actions.block != nil {
            items.append(ConversationMenuAction(
                id: "block", title: RequestConversationCopy.blockTitle, isDestructive: true
            ) { beginBlock() })
        }
        return items
    }

    private func beginBlock() {
        switch actions.beginBlock() {
        case .viewedRequest: isConfirmingBlock = true
        case .helpingReservation: isAskingExternalOrder = true
        case nil: break
        }
    }

    private func blockViewedRequest() async { await actions.blockViewedRequest() }

    private func blockHelpingReservation(externalOrderPlaced: Bool) async {
        await actions.blockHelpingReservation(externalOrderPlaced: externalOrderPlaced)
    }
}

/// Routes the chat menu's Report and Block into the existing flows. It never
/// names the counterpart: `presentReportPopup`, `blockRequesterOfViewedRequest`
/// and `blockHelpedRequester` resolve the exact participant on the backend
/// from this request and the caller's current authority. A successful Block
/// retires the conversation for good; a failed one leaves it as it was.
@MainActor
struct RequestConversationActions {
    let requestID: String
    let session: RequestConversationSession
    let store: RequestStore
    let path: Binding<[AppRoute]>

    func report() {
        guard session.state == .open, session.actions.report else { return }
        store.presentReportPopup(
            requestID: requestID,
            returnsHome: false,
            offersBlockAfter: false
        )
    }

    /// The prompt the host should show, or nil when no Block is offered now.
    func beginBlock() -> ConversationActionAvailability.BlockKind? {
        guard session.state == .open, !store.isBlockingParticipant,
              let kind = session.actions.block else { return nil }
        store.clearBlockError()
        return kind
    }

    private var pathWithoutConversation: [AppRoute] {
        path.wrappedValue.filter {
            if case .requestConversation = $0 { return false }
            return true
        }
    }

    func blockViewedRequest() async {
        guard session.state == .open, session.actions.block == .viewedRequest else { return }
        guard case .blocked = await store.blockRequesterOfViewedRequest(requestID: requestID) else {
            // The error alert is owned by the host; authorization is re-proven
            // without discarding an otherwise authorized conversation.
            session.retryVerification()
            return
        }
        session.blockSucceeded()
        path.wrappedValue = AppRoute.afterParticipantBlock(from: path.wrappedValue)
    }

    func blockHelpingReservation(externalOrderPlaced: Bool) async {
        guard session.state == .open, session.actions.block == .helpingReservation else { return }
        guard case .blocked(let released) = await store.blockHelpedRequester(
            externalOrderPlaced: externalOrderPlaced
        ) else {
            session.retryVerification()
            return
        }
        session.blockSucceeded()
        if externalOrderPlaced {
            path.wrappedValue = AppRoute.afterParticipantBlockKeepingHelping(
                from: pathWithoutConversation
            )
        } else if released {
            path.wrappedValue = AppRoute.afterParticipantBlock(from: path.wrappedValue)
        } else {
            path.wrappedValue = pathWithoutConversation
        }
    }
}
