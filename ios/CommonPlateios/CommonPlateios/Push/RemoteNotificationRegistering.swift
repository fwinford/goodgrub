//
//  RemoteNotificationRegistering.swift
//  CommonPlateios
//
// Bridges `UIApplicationDelegate`'s imperative
// `didRegisterForRemoteNotificationsWithDeviceToken` /
// `didFailToRegisterForRemoteNotificationsWithError` callbacks into the
// async/await push-setup flow `PushSubscriptionStore` uses. `PushAppDelegate`
// is the only other file that touches `received(deviceToken:)` /
// `failed(error:)`; nothing else calls them.
import UIKit

enum RemoteNotificationRegistrationError: Error {
    /// Registration did not resolve within the bound. A UI safeguard against
    /// showing a setup state forever — not an Apple delivery guarantee, and
    /// not evidence that registration will never complete.
    case timedOut
    case system(Error)
}

protocol RemoteNotificationRegistering {
    /// Begins remote-notification registration and asynchronously returns the
    /// normalized device token. Throws `RemoteNotificationRegistrationError`
    /// on failure or on exceeding `timeout`.
    func registerAndAwaitToken(timeout: Duration) async throws -> String
}

/// The one production implementation. `@MainActor` because
/// `UIApplication.registerForRemoteNotifications()` must be called on the
/// main thread, and because the pending continuation is resumed from the app
/// delegate's callbacks, which UIKit also delivers on the main thread.
@MainActor
final class UIKitRemoteNotificationRegistrar: RemoteNotificationRegistering {
    private var pending: CheckedContinuation<Result<Data, Error>, Never>?

    /// Test-only visibility into whether a registration is currently
    /// awaiting a callback, so a test can synchronize with the real
    /// continuation instead of racing it with sleeps. Read-only, and no
    /// production code reads it.
    var isAwaitingCallback: Bool {
        pending != nil
    }

    init() {}

    func registerAndAwaitToken(timeout: Duration) async throws -> String {
        let outcome = await withTaskGroup(of: RaceOutcome.self) { group in
            group.addTask { @MainActor in
                .token(await self.awaitBridgeToken())
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }

        switch outcome {
        case .token(.success(let data)):
            do {
                return try APNsTokenFormatter.normalize(data)
            } catch {
                throw RemoteNotificationRegistrationError.system(error)
            }
        case .token(.failure(let error)):
            throw RemoteNotificationRegistrationError.system(error)
        case .timedOut:
            throw RemoteNotificationRegistrationError.timedOut
        }
    }

    /// Called by `PushAppDelegate` on a successful registration.
    func received(deviceToken: Data) {
        complete(with: .success(deviceToken))
    }

    /// Called by `PushAppDelegate` when registration itself fails (for
    /// example, no network path to APNs).
    func failed(error: Error) {
        complete(with: .failure(error))
    }

    /// The one place a pending continuation is ever resumed, whichever of the
    /// three sources — a real callback, cancellation racing that callback, or
    /// cancellation that arrived first — gets here first. Reading and
    /// clearing `pending` together, before resuming, is what makes this safe
    /// to call more than once: whichever caller finds `pending` already `nil`
    /// resumes nothing, so a callback racing cancellation can never resume
    /// the same continuation twice.
    private func complete(with result: Result<Data, Error>) {
        guard let continuation = pending else { return }
        pending = nil
        continuation.resume(returning: result)
    }

    private enum RaceOutcome {
        case token(Result<Data, Error>)
        case timedOut
    }

    /// `withTaskGroup` does not return until every child task finishes, and
    /// `cancelAll()` only requests cooperative cancellation — it cannot force
    /// a bare `CheckedContinuation` to resume. Without
    /// `withTaskCancellationHandler` here, the loser of the timeout race
    /// would stay parked forever whenever nothing ever calls `received` or
    /// `failed`, and the timeout that exists to bound the UI's setup state
    /// would itself hang indefinitely instead.
    private func awaitBridgeToken() async -> Result<Data, Error> {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<Data, Error>, Never>) in
                // Installed before checking cancellation, and in that order
                // deliberately: `onCancel` below can only find a continuation
                // to resume once `pending` holds one, so checking first would
                // leave a real window where cancellation notices nothing and
                // this continuation then waits forever anyway. `complete(with:)`
                // being idempotent is what keeps this safe even though
                // `onCancel` can also observe cancellation independently and
                // race this check.
                self.pending = continuation
                if Task.isCancelled {
                    complete(with: .failure(CancellationError()))
                    return
                }
                UIApplication.shared.registerForRemoteNotifications()
            }
        } onCancel: {
            // Runs on an arbitrary, non-isolated executor by contract, and
            // may run concurrently with the continuation still being
            // installed above — hopping back to the actor is required to
            // touch `pending` at all, and `complete(with:)`'s own guard is
            // what makes the resulting race harmless either way.
            Task { @MainActor in
                self.complete(with: .failure(CancellationError()))
            }
        }
    }
}
