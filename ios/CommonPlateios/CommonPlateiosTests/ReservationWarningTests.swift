//
//  ReservationWarningTests.swift
//  CommonPlateiosTests
//
// Focused coverage for the W3-H1 five-minute reservation warning:
// `RequestStore` scheduling/rescheduling/canceling the local notification
// through `ReservationWarningScheduling`, the in-app foreground warning
// firing exactly once, and — since W4-H1 removed the legacy T−3 prompt — the
// warning creating no second extension decision of its own.
import Foundation
import XCTest
@testable import CommonPlateios

/// Records every schedule/cancel call `RequestStore` makes, so these cases can
/// assert the scheduling contract (when, and for which request) without a real
/// `UNUserNotificationCenter` — matching the double-per-dependency convention
/// used throughout this test target.
@MainActor
final class RecordingReservationWarningScheduler: ReservationWarningScheduling {
    struct ScheduledWarning: Equatable {
        let requestID: String
        let fireAt: Date
    }

    private(set) var scheduled: [ScheduledWarning] = []
    private(set) var cancelled: [String] = []
    private(set) var cancelAllCount = 0
    private(set) var pending: [String: Date] = [:]

    func scheduleWarning(requestID: String, fireAt: Date) {
        scheduled.append(ScheduledWarning(requestID: requestID, fireAt: fireAt))
        pending[requestID] = fireAt
    }

    func cancelWarning(requestID: String) {
        cancelled.append(requestID)
        pending.removeValue(forKey: requestID)
    }

    func cancelAllWarnings() {
        cancelAllCount += 1
        pending.removeAll()
    }
}

/// A notification-center double whose add, pending-enumeration, and
/// delivered-enumeration callbacks are completed independently by each test.
/// Snapshots are taken when enumeration completes, matching the scheduler's
/// only safe assumption about the real center: callbacks may arrive in any
/// order relative to later schedule and cleanup operations.
nonisolated final class ControlledReservationWarningNotificationCenter:
    ReservationWarningNotificationCentering,
    @unchecked Sendable
{
    private struct AddOperation {
        let request: UNNotificationRequest
        let completion: @Sendable (Error?) -> Void
    }

    private let lock = NSLock()
    private var pendingRequests: [UNNotificationRequest]
    private var deliveredRequests: [UNNotificationRequest]
    private var addOperations: [AddOperation] = []
    private var pendingCallbacks: [@Sendable ([UNNotificationRequest]) -> Void] = []
    private var deliveredCallbacks: [@Sendable ([UNNotificationRequest]) -> Void] = []

    init(
        pendingIdentifiers: [String] = [],
        deliveredIdentifiers: [String] = []
    ) {
        pendingRequests = Self.requests(for: pendingIdentifiers)
        deliveredRequests = Self.requests(for: deliveredIdentifiers)
    }

    private static func requests(for identifiers: [String]) -> [UNNotificationRequest] {
        identifiers.map { identifier in
            UNNotificationRequest(
                identifier: identifier,
                content: UNMutableNotificationContent(),
                trigger: nil
            )
        }
    }

    func add(
        _ request: UNNotificationRequest,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        lock.lock()
        addOperations.append(AddOperation(request: request, completion: completionHandler))
        lock.unlock()
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        lock.lock()
        pendingRequests.removeAll { identifiers.contains($0.identifier) }
        lock.unlock()
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        lock.lock()
        deliveredRequests.removeAll { identifiers.contains($0.identifier) }
        lock.unlock()
    }

    func getPendingNotificationRequests(
        completionHandler: @escaping @Sendable ([UNNotificationRequest]) -> Void
    ) {
        lock.lock()
        pendingCallbacks.append(completionHandler)
        lock.unlock()
    }

    func getDeliveredNotificationRequests(
        completionHandler: @escaping @Sendable ([UNNotificationRequest]) -> Void
    ) {
        lock.lock()
        deliveredCallbacks.append(completionHandler)
        lock.unlock()
    }

    var pendingIdentifiers: [String] {
        lock.lock()
        defer { lock.unlock() }
        return pendingRequests.map(\.identifier)
    }

    var pendingEnumerationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingCallbacks.count
    }

    var deliveredIdentifiers: [String] {
        lock.lock()
        defer { lock.unlock() }
        return deliveredRequests.map(\.identifier)
    }

    var deliveredEnumerationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return deliveredCallbacks.count
    }

    var delayedAddCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return addOperations.count
    }

    func completeNextAdd(error: Error? = nil) {
        let operation: AddOperation
        lock.lock()
        operation = addOperations.removeFirst()
        if error == nil {
            pendingRequests.removeAll { $0.identifier == operation.request.identifier }
            pendingRequests.append(operation.request)
        }
        lock.unlock()
        operation.completion(error)
    }

    func completeNextPendingEnumeration() {
        let callback: @Sendable ([UNNotificationRequest]) -> Void
        let snapshot: [UNNotificationRequest]
        lock.lock()
        callback = pendingCallbacks.removeFirst()
        snapshot = pendingRequests
        lock.unlock()
        callback(snapshot)
    }

    func completeNextDeliveredEnumeration() {
        let callback: @Sendable ([UNNotificationRequest]) -> Void
        let snapshot: [UNNotificationRequest]
        lock.lock()
        callback = deliveredCallbacks.removeFirst()
        snapshot = deliveredRequests
        lock.unlock()
        callback(snapshot)
    }
}

@MainActor
final class ReservationWarningTests: XCTestCase {
    private let requestID = "warning-target"

    override func tearDown() {
        ClaimFlowURLProtocol.reset()
        super.tearDown()
    }

    func testConcreteIdentifierIsStableByRequestAndBulkFilteringPreservesUnrelatedNotifications() {
        XCTAssertEqual(
            UNUserNotificationCenterReservationWarningScheduler.identifier(for: requestID),
            "reservation-warning-\(requestID)"
        )
        XCTAssertEqual(
            UNUserNotificationCenterReservationWarningScheduler.reservationWarningIdentifiers(in: [
                "reservation-warning-first",
                "unrelated-commonplate-notification",
                "reservation-warning-second"
            ]),
            ["reservation-warning-first", "reservation-warning-second"]
        )
    }

    func testCleanupCompletesBeforeALaterScheduleAndTheLaterWarningSurvives() {
        let identifier = UNUserNotificationCenterReservationWarningScheduler.identifier(
            for: requestID
        )
        let center = ControlledReservationWarningNotificationCenter(
            pendingIdentifiers: [identifier]
        )
        let scheduler = UNUserNotificationCenterReservationWarningScheduler(
            notificationCenter: center
        )

        scheduler.cancelAllWarnings()
        center.completeNextPendingEnumeration()
        center.completeNextDeliveredEnumeration()
        XCTAssertFalse(center.pendingIdentifiers.contains(identifier))

        scheduler.scheduleWarning(
            requestID: requestID,
            fireAt: Date().addingTimeInterval(60)
        )
        center.completeNextAdd()

        XCTAssertEqual(center.pendingIdentifiers, [identifier])
    }

    func testScheduleEstablishedDuringOlderCleanupSurvivesLaterEnumeration() {
        let staleIdentifier = UNUserNotificationCenterReservationWarningScheduler.identifier(
            for: "stale-reservation"
        )
        let newerIdentifier = UNUserNotificationCenterReservationWarningScheduler.identifier(
            for: "new-reservation"
        )
        let helperIdentifier = "helper-new-request-notification"
        let requesterIdentifier = "requester-fulfillment-notification"
        let center = ControlledReservationWarningNotificationCenter(
            pendingIdentifiers: [staleIdentifier, helperIdentifier, requesterIdentifier]
        )
        let scheduler = UNUserNotificationCenterReservationWarningScheduler(
            notificationCenter: center
        )

        scheduler.cancelAllWarnings()
        XCTAssertEqual(center.pendingEnumerationCount, 1)
        XCTAssertEqual(center.deliveredEnumerationCount, 1)

        scheduler.scheduleWarning(
            requestID: "new-reservation",
            fireAt: Date().addingTimeInterval(60)
        )
        center.completeNextAdd()
        center.completeNextPendingEnumeration()
        center.completeNextDeliveredEnumeration()

        XCTAssertFalse(center.pendingIdentifiers.contains(staleIdentifier))
        XCTAssertTrue(center.pendingIdentifiers.contains(newerIdentifier))
        XCTAssertTrue(center.pendingIdentifiers.contains(helperIdentifier))
        XCTAssertTrue(center.pendingIdentifiers.contains(requesterIdentifier))
    }

    func testCancelBeforeDelayedAddCompletionRetiresTheLateWarning() {
        let identifier = UNUserNotificationCenterReservationWarningScheduler.identifier(
            for: requestID
        )
        let center = ControlledReservationWarningNotificationCenter()
        let scheduler = UNUserNotificationCenterReservationWarningScheduler(
            notificationCenter: center
        )

        scheduler.scheduleWarning(
            requestID: requestID,
            fireAt: Date().addingTimeInterval(60)
        )
        XCTAssertEqual(center.delayedAddCount, 1)

        scheduler.cancelWarning(requestID: requestID)
        center.completeNextAdd()

        XCTAssertFalse(center.pendingIdentifiers.contains(identifier))
        XCTAssertFalse(center.deliveredIdentifiers.contains(identifier))
    }

    func testCleanupBeforeDelayedAddCompletionRetiresTheLateWarning() {
        let identifier = UNUserNotificationCenterReservationWarningScheduler.identifier(
            for: requestID
        )
        let center = ControlledReservationWarningNotificationCenter()
        let scheduler = UNUserNotificationCenterReservationWarningScheduler(
            notificationCenter: center
        )

        scheduler.scheduleWarning(
            requestID: requestID,
            fireAt: Date().addingTimeInterval(60)
        )
        scheduler.cancelAllWarnings()
        center.completeNextPendingEnumeration()
        center.completeNextDeliveredEnumeration()

        center.completeNextAdd()

        XCTAssertFalse(center.pendingIdentifiers.contains(identifier))
        XCTAssertFalse(center.deliveredIdentifiers.contains(identifier))
    }

    func testCleanupScopesDeliveredAndPendingWarningsWithoutTouchingOtherNotificationKinds() {
        let pendingWarning = UNUserNotificationCenterReservationWarningScheduler.identifier(
            for: "pending-reservation"
        )
        let deliveredWarning = UNUserNotificationCenterReservationWarningScheduler.identifier(
            for: "delivered-reservation"
        )
        let helperIdentifier = "helper-new-request-notification"
        let requesterIdentifier = "requester-fulfillment-notification"
        let center = ControlledReservationWarningNotificationCenter(
            pendingIdentifiers: [pendingWarning, helperIdentifier],
            deliveredIdentifiers: [deliveredWarning, requesterIdentifier]
        )
        let scheduler = UNUserNotificationCenterReservationWarningScheduler(
            notificationCenter: center
        )

        scheduler.cancelAllWarnings()
        center.completeNextDeliveredEnumeration()
        center.completeNextPendingEnumeration()

        XCTAssertEqual(center.pendingIdentifiers, [helperIdentifier])
        XCTAssertEqual(center.deliveredIdentifiers, [requesterIdentifier])
    }

    func testRepeatedCompletedScheduleCancelCyclesDoNotLeaveGhostOperations() {
        let center = ControlledReservationWarningNotificationCenter()
        let scheduler = UNUserNotificationCenterReservationWarningScheduler(
            notificationCenter: center
        )

        for cycle in 0..<200 {
            let cycleRequestID = "cycle-\(cycle)"
            scheduler.scheduleWarning(
                requestID: cycleRequestID,
                fireAt: Date().addingTimeInterval(60)
            )
            center.completeNextAdd()
            scheduler.cancelWarning(requestID: cycleRequestID)
        }
        XCTAssertTrue(center.pendingIdentifiers.isEmpty)
        XCTAssertEqual(center.delayedAddCount, 0)

        // No retired generation from the completed cycles may interfere with
        // the next ordinary schedule or the next authoritative cleanup.
        scheduler.scheduleWarning(
            requestID: requestID,
            fireAt: Date().addingTimeInterval(60)
        )
        center.completeNextAdd()
        XCTAssertEqual(
            center.pendingIdentifiers,
            [UNUserNotificationCenterReservationWarningScheduler.identifier(for: requestID)]
        )

        scheduler.cancelAllWarnings()
        center.completeNextPendingEnumeration()
        center.completeNextDeliveredEnumeration()
        XCTAssertTrue(center.pendingIdentifiers.isEmpty)
    }

    func testClaimingSchedulesTheWarningFiveMinutesBeforeTheDeadline() async throws {
        let scheduler = RecordingReservationWarningScheduler()
        let store = makeStore(scheduler: scheduler)
        let claimExpiresAt = Date().addingTimeInterval(15 * 60)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimExpiresAt: claimExpiresAt)))

        try await store.claim(requestID: requestID)

        let warning = try XCTUnwrap(scheduler.scheduled.first)
        XCTAssertEqual(warning.requestID, requestID)
        XCTAssertEqual(
            warning.fireAt.timeIntervalSince1970,
            claimExpiresAt.addingTimeInterval(-RequestStore.reservationWarningLead).timeIntervalSince1970,
            accuracy: 0.01
        )
    }

    func testExtendingReschedulesTheWarningAgainstTheNewDeadline() async throws {
        let scheduler = RecordingReservationWarningScheduler()
        let store = makeStore(scheduler: scheduler)
        let originalExpiration = Date().addingTimeInterval(15 * 60)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimExpiresAt: originalExpiration)))
        try await store.claim(requestID: requestID)

        let extendedExpiration = originalExpiration.addingTimeInterval(5 * 60)
        ClaimFlowURLProtocol.enqueue(.response(
            data: extensionResponse(claimExpiresAt: extendedExpiration, claimExtendedAt: Date())
        ))
        await store.extendActiveClaim()

        XCTAssertEqual(scheduler.scheduled.count, 2)
        let rescheduled = try XCTUnwrap(scheduler.scheduled.last)
        XCTAssertEqual(rescheduled.requestID, requestID)
        XCTAssertEqual(
            rescheduled.fireAt.timeIntervalSince1970,
            extendedExpiration.addingTimeInterval(-RequestStore.reservationWarningLead).timeIntervalSince1970,
            accuracy: 0.01
        )
        XCTAssertEqual(scheduler.pending.count, 1, "the same request identity replaces its earlier schedule")
    }

    func testRelaunchReconstructionUsesTheSameStableRequestIdentity() async throws {
        let scheduler = RecordingReservationWarningScheduler()
        let firstProcess = makeStore(scheduler: scheduler)
        ClaimFlowURLProtocol.enqueue(.response(
            data: claimResponse(claimExpiresAt: Date().addingTimeInterval(15 * 60))
        ))
        try await firstProcess.claim(requestID: requestID)

        let reconstructedProcess = makeStore(scheduler: scheduler)
        ClaimFlowURLProtocol.enqueue(.response(
            data: activeReservationResponse(claimExpiresAt: Date().addingTimeInterval(14 * 60))
        ))
        _ = try await reconstructedProcess.continueActiveReservationIfNeeded()

        XCTAssertEqual(scheduler.scheduled.map(\.requestID), [requestID, requestID])
        XCTAssertEqual(scheduler.pending.count, 1)
    }

    func testReleasingCancelsTheScheduledWarning() async throws {
        let scheduler = RecordingReservationWarningScheduler()
        let store = makeStore(scheduler: scheduler)
        ClaimFlowURLProtocol.enqueue(.response(
            data: claimResponse(claimExpiresAt: Date().addingTimeInterval(15 * 60))
        ))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(data: Data(#"{"released":true}"#.utf8)))
        ClaimFlowURLProtocol.enqueue(.response(data: Data(#"{"requests":[]}"#.utf8)))

        await store.releaseActiveClaim()
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }

        XCTAssertEqual(scheduler.cancelled, [requestID])
    }

    func testFulfillingCancelsTheScheduledWarning() async throws {
        let scheduler = RecordingReservationWarningScheduler()
        let store = makeStore(scheduler: scheduler)
        ClaimFlowURLProtocol.enqueue(.response(
            data: claimResponse(claimExpiresAt: Date().addingTimeInterval(15 * 60))
        ))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse()))

        try await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "12345",
            eta: "15 minutes",
            contactMessage: nil
        )

        XCTAssertEqual(scheduler.cancelled, [requestID])
    }

    func testReconstructedReleaseCancelsAWarningCreatedByAnEarlierProcessIdentity() async throws {
        let scheduler = RecordingReservationWarningScheduler()
        scheduler.scheduleWarning(requestID: requestID, fireAt: Date().addingTimeInterval(60))
        let reconstructedProcess = makeStore(scheduler: scheduler)
        ClaimFlowURLProtocol.enqueue(.response(
            data: activeReservationResponse(claimExpiresAt: Date().addingTimeInterval(14 * 60))
        ))
        _ = try await reconstructedProcess.continueActiveReservationIfNeeded()
        ClaimFlowURLProtocol.enqueue(.response(data: Data(#"{"released":true}"#.utf8)))
        ClaimFlowURLProtocol.enqueue(.response(data: Data(#"{"requests":[]}"#.utf8)))

        await reconstructedProcess.releaseActiveClaim()
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !reconstructedProcess.isFetching }

        XCTAssertNil(scheduler.pending[requestID])
        XCTAssertEqual(scheduler.cancelled.last, requestID)
    }

    func testReconstructedFulfillmentCancelsAWarningCreatedByAnEarlierProcessIdentity() async throws {
        let scheduler = RecordingReservationWarningScheduler()
        scheduler.scheduleWarning(requestID: requestID, fireAt: Date().addingTimeInterval(60))
        let reconstructedProcess = makeStore(scheduler: scheduler)
        ClaimFlowURLProtocol.enqueue(.response(
            data: activeReservationResponse(claimExpiresAt: Date().addingTimeInterval(14 * 60))
        ))
        _ = try await reconstructedProcess.continueActiveReservationIfNeeded()
        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse()))

        try await reconstructedProcess.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "12345",
            eta: "15 minutes",
            contactMessage: nil
        )

        XCTAssertNil(scheduler.pending[requestID])
        XCTAssertEqual(scheduler.cancelled.last, requestID)
    }

    /// The foreground half: fires once while the claim is live, and cancels
    /// the redundant scheduled notification for the same live moment rather
    /// than let both surface.
    func testTheInAppWarningFiresOnceAndCancelsTheScheduledNotification() async throws {
        let scheduler = RecordingReservationWarningScheduler()
        let store = makeStore(scheduler: scheduler)
        store.updateApplicationVisibility(isVisible: true)
        // Already inside the five-minute window when the timer starts, so the
        // warning step runs immediately rather than after a real five-minute
        // sleep — the same "already past" pattern the existing T-3 tests use.
        ClaimFlowURLProtocol.enqueue(.response(
            data: claimResponse(claimExpiresAt: Date().addingTimeInterval(0.3))
        ))

        try await store.claim(requestID: requestID)

        await waitUntil { store.isShowingReservationWarning }
        XCTAssertTrue(scheduler.cancelled.contains(requestID))
    }

    func testDueInAppWarningTransfersToLocalOwnershipWhenTheAppBecomesInactive() async throws {
        let scheduler = RecordingReservationWarningScheduler()
        let store = makeStore(scheduler: scheduler)
        store.updateApplicationVisibility(isVisible: true)
        ClaimFlowURLProtocol.enqueue(.response(
            data: claimResponse(claimExpiresAt: Date().addingTimeInterval(2))
        ))
        try await store.claim(requestID: requestID)
        await waitUntil { store.isShowingReservationWarning }

        XCTAssertNil(scheduler.pending[requestID], "the active in-app owner suppresses its local duplicate")

        let transitionTime = Date()
        store.updateApplicationVisibility(isVisible: false, now: transitionTime)

        XCTAssertFalse(store.isShowingReservationWarning)
        let transferred = try XCTUnwrap(scheduler.scheduled.last)
        XCTAssertEqual(transferred.requestID, requestID)
        XCTAssertEqual(
            transferred.fireAt.timeIntervalSince1970,
            transitionTime.timeIntervalSince1970,
            accuracy: 0.01
        )
        XCTAssertNotNil(scheduler.pending[requestID])
    }

    func testActiveReentryBeforeTransferredWarningDeliveryRestoresInAppOwnershipWithoutDuplicate() async throws {
        let scheduler = RecordingReservationWarningScheduler()
        let store = makeStore(scheduler: scheduler)
        store.updateApplicationVisibility(isVisible: true)
        ClaimFlowURLProtocol.enqueue(.response(
            data: claimResponse(claimExpiresAt: Date().addingTimeInterval(2))
        ))
        try await store.claim(requestID: requestID)
        await waitUntil { store.isShowingReservationWarning }

        store.updateApplicationVisibility(isVisible: false)
        XCTAssertFalse(store.isShowingReservationWarning)
        XCTAssertNotNil(scheduler.pending[requestID])

        store.updateApplicationVisibility(isVisible: true)
        await waitUntil { store.isShowingReservationWarning }

        XCTAssertNil(scheduler.pending[requestID])
        XCTAssertEqual(scheduler.scheduled.map(\.requestID), [requestID, requestID])
        XCTAssertEqual(scheduler.cancelled, [requestID, requestID])
    }

    func testReleaseCompletingDuringWarningOwnershipTransferCancelsTheTransferredWarning() async throws {
        let scheduler = RecordingReservationWarningScheduler()
        let store = makeStore(scheduler: scheduler)
        store.updateApplicationVisibility(isVisible: true)
        ClaimFlowURLProtocol.enqueue(.response(
            data: claimResponse(claimExpiresAt: Date().addingTimeInterval(2))
        ))
        try await store.claim(requestID: requestID)
        await waitUntil { store.isShowingReservationWarning }

        store.updateApplicationVisibility(isVisible: false)
        XCTAssertNotNil(scheduler.pending[requestID])

        let releaseGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            data: Data(#"{"released":true}"#.utf8),
            gate: releaseGate
        ))
        ClaimFlowURLProtocol.enqueue(.response(data: Data(#"{"requests":[]}"#.utf8)))
        let release = Task { await store.releaseActiveClaim() }
        await waitUntil { releaseGate.isWaiting }
        XCTAssertNotNil(scheduler.pending[requestID])

        releaseGate.open()
        await release.value
        await waitUntil { store.activeClaim == nil }

        XCTAssertNil(scheduler.pending[requestID])
        XCTAssertEqual(scheduler.cancelled.last, requestID)
    }

    func testFulfillmentCompletingDuringWarningOwnershipTransferCancelsTheTransferredWarning() async throws {
        let scheduler = RecordingReservationWarningScheduler()
        let store = makeStore(scheduler: scheduler)
        store.updateApplicationVisibility(isVisible: true)
        ClaimFlowURLProtocol.enqueue(.response(
            data: claimResponse(claimExpiresAt: Date().addingTimeInterval(2))
        ))
        try await store.claim(requestID: requestID)
        await waitUntil { store.isShowingReservationWarning }

        store.updateApplicationVisibility(isVisible: false)
        XCTAssertNotNil(scheduler.pending[requestID])

        let fulfillmentGate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            data: fulfillmentResponse(),
            gate: fulfillmentGate
        ))
        let fulfillment = Task {
            try await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "12345",
                eta: "15 minutes",
                contactMessage: nil
            )
        }
        await waitUntil { fulfillmentGate.isWaiting }
        XCTAssertNotNil(scheduler.pending[requestID])

        fulfillmentGate.open()
        try await fulfillment.value

        XCTAssertNil(store.activeClaim)
        XCTAssertNil(scheduler.pending[requestID])
        XCTAssertEqual(scheduler.cancelled.last, requestID)
    }

    func testAWarningDueWhileNotVisibleKeepsTheLocalNotificationAndShowsNoInAppWarning() async throws {
        let scheduler = RecordingReservationWarningScheduler()
        let store = makeStore(scheduler: scheduler)
        ClaimFlowURLProtocol.enqueue(.response(
            data: claimResponse(claimExpiresAt: Date().addingTimeInterval(1))
        ))

        try await store.claim(requestID: requestID)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(store.isShowingReservationWarning)
        XCTAssertTrue(scheduler.cancelled.isEmpty)
        XCTAssertNotNil(scheduler.pending[requestID])
    }

    func testForegroundToBackgroundBeforeT5PreservesTheLocalWarningPath() async throws {
        let scheduler = RecordingReservationWarningScheduler()
        let store = makeStore(scheduler: scheduler)
        store.updateApplicationVisibility(isVisible: true)
        ClaimFlowURLProtocol.enqueue(.response(
            data: claimResponse(
                claimExpiresAt: Date().addingTimeInterval(RequestStore.reservationWarningLead + 0.2)
            )
        ))
        try await store.claim(requestID: requestID)

        store.updateApplicationVisibility(isVisible: false)
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(store.isShowingReservationWarning)
        XCTAssertTrue(scheduler.cancelled.isEmpty)
        XCTAssertNotNil(scheduler.pending[requestID])
    }

    func testBackgroundToForegroundBeforeT5UsesTheInAppWarningAndCancelsLocalPresentation() async throws {
        let scheduler = RecordingReservationWarningScheduler()
        let store = makeStore(scheduler: scheduler)
        ClaimFlowURLProtocol.enqueue(.response(
            data: claimResponse(
                claimExpiresAt: Date().addingTimeInterval(RequestStore.reservationWarningLead + 0.2)
            )
        ))
        try await store.claim(requestID: requestID)

        store.updateApplicationVisibility(isVisible: true)
        await waitUntil { store.isShowingReservationWarning }

        XCTAssertEqual(scheduler.cancelled, [requestID])
        XCTAssertNil(scheduler.pending[requestID])
    }

    func testForegroundingAfterTheBackgroundWarningMomentReconcilesToTheInAppSurface() async throws {
        let scheduler = RecordingReservationWarningScheduler()
        let store = makeStore(scheduler: scheduler)
        ClaimFlowURLProtocol.enqueue(.response(
            data: claimResponse(claimExpiresAt: Date().addingTimeInterval(1))
        ))
        try await store.claim(requestID: requestID)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(store.isShowingReservationWarning)

        store.updateApplicationVisibility(isVisible: true)
        await waitUntil { store.isShowingReservationWarning }

        XCTAssertEqual(scheduler.cancelled, [requestID])
    }

    /// W3-H1 MUST FIX 2: `Release reservation` and `Add 5 minutes` are
    /// backend-authoritative actions that must be truthfully available the
    /// moment a reservation is active, not only once the five-minute warning
    /// has fired. `RequestStore.releaseActiveClaim()` and
    /// `.extendActiveClaim()` are proven here to succeed immediately after
    /// `claim()`, with `isShowingReservationWarning` still `false` throughout
    /// — the same store-level truth `FulfillRequestView`'s reservation-actions
    /// section reads unconditionally (see `reservationActionsSection`, which
    /// is no longer gated behind `store.isShowingReservationWarning`).
    func testExtendSucceedsBeforeTheWarningEverFires() async throws {
        let scheduler = RecordingReservationWarningScheduler()
        let store = makeStore(scheduler: scheduler)
        store.updateApplicationVisibility(isVisible: true)
        let originalExpiration = Date().addingTimeInterval(15 * 60)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimExpiresAt: originalExpiration)))
        try await store.claim(requestID: requestID)
        XCTAssertFalse(store.isShowingReservationWarning)
        XCTAssertTrue(store.activeClaim?.isExtensionAvailable ?? false)

        ClaimFlowURLProtocol.enqueue(.response(
            data: extensionResponse(
                claimExpiresAt: originalExpiration.addingTimeInterval(5 * 60),
                claimExtendedAt: Date()
            )
        ))
        await store.extendActiveClaim()

        XCTAssertFalse(store.isShowingReservationWarning)
        XCTAssertNil(store.claimExtensionError)
        XCTAssertTrue(store.activeClaim?.hasUsedExtension ?? false)
    }

    func testReleaseSucceedsBeforeTheWarningEverFires() async throws {
        let scheduler = RecordingReservationWarningScheduler()
        let store = makeStore(scheduler: scheduler)
        ClaimFlowURLProtocol.enqueue(.response(
            data: claimResponse(claimExpiresAt: Date().addingTimeInterval(15 * 60))
        ))
        try await store.claim(requestID: requestID)
        XCTAssertFalse(store.isShowingReservationWarning)

        ClaimFlowURLProtocol.enqueue(.response(data: Data(#"{"released":true}"#.utf8)))
        ClaimFlowURLProtocol.enqueue(.response(data: Data(#"{"requests":[]}"#.utf8)))
        await store.releaseActiveClaim()
        await waitUntil { ClaimFlowURLProtocol.capturedPaths.contains("/api/requests") }
        await waitUntil { !store.isFetching }

        XCTAssertNil(store.activeClaim)
        XCTAssertNil(store.releaseClaimError)
    }

    /// W4-H1 removes the legacy T−3 extension prompt. The five-minute warning
    /// is now the only timed reservation presentation, and it creates no
    /// controls or decision of its own: the Helping page's single extension
    /// offer is left exactly as it was, still offered once.
    func testTheWarningCreatesNoSecondDecisionAndLeavesTheSingleExtensionOfferIntact() async throws {
        let scheduler = RecordingReservationWarningScheduler()
        let store = makeStore(scheduler: scheduler)
        store.updateApplicationVisibility(isVisible: true)
        // Inside the five-minute window already, with plenty of request time
        // left, so the one extension still fits.
        ClaimFlowURLProtocol.enqueue(.response(
            data: claimResponse(claimExpiresAt: Date().addingTimeInterval(4 * 60))
        ))

        try await store.claim(requestID: requestID)

        await waitUntil { store.isShowingReservationWarning }
        let claim = try XCTUnwrap(store.activeClaim)
        XCTAssertTrue(claim.isExtensionAvailable)
        XCTAssertTrue(store.canExtendActiveClaim)
        XCTAssertEqual(FulfillRequestView.extensionControlState(for: claim), .available)
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, ["/api/request/\(requestID)/claim"])
    }

    // MARK: - Helpers

    private func makeStore(scheduler: ReservationWarningScheduling) -> RequestStore {
        RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { "64c0000000000000000000a1.1.credential" },
            participantAuthorityRejected: {},
            reservationWarningScheduler: scheduler
        )
    }

    private func makeService() -> RequestService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaimFlowURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return RequestService(client: client)
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func requestObject(status: String) -> String {
        """
        {
          "id": "\(requestID)",
          "vendor": "Crave NYU",
          "food": "Rice bowl",
          "pickupWindowText": "ASAP",
          "mealSwipes": 2,
          "menuPath": "meal-exchange",
          "mealItems": ["Meal 1", "Meal 2"],
          "orderDetails": null,
          "estimatedDiningDollarsCents": null,
          "windowStart": null,
          "windowEnd": null,
          "status": "\(status)",
          "createdAt": "2026-07-20T18:30:00.000Z",
          "expiresAt": "\(iso8601String(Date().addingTimeInterval(5 * 60 * 60)))"
        }
        """
    }

    private func claimResponse(claimExpiresAt: Date) -> Data {
        Data("""
        {
          "request": \(requestObject(status: "claimed")),
          "claim": {
            "pickupName": "Taylor",
            "claimToken": "claim-token",
            "claimExpiresAt": "\(iso8601String(claimExpiresAt))"
          }
        }
        """.utf8)
    }

    private func extensionResponse(claimExpiresAt: Date, claimExtendedAt: Date) -> Data {
        Data("""
        {
          "claim": {
            "claimExpiresAt": "\(iso8601String(claimExpiresAt))",
            "claimExtendedAt": "\(iso8601String(claimExtendedAt))"
          }
        }
        """.utf8)
    }

    private func activeReservationResponse(claimExpiresAt: Date) -> Data {
        Data("""
        {
          "reservation": {
            "request": \(requestObject(status: "claimed")),
            "pickupName": "Taylor",
            "claimExpiresAt": "\(iso8601String(claimExpiresAt))",
            "claimExtendedAt": null
          }
        }
        """.utf8)
    }

    private func fulfillmentResponse() -> Data {
        Data("""
        {
          "request": \(requestObject(status: "placed")),
          "notification": { "status": "sent" }
        }
        """.utf8)
    }

    private func waitUntil(
        timeoutIterations: Int = 400,
        condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<timeoutIterations {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}
