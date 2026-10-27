//
//  MessagingPreviewViews.swift
//  CommonPlateios
//
// DEVELOPMENT-ONLY (W4-MSG1 CP6 UI preview). A dedicated fictional request
// screen that exposes the real `RequestConversationEntryRow`, the real
// `.requestConversation` route and the real `ConversationScreen`. Only the
// surrounding host is a small adapter (the production host is bound to the
// live request store, which the preview must never touch). Report and Block
// are local mock presentations: nothing is submitted anywhere.
#if DEBUG
import SwiftUI

nonisolated enum MessagingPreviewLaunch {
    /// Set by the shared "CommonPlateios Messaging Preview" scheme. Meaningful
    /// only because this whole file exists only in Debug builds.
    static let environmentKey = "COMMONPLATE_MESSAGING_PREVIEW"

    /// Optional "<scenario>:<role>" (for example `long:helper`) that opens that
    /// conversation immediately, for screenshots. Anything else is ignored.
    static let startKey = "COMMONPLATE_MESSAGING_PREVIEW_START"

    /// Optional fictional text sent once the chat is active, for screenshots
    /// of the send-failure scenario. `AUTORETRY=1` then taps retry once.
    static let autoSendKey = "COMMONPLATE_MESSAGING_PREVIEW_AUTOSEND"
    static let autoRetryKey = "COMMONPLATE_MESSAGING_PREVIEW_AUTORETRY"

    static func isRequested(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[environmentKey] == "1"
    }

    static func start(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (MessagingPreviewScenario, RequestConversationRole)? {
        let parts = (environment[startKey] ?? "").split(separator: ":").map(String.init)
        guard parts.count == 2,
              let scenario = MessagingPreviewScenario.allCases.first(where: { String(describing: $0) == parts[0] }),
              ["requester", "helper"].contains(parts[1]) else { return nil }
        return (scenario, parts[1] == "helper" ? .helper : .requester)
    }
}

struct MessagingPreviewRootView: View {
    @State private var path: [AppRoute]
    @State private var scenario: MessagingPreviewScenario
    @State private var role: RequestConversationRole
    private let composition = MessagingPreviewComposition.make()

    init(start: (MessagingPreviewScenario, RequestConversationRole)? = MessagingPreviewLaunch.start()) {
        _scenario = State(initialValue: start?.0 ?? .reserved)
        _role = State(initialValue: start?.1 ?? .requester)
        _path = State(initialValue: start.map {
            [.requestConversation(requestID: MessagingPreviewFixtures.requestID($0.0, $0.1), role: $0.1)]
        } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Text("Preview only. Fictional people and messages. Nothing is sent to any server, and Report and Block are mock.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Fictional request") {
                    VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
                        Text(MessagingPreviewFixtures.mealTitle).font(.headline)
                        Text(MessagingPreviewFixtures.venueName).font(.subheadline)
                        Text(role == .requester
                             ? "\(MessagingPreviewFixtures.helperName) reserved your request."
                             : "You reserved \(MessagingPreviewFixtures.requesterName)'s request.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    RequestConversationEntryRow(
                        requestID: MessagingPreviewFixtures.requestID(scenario, role),
                        role: role,
                        path: $path
                    )
                }
                Section("Preview controls") {
                    Picker("Perspective", selection: $role) {
                        Text("Requester").tag(RequestConversationRole.requester)
                        Text("Helper").tag(RequestConversationRole.helper)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("messaging-preview-role")
                    Picker("Scenario", selection: $scenario) {
                        ForEach(MessagingPreviewScenario.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("messaging-preview-scenario")
                }
            }
            .navigationTitle("Messaging preview")
            .navigationDestination(for: AppRoute.self) { route in
                if case .requestConversation(let requestID, let routeRole) = route {
                    MessagingPreviewConversationHost(
                        requestID: requestID,
                        role: routeRole,
                        composition: composition,
                        path: $path
                    )
                } else {
                    ConversationUnavailableState()
                }
            }
        }
        .environment(\.requestMessaging, composition)
    }
}

struct MessagingPreviewConversationHost: View {
    let requestID: String
    let role: RequestConversationRole
    @Binding var path: [AppRoute]
    @StateObject private var session: RequestConversationSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var isConfirmingBlock = false
    @State private var isAskingExternalOrder = false
    @State private var isShowingReport = false

    init(
        requestID: String,
        role: RequestConversationRole,
        composition: RequestMessagingComposition,
        path: Binding<[AppRoute]>
    ) {
        self.requestID = requestID
        self.role = role
        _path = path
        _session = StateObject(wrappedValue: RequestConversationSession(
            requestID: requestID,
            role: role,
            coordinator: composition.makeCoordinator!(
                requestID, { MessagingPreviewComposition.fictionalAuthority }, {}
            ),
            verifier: PreviewConversationVerifier()
        ))
    }

    private func runScriptedSend() async {
        let env = ProcessInfo.processInfo.environment
        guard let text = env[MessagingPreviewLaunch.autoSendKey], !text.isEmpty else { return }
        let coordinator = session.coordinator
        for _ in 0..<50 where coordinator.phase != .active || coordinator.isLoadingInitialMessages {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        coordinator.draft = text
        coordinator.sendDraft()
        guard env[MessagingPreviewLaunch.autoRetryKey] == "1" else { return }
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if let failed = coordinator.items.compactMap({ item -> String? in
                if case .local(let local) = item, case .failed = local.state { return local.clientMessageId }
                return nil
            }).first {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                coordinator.retryFailed(failed)
                return
            }
        }
    }

    var body: some View {
        Group {
            switch session.state {
            case .open:
                ConversationScreen(
                    coordinator: session.coordinator,
                    menuActions: menuActions
                )
            case .closed:
                ConversationUnavailableState()
                    .accessibilityIdentifier("request-conversation-closed")
            }
        }
        .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
        .navigationTitle(ConversationCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { session.begin(isForeground: scenePhase == .active) }
        .task { await runScriptedSend() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: session.sceneDidBecomeActive()
            case .background: session.sceneDidEnterBackground()
            default: break
            }
        }
        .onChange(of: path) { _, newPath in
            if !newPath.contains(.requestConversation(requestID: requestID, role: role)) {
                session.retire()
            }
        }
        .alert(ParticipantBlockCopy.blockConfirmationTitle, isPresented: $isConfirmingBlock) {
            Button(ParticipantBlockCopy.blockConfirmButtonTitle, role: .destructive) {
                session.blockSucceeded()
            }
            Button(ParticipantBlockCopy.cancelTitle, role: .cancel) {}
        } message: {
            Text(ParticipantBlockCopy.blockConfirmationMessage + "\n\n(Preview: nothing is blocked.)")
        }
        .alert(HelpingQuestion.block.title, isPresented: $isAskingExternalOrder) {
            Button(ParticipantBlockCopy.externalOrderYesTitle) { session.blockSucceeded() }
            Button(ParticipantBlockCopy.externalOrderNoTitle) { session.blockSucceeded() }
            Button(ParticipantBlockCopy.cancelTitle, role: .cancel) {}
        }
        .sheet(isPresented: $isShowingReport) {
            MessagingPreviewReportSheet()
        }
    }

    private var menuActions: [ConversationMenuAction] {
        var items: [ConversationMenuAction] = []
        if session.actions.report {
            items.append(ConversationMenuAction(
                id: "report", title: RequestConversationCopy.reportTitle, isDestructive: false
            ) { isShowingReport = true })
        }
        if let kind = session.actions.block {
            items.append(ConversationMenuAction(
                id: "block", title: RequestConversationCopy.blockTitle, isDestructive: true
            ) {
                switch kind {
                case .viewedRequest: isConfirmingBlock = true
                case .helpingReservation: isAskingExternalOrder = true
                }
            })
        }
        return items
    }
}

/// Mock of the Report popup: the real reason list and the real conversation
/// disclosure text, with no submission path at all.
private struct MessagingPreviewReportSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(ParticipantReportConversationDisclosure.text)
                        .font(.footnote)
                        .accessibilityIdentifier("participant-report-conversation-disclosure")
                }
                Section("Reason") {
                    ForEach(ParticipantReportReason.allCases) { Text($0.title) }
                }
                Section {
                    Text("Preview only. Nothing is reported or sent.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Report participant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
#endif
