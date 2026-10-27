//
//  ReservationWarningScheduling.swift
//  CommonPlateios
//
// Schedules, reschedules, and cancels the W3-H1 five-minute
// reservation-warning local notification. `RequestStore` owns *when* one is
// due (`claimExpiresAt - 5min`, recomputed on every claim/extension) but
// knows nothing about `UserNotifications` itself — this protocol is the seam,
// matching `RemoteNotificationRegistering`'s existing shape.
//
// This notification is never sent by APNs. It exists so a warning still
// fires after CommonPlate is backgrounded or terminated, without any new
// server-side push infrastructure and without overlapping the helper
// new-request or requester-fulfillment push payloads — see
// `ReservationWarningNotificationPayload.swift`.
import Foundation
import UserNotifications

/// Not `@MainActor`, matching `RemoteNotificationRegistering`: only the real
/// `UNUserNotificationCenter`-backed implementation needs to care about
/// threading (it does not, in fact — `UNUserNotificationCenter` is itself
/// thread-safe), and leaving the protocol unisolated is what lets
/// `RequestStore`'s initializer default this parameter to a plain, ordinary
/// value.
protocol ReservationWarningScheduling {
    /// Schedules (replacing any existing schedule for this exact request) a
    /// local notification to fire at `fireAt`. Called at claim grant and
    /// again on a successful extension, since extension moves the deadline
    /// the warning is five minutes ahead of.
    func scheduleWarning(requestID: String, fireAt: Date)

    /// Cancels any pending or already-delivered warning for `requestID`.
    /// Idempotent. Called on release, fulfillment, and every other path that
    /// ends this claim locally, and by the in-app foreground warning path
    /// itself — once a live warning has actually been shown, the scheduled
    /// notification for the same moment must not also appear.
    func cancelWarning(requestID: String)

    /// Retires every CommonPlate reservation warning, and no other local or
    /// remote notification. Used only when continuation has authoritatively
    /// established that this one-active-reservation participant holds none.
    func cancelAllWarnings()
}

/// The narrow subset of `UNUserNotificationCenter` the reservation-warning
/// scheduler needs. Keeping this seam here makes the real asynchronous
/// enumeration/removal ordering testable without trying to construct or
/// replace the process-wide notification center in a unit test.
protocol ReservationWarningNotificationCentering: AnyObject, Sendable {
    func add(
        _ request: UNNotificationRequest,
        completionHandler: @escaping @Sendable (Error?) -> Void
    )
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    func getPendingNotificationRequests(
        completionHandler: @escaping @Sendable ([UNNotificationRequest]) -> Void
    )
    func getDeliveredNotificationRequests(
        completionHandler: @escaping @Sendable ([UNNotificationRequest]) -> Void
    )
}

nonisolated final class SystemReservationWarningNotificationCenter:
    ReservationWarningNotificationCentering,
    @unchecked Sendable
{
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter) {
        self.center = center
    }

    func add(
        _ request: UNNotificationRequest,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        center.add(request, withCompletionHandler: completionHandler)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func getPendingNotificationRequests(
        completionHandler: @escaping @Sendable ([UNNotificationRequest]) -> Void
    ) {
        center.getPendingNotificationRequests(completionHandler: completionHandler)
    }

    func getDeliveredNotificationRequests(
        completionHandler: @escaping @Sendable ([UNNotificationRequest]) -> Void
    ) {
        center.getDeliveredNotifications { notifications in
            completionHandler(notifications.map(\.request))
        }
    }
}

/// Orders scheduler intent independently from the notification center's
/// asynchronous callbacks. A namespace cleanup may enumerate after a later
/// reservation has already scheduled its warning; per-identifier latest
/// operation state lets that newer schedule win while every genuinely stale
/// namespace member is still removed.
nonisolated final class ReservationWarningOperationFence: @unchecked Sendable {
    private enum ExactOperation {
        case schedule
        case cancel
    }

    private struct ExactState {
        let generation: Int
        let operation: ExactOperation
    }

    private let lock = NSLock()
    private var generation = 0
    private var latestNamespaceCleanupGeneration = 0
    private var latestExactState: [String: ExactState] = [:]
    private var inFlightScheduleGenerations: [String: Set<Int>] = [:]

    func beginSchedule(identifier: String) -> Int {
        lock.withLock {
            generation += 1
            latestExactState[identifier] = ExactState(
                generation: generation,
                operation: .schedule
            )
            inFlightScheduleGenerations[identifier, default: []].insert(generation)
            return generation
        }
    }

    func beginCancel(identifier: String) {
        lock.withLock {
            generation += 1
            latestExactState[identifier] = ExactState(
                generation: generation,
                operation: .cancel
            )
            pruneExactStateIfPossible(identifier: identifier)
        }
    }

    func beginNamespaceCleanup() -> Int {
        lock.withLock {
            generation += 1
            latestNamespaceCleanupGeneration = generation
            return generation
        }
    }

    func removeIdentifiersEligibleForCleanup(
        _ identifiers: [String],
        cleanupGeneration: Int,
        remove: ([String]) -> Void
    ) {
        lock.withLock {
            let eligibleIdentifiers = identifiers.filter { identifier in
                guard let exactState = latestExactState[identifier],
                      exactState.generation > cleanupGeneration else {
                    pruneExactStateIfPossible(identifier: identifier)
                    return true
                }
                // Only a newer schedule owns survival. A newer exact cancel is
                // compatible with cleanup removing the same identifier again.
                let isEligible = exactState.operation != .schedule
                if isEligible {
                    pruneExactStateIfPossible(identifier: identifier)
                }
                return isEligible
            }
            // Keep the decision and the notification-center removal command
            // in one critical section. If a new schedule begins first, its
            // generation excludes it above. If cleanup gets here first, the
            // later schedule cannot begin until removal has been issued, so
            // its subsequent add is the winning notification-center command.
            remove(eligibleIdentifiers)
        }
    }

    func completeSchedule(
        identifier: String,
        scheduleGeneration: Int,
        succeeded: Bool
    ) -> Bool {
        lock.withLock {
            inFlightScheduleGenerations[identifier]?.remove(scheduleGeneration)
            if inFlightScheduleGenerations[identifier]?.isEmpty == true {
                inFlightScheduleGenerations.removeValue(forKey: identifier)
            }

            guard succeeded else {
                // A failed add owns no live notification. Retire its exact
                // state when it is still current; newer schedule/cancel state
                // remains authoritative and is pruned by its own completion.
                if latestExactState[identifier]?.generation == scheduleGeneration {
                    latestExactState.removeValue(forKey: identifier)
                }
                pruneExactStateIfPossible(identifier: identifier)
                return false
            }

            let shouldRetire: Bool
            if let exactState = latestExactState[identifier],
               exactState.generation > scheduleGeneration {
                switch exactState.operation {
                case .schedule:
                    shouldRetire = false
                case .cancel:
                    shouldRetire = true
                }
            } else {
                // Covers an add that completed only after a newer namespace
                // cleanup enumerated and therefore could not see it.
                shouldRetire = latestNamespaceCleanupGeneration > scheduleGeneration
            }
            if shouldRetire {
                pruneExactStateIfPossible(identifier: identifier)
            }
            return shouldRetire
        }
    }

    /// Exact state is needed only while it represents a live scheduled warning
    /// or fences an add that has not completed. Cancellation/cleanup retirement
    /// removes it as soon as no in-flight add can resurrect the identifier, so
    /// storage stays bounded by live and in-flight reservation operations.
    private func pruneExactStateIfPossible(identifier: String) {
        guard inFlightScheduleGenerations[identifier] == nil,
              let exactState = latestExactState[identifier] else {
            return
        }
        switch exactState.operation {
        case .schedule:
            if exactState.generation <= latestNamespaceCleanupGeneration {
                latestExactState.removeValue(forKey: identifier)
            }
        case .cancel:
            latestExactState.removeValue(forKey: identifier)
        }
    }
}

/// No-op default so this dependency's addition to `RequestStore` does not by
/// itself require every existing construction site (tests included) to name
/// a real scheduler. Production wiring (`ContentView`) always supplies
/// `UNUserNotificationCenterReservationWarningScheduler`.
///
/// Explicitly `nonisolated`: this project defaults every otherwise-unmarked
/// type to `@MainActor` (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), which
/// would make even this trivial, stateless struct's initializer
/// actor-isolated — and a default parameter value on `RequestStore.init` has
/// to be constructible without assuming the caller's own isolation.
nonisolated struct NoOpReservationWarningScheduler: ReservationWarningScheduling {
    nonisolated init() {}
    nonisolated func scheduleWarning(requestID: String, fireAt: Date) {}
    nonisolated func cancelWarning(requestID: String) {}
    nonisolated func cancelAllWarnings() {}
}

/// W4-N1 copy (Faith): warm five-minute reminder; promises no extension or completion.
enum ReservationWarningCopy {
    static let title = "A little help goes a long way"
    static let body = "You have 5 minutes left to finish helping. Head back to \(AppBrand.name) to wrap things up."
}

/// The real implementation, backed by `UNUserNotificationCenter`.
///
/// Deliberately no notification actions/categories: `Add 5 minutes` and
/// `Release reservation` are in-app actions reached after the tap opens
/// CommonPlate, not background notification-action-button mutations — the
/// accepted contract stops short of the materially broader
/// background-execution architecture that would require.
nonisolated final class UNUserNotificationCenterReservationWarningScheduler:
    ReservationWarningScheduling,
    @unchecked Sendable
{
    static let identifierPrefix = "reservation-warning-"

    private let center: ReservationWarningNotificationCentering
    private let operationFence = ReservationWarningOperationFence()

    init(center: UNUserNotificationCenter = .current()) {
        self.center = SystemReservationWarningNotificationCenter(center: center)
    }

    init(notificationCenter: ReservationWarningNotificationCentering) {
        self.center = notificationCenter
    }

    /// Stable domain identifier. `requestID` survives process termination,
    /// unlike `RequestStore`'s process-local claim UUID, so a relaunched
    /// process can replace or cancel the exact warning an earlier process
    /// scheduled. Adding another request with this identifier replaces the
    /// pending one, which is the extension/reschedule behavior this needs.
    static func identifier(for requestID: String) -> String {
        "\(identifierPrefix)\(requestID)"
    }

    static func reservationWarningIdentifiers(in identifiers: [String]) -> [String] {
        identifiers.filter { $0.hasPrefix(identifierPrefix) }
    }

    func scheduleWarning(requestID: String, fireAt: Date) {
        let identifier = Self.identifier(for: requestID)
        let scheduleGeneration = operationFence.beginSchedule(identifier: identifier)
        // A prior deadline may already have delivered while the app was in
        // the background. Reconciliation/extension under the same durable
        // reservation identity retires that stale delivered warning before
        // installing the warning for the authoritative current deadline.
        center.removeDeliveredNotifications(withIdentifiers: [identifier])

        let content = UNMutableNotificationContent()
        content.title = ReservationWarningCopy.title
        content.body = ReservationWarningCopy.body
        content.sound = .default
        content.userInfo = [
            "type": ReservationWarningNotificationPayloadParser.reservationWarningType,
            "requestId": requestID,
        ]

        // `UNTimeIntervalNotificationTrigger` requires a positive interval;
        // a `fireAt` at or before now (the claim's own five-minute-remaining
        // instant already passed by the time this runs, e.g. a very short
        // remaining request window) still schedules, just as close to
        // immediately as the API allows, rather than silently scheduling
        // nothing.
        let interval = max(fireAt.timeIntervalSinceNow, 1)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )
        center.add(request) { [weak self] error in
            guard let self else { return }
            guard self.operationFence.completeSchedule(
                    identifier: identifier,
                    scheduleGeneration: scheduleGeneration,
                    succeeded: error == nil
                  ) else {
                return
            }
            // A newer exact cancellation or namespace cleanup won while the
            // notification center was still installing this older request.
            self.center.removePendingNotificationRequests(withIdentifiers: [identifier])
            self.center.removeDeliveredNotifications(withIdentifiers: [identifier])
        }
    }

    func cancelWarning(requestID: String) {
        let identifier = Self.identifier(for: requestID)
        operationFence.beginCancel(identifier: identifier)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    func cancelAllWarnings() {
        let cleanupGeneration = operationFence.beginNamespaceCleanup()
        center.getPendingNotificationRequests { [center] requests in
            let namespaceIdentifiers = Self.reservationWarningIdentifiers(
                in: requests.map(\.identifier)
            )
            self.operationFence.removeIdentifiersEligibleForCleanup(
                namespaceIdentifiers,
                cleanupGeneration: cleanupGeneration,
                remove: { identifiers in
                    center.removePendingNotificationRequests(withIdentifiers: identifiers)
                }
            )
        }
        center.getDeliveredNotificationRequests { [center] requests in
            let namespaceIdentifiers = Self.reservationWarningIdentifiers(
                in: requests.map(\.identifier)
            )
            self.operationFence.removeIdentifiersEligibleForCleanup(
                namespaceIdentifiers,
                cleanupGeneration: cleanupGeneration,
                remove: { identifiers in
                    center.removeDeliveredNotifications(withIdentifiers: identifiers)
                }
            )
        }
    }
}
