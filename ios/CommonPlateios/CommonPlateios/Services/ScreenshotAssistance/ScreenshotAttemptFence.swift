//
//  ScreenshotAttemptFence.swift
//  CommonPlateios
//
// W4-S3: the shared analysis-lifecycle mechanism — generation identity,
// cancellation, and stale-result fencing — extracted from the requester store
// (W4-S1) so a later Helper consumer gets the same proven behavior without
// reimplementing it. Owns no workflow policy: it neither knows what an
// attempt analyzes nor what a result may change.
import Foundation

/// A specific screenshot selection's identity, minted synchronously by
/// `ScreenshotAttemptFence.beginAttempt()` at the moment the requester picks
/// an image — before any normalization, OCR, local analysis, or transfer for
/// it has started. Every later async stage re-checks `isCurrent(_:)` against
/// this exact token before proceeding or mutating shared state, so the newest
/// selection always wins regardless of how long an older selection's own work
/// takes. Only this file can mint one, so no caller can fabricate a token that
/// reads as current. A token also records WHICH fence minted it: a token is only
/// ever current against its own fence, so a token from another fence (another
/// runtime, a test double) can never read as current here, even when the two
/// generation numbers happen to match.
struct ScreenshotSelectionToken: Equatable {
    let generation: Int
    fileprivate let fenceID: UUID

    fileprivate init(generation: Int, fenceID: UUID) {
        self.generation = generation
        self.fenceID = fenceID
    }
}

@MainActor
final class ScreenshotAttemptFence {
    private let id = UUID()
    private(set) var currentGeneration = 0
    private var cancellers: [Int: () -> Void] = [:]

    /// Retires and cancels whatever the previous attempt was doing,
    /// synchronously, then mints the identity of the new one.
    func beginAttempt() -> ScreenshotSelectionToken {
        retire()
        return ScreenshotSelectionToken(generation: currentGeneration, fenceID: id)
    }

    /// Makes every previously minted token stale and cancels every tracked
    /// task right now, synchronously — Off, screen disappearance, and a newer
    /// selection all must stop mattering immediately rather than "the next
    /// time someone happens to check a flag." Turning something back on never
    /// revives a retired token: work only ever starts from a fresh one.
    func retire() {
        cancelTrackedTasks()
        currentGeneration += 1
    }

    func isCurrent(_ token: ScreenshotSelectionToken) -> Bool {
        token.fenceID == id && token.generation == currentGeneration
    }

    /// Tracks the real, cancellable unit of work behind `token`. `Task.cancel()`
    /// closes the suspension window a plain boolean re-check cannot: it takes
    /// effect immediately, including before the task body has started, and the
    /// async call chain observes it cooperatively.
    func track<Success>(_ task: Task<Success, Never>, for token: ScreenshotSelectionToken) {
        cancellers[token.generation] = { task.cancel() }
    }

    func untrack(_ token: ScreenshotSelectionToken) {
        cancellers.removeValue(forKey: token.generation)
    }

    private func cancelTrackedTasks() {
        for cancel in cancellers.values {
            cancel()
        }
        cancellers.removeAll()
    }
}
