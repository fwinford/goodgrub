import Foundation
import SwiftUI
import XCTest
import UIKit
@testable import CommonPlateios

@MainActor
final class ParticipantDeletionLifecycleTests: XCTestCase {
    final class SecureStorage: ParticipantDeletionSecureStorage {
        var record: ParticipantDeletionRecord?
        var inaccessible = false
        var failJournalWrite = false
        var failRemoval = false
        var writes: [ParticipantDeletionRecord] = []
        func load() -> ParticipantDeletionRecordLoad {
            if inaccessible { return .unavailable }
            return record.map(ParticipantDeletionRecordLoad.record) ?? .absent
        }
        func save(_ record: ParticipantDeletionRecord) throws {
            if inaccessible || (failJournalWrite && record.stage == .completedCleanupPending) {
                throw ParticipantDeletionError.storageUnavailable
            }
            guard record.isValid else { throw ParticipantDeletionError.storageUnavailable }
            writes.append(record)
            self.record = record
        }
        func remove() throws {
            if inaccessible || failRemoval { throw ParticipantDeletionError.storageUnavailable }
            record = nil
        }
    }

    final class IdentityStorage: ParticipantIdentityStorage {
        var record: ParticipantIdentityRecord? = ParticipantIdentityRecord(
            principal: "test@nyu.edu", authority: canonicalParticipantAuthorityFixture, verifiedAt: Date()
        )
        let binding = UUID().uuidString
        var failCleanup = false
        var beforeCleanup: (() -> Void)?
        func loadValidIdentity() -> ParticipantIdentityRecord? { record }
        func save(_ record: ParticipantIdentityRecord) -> Bool { self.record = record; return true }
        func clear() { record = nil }
        func deletionBinding(participantID: String) throws -> String {
            guard record.map({ ParticipantAuthorityShape.participantIdentifier(ofAuthority: $0.authority) }) == participantID else {
                throw ParticipantDeletionError.identityChanged
            }
            return binding
        }
        func deleteCompletedIdentity(participantID: String, installationBinding: String) throws -> CompletedIdentityCleanup {
            beforeCleanup?()
            if failCleanup { throw ParticipantDeletionError.storageUnavailable }
            if let record,
               ParticipantAuthorityShape.participantIdentifier(ofAuthority: record.authority) != participantID {
                return .preservedForeign
            }
            guard installationBinding == binding,
                  record == nil || record.map({
                      ParticipantAuthorityShape.participantIdentifier(ofAuthority: $0.authority)
                  }) == participantID else { throw ParticipantDeletionError.identityChanged }
            record = nil
            return .removedOrAbsent
        }
    }

    final class OnboardingStorage: OnboardingPresentationStoring {
        var completion = true
        var discovery: HelpingDiscoveryRecord? = .complete
        var failReset = false
        var failCompletionReset = false
        var failDiscoveryReset = false
        var hasCompletedOnboarding: Bool {
            get { completion }
            set { if !failReset && !failCompletionReset { completion = newValue } }
        }
        var helpingDiscoveryRecord: HelpingDiscoveryRecord? {
            get { discovery }
            set { if !failReset && !failDiscoveryReset { discovery = newValue } }
        }
    }

    var defaults: UserDefaults!
    var suite: String!
    var secure: SecureStorage!
    var identityStorage: IdentityStorage!
    var identity: ParticipantIdentityStore!
    var onboardingStorage: OnboardingStorage!
    var onboarding: OnboardingPresentationStore!
    var service: RequestService!
    var fence: ParticipantDeletionNetworkFence!
    var notificationRouter: HelperNotificationRouter!
    var retirements = 0
    var handoffs = 0
    let operation = "a3f1c2b4-5e6d-4a1b-8c9d-0e1f2a3b4c5d"
    let namespace = "dn1_" + String(repeating: "a", count: 64)

    override func setUp() {
        super.setUp()
        suite = "ParticipantDeletionLifecycleTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        secure = SecureStorage()
        identityStorage = IdentityStorage()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ParticipantEmailUnsubscribeURLProtocol.self]
        fence = ParticipantDeletionNetworkFence()
        notificationRouter = HelperNotificationRouter(
            deletionNotificationFence: ParticipantDeletionNotificationFence(defaults: defaults)
        )
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://example.test")!),
            session: URLSession(configuration: config), deletionFence: fence
        )
        service = RequestService(client: client)
        identity = ParticipantIdentityStore(
            service: ParticipantVerificationService(client: client), storage: identityStorage
        )
        onboardingStorage = OnboardingStorage()
        onboarding = OnboardingPresentationStore(storage: onboardingStorage)
        retirements = 0
        handoffs = 0
    }

    override func tearDown() {
        ParticipantEmailUnsubscribeURLProtocol.reset()
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func makeStore() -> ParticipantDeletionStore {
        ParticipantDeletionStore(
            service: service, identity: identity, secureStorage: secure, defaults: defaults,
            networkFence: fence, onboarding: onboarding,
            fenceNotificationIntents: notificationRouter.fenceForCompletedDeletion,
            retirePresentation: { self.retirements += 1 },
            handoff: { self.handoffs += 1 }
        )
    }

    func enqueue(_ object: [String: Any], status: Int = 200) throws {
        ParticipantEmailUnsubscribeURLProtocol.enqueue(.response(
            statusCode: status, data: try JSONSerialization.data(withJSONObject: object)
        ))
    }

    func phase(_ phase: String) -> [String: Any] {
        var object: [String: Any] = [
            "operationId": operation, "namespaceBinding": namespace,
            "phase": phase, "readinessGeneration": 1,
        ]
        if phase == "challengeIssued" {
            object["challenge"] = [
                "expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(600)),
                "cooldownEndsAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(60)),
                "attemptsRemaining": 5,
            ]
        }
        if phase == "authorized" {
            object["authorization"] = ["expiresAt": "2099-10-24T20:05:00.000Z"]
            object["recoveryCapability"] = "opaque-test-recovery-capability"
        }
        return object
    }

    /// Default: eligible immediately, so B → Delete Account requests the code
    /// and opens J. `waited` (or any non-ready phase) uses the F wait path.
    func begin(_ store: ParticipantDeletionStore, phase: String = "ready", waited: Bool = false) async throws {
        if phase == "ready" && !waited {
            try enqueue(["eligible": true, "categories": []])
            try enqueue(self.phase(phase), status: 201)
            try enqueue(self.phase("challengeIssued"), status: 202)
            await store.begin()
            XCTAssertEqual(store.route, .verify)
        } else {
            try enqueue(["eligible": false, "categories": ["unknown"]])
            await store.begin()
            XCTAssertEqual(store.route, .wait)
            try enqueue(self.phase(phase), status: 201)
            await store.startDeletion()
        }
    }

    func authorize(_ store: ParticipantDeletionStore) async throws {
        try await begin(store)
        try enqueue(phase("authorized"))
        await store.redeem(code: "123456")
    }

    func testWaitingAndReadySurviveRelaunchWithoutIssuingCodeOrCompleting() async throws {
        let store = makeStore()
        try await begin(store, phase: "waiting")
        XCTAssertEqual(store.status?.phase, .waiting)
        XCTAssertNotNil(identityStorage.record)
        XCTAssertTrue(onboarding.hasCompletedOnboarding)
        XCTAssertFalse(fence.isFrozen)
        XCTAssertNil(defaults.object(forKey: ParticipantDeletionFreeze.key))
        let restored = makeStore()
        XCTAssertFalse(fence.isFrozen, "Waiting/ready keep ordinary use available (Faith 2026-10-25).")
        XCTAssertNotNil(identity.currentAuthority())
        try enqueue(phase("ready"))
        await restored.refresh()
        XCTAssertEqual(restored.status?.phase, .ready)
        XCTAssertFalse(fence.isFrozen)
        XCTAssertEqual(retirements, 0)
        XCTAssertFalse(ParticipantEmailUnsubscribeURLProtocol.capturedRequests.contains {
            $0.path.hasSuffix("/challenge") || $0.path.hasSuffix("/complete")
        })
    }

    func testAuthorizationRequiresSeparateExplicitFinalAction() async throws {
        let store = makeStore()
        try await authorize(store)
        XCTAssertEqual(store.status?.phase, .authorized)
        XCTAssertTrue(store.canComplete)
        XCTAssertNotNil(identityStorage.record)
        XCTAssertNotNil(secure.record?.capability)
        XCTAssertFalse(store.isCompleted)
        XCTAssertEqual(handoffs, 0)
        XCTAssertFalse(ParticipantEmailUnsubscribeURLProtocol.capturedRequests.contains { $0.path.hasSuffix("/complete") })
    }

    func testKnownFinalRefusalRequiresReconciliationAndNeverAutomaticallyResends() async throws {
        let store = makeStore()
        try await authorize(store)
        try enqueue(["error": ["code": "DELETION_BLOCKED", "message": "Finish current activity."]], status: 409)
        await store.complete()
        XCTAssertFalse(store.isUnresolved)
        XCTAssertFalse(store.isCompleted)
        XCTAssertFalse(store.canComplete)
        XCTAssertNotNil(identityStorage.record)
        XCTAssertNil(secure.record?.capability)
        XCTAssertEqual(secure.record?.stage, .active)
        let host = try OwnerRequestHost { _, _ in AnyView(ParticipantDeletionView(store: store)) }
        captureDeletionPresentation(host, name: "final-known-refusal")
        try enqueue(phase("waiting"))
        await store.refresh()
        XCTAssertEqual(store.status?.phase, .waiting)
        XCTAssertEqual(ParticipantEmailUnsubscribeURLProtocol.capturedRequests.filter { $0.path.hasSuffix("/complete") }.count, 1)
    }

    func testWrongCodeAndCooldownDoNotInventAttemptsReadinessOrCompletion() async throws {
        let store = makeStore()
        try await begin(store)
        XCTAssertEqual(store.maskedEmail, identity.identity?.masked)
        try enqueue(["error": ["code": "DELETION_CODE_INVALID", "message": "That code is incorrect."]], status: 401)
        await store.redeem(code: "111111")
        XCTAssertEqual(store.status?.phase, .challengeIssued)
        XCTAssertEqual(store.status?.challenge?.attemptsRemaining, 5)
        XCTAssertEqual(store.errorMessage, "That code is incorrect.")
        let host = try OwnerRequestHost { _, _ in AnyView(ParticipantDeletionView(store: store)) }
        captureDeletionPresentation(host, name: "verification-wrong-code")
        var updated = phase("challengeIssued")
        var challenge = try XCTUnwrap(updated["challenge"] as? [String: Any])
        challenge["attemptsRemaining"] = 4
        updated["challenge"] = challenge
        try enqueue(updated)
        await store.refresh()
        XCTAssertEqual(store.status?.challenge?.attemptsRemaining, 4)
        try enqueue(["error": ["code": "DELETION_CHALLENGE_COOLDOWN", "message": "Wait before resending."]], status: 429)
        await store.requestCode()
        XCTAssertEqual(store.status?.phase, .challengeIssued)
        XCTAssertNil(secure.record?.capability)
        XCTAssertFalse(store.isCompleted)
        XCTAssertEqual(handoffs, 0)
    }

    func testFinalJournalRetirementFailureResumesAfterO1WithoutBearerOrNetwork() async throws {
        let store = makeStore()
        try await authorize(store)
        secure.failRemoval = true
        try enqueue(["outcome": "completed"])
        await store.complete()
        XCTAssertTrue(store.cleanupFailed)
        XCTAssertFalse(store.isCompleted)
        XCTAssertNil(identityStorage.record)
        XCTAssertNil(secure.record?.capability)
        XCTAssertEqual(secure.record?.stage, .completedCleanupPending)
        XCTAssertNil(defaults.object(forKey: ParticipantDeletionFreeze.key))
        XCTAssertFalse(onboarding.hasCompletedOnboarding)
        secure.failRemoval = false
        let count = ParticipantEmailUnsubscribeURLProtocol.capturedRequests.count
        let restored = makeStore()
        XCTAssertNotNil(defaults.object(forKey: ParticipantDeletionFreeze.key))
        await restored.refresh()
        XCTAssertTrue(restored.isCompleted)
        XCTAssertEqual(ParticipantEmailUnsubscribeURLProtocol.capturedRequests.count, count)
        XCTAssertNil(secure.record)
    }

    func testMissingContextBindingCannotBeAcceptedAsAnActiveStatusRecord() async throws {
        let store = makeStore()
        try await begin(store)
        var invalid = try XCTUnwrap(secure.record)
        invalid.context.operationID = nil
        invalid.context.namespace = nil
        XCTAssertFalse(invalid.isValid)
        XCTAssertThrowsError(try secure.save(invalid))
    }

    func testCompletedJournalPreservesAnAlreadyAuthoritativeForeignParticipantAndItsOnboarding() async throws {
        let store = makeStore()
        try await authorize(store)
        secure.record = try XCTUnwrap(secure.record).cleanupJournal
        identityStorage.record = ParticipantIdentityRecord(
            principal: "b@nyu.edu", authority: replacementParticipantAuthorityFixture, verifiedAt: Date()
        )
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ParticipantEmailUnsubscribeURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://example.test")!),
            session: URLSession(configuration: config)
        )
        identity = ParticipantIdentityStore(
            service: ParticipantVerificationService(client: client), storage: identityStorage
        )
        let deliveredAt = Date().addingTimeInterval(-60)
        notificationRouter.handleUserActedOnNotification(userInfo: [
            "type": "requester-order-placed", "requestId": "64c0000000000000000000a1",
        ], deliveredAt: deliveredAt)
        let capturedSequence = notificationRouter.latestTapSequence
        XCTAssertNotNil(notificationRouter.pendingRequesterFulfillmentIntent)
        let restored = makeStore()
        await restored.refresh()
        XCTAssertFalse(restored.isPresented)
        XCTAssertFalse(restored.isCompleted)
        XCTAssertEqual(identity.currentAuthority(), replacementParticipantAuthorityFixture)
        XCTAssertEqual(identityStorage.record?.principal, "b@nyu.edu")
        XCTAssertTrue(onboarding.hasCompletedOnboarding)
        XCTAssertEqual(onboarding.helpingDiscoveryRecord, .complete)
        XCTAssertNil(defaults.object(forKey: ParticipantLocalPresentationStorage.generationKey))
        XCTAssertNil(secure.record)
        XCTAssertEqual(retirements, 0)
        XCTAssertEqual(handoffs, 0, "A foreign participant must not receive the root navigation reset.")
        XCTAssertNil(notificationRouter.pendingRequesterFulfillmentIntent)
        XCTAssertGreaterThan(notificationRouter.latestTapSequence, capturedSequence)
        notificationRouter.handleUserActedOnNotification(userInfo: [
            "type": "requester-order-placed", "requestId": "64c0000000000000000000a1",
        ], deliveredAt: deliveredAt)
        XCTAssertNil(notificationRouter.pendingRequesterFulfillmentIntent)
    }

    func testAuthoritativeCompletionRetiresBearerBeforeCheckedCleanupAndDoneUsesWelcome() async throws {
        let store = makeStore()
        try await authorize(store)
        identityStorage.beforeCleanup = {
            XCTAssertEqual(self.secure.record?.stage, .completedCleanupPending)
            XCTAssertNil(self.secure.record?.capability)
            XCTAssertNil(self.secure.record?.status)
            XCTAssertTrue(self.defaults.object(forKey: ParticipantDeletionFreeze.key) != nil)
        }
        try enqueue(["outcome": "completed"])
        await store.complete()
        XCTAssertTrue(store.isCompleted)
        XCTAssertFalse(store.cleanupFailed)
        XCTAssertNil(identityStorage.record)
        XCTAssertNil(identity.currentAuthority())
        XCTAssertNil(identity.identity)
        XCTAssertNil(secure.record)
        XCTAssertNil(defaults.object(forKey: ParticipantDeletionFreeze.key))
        XCTAssertFalse(onboarding.hasCompletedOnboarding)
        XCTAssertNil(onboarding.helpingDiscoveryRecord)
        XCTAssertEqual(handoffs, 0)
        store.done()
        XCTAssertEqual(handoffs, 1)
    }

    func testForeignParticipantCleanupRetryRetiresOnlyDeletedContextWithoutRootReset() async throws {
        let store = makeStore()
        try await authorize(store)
        secure.record = try XCTUnwrap(secure.record).cleanupJournal
        identityStorage.record = ParticipantIdentityRecord(
            principal: "b@nyu.edu", authority: replacementParticipantAuthorityFixture, verifiedAt: Date()
        )
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ParticipantEmailUnsubscribeURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://example.test")!),
            session: URLSession(configuration: config)
        )
        identity = ParticipantIdentityStore(
            service: ParticipantVerificationService(client: client), storage: identityStorage
        )
        secure.failRemoval = true
        let restored = makeStore()
        await restored.refresh()
        XCTAssertTrue(restored.cleanupFailed)
        XCTAssertNotNil(secure.record)
        XCTAssertEqual(handoffs, 0)
        secure.failRemoval = false
        restored.resumeCleanup()
        XCTAssertFalse(restored.cleanupFailed)
        XCTAssertFalse(restored.isPresented)
        XCTAssertNil(restored.errorMessage)
        XCTAssertNil(secure.record)
        XCTAssertEqual(identity.currentAuthority(), replacementParticipantAuthorityFixture)
        XCTAssertTrue(onboarding.hasCompletedOnboarding)
        XCTAssertEqual(retirements, 0)
        XCTAssertEqual(handoffs, 0)
    }

    func testLostCompleteResponseRetainsOnlyUnresolvedCapabilityThenRecoveryCleansWithoutSecondMutation() async throws {
        let store = makeStore()
        try await authorize(store)
        ParticipantEmailUnsubscribeURLProtocol.enqueue(.failure(.networkConnectionLost))
        await store.complete()
        XCTAssertTrue(store.isUnresolved)
        XCTAssertFalse(store.isCompleted)
        XCTAssertNotNil(identityStorage.record)
        XCTAssertEqual(secure.record?.stage, .completing)
        let restored = makeStore()
        let host = try OwnerRequestHost { _, _ in AnyView(ParticipantDeletionView(store: restored)) }
        XCTAssertTrue(host.exists("deletion-check-status"))
        XCTAssertTrue(host.exists("deletion-status-close"))
        captureDeletionPresentation(host, name: "recovery-relaunch-check")
        try enqueue(["outcome": "completed"])
        await restored.refresh()
        XCTAssertTrue(restored.isCompleted)
        XCTAssertNil(secure.record)
        XCTAssertEqual(ParticipantEmailUnsubscribeURLProtocol.capturedRequests.filter { $0.path.hasSuffix("/complete") }.count, 1)
        XCTAssertEqual(ParticipantEmailUnsubscribeURLProtocol.capturedRequests.filter { $0.path.hasSuffix("/recovery") }.count, 1)
    }

    func testUnavailableRecoveryNeverClearsIdentityOrResetsOnboarding() async throws {
        let store = makeStore()
        try await authorize(store)
        ParticipantEmailUnsubscribeURLProtocol.enqueue(.failure(.timedOut))
        await store.complete()
        try enqueue(["error": ["code": "PARTICIPANT_VERIFICATION_UNAVAILABLE", "message": "Unavailable"]], status: 503)
        let host = try OwnerRequestHost { _, _ in AnyView(ParticipantDeletionView(store: store)) }
        captureDeletionPresentation(host, name: "completion-unresolved")
        await store.recover()
        XCTAssertTrue(store.isUnresolved)
        XCTAssertFalse(store.isCompleted)
        XCTAssertNotNil(identityStorage.record)
        XCTAssertNotNil(secure.record?.capability)
        XCTAssertTrue(onboarding.hasCompletedOnboarding)
        host.settle()
        captureDeletionPresentation(host, name: "recovery-unavailable")
        store.done()
        XCTAssertEqual(handoffs, 0)
    }

    func testCleanupFailureBlocksWelcomeButBearerIsAlreadyRetiredAndJournalResumesOffline() async throws {
        let store = makeStore()
        try await authorize(store)
        identityStorage.failCleanup = true
        try enqueue(["outcome": "completed"])
        await store.complete()
        XCTAssertTrue(store.cleanupFailed)
        XCTAssertFalse(store.isCompleted)
        let host = try OwnerRequestHost { _, _ in AnyView(ParticipantDeletionView(store: store)) }
        captureDeletionPresentation(host, name: "local-cleanup-failure")
        XCTAssertNil(secure.record?.capability)
        XCTAssertEqual(secure.record?.stage, .completedCleanupPending)
        XCTAssertTrue(onboarding.hasCompletedOnboarding)
        store.done()
        XCTAssertEqual(handoffs, 0)
        identityStorage.failCleanup = false
        let requests = ParticipantEmailUnsubscribeURLProtocol.capturedRequests.count
        let restored = makeStore()
        await restored.refresh()
        XCTAssertTrue(restored.isCompleted)
        XCTAssertEqual(ParticipantEmailUnsubscribeURLProtocol.capturedRequests.count, requests)
    }

    func testFailedJournalReplacementAttemptsCheckedBearerRemovalAndKeepsFreeze() async throws {
        let store = makeStore()
        try await authorize(store)
        secure.failJournalWrite = true
        try enqueue(["outcome": "completed"])
        await store.complete()
        XCTAssertNil(secure.record)
        XCTAssertTrue(defaults.object(forKey: ParticipantDeletionFreeze.key) != nil)
        XCTAssertFalse(store.isCompleted)
        XCTAssertTrue(store.cleanupFailed)
        XCTAssertNotNil(identityStorage.record)
        XCTAssertNil(identity.identity)
        secure.failJournalWrite = false
        store.resumeCleanup()
        XCTAssertTrue(store.isCompleted)
    }

    func testO1WriteFailureKeepsJournalAndBlocksFinalHandoff() async throws {
        let store = makeStore()
        try await authorize(store)
        onboardingStorage.failReset = true
        try enqueue(["outcome": "completed"])
        await store.complete()
        XCTAssertNil(identityStorage.record)
        XCTAssertTrue(store.cleanupFailed)
        XCTAssertEqual(secure.record?.stage, .completedCleanupPending)
        XCTAssertNil(secure.record?.capability)
        store.done()
        XCTAssertEqual(handoffs, 0)
        onboardingStorage.failReset = false
        store.resumeCleanup()
        XCTAssertTrue(store.isCompleted)
    }

    func testFailedFirstO1WriteNeverClearsDiscoveryOrPublishesWelcome() async throws {
        let store = makeStore()
        try await authorize(store)
        onboardingStorage.failCompletionReset = true
        try enqueue(["outcome": "completed"])
        await store.complete()
        XCTAssertTrue(store.cleanupFailed)
        XCTAssertTrue(onboardingStorage.completion)
        XCTAssertEqual(onboardingStorage.discovery, .complete)
        XCTAssertTrue(onboarding.hasCompletedOnboarding)
        XCTAssertNil(secure.record?.capability)
        XCTAssertEqual(handoffs, 0)
        onboardingStorage.failCompletionReset = false
        makeStore().resumeCleanup()
        XCTAssertFalse(onboardingStorage.completion)
        XCTAssertNil(onboardingStorage.discovery)
    }

    func testFailedSecondO1WriteKeepsJournalAndRelaunchResumesOrderedReset() async throws {
        let store = makeStore()
        try await authorize(store)
        onboardingStorage.failDiscoveryReset = true
        try enqueue(["outcome": "completed"])
        await store.complete()
        XCTAssertTrue(store.cleanupFailed)
        XCTAssertFalse(onboardingStorage.completion)
        XCTAssertEqual(onboardingStorage.discovery, .complete)
        XCTAssertEqual(secure.record?.stage, .completedCleanupPending)
        XCTAssertFalse(store.isCompleted)
        onboardingStorage.failDiscoveryReset = false
        let restored = makeStore()
        restored.resumeCleanup()
        XCTAssertTrue(restored.isCompleted)
        XCTAssertNil(onboardingStorage.discovery)
    }

    func testInaccessibleRecoveryAndOrphanFreezeFailClosedWithoutNetwork() async throws {
        secure.inaccessible = true
        let inaccessible = makeStore()
        await inaccessible.refresh()
        XCTAssertTrue(inaccessible.isPresented)
        XCTAssertFalse(inaccessible.isCompleted)
        XCTAssertTrue(ParticipantEmailUnsubscribeURLProtocol.capturedRequests.isEmpty)
        let inaccessibleHost = try OwnerRequestHost { _, _ in AnyView(ParticipantDeletionView(store: inaccessible)) }
        captureDeletionPresentation(inaccessibleHost, name: "recovery-storage-unavailable")
        secure.inaccessible = false
        try ParticipantDeletionFreeze(defaults: defaults).write(UUID().uuidString)
        let orphan = makeStore()
        await orphan.refresh()
        XCTAssertTrue(orphan.isPresented)
        XCTAssertFalse(orphan.isCompleted)
        XCTAssertNotNil(identityStorage.record)
        let orphanHost = try OwnerRequestHost { _, _ in AnyView(ParticipantDeletionView(store: orphan)) }
        captureDeletionPresentation(orphanHost, name: "recovery-orphan-freeze")
    }

    func testAuthoritativeCancelUnfreezesWithoutIdentityCleanupOrO1Reset() async throws {
        let store = makeStore()
        try await begin(store)
        try enqueue(phase("canceled"))
        await store.cancel()
        XCTAssertFalse(store.isPresented)
        XCTAssertFalse(store.isBusy)
        XCTAssertNil(secure.record)
        XCTAssertFalse(fence.isFrozen)
        XCTAssertNotNil(identity.currentAuthority())
        XCTAssertTrue(onboarding.hasCompletedOnboarding)
        XCTAssertEqual(retirements, 0)
    }

    func testRefreshPreservesCapabilityOnlyWithinTheSameAuthorizationGeneration() async throws {
        let store = makeStore()
        try await authorize(store)
        var status = phase("authorized")
        status.removeValue(forKey: "recoveryCapability")
        try enqueue(status)
        await store.refresh()
        XCTAssertTrue(store.canComplete)
        status["readinessGeneration"] = 2
        try enqueue(status)
        await store.refresh()
        XCTAssertFalse(store.canComplete)
        XCTAssertNil(secure.record?.capability)
    }

    func testMountedCompletionShowsExactCopyAndOnlyDoneAfterCheckedCleanup() async throws {
        let store = makeStore()
        try await authorize(store)
        try enqueue(["outcome": "completed"])
        await store.complete()
        let host = try OwnerRequestHost { _, _ in AnyView(ParticipantDeletionView(store: store)) }
        XCTAssertEqual(host.label("deletion-completed-title"), "Account deleted")
        XCTAssertEqual(host.label("deletion-completed-message"),
                       "Thanks for being part of CommonPlate. Your account and history have been deleted.")
        XCTAssertTrue(host.exists("deletion-done"))
        captureDeletionPresentation(host, name: "completed-page")
        XCTAssertEqual(host.isDisabled("deletion-done"), false)
        XCTAssertFalse(host.exists("deletion-final-confirmation"))
        XCTAssertFalse(host.exists("deletion-code"))
        XCTAssertEqual(handoffs, 0)
    }

    func testDeleteEntryShowsConfirmationBeforeStartingDeletion() async throws {
        var deletionStarts = 0
        let host = try OwnerRequestHost { _, _ in
            AnyView(PrivacySafetyView(
                participantIdentityStore: identity,
                onDeleteAccount: { deletionStarts += 1 }
            ))
        }

        XCTAssertTrue(host.exists("privacy-safety-delete-account"))
        XCTAssertFalse(host.exists("deletion-entry-confirmation"))
        XCTAssertEqual(deletionStarts, 0)

        let entry = try XCTUnwrap(host.nodes()["privacy-safety-delete-account"])
        XCTAssertTrue(entry.accessibilityActivate())
        host.settle()
        XCTAssertTrue(host.exists("deletion-entry-confirmation"))
        XCTAssertTrue(host.exists("deletion-entry-confirmation-title"))
        XCTAssertTrue(host.exists("deletion-entry-confirmation-message"))
        XCTAssertEqual(host.label("deletion-entry-confirmation-message"),
                       "This permanently deletes your CommonPlate account and history.")
        XCTAssertEqual(host.label("deletion-entry-confirmation-safety-note"),
                       "Blocks may still apply if you rejoin with the same NYU email.")
        let confirmationFrame = try XCTUnwrap(host.frame("deletion-entry-confirmation"))
        XCTAssertLessThan(confirmationFrame.height, host.window.bounds.height * 0.75)
        XCTAssertEqual(deletionStarts, 0)

        XCTAssertFalse(host.exists("deletion-entry-confirmation-close"))
        XCTAssertEqual(host.label("deletion-entry-confirmation-keep-account"), "Keep My Account")
        let buttons = host.nodes().filter {
            $0.key.hasPrefix("deletion-entry-confirmation-") && $0.value.accessibilityTraits.contains(.button)
        }.map(\.key)
        XCTAssertEqual(Set(buttons), [
            "deletion-entry-confirmation-confirm", "deletion-entry-confirmation-keep-account"
        ])
        let keepAccount = try XCTUnwrap(host.nodes()["deletion-entry-confirmation-keep-account"])
        XCTAssertTrue(keepAccount.accessibilityActivate())
        host.settle()
        XCTAssertFalse(host.exists("deletion-entry-confirmation"))
        XCTAssertEqual(deletionStarts, 0)

        let reopenedEntry = try XCTUnwrap(host.nodes()["privacy-safety-delete-account"])
        XCTAssertTrue(reopenedEntry.accessibilityActivate())
        host.settle()
        let confirm = try XCTUnwrap(host.nodes()["deletion-entry-confirmation-confirm"])
        XCTAssertTrue(confirm.accessibilityActivate())
        host.settle()
        XCTAssertFalse(host.exists("deletion-entry-confirmation"))
        XCTAssertEqual(deletionStarts, 1)
    }

    private func captureDeletionPresentation(_ host: OwnerRequestHost, name: String) {
        let previousStyle = host.window.overrideUserInterfaceStyle
        defer { host.window.overrideUserInterfaceStyle = previousStyle }
        for (style, suffix) in [(UIUserInterfaceStyle.light, "light"), (.dark, "dark")] {
            host.window.overrideUserInterfaceStyle = style
            host.settle(0.1)
            let image = UIGraphicsImageRenderer(bounds: host.window.bounds).image { _ in
                host.window.drawHierarchy(in: host.window.bounds, afterScreenUpdates: true)
            }
            let capture = XCTAttachment(image: image)
            capture.name = "\(name)-\(suffix)"
            capture.lifetime = .keepAlways
            add(capture)
        }
    }

    func testBodylessModalDoesNotReserveAnEmptyContentGroup() throws {
        let host = try OwnerRequestHost { _, _ in
            AnyView(ParticipantDeletionModalFrame(
                identifier: "bodyless-modal", title: "Account deletion", hasContent: false
            ) {
                Text("Unused body").accessibilityIdentifier("unused-body")
            } actions: {
                ParticipantDeletionTextButton(title: "Close", identifier: "bodyless-close", action: {})
            })
        }
        XCTAssertFalse(host.exists("unused-body"))
        let title = try XCTUnwrap(host.frame("bodyless-modal-title"))
        let action = try XCTUnwrap(host.frame("bodyless-close"))
        XCTAssertGreaterThan(action.minY, title.maxY)
        XCTAssertLessThanOrEqual(action.minY - title.maxY, ParticipantDeletionModalLayout.contentSpacing + 1)
    }

    func testDeletionStatesShareNaturalShellAndConsistentActionHierarchy() async throws {
        let entryHost = try OwnerRequestHost { _, _ in
            AnyView(PrivacySafetyView(participantIdentityStore: identity, onDeleteAccount: {}).dynamicTypeSize(.large))
        }
        let entry = try XCTUnwrap(entryHost.nodes()["privacy-safety-delete-account"])
        XCTAssertTrue(entry.accessibilityActivate())
        entryHost.settle()
        let entryFrame = try XCTUnwrap(entryHost.frame("deletion-entry-confirmation"))
        captureDeletionPresentation(entryHost, name: "entry")
        let keep = try XCTUnwrap(entryHost.nodes()["deletion-entry-confirmation-keep-account"])
        XCTAssertTrue(keep.accessibilityActivate())
        entryHost.settle()

        let store = makeStore()
        try enqueue(["eligible": false, "categories": ["activeHelpingOrPickup"]])
        await store.begin()
        let host = try OwnerRequestHost { _, _ in
            AnyView(ParticipantDeletionView(store: store).dynamicTypeSize(.large))
        }
        func assertNaturalLayout(_ modalID: String, _ primaryID: String, _ secondaryID: String, contentID: String) throws -> CGFloat {
            let modal = try XCTUnwrap(host.frame(modalID))
            let primary = try XCTUnwrap(host.frame(primaryID))
            let secondary = try XCTUnwrap(host.frame(secondaryID))
            let content = try XCTUnwrap(host.frame(contentID))
            XCTAssertEqual(modal.width, entryFrame.width, accuracy: 1)
            XCTAssertGreaterThan(primary.minX, modal.minX)
            XCTAssertLessThan(primary.maxX, modal.maxX)
            XCTAssertEqual(primary.width, secondary.width, accuracy: 1)
            XCTAssertGreaterThanOrEqual(primary.height, 44)
            XCTAssertGreaterThanOrEqual(secondary.height, 44)
            XCTAssertGreaterThan(secondary.minY, primary.maxY)
            XCTAssertLessThan(secondary.maxY, modal.maxY)
            XCTAssertGreaterThan(primary.minY, content.maxY)
            XCTAssertLessThan(modal.height, host.window.bounds.height)
            XCTAssertEqual(host.isDisabled(secondaryID), secondaryID == "deletion-resend")
            captureDeletionPresentation(host, name: modalID)
            return modal.height
        }
        let blockerHeight = try assertNaturalLayout(
            "deletion-open-request", "deletion-go-to-request", "deletion-keep-account",
            contentID: "deletion-open-request-message"
        )
        store.close()
        try await begin(store)
        var challenge = phase("challengeIssued")
        challenge["challenge"] = [
            "expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(600)),
            "cooldownEndsAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(43)),
            "attemptsRemaining": 4,
        ]
        try enqueue(challenge)
        await store.refresh()
        host.settle()
        XCTAssertTrue(host.exists("deletion-verify-close"))
        let verificationHeight = try assertNaturalLayout(
            "deletion-verify", "deletion-verify-code", "deletion-resend", contentID: "deletion-code"
        )
        XCTAssertGreaterThan(verificationHeight, blockerHeight, "An input adds content; short states must not stretch to match it.")
        try enqueue(phase("authorized"))
        await store.redeem(code: "123456")
        host.settle()
        _ = try assertNaturalLayout("deletion-final", "deletion-final-confirmation", "deletion-final-cancel",
                                   contentID: "deletion-final-message")
    }

    func testAlignedVerificationSupportsAccessibilityTextAndEmailPresentation() async throws {
        let store = makeStore()
        try enqueue(["eligible": false, "categories": ["activeHelpingOrPickup"]])
        await store.begin()
        func assertAccessible(_ modalID: String, _ actionIDs: [String]) throws {
            for size: DynamicTypeSize in [.accessibility3, .accessibility5] {
                for style: UIUserInterfaceStyle in [.light, .dark] {
                    let host = try OwnerRequestHost(style: style, dynamicTypeSize: size) { _, _ in
                        AnyView(ParticipantDeletionView(store: store))
                    }
                    let modal = try XCTUnwrap(host.frame(modalID))
                    XCTAssertLessThanOrEqual(modal.height, host.window.bounds.height)
                    XCTAssertGreaterThanOrEqual(modal.minY, 0)
                    for id in actionIDs { XCTAssertTrue(host.exists(id), id) }
                    if style == .light && size == .accessibility5 {
                        captureDeletionPresentation(host, name: "\(modalID)-accessibility5")
                    }
                    func scrollView(in view: UIView) -> UIScrollView? {
                        if let scroll = view as? UIScrollView { return scroll }
                        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
                    }
                    let scroll = try XCTUnwrap(scrollView(in: host.controller.view))
                    scroll.setContentOffset(CGPoint(
                        x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                    ), animated: false)
                    host.settle(0.1)
                    let buttons = actionIDs.filter {
                        !["deletion-code", "deletion-verify-close"].contains($0)
                    }
                    for id in buttons {
                        let frame = try XCTUnwrap(host.frame(id))
                        XCTAssertGreaterThanOrEqual(frame.minY, modal.minY - 1, id)
                        XCTAssertLessThanOrEqual(frame.maxY, modal.maxY + 1, id)
                    }
                    if style == .light && size == .accessibility5 {
                        captureDeletionPresentation(host, name: "\(modalID)-accessibility5-actions")
                    }
                }
            }
        }
        try assertAccessible("deletion-open-request", ["deletion-go-to-request", "deletion-keep-account"])
        store.close()
        try await begin(store)
        try assertAccessible("deletion-verify", ["deletion-code", "deletion-verify-code", "deletion-resend",
                                              "deletion-verify-close"])
        try enqueue(phase("authorized"))
        await store.redeem(code: "123456")
        try assertAccessible("deletion-final", ["deletion-final-confirmation", "deletion-final-cancel"])
    }

    func testVerifyRequiresExactlySixDigitsWithoutAffectingResend() async throws {
        let store = makeStore()
        try await begin(store)
        var available = phase("challengeIssued")
        available["challenge"] = [
            "expiresAt": "2099-10-24T20:10:00.000Z",
            "cooldownEndsAt": "2000-10-24T20:01:00.000Z", "attemptsRemaining": 4,
        ]
        try enqueue(available)
        await store.refresh()
        let host = try OwnerRequestHost { _, _ in AnyView(ParticipantDeletionView(store: store)) }
        func input(in view: UIView) -> UITextField? {
            if let field = view as? UITextField { return field }
            return view.subviews.lazy.compactMap { input(in: $0) }.first
        }
        let field = try XCTUnwrap(input(in: host.controller.view))
        XCTAssertEqual(field.placeholder, "6-digit code")
        for value in ["", "12345", "123456", "1234567", "12345a", "１２３４５６"] {
            field.text = value
            field.sendActions(for: .editingChanged)
            host.settle()
            XCTAssertEqual(host.isDisabled("deletion-verify-code"), value != "123456", value)
            XCTAssertEqual(host.isDisabled("deletion-resend"), false, value)
            XCTAssertEqual(host.label("deletion-resend"), "Send a new code")
            if value == "123456" { captureDeletionPresentation(host, name: "verification-enabled-actions") }
        }
        XCTAssertEqual(completeRequests, 0)
    }

    func testResendCountdownIsExplicitAndEnablesAtBackendDeadline() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        for (remaining, label, disabled) in [
            (43.0, "Send a new code in 0:43", true),
            (61.0, "Send a new code in 1:01", true),
            (0.1, "Send a new code in 0:01", true),
            (0.0, "Send a new code", false),
            (-1.0, "Send a new code", false),
        ] {
            var taps = 0
            let host = try OwnerRequestHost { _, _ in
                AnyView(ParticipantDeletionResendAction(
                    cooldownEndsAt: now.addingTimeInterval(remaining), now: now, action: { taps += 1 }
                ))
            }
            XCTAssertEqual(host.label("deletion-resend"), label)
            XCTAssertEqual(host.isDisabled("deletion-resend"), disabled)
            if remaining == 43 || remaining == 0 {
                captureDeletionPresentation(host, name: disabled ? "resend-cooldown" : "resend-available")
            }
            if !disabled {
                let resend = try XCTUnwrap(host.nodes()["deletion-resend"])
                XCTAssertTrue(resend.accessibilityActivate())
                XCTAssertEqual(taps, 1)
            }
        }
    }

    func testBusyVerificationKeepsActionsDisabledUntilResponse() async throws {
        let store = makeStore()
        try await begin(store)
        let host = try OwnerRequestHost { _, _ in AnyView(ParticipantDeletionView(store: store)) }
        ParticipantEmailUnsubscribeURLProtocol.enqueue(.response(
            data: try JSONSerialization.data(withJSONObject: phase("authorized")), delay: 2
        ))
        let request = Task { await store.redeem(code: "123456") }
        for _ in 0..<40 where !store.isBusy { await Task.yield() }
        host.settle(0.1)
        XCTAssertTrue(store.isBusy)
        XCTAssertEqual(host.isDisabled("deletion-verify-code"), true)
        XCTAssertEqual(host.isDisabled("deletion-resend"), true)
        captureDeletionPresentation(host, name: "verification-busy")
        await request.value
        XCTAssertFalse(store.isBusy)
    }

    func testExpiredAuthorizationPreservesSafeInteractiveCancel() async throws {
        let store = makeStore()
        try await begin(store)
        var expired = phase("authorized")
        expired["authorization"] = ["expiresAt": "2000-10-24T20:05:00.000Z"]
        try enqueue(expired)
        await store.redeem(code: "123456")
        let host = try OwnerRequestHost { _, _ in AnyView(ParticipantDeletionView(store: store)) }
        XCTAssertTrue(host.exists("deletion-authorization-unavailable"))
        XCTAssertEqual(host.isDisabled("deletion-final-confirmation"), true)
        XCTAssertEqual(host.isDisabled("deletion-final-cancel"), false)
        captureDeletionPresentation(host, name: "final-authorization-expired")
        try enqueue(phase("canceled"))
        try await activate("deletion-final-cancel", in: host) { store.route == nil }
        XCTAssertNil(store.route)
        XCTAssertEqual(completeRequests, 0)
    }

    func testMountedChallengeShowsMaskedEmailCooldownExpiryResendAndSeparateFinalAction() async throws {
        let store = makeStore()
        try await begin(store, waited: true)
        try enqueue(phase("ready"))
        _ = await store.openExisting()
        XCTAssertEqual(store.route, .ready)
        let host = try OwnerRequestHost { _, _ in AnyView(ParticipantDeletionView(store: store)) }
        XCTAssertEqual(host.label("deletion-ready-title"), "Your account is ready to delete")
        let verifyFrame = try XCTUnwrap(host.frame("deletion-verify-its-you"))
        let cancelFrame = try XCTUnwrap(host.frame("deletion-cancel"))
        XCTAssertEqual(verifyFrame.width, cancelFrame.width, accuracy: 1)
        XCTAssertEqual(verifyFrame.minX, cancelFrame.minX, accuracy: 1)
        captureDeletionPresentation(host, name: "ready-page")
        XCTAssertTrue(host.exists("deletion-verify-its-you"))
        XCTAssertTrue(host.exists("deletion-cancel"))
        XCTAssertFalse(host.exists("deletion-final-confirmation"))
        XCTAssertFalse(fence.isFrozen)
        try enqueue(phase("challengeIssued"), status: 202)
        await store.openVerification()
        host.settle()
        XCTAssertEqual(store.route, .verify)
        XCTAssertTrue(fence.isFrozen)
        XCTAssertNotNil(defaults.object(forKey: ParticipantDeletionFreeze.key))
        XCTAssertEqual(store.status?.phase, .challengeIssued)
        XCTAssertEqual(host.label("deletion-verify-title"), "Verify it’s you")
        XCTAssertEqual(host.label("deletion-verify-message"),
                       "Enter the 6-digit code we sent to \(try XCTUnwrap(identity.identity?.principal)).")
        XCTAssertTrue(host.exists("deletion-code"))
        XCTAssertTrue(host.exists("deletion-verify-close"))
        XCTAssertEqual(host.isDisabled("deletion-resend"), true)
        XCTAssertTrue(try XCTUnwrap(host.label("deletion-resend")).hasPrefix("Send a new code in "))
        var expired = phase("challengeIssued")
        expired["challenge"] = [
            "expiresAt": "2000-10-24T20:10:00.000Z",
            "cooldownEndsAt": "2000-10-24T20:01:00.000Z", "attemptsRemaining": 4,
        ]
        try enqueue(expired)
        await store.refresh()
        host.settle()
        XCTAssertEqual(store.route, .verify)
        XCTAssertTrue(host.exists("deletion-challenge-expired"))
        XCTAssertEqual(host.isDisabled("deletion-resend"), false)
        XCTAssertEqual(host.label("deletion-resend"), "Send a new code")
        captureDeletionPresentation(host, name: "verification-expired-code")
        try enqueue(phase("challengeIssued"), status: 202)
        await store.requestCode()
        try enqueue(phase("authorized"))
        await store.redeem(code: "123456")
        host.settle()
        XCTAssertEqual(host.label("deletion-final-title"), "Delete your account?")
        XCTAssertFalse(host.exists("deletion-verify"))
        XCTAssertFalse(host.exists("deletion-code"))
        XCTAssertTrue(host.exists("deletion-final-confirmation"))
        XCTAssertEqual(host.isDisabled("deletion-final-confirmation"), false)
        XCTAssertFalse(host.exists("deletion-done"))
        XCTAssertFalse(ParticipantEmailUnsubscribeURLProtocol.capturedRequests.contains { $0.path.hasSuffix("/complete") })
    }

    // MARK: - Figma 1151:7504 entry, wait, freeze-at-challenge and inline errors (Faith 2026-10-25)

    private var startRequests: Int {
        ParticipantEmailUnsubscribeURLProtocol.capturedRequests.filter {
            $0.path.hasSuffix("/api/participant/deletion")
        }.count
    }

    private func paths(_ suffix: String) -> Int {
        ParticipantEmailUnsubscribeURLProtocol.capturedRequests.filter { $0.path.hasSuffix(suffix) }.count
    }

    /// Requester (`activeRequest`) and helper/pickup (`activeHelpingOrPickup`)
    /// blockers share one two-action modal (decision 10).
    func testRequestBlockersShareConciseTwoActionModal() async throws {
        for categories in [["activeRequest"], ["activeHelpingOrPickup"], ["activeRequest", "activeHelpingOrPickup"]] {
            let store = makeStore()
            try enqueue(["eligible": false, "categories": categories])
            await store.begin()
            XCTAssertEqual(store.route, .openRequest, "\(categories)")
            XCTAssertNil(secure.record)
            XCTAssertFalse(fence.isFrozen)
            let host = try OwnerRequestHost { _, _ in AnyView(ParticipantDeletionView(store: store)) }
            XCTAssertEqual(host.label("deletion-open-request-title"), "Finish your request first")
            XCTAssertEqual(
                host.label("deletion-open-request-message"),
                "You’re part of an active food request. Finish it before continuing with account deletion."
            )
            XCTAssertEqual(host.label("deletion-go-to-request"), "Go to Request")
            XCTAssertEqual(host.label("deletion-keep-account"), "Keep My Account")
            XCTAssertFalse(host.exists("deletion-start"))
            XCTAssertFalse(host.exists("deletion-open-request-close"))
            XCTAssertFalse(host.exists("deletion-wait-title"))
            let buttons = host.nodes().filter { $0.value.accessibilityTraits.contains(.button) }.map(\.key)
            XCTAssertEqual(Set(buttons), ["deletion-go-to-request", "deletion-keep-account"], "\(categories)")
            store.close()
        }
        XCTAssertEqual(startRequests, 0)
    }

    func testGoToRequestNavigatesWithoutCreatingAnyOperationOrFreeze() async throws {
        let store = makeStore()
        try enqueue(["eligible": false, "categories": ["activeHelpingOrPickup"]])
        await store.begin()
        var navigations = 0
        let host = try OwnerRequestHost { _, _ in
            AnyView(ParticipantDeletionView(store: store, onViewCurrentRequest: { navigations += 1 }))
        }
        let goToRequest = try XCTUnwrap(host.nodes()["deletion-go-to-request"])
        XCTAssertTrue(goToRequest.accessibilityActivate())
        host.settle()
        XCTAssertEqual(navigations, 1)
        XCTAssertNil(store.route)
        XCTAssertNil(secure.record)
        XCTAssertFalse(fence.isFrozen)
        XCTAssertNil(defaults.object(forKey: ParticipantDeletionFreeze.key))
        XCTAssertEqual(store.rowState, .none)
        XCTAssertEqual(startRequests, 0)
    }

    func testGoToRequestActionPreservesAnExistingWaitingOperation() async throws {
        let store = makeStore()
        try await begin(store, phase: "waiting", waited: true)
        XCTAssertEqual(secure.record?.status?.phase, .waiting)
        let startsBefore = startRequests
        // Go to Request's store effect is `close()` before navigating.
        store.close()
        XCTAssertEqual(secure.record?.status?.phase, .waiting)
        XCTAssertEqual(store.rowState, .inProgress)
        XCTAssertEqual(startRequests, startsBefore, "Navigating creates no second operation.")
        XCTAssertEqual(paths("/cancel"), 0)
    }

    func testKeepMyAccountWithoutOperationOnlyClosesAndDeletesNothing() async throws {
        let store = makeStore()
        try enqueue(["eligible": false, "categories": ["activeRequest"]])
        await store.begin()
        let host = try OwnerRequestHost { _, _ in AnyView(ParticipantDeletionView(store: store)) }
        let keep = try XCTUnwrap(host.nodes()["deletion-keep-account"])
        XCTAssertTrue(keep.accessibilityActivate())
        for _ in 0..<20 where store.route != nil { await Task.yield() }
        host.settle()
        XCTAssertNil(store.route)
        XCTAssertNil(secure.record)
        XCTAssertEqual(startRequests, 0)
        XCTAssertEqual(paths("/cancel"), 0)
        XCTAssertEqual(paths("/complete"), 0)
    }

    func testKeepMyAccountWithWaitingOperationCancelsAuthoritatively() async throws {
        let store = makeStore()
        try await begin(store, phase: "waiting", waited: true)
        XCTAssertEqual(secure.record?.status?.phase, .waiting)
        try enqueue(phase("canceled"))
        await store.keepAccount()
        XCTAssertEqual(paths("/cancel"), 1)
        XCTAssertEqual(paths("/complete"), 0)
        XCTAssertNil(secure.record)
        XCTAssertEqual(store.rowState, .none)
        XCTAssertFalse(fence.isFrozen)
    }

    func testUnknownWaitKeepsGenericCopyAndStartAction() async throws {
        let store = makeStore()
        try enqueue(["eligible": false, "categories": ["unknown"]])
        await store.begin()
        XCTAssertEqual(store.route, .wait)
        let host = try OwnerRequestHost { _, _ in AnyView(ParticipantDeletionView(store: store)) }
        XCTAssertEqual(host.label("deletion-wait-title"), "CommonPlate needs a little more time")
        XCTAssertFalse(host.exists("deletion-go-to-request"))
        XCTAssertTrue(host.exists("deletion-start"))
        XCTAssertFalse(host.exists("deletion-wait-close"))
        XCTAssertEqual(host.isDisabled("deletion-keep-account"), false)
        captureDeletionPresentation(host, name: "unknown-wait")
    }

    func testUnknownWaitStartsOperationWithoutFreezeAndHoldsIdentity() async throws {
        let store = makeStore()
        try enqueue(["eligible": false, "categories": ["unknown"]])
        await store.begin()
        XCTAssertEqual(store.route, .wait)
        XCTAssertNil(secure.record)
        let host = try OwnerRequestHost { _, _ in AnyView(ParticipantDeletionView(store: store)) }
        XCTAssertEqual(host.label("deletion-wait-title"), "CommonPlate needs a little more time")
        XCTAssertTrue(host.exists("deletion-start"))
        XCTAssertTrue(host.exists("deletion-keep-account"))
        try enqueue(phase("waiting"), status: 201)
        await store.startDeletion()
        XCTAssertNil(store.route, "Starting returns to Privacy & Safety; there is no status page.")
        XCTAssertEqual(store.rowState, .inProgress)
        XCTAssertEqual(secure.record?.status?.phase, .waiting)
        XCTAssertFalse(fence.isFrozen)
        XCTAssertNotNil(identity.currentAuthority())
        identity.beginEmailReplacement()
        XCTAssertNil(identity.flow, "Identity replacement is held while a deletion record exists.")
        _ = await store.openExisting()
        XCTAssertEqual(store.route, .inProgress)
    }

    func testWaitingModalAcknowledgementPreservesOperationAndCancelIsAuthoritative() async throws {
        let store = makeStore()
        try await begin(store, phase: "waiting")
        try enqueue(phase("waiting"))
        _ = await store.openExisting()
        XCTAssertEqual(store.route, .inProgress)
        let without = try OwnerRequestHost { _, _ in AnyView(ParticipantDeletionView(store: store)) }
        XCTAssertEqual(without.label("deletion-in-progress-title"), "Account deletion is on hold")
        XCTAssertEqual(without.label("deletion-in-progress-message"),
                       "Your account isn’t ready to delete yet. We’ll let you know when you can continue.")
        XCTAssertEqual(without.label("deletion-got-it"), "Got It")
        XCTAssertFalse(without.exists("deletion-view-request"))
        XCTAssertTrue(without.exists("deletion-cancel"))
        XCTAssertFalse(without.exists("deletion-in-progress-close"))
        XCTAssertEqual(without.isDisabled("deletion-cancel"), false)
        captureDeletionPresentation(without, name: "waiting-without-local-request")
        let with = try OwnerRequestHost { _, _ in
            AnyView(ParticipantDeletionView(store: store))
        }
        XCTAssertFalse(with.exists("deletion-view-request"))
        XCTAssertFalse(with.exists("deletion-in-progress-close"))
        let buttons = with.nodes().filter { $0.value.accessibilityTraits.contains(.button) }.map(\.key)
        XCTAssertEqual(Set(buttons), ["deletion-got-it", "deletion-cancel"])
        captureDeletionPresentation(with, name: "waiting-with-current-request")
        let close = try XCTUnwrap(with.nodes()["deletion-got-it"])
        XCTAssertTrue(close.accessibilityActivate())
        XCTAssertNil(store.route)
        XCTAssertEqual(secure.record?.status?.phase, .waiting)
        XCTAssertEqual(paths("/cancel"), 0, "Dismissing waiting is not equivalent to cancelling deletion.")
        XCTAssertEqual(completeRequests, 0)
        try enqueue(phase("waiting"))
        _ = await store.openExisting()
        with.settle()
        try enqueue(phase("canceled"))
        let cancel = try XCTUnwrap(with.nodes()["deletion-cancel"])
        XCTAssertTrue(cancel.accessibilityActivate())
        for _ in 0..<40 where store.route != nil {
            try await Task.sleep(nanoseconds: 50_000_000)
            with.settle(0.05)
        }
        XCTAssertEqual(paths("/cancel"), 1)
        XCTAssertNil(secure.record)
        XCTAssertNil(store.route)
        XCTAssertEqual(completeRequests, 0)
        XCTAssertNotNil(identity.currentAuthority())
    }

    func testEntryErrorIsInlineWithTryAgainAndCloseLeavesNothingBehind() async throws {
        let store = makeStore()
        try enqueue(["error": "unavailable"], status: 503)
        await store.begin()
        XCTAssertEqual(store.route, .status)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.canRetry)
        let host = try OwnerRequestHost { _, _ in AnyView(ParticipantDeletionView(store: store)) }
        XCTAssertTrue(host.exists("deletion-error"))
        XCTAssertTrue(host.exists("deletion-try-again"))
        XCTAssertTrue(host.exists("deletion-error-close"))
        XCTAssertFalse(host.exists("deletion-status-close"))
        XCTAssertEqual(host.isDisabled("deletion-error-close"), false)
        captureDeletionPresentation(host, name: "eligibility-error")
        let close = try XCTUnwrap(host.nodes()["deletion-error-close"])
        XCTAssertTrue(close.accessibilityActivate())
        host.settle()
        XCTAssertNil(store.route)
        XCTAssertFalse(store.isPresented)
        XCTAssertNil(secure.record)
        XCTAssertFalse(fence.isFrozen)
    }

    func testClosingVerificationCancelsDeletionSoTheNextAttemptStartsAtConfirmation() async throws {
        let store = makeStore()
        try await begin(store)
        XCTAssertTrue(fence.isFrozen)
        let host = try OwnerRequestHost { _, _ in AnyView(ParticipantDeletionView(store: store)) }
        try enqueue(phase("canceled"))
        let close = try XCTUnwrap(host.nodes()["deletion-verify-close"])
        XCTAssertTrue(close.accessibilityActivate())
        for _ in 0..<40 where store.route != nil {
            try await Task.sleep(nanoseconds: 50_000_000)
            host.settle(0.05)
        }
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.route)
        XCTAssertNil(secure.record)
        XCTAssertEqual(store.rowState, .none)
        XCTAssertFalse(fence.isFrozen)
        XCTAssertNil(defaults.object(forKey: ParticipantDeletionFreeze.key))
        XCTAssertNotNil(identity.currentAuthority())
        XCTAssertEqual(retirements, 0)
        XCTAssertTrue(onboarding.hasCompletedOnboarding)
    }

    func testFailedVerificationCancelShowsTryAgainAndCloseLeavesCancelToReconcile() async throws {
        let store = makeStore()
        try await authorize(store)
        ParticipantEmailUnsubscribeURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.abandonVerification()
        XCTAssertEqual(store.route, .status)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.canRetry)
        XCTAssertNotNil(secure.record)
        XCTAssertTrue(fence.isFrozen)
        let host = try OwnerRequestHost { _, _ in AnyView(ParticipantDeletionView(store: store)) }
        captureDeletionPresentation(host, name: "cancellation-error")
        store.close()
        XCTAssertNil(store.route)
        XCTAssertTrue(fence.isFrozen, "Close never releases the freeze without an authoritative cancel.")
        try enqueue(phase("authorized"))
        try enqueue(phase("canceled"))
        await store.reconcile()
        XCTAssertNil(store.route)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(secure.record)
        XCTAssertFalse(fence.isFrozen)
        XCTAssertEqual(ParticipantEmailUnsubscribeURLProtocol.capturedRequests.filter { $0.path.hasSuffix("/complete") }.count, 0)
    }

    func testRelaunchDuringVerificationNeverReopensItAndCancelsSilently() async throws {
        let store = makeStore()
        try await begin(store)
        fence.setFrozen(false)
        let restored = makeStore()
        XCTAssertTrue(fence.isFrozen)
        XCTAssertNil(restored.route)
        try enqueue(phase("challengeIssued"))
        try enqueue(phase("canceled"))
        await restored.reconcile()
        XCTAssertNil(restored.route)
        XCTAssertFalse(restored.isPresented)
        XCTAssertNil(secure.record)
        XCTAssertFalse(fence.isFrozen)
        XCTAssertEqual(restored.rowState, .none)
        XCTAssertNotNil(identity.currentAuthority())
    }

    func testVerificationKeepsOrdinaryDeleteRowAndRetryingAfterFailedCancelRestartsCleanly() async throws {
        let store = makeStore()
        try await begin(store)
        XCTAssertEqual(store.rowState, .none, "The page behind J/K does not change.")
        ParticipantEmailUnsubscribeURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.abandonVerification()
        store.close()
        XCTAssertNotNil(secure.record)
        XCTAssertEqual(store.rowState, .none)
        try enqueue(phase("canceled"))
        try enqueue(["eligible": true, "categories": []])
        try enqueue(phase("ready"), status: 201)
        try enqueue(phase("challengeIssued"), status: 202)
        await store.begin()
        XCTAssertEqual(store.route, .verify)
        XCTAssertEqual(store.status?.phase, .challengeIssued)
        XCTAssertNil(store.errorMessage)
    }

    func testClosingAFailedImmediateAttemptCancelsItWithoutLeavingAStatusRow() async throws {
        let store = makeStore()
        try enqueue(["eligible": true, "categories": []])
        try enqueue(phase("ready"), status: 201)
        try enqueue(["error": "unavailable"], status: 503)
        await store.begin()
        XCTAssertEqual(store.route, .status)
        XCTAssertNotNil(secure.record)
        XCTAssertEqual(store.rowState, .none)
        try enqueue(phase("canceled"))
        store.close()
        for _ in 0..<40 where secure.record != nil { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertNil(store.route)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(secure.record)
        XCTAssertEqual(store.rowState, .none)
        XCTAssertFalse(fence.isFrozen)
        XCTAssertNotNil(identity.currentAuthority())
        try enqueue(["eligible": true, "categories": []])
        try enqueue(phase("ready"), status: 201)
        try enqueue(phase("challengeIssued"), status: 202)
        await store.begin()
        XCTAssertEqual(store.route, .verify)
    }

    func testInitialCodeDeliveryFailureShowsDedicatedDialogAndRetryOpensVerification() async throws {
        let store = makeStore()
        try enqueue(["eligible": true, "categories": []])
        try enqueue(phase("ready"), status: 201)
        try enqueue(["error": [
            "code": "DELETION_EMAIL_UNAVAILABLE",
            "message": "We couldn’t send your deletion code. Please try again in a moment.",
        ]], status: 503)
        await store.begin()
        let host = try OwnerRequestHost { _, _ in AnyView(ParticipantDeletionView(store: store)) }
        XCTAssertTrue(store.codeRequestFailed)
        XCTAssertTrue(host.exists("deletion-code-send-error"))
        XCTAssertFalse(host.exists("deletion-code"))
        XCTAssertFalse(host.exists("deletion-status"))
        XCTAssertTrue(host.exists("deletion-try-again"))
        XCTAssertEqual(host.label("deletion-error-cancel"), "Cancel")
        XCTAssertEqual(store.status?.phase, .ready)
        XCTAssertNotNil(identityStorage.record)
        XCTAssertTrue(fence.isFrozen)
        captureDeletionPresentation(host, name: "initial-code-delivery-error")
        try enqueue(phase("challengeIssued"), status: 202)
        await store.retry()
        host.settle()
        XCTAssertFalse(store.codeRequestFailed)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.route, .verify)
        XCTAssertTrue(host.exists("deletion-code"))
        XCTAssertEqual(ParticipantEmailUnsubscribeURLProtocol.capturedRequests.filter {
            $0.path.hasSuffix("/challenge")
        }.count, 2)
        XCTAssertEqual(handoffs, 0)
    }

    func testInitialCodeCooldownDoesNotClaimAnEarlierCodeAndCancelPreservesAccount() async throws {
        let store = makeStore()
        try enqueue(["eligible": true, "categories": []])
        try enqueue(phase("ready"), status: 201)
        try enqueue(["error": [
            "code": "DELETION_CHALLENGE_COOLDOWN",
            "message": "Please wait before requesting another code.",
        ]], status: 429)
        await store.begin()
        XCTAssertEqual(store.errorMessage, "Please wait a moment before trying again.")
        let host = try OwnerRequestHost { _, _ in AnyView(ParticipantDeletionView(store: store)) }
        XCTAssertTrue(host.exists("deletion-code-send-error"))
        XCTAssertFalse(host.exists("deletion-code"))
        captureDeletionPresentation(host, name: "initial-code-cooldown-error")
        try enqueue(phase("canceled"))
        XCTAssertTrue(try XCTUnwrap(host.nodes()["deletion-error-cancel"]).accessibilityActivate())
        for _ in 0..<40 where secure.record != nil {
            try await Task.sleep(nanoseconds: 50_000_000)
            host.settle(0.05)
        }
        XCTAssertNil(secure.record)
        XCTAssertNil(store.route)
        XCTAssertFalse(fence.isFrozen)
        XCTAssertNotNil(identity.currentAuthority())
        XCTAssertEqual(handoffs, 0)
    }

    func testCancelAfterCodeSendFailureKeepsFreezeIfCancellationFails() async throws {
        let store = makeStore()
        try await begin(store, waited: true)
        ParticipantEmailUnsubscribeURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.openVerification()
        XCTAssertTrue(store.codeRequestFailed)
        XCTAssertEqual(store.route, .status)
        ParticipantEmailUnsubscribeURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.cancel()
        XCTAssertFalse(store.codeRequestFailed)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNotNil(secure.record)
        XCTAssertTrue(fence.isFrozen)
        XCTAssertNotNil(identityStorage.record)
        XCTAssertEqual(handoffs, 0)
    }

    func testWaitedDeletionStillShowsItsStatusRow() async throws {
        let store = makeStore()
        try await begin(store, phase: "waiting")
        XCTAssertEqual(store.rowState, .inProgress)
        try enqueue(phase("ready"))
        await store.refresh()
        XCTAssertEqual(store.rowState, .readyToDelete)
    }

    func testWaitingPrivacyRowSaysOnHoldAndOpensExistingDeletion() throws {
        var opens = 0
        var starts = 0
        let host = try OwnerRequestHost { _, _ in
            AnyView(PrivacySafetyView(
                participantIdentityStore: identity, deletionRow: .inProgress,
                onDeleteAccount: { starts += 1 }, onOpenDeletion: { opens += 1 }
            ))
        }
        let rowLabel = try XCTUnwrap(host.label("privacy-safety-account-deletion"))
        XCTAssertTrue(rowLabel.contains("Account Deletion"))
        XCTAssertTrue(rowLabel.contains("On hold"))
        XCTAssertFalse(rowLabel.contains("In progress"))
        XCTAssertFalse(host.exists("privacy-safety-delete-account"))
        let row = try XCTUnwrap(host.nodes()["privacy-safety-account-deletion"])
        XCTAssertTrue(row.accessibilityActivate())
        host.settle()
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(starts, 0)
    }

    func testReconciledWaitingPromotesToReadyWithoutShowingHoldOrRequestingCode() async throws {
        let store = makeStore()
        try await begin(store, phase: "waiting")
        store.close()
        let restored = makeStore()
        try enqueue(phase("ready"))
        await restored.reconcile()
        XCTAssertEqual(restored.status?.phase, .ready)
        XCTAssertEqual(secure.record?.status?.phase, .ready)
        XCTAssertEqual(restored.route, .ready)
        let host = try OwnerRequestHost { _, _ in AnyView(ParticipantDeletionView(store: restored)) }
        XCTAssertTrue(host.exists("deletion-ready-title"))
        XCTAssertFalse(host.exists("deletion-in-progress"))
        XCTAssertFalse(host.exists("deletion-code"))
        XCTAssertEqual(paths("/challenge"), 0)
        XCTAssertEqual(completeRequests, 0)
    }

    func testGenericWaitingActionsRemainReachableAtLargestDynamicType() async throws {
        let store = makeStore()
        try await begin(store, phase: "waiting")
        try enqueue(phase("waiting"))
        _ = await store.openExisting()
        let host = try OwnerRequestHost(dynamicTypeSize: .accessibility5) { _, _ in
            AnyView(ParticipantDeletionView(store: store))
        }
        XCTAssertFalse(host.exists("deletion-in-progress-close"))
        XCTAssertEqual(host.label("deletion-in-progress-message"),
                       "Your account isn’t ready to delete yet. We’ll let you know when you can continue.")
        func scrollView(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        let scroll = try XCTUnwrap(scrollView(in: host.controller.view))
        scroll.setContentOffset(CGPoint(
            x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        ), animated: false)
        host.settle()
        let modal = try XCTUnwrap(host.frame("deletion-in-progress"))
        for id in ["deletion-got-it", "deletion-cancel"] {
            let frame = try XCTUnwrap(host.frame(id))
            XCTAssertGreaterThanOrEqual(frame.minY, modal.minY - 1)
            XCTAssertLessThanOrEqual(frame.maxY, modal.maxY + 1)
            XCTAssertEqual(host.isDisabled(id), false)
        }
        captureDeletionPresentation(host, name: "generic-waiting-accessibility5-actions")
    }

    func testImmediatelyEligibleDeletionGoesStraightToVerificationWithoutReadyPage() async throws {
        let store = makeStore()
        XCTAssertFalse(fence.isFrozen)
        try enqueue(["eligible": true, "categories": []])
        try enqueue(phase("ready"), status: 201)
        try enqueue(phase("challengeIssued"), status: 202)
        await store.begin()
        XCTAssertEqual(store.route, .verify)
        XCTAssertEqual(store.status?.phase, .challengeIssued)
        XCTAssertTrue(fence.isFrozen, "The freeze is established before the challenge request.")
        let host = try OwnerRequestHost { _, _ in AnyView(ParticipantDeletionView(store: store)) }
        XCTAssertFalse(host.exists("deletion-ready-title"))
        XCTAssertEqual(host.label("deletion-verify-title"), "Verify it’s you")
        XCTAssertTrue(host.exists("deletion-code"))
    }

    func testImmediateChallengeFailureShowsInlineErrorAndTryAgainOpensVerification() async throws {
        let store = makeStore()
        try enqueue(["eligible": true, "categories": []])
        try enqueue(phase("ready"), status: 201)
        try enqueue(["error": "unavailable"], status: 503)
        await store.begin()
        XCTAssertEqual(store.route, .status)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.canRetry)
        XCTAssertEqual(store.rowState, .none, "A failed attempt never flashes a status row.")
        try enqueue(phase("challengeIssued"), status: 202)
        await store.retry()
        XCTAssertEqual(store.route, .verify)
        XCTAssertNil(store.errorMessage)
    }

    func testRepeatedDeleteTapWhileVerificationIsOpenNeverCancelsOrRecreatesIt() async throws {
        let store = makeStore()
        try enqueue(["eligible": true, "categories": []])
        try enqueue(phase("ready"), status: 201)
        try enqueue(phase("challengeIssued"), status: 202)
        await store.begin()
        XCTAssertEqual(store.route, .verify)
        let before = ParticipantEmailUnsubscribeURLProtocol.capturedRequests.count
        await store.begin()
        XCTAssertEqual(ParticipantEmailUnsubscribeURLProtocol.capturedRequests.count, before,
                       "A second B tap must not cancel, start or request anything.")
        XCTAssertEqual(store.route, .verify)
        XCTAssertEqual(store.status?.phase, .challengeIssued)
    }

    // MARK: - K final confirmation replaces verification (Faith 2026-10-25, item 9)

    private var completeRequests: Int {
        ParticipantEmailUnsubscribeURLProtocol.capturedRequests.filter { $0.path.hasSuffix("/complete") }.count
    }

    private func authorizedHost() async throws -> (ParticipantDeletionStore, OwnerRequestHost) {
        let store = makeStore()
        try await begin(store)
        let host = try OwnerRequestHost { _, _ in AnyView(ParticipantDeletionView(store: store)) }
        XCTAssertTrue(host.exists("deletion-code"))
        try enqueue(phase("authorized"))
        await store.redeem(code: "123456")
        host.settle()
        return (store, host)
    }

    private func activate(_ id: String, in host: OwnerRequestHost, until done: () -> Bool) async throws {
        let node = try XCTUnwrap(host.nodes()[id])
        XCTAssertTrue(node.accessibilityActivate())
        for _ in 0..<40 where !done() {
            try await Task.sleep(nanoseconds: 50_000_000)
            host.settle(0.05)
        }
    }

    func testRedeemedCodeReplacesVerificationWithCompactFinalConfirmation() async throws {
        let (_, host) = try await authorizedHost()
        XCTAssertFalse(host.exists("deletion-verify"))
        XCTAssertFalse(host.exists("deletion-verify-title"))
        XCTAssertFalse(host.exists("deletion-code"))
        XCTAssertFalse(host.exists("deletion-code-verified"))
        let labels = host.nodes().values.compactMap(\.accessibilityLabel)
        XCTAssertFalse(labels.contains("Verify it’s you"))
        XCTAssertFalse(labels.contains { $0.localizedCaseInsensitiveContains("code verified") })
        XCTAssertEqual(host.label("deletion-final-title"), "Delete your account?")
        XCTAssertFalse(labels.contains("Your identity has been verified."))
        XCTAssertEqual(host.label("deletion-final-message"),
                       "Your identity is verified. Deleting your account can’t be undone.")
        XCTAssertFalse(host.exists("deletion-final-detail"))
        XCTAssertFalse(host.exists("deletion-final-success-icon"))
        XCTAssertEqual(host.isDisabled("deletion-final-confirmation"), false)
        XCTAssertTrue(host.exists("deletion-final-cancel"))
        let frame = try XCTUnwrap(host.frame("deletion-final"))
        XCTAssertLessThan(frame.height, host.window.bounds.height * 0.65)
        XCTAssertEqual(completeRequests, 0)
    }

    func testFinalCancelNeverCompletes() async throws {
        let (store, host) = try await authorizedHost()
        try enqueue(phase("canceled"))
        try await activate("deletion-final-cancel", in: host) { store.route == nil }
        XCTAssertNil(store.route)
        XCTAssertEqual(completeRequests, 0)
        XCTAssertFalse(store.isCompleted)
        XCTAssertNotNil(identityStorage.record)
        XCTAssertEqual(handoffs, 0)
    }

    func testFinalConfirmationHasOnlyDeleteAndCancelAndNoClose() async throws {
        let (store, host) = try await authorizedHost()
        XCTAssertFalse(host.exists("deletion-final-close"))
        let buttons = host.nodes().filter { $0.value.accessibilityTraits.contains(.button) }.map(\.key)
        XCTAssertEqual(Set(buttons), ["deletion-final-confirmation", "deletion-final-cancel"])
        XCTAssertEqual(completeRequests, 0)
        XCTAssertFalse(store.isCompleted)
        XCTAssertNotNil(identityStorage.record)
        XCTAssertEqual(handoffs, 0)
    }

    func testFinalDeleteAccountCompletesExactlyOnce() async throws {
        let (store, host) = try await authorizedHost()
        try enqueue(["outcome": "completed"])
        try await activate("deletion-final-confirmation", in: host) { store.isCompleted }
        XCTAssertTrue(store.isCompleted)
        XCTAssertEqual(completeRequests, 1)
    }

    func testRelaunchAfterVerificationExpiredToReadyStillCancelsAndUnfreezes() async throws {
        let store = makeStore()
        try await authorize(store)
        XCTAssertTrue(fence.isFrozen)
        fence.setFrozen(false)
        let restored = makeStore()
        XCTAssertTrue(fence.isFrozen)
        try enqueue(phase("ready"))
        try enqueue(phase("canceled"))
        await restored.reconcile()
        XCTAssertNil(restored.route, "An expired verification is never reopened as the ready page.")
        XCTAssertNil(secure.record)
        XCTAssertFalse(fence.isFrozen)
        XCTAssertNil(defaults.object(forKey: ParticipantDeletionFreeze.key))
        XCTAssertEqual(restored.rowState, .none)
        XCTAssertEqual(completeRequests, 0)
    }

    func testReadySurfacesOncePerReadinessGenerationOnReconcile() async throws {
        let store = makeStore()
        try await begin(store, phase: "waiting")
        let restored = makeStore()
        XCTAssertNil(restored.route)
        XCTAssertFalse(fence.isFrozen)
        try enqueue(phase("ready"))
        await restored.reconcile()
        XCTAssertEqual(restored.route, .ready)
        XCTAssertFalse(fence.isFrozen)
        restored.close()
        try enqueue(phase("ready"))
        await restored.reconcile()
        XCTAssertNil(restored.route)
    }

    func testCancelWithLostStartResponseReconcilesThenCancels() async throws {
        let store = makeStore()
        try enqueue(["eligible": false, "categories": ["unknown"]])
        await store.begin()
        ParticipantEmailUnsubscribeURLProtocol.enqueue(.failure(.networkConnectionLost))
        await store.startDeletion()
        XCTAssertEqual(store.route, .wait)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(secure.record?.context.operationID)
        store.close()
        XCTAssertEqual(store.rowState, .inProgress)
        try enqueue(phase("waiting"), status: 201)
        try enqueue(phase("canceled"))
        await store.cancel()
        XCTAssertNil(secure.record)
        XCTAssertEqual(store.rowState, .none)
        XCTAssertFalse(fence.isFrozen)
    }

    func testPrivacyRowShowsDeletionStatusAndOpensExistingDeletion() throws {
        var opens = 0
        var starts = 0
        let host = try OwnerRequestHost { _, _ in
            AnyView(PrivacySafetyView(
                participantIdentityStore: identity, deletionRow: .readyToDelete,
                onDeleteAccount: { starts += 1 }, onOpenDeletion: { opens += 1 }
            ))
        }
        XCTAssertFalse(host.exists("privacy-safety-delete-account"))
        let row = try XCTUnwrap(host.nodes()["privacy-safety-account-deletion"])
        XCTAssertTrue(row.accessibilityActivate())
        host.settle()
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(starts, 0)
        XCTAssertFalse(host.exists("deletion-entry-confirmation"))
    }
}
