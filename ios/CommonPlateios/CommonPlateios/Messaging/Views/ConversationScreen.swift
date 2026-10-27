//
//  ConversationScreen.swift
//  CommonPlateios
//
// W4-MSG1 CP3 (dormant). The request-linked chat screen, driven entirely by an
// injected `ConversationCoordinator`. Not reachable from any route or tab.
// The ellipsis menu lists only actions the host injects; with none it is
// hidden, so nothing implies Block/Report works before U1.3/U1.2 integration.
import SwiftUI
import UIKit
import Combine

struct ConversationMenuAction: Identifiable {
    let id: String
    let title: String
    var isDestructive = false
    let perform: () -> Void
}

struct ConversationScreen: View {
    @ObservedObject var coordinator: ConversationCoordinator
    var menuActions: [ConversationMenuAction] = []

    @StateObject private var viewport = ConversationViewport()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(CommonPlateStyle.Color.baseCanvas)
        .navigationTitle(ConversationCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !menuActions.isEmpty && coordinator.phase == .active {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(menuActions) { action in
                            Button(role: action.isDestructive ? .destructive : nil, action: action.perform) {
                                Text(action.title)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(minWidth: ConversationLayout.minimumTarget, minHeight: ConversationLayout.minimumTarget)
                    }
                    .accessibilityLabel("More options")
                }
            }
        }
        .sheet(isPresented: sheetBinding) {
            if let failed = coordinator.failedSheetMessage, case .failed(let failure) = failed.state {
                FailedMessageSheet(
                    failure: failure,
                    onTryAgain: { coordinator.retryFailed(failed.clientMessageId) },
                    onCancel: { coordinator.cancelFailed(failed.clientMessageId) }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .onChange(of: coordinator.phase) { _, phase in
            if phase != .active {
                viewport.reset()
                coordinator.messagesDidDisplay([])
            }
        }
        .onChange(of: scenePhase) { _, phase in
            viewport.isSceneActive = phase == .active
            // Nothing is on screen unless the scene is active.
            if phase == .active { viewport.scheduleVisibilityReport(force: true) }
            else { coordinator.messagesDidDisplay([]) }
        }
        .onAppear {
            viewport.observe(coordinator)
            viewport.isSceneActive = scenePhase == .active
            viewport.onReachedTop = { [weak coordinator] in coordinator?.loadOlderMessages() }
            viewport.onVisibleChanged = { [weak coordinator] ids in coordinator?.messagesDidDisplay(ids) }
        }
        .onChange(of: dynamicTypeSize) { _, _ in viewport.capture() }
        .onChange(of: failedSendCount) { _, _ in viewport.refollowIfPinned() }
        .onDisappear {
            viewport.reset()
            coordinator.messagesDidDisplay([])
        }
    }

    /// A recoverable failure retries inline, with no sheet. Only a definitive
    /// refusal, which can never be retried, opens the explanation sheet.
    private func handleFailedTap(_ model: ChatBubbleModel) {
        guard case .failed(let failure) = model.kind else { return }
        if failure.isRetryable {
            coordinator.retryFailed(model.id)
        } else {
            coordinator.presentFailedSheet(for: model.id)
        }
    }

    private var sheetBinding: Binding<Bool> {
        Binding(
            get: { coordinator.failedSheetMessage != nil },
            set: { if !$0 { coordinator.dismissFailedSheet() } }
        )
    }

    @ViewBuilder private var content: some View {
        switch coordinator.phase {
        case .unavailable, .ended:
            ConversationUnavailableState()
        case .authorityRequired:
            statusText(ConversationCopy.authorityRequiredLine)
        case .openFailed:
            VStack(spacing: CommonPlateStyle.Spacing.m) {
                Text(ConversationCopy.openFailed).font(.callout)
                Button(ConversationCopy.retry, action: coordinator.retryConnection)
                    .frame(minHeight: ConversationLayout.minimumTarget)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .idle, .opening:
            statusText(ConversationCopy.loading)
        case .active:
            activeContent
        }
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var activeContent: some View {
        VStack(spacing: 0) {
            if coordinator.isOffline && coordinator.hasLoaded {
                ConversationStatusBanner(
                    text: ConversationCopy.offlineBanner,
                    actionTitle: ConversationCopy.retry,
                    action: coordinator.retryConnection
                )
            } else if coordinator.connectionStatus == .disconnected {
                ConversationStatusBanner(text: ConversationCopy.reconnecting)
            }
            if coordinator.historyFailed && !coordinator.hasLoaded {
                ConversationStatusBanner(
                    text: ConversationCopy.historyFailed,
                    actionTitle: ConversationCopy.retry,
                    action: coordinator.retryHistory
                )
            } else if coordinator.isLoadingInitialMessages {
                statusText(ConversationCopy.loading)
            } else if coordinator.items.isEmpty {
                ConversationEmptyState()
            } else {
                transcript
            }
            if coordinator.isAtLocalCapacity {
                Text(ConversationCopy.capacityNotice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, CommonPlateStyle.Spacing.l)
                    .accessibilityIdentifier("chat.capacityNotice")
            }
            if coordinator.notice == .reviseMessage {
                Text(ConversationCopy.reviseMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, CommonPlateStyle.Spacing.l)
            }
            Divider()
            ConversationComposer(
                text: $coordinator.draft,
                canSend: coordinator.canSend,
                onSend: {
                    viewport.pinToBottom()
                    coordinator.sendDraft()
                }
            )
        }
    }

    /// Changes when a send fails or recovers, which grows or shrinks the last row.
    private var failedSendCount: Int {
        coordinator.items.reduce(0) { count, item in
            if case .local(let local) = item, case .failed = local.state { return count + 1 }
            return count
        }
    }

    private var transcript: some View {
        let rows = ConversationPresentation.rows(for: coordinator.items)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: CommonPlateStyle.Spacing.m) {
                    if coordinator.hasOlder {
                        historyBoundary
                    }
                    ForEach(rows) { row in
                        switch row {
                        case .timestamp(_, let label):
                            ConversationTimestampView(label: label)
                        case .bubble(let model):
                            ChatBubbleView(
                                model: model,
                                onFailedTap: { handleFailedTap(model) },
                                onDiscard: { coordinator.cancelFailed(model.id) }
                            )
                            .background(ConversationRowMarker(id: model.id, viewport: viewport))
                        }
                    }
                }
                .padding(.horizontal, CommonPlateStyle.Spacing.l)
                .padding(.vertical, CommonPlateStyle.Spacing.m)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                viewport.materialize = { id in proxy.scrollTo(id, anchor: .top) }
                if let last = rows.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                viewport.openAtBottom()
            }
        }
    }

    private var historyBoundary: some View {
        VStack(spacing: 0) {
            if coordinator.isLoadingHistory {
                ProgressView(ConversationCopy.loadingOlder)
            } else if coordinator.historyFailed {
                Text(ConversationCopy.historyFailed).font(.footnote)
                Button(action: coordinator.retryHistory) {
                    Text(ConversationCopy.retry)
                        .frame(minWidth: ConversationLayout.minimumTarget, minHeight: ConversationLayout.minimumTarget)
                        .contentShape(Rectangle())
                }
                    .accessibilityLabel(ConversationCopy.retryOlder)
                    .accessibilityIdentifier("chat.historyRetry")
            } else {
                Button(action: coordinator.loadOlderMessages) {
                    Text(ConversationCopy.loadingOlder)
                        .font(.footnote)
                        .frame(minWidth: ConversationLayout.minimumTarget, minHeight: ConversationLayout.minimumTarget)
                        .contentShape(Rectangle())
                }
                    .accessibilityLabel(ConversationCopy.loadOlder)
                    .accessibilityIdentifier("chat.loadOlder")
            }
        }
        .frame(maxWidth: .infinity, minHeight: ConversationLayout.minimumTarget)
    }
}

/// Measures real lazy-row geometry, not estimated content-height deltas. A
/// snapshot is taken at application time and corrected without animation after
/// layout. Only visible row markers are retained; message storage stays owned
/// by the coordinator. Timestamps are deliberately not reading anchors.
@MainActor
final class ConversationViewport: NSObject, ObservableObject {
    private final class WeakRow {
        weak var view: UIView?
        init(_ view: UIView) { self.view = view }
    }

    private var rows: [String: WeakRow] = [:]
    private weak var scroll: UIScrollView?
    private var anchor: (id: String, y: CGFloat)?
    private var followBottom = true
    /// Set when the user sends; holds the transcript at the newest message
    /// until they scroll away themselves.
    private var pinnedToBottom = false
    private var revision = 0
    private var correction: Task<Void, Never>?
    private var observation: NSKeyValueObservation?
    private var changes: AnyCancellable?
    private var topRequestedInGesture = false
    var onReachedTop: (() -> Void)?
    var materialize: ((String) -> Void)?
    /// Receives the ids of message rows that are actually on screen, only after
    /// layout has settled and held still for `visibilityDwell`.
    var onVisibleChanged: ((Set<String>) -> Void)?
    var isSceneActive = true
    var visibilityDwell: Duration = .milliseconds(400)
    private var visibilityTask: Task<Void, Never>?
    private var lastReportedVisible: Set<String>?
    private var visibilityObservation: NSKeyValueObservation?
    var isSettling: Bool { correction != nil }

    func observe(_ coordinator: ConversationCoordinator) {
        changes = coordinator.objectWillChange.sink { [weak self] in self?.capture() }
    }

    func pinToBottom() {
        pinnedToBottom = true
        followBottom = true
        anchor = nil
        scheduleCorrection()
    }

    /// Re-pins after layout when the user's send is still being followed.
    func refollowIfPinned() {
        guard pinnedToBottom else { return }
        pinToBottom()
    }

    func openAtBottom() {
        followBottom = true
        anchor = nil
        scheduleCorrection()
    }

    func register(_ view: UIView, id: String) {
        rows = rows.filter { $0.value.view != nil && ($0.key == id || $0.value.view !== view) }
        rows[id] = WeakRow(view)
        scheduleVisibilityReport()
        var parent = view.superview
        while let current = parent {
            if let found = current as? UIScrollView {
                if scroll !== found {
                    scroll = found
                    visibilityObservation = found.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                        MainActor.assumeIsolated { self?.scheduleVisibilityReport() }
                    }
                    found.panGestureRecognizer.addTarget(self, action: #selector(panChanged(_:)))
                    observation = found.observe(\.contentOffset, options: [.old, .new]) { [weak self] scroll, change in
                        MainActor.assumeIsolated {
                            guard scroll.isDragging || scroll.isDecelerating,
                                  let old = change.oldValue, let new = change.newValue,
                                  new.y < old.y, new.y + scroll.adjustedContentInset.top <= 1,
                                  let self, !self.topRequestedInGesture else { return }
                            self.topRequestedInGesture = true
                            self.onReachedTop?()
                        }
                    }
                }
                break
            }
            parent = current.superview
        }
    }

    @objc private func panChanged(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began {
            topRequestedInGesture = false
            pinnedToBottom = false
            correction?.cancel()
            correction = nil
            anchor = nil
        }
    }

    /// A row is displayed when at least half of it (or half of the viewport,
    /// for a row taller than the viewport) lies inside the visible region.
    nonisolated static func visibleIDs(frames: [String: CGRect], in visible: CGRect) -> Set<String> {
        guard visible.height > 0 else { return [] }
        return Set(frames.compactMap { id, frame in
            let overlap = frame.intersection(visible)
            guard !overlap.isNull, frame.height > 0 else { return nil }
            return overlap.height >= min(frame.height, visible.height) * 0.5 ? id : nil
        })
    }

    /// Debounced and held back while the viewport is still correcting its
    /// position, so a transient layout (e.g. the first frame before the
    /// transcript scrolls to its newest message) is never reported.
    func scheduleVisibilityReport(force: Bool = false) {
        if force { lastReportedVisible = nil }
        visibilityTask?.cancel()
        let dwell = visibilityDwell
        visibilityTask = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: dwell) } catch { return }
                guard let self, !Task.isCancelled else { return }
                if self.isSettling { continue }
                self.reportVisibility()
                return
            }
        }
    }

    private func reportVisibility() {
        visibilityTask = nil
        guard isSceneActive, let scroll else { return }
        let inset = scroll.adjustedContentInset
        let visible = CGRect(
            x: scroll.bounds.minX + inset.left,
            y: scroll.bounds.minY + inset.top,
            width: scroll.bounds.width - inset.left - inset.right,
            height: scroll.bounds.height - inset.top - inset.bottom
        )
        var frames: [String: CGRect] = [:]
        for (id, row) in rows {
            guard let view = row.view, view.window != nil else { continue }
            frames[id] = view.convert(view.bounds, to: scroll)
        }
        let ids = Self.visibleIDs(frames: frames, in: visible)
        guard ids != lastReportedVisible else { return }
        lastReportedVisible = ids
        onVisibleChanged?(ids)
    }

    func capture() {
        scheduleVisibilityReport()
        // One model application publishes several properties. Never replace
        // its pre-layout snapshot with intermediate geometry from that update.
        if pinnedToBottom, correction != nil {
            // A later update (e.g. a send failure adding the inline retry row)
            // grows the last row; keep following it.
            scheduleCorrection()
            return
        }
        guard correction == nil, let scroll else { return }
        let bottom = max(-scroll.adjustedContentInset.top,
                         scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        followBottom = pinnedToBottom || bottom - scroll.contentOffset.y <= 2
        anchor = nil
        if !followBottom {
            let visible = rows.compactMap { id, row -> (String, CGFloat)? in
                guard let view = row.view, view.window != nil else { return nil }
                let frame = view.convert(view.bounds, to: scroll)
                guard frame.maxY > scroll.bounds.minY, frame.minY < scroll.bounds.maxY else { return nil }
                return (id, frame.minY - scroll.bounds.minY)
            }.sorted { $0.1 < $1.1 }
            if let first = visible.first { anchor = (first.0, first.1) }
        }
        scheduleCorrection()
    }

    private func scheduleCorrection() {
        correction?.cancel()
        revision += 1
        let revision = revision
        correction = Task { [weak self] in
            // LazyVStack can refine estimated heights over several layout passes.
            // Keep the same real bubble pinned while those refinements settle.
            for _ in 0..<20 {
                await Task.yield()
                guard !Task.isCancelled, let self, self.revision == revision else { return }
                self.restore()
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
            guard let self, self.revision == revision else { return }
            self.correction = nil
        }
    }

    private func restore() {
        guard let scroll else { return }
        scroll.superview?.layoutIfNeeded()
        if followBottom {
            let y = max(-scroll.adjustedContentInset.top,
                        scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: false)
        } else if let anchor, let view = rows[anchor.id]?.view, view.window != nil {
            let y = view.convert(view.bounds, to: scroll).minY - scroll.bounds.minY
            if abs(y - anchor.y) > 0.1 {
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: scroll.contentOffset.y + y - anchor.y), animated: false)
            }
        } else if let anchor {
            materialize?(anchor.id)
        }
    }

    func reset() {
        visibilityTask?.cancel()
        visibilityTask = nil
        visibilityObservation = nil
        lastReportedVisible = nil
        correction?.cancel()
        correction = nil
        revision += 1
        rows.removeAll()
        scroll?.panGestureRecognizer.removeTarget(self, action: #selector(panChanged(_:)))
        observation = nil
        changes = nil
        pinnedToBottom = false
        materialize = nil
        scroll = nil
        anchor = nil
        followBottom = true
    }
}

struct ConversationRowMarker: UIViewRepresentable {
    let id: String
    let viewport: ConversationViewport

    final class Marker: UIView {
        weak var viewport: ConversationViewport?
        var register: ((UIView) -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            register?(self)
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            register?(self)
        }
    }

    func makeUIView(context: Context) -> Marker {
        let view = Marker()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Marker, context: Context) {
        view.viewport = viewport
        view.accessibilityIdentifier = "chat.row.\(id)"
        view.register = { [weak viewport] view in viewport?.register(view, id: id) }
        viewport.register(view, id: id)
    }
}
