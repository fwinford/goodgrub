import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class ParticipantDeletionCompanionTests: XCTestCase {
    final class AuthorityStorage: ParticipantAuthorityStorage {
        var record: StoredParticipantAuthority?
        var unavailable = false
        var failRemoval = false
        var removals = 0
        func load() -> StoredParticipantAuthority? { record }
        func save(_ record: StoredParticipantAuthority) -> Bool { self.record = record; return true }
        func clear() { record = nil }
        func loadChecked() -> ParticipantAuthorityLoad {
            if unavailable { return .unavailable }
            return record.map(ParticipantAuthorityLoad.record) ?? .absent
        }
        func removeChecked() throws {
            if unavailable || failRemoval { throw ParticipantDeletionError.storageUnavailable }
            removals += 1
            record = nil
        }
    }

    var defaults: UserDefaults!
    var suite: String!
    let participant = "64c0000000000000000000a1"

    override func setUp() {
        super.setUp()
        suite = "ParticipantDeletionCompanionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        AlertSignupURLProtocol.reset()
        InstallationPushURLProtocol.reset()
        RequestFetchingURLProtocol.reset()
        ClaimFlowURLProtocol.reset()
        super.tearDown()
    }

    func identityStorage(_ authority: AuthorityStorage) -> UserDefaultsParticipantIdentityStorage {
        UserDefaultsParticipantIdentityStorage(defaults: defaults, authorityStorage: authority)
    }

    func saveIdentity(
        _ storage: UserDefaultsParticipantIdentityStorage,
        authority: String = canonicalParticipantAuthorityFixture,
        principal: String = "a@nyu.edu"
    ) {
        XCTAssertTrue(storage.save(ParticipantIdentityRecord(
            principal: principal, authority: authority, verifiedAt: Date()
        )))
    }

    func testCheckedIdentityErasureUsesExactBindingAndIsIdempotentUnderFreeze() throws {
        let authority = AuthorityStorage()
        let storage = identityStorage(authority)
        saveIdentity(storage)
        let binding = try storage.deletionBinding(participantID: participant)
        try ParticipantDeletionFreeze(defaults: defaults).write(UUID().uuidString)
        XCTAssertEqual(try storage.deleteCompletedIdentity(
            participantID: participant, installationBinding: binding
        ), .removedOrAbsent)
        XCTAssertNil(authority.record)
        XCTAssertNil(defaults.object(forKey: UserDefaultsParticipantIdentityStorage.key))
        XCTAssertEqual(try storage.deleteCompletedIdentity(
            participantID: participant, installationBinding: binding
        ), .removedOrAbsent)
        XCTAssertEqual(authority.removals, 1)
    }

    func testForeignIdentityPairIsPreservedWithoutMarkerOrKeychainWrites() throws {
        let authority = AuthorityStorage()
        let storage = identityStorage(authority)
        saveIdentity(storage)
        let binding = try storage.deletionBinding(participantID: participant)
        saveIdentity(storage, authority: replacementParticipantAuthorityFixture, principal: "b@nyu.edu")
        let foreign = authority.record
        let marker = defaults.data(forKey: UserDefaultsParticipantIdentityStorage.key)
        XCTAssertEqual(try storage.deleteCompletedIdentity(
            participantID: participant, installationBinding: binding
        ), .preservedForeign)
        XCTAssertEqual(authority.record, foreign)
        XCTAssertEqual(defaults.data(forKey: UserDefaultsParticipantIdentityStorage.key), marker)
        XCTAssertEqual(authority.removals, 0)
    }

    func testInaccessibleAndFailedKeychainRemovalBlockErasureAndPreserveMarker() throws {
        let authority = AuthorityStorage()
        let storage = identityStorage(authority)
        saveIdentity(storage)
        let binding = try storage.deletionBinding(participantID: participant)
        let marker = defaults.data(forKey: UserDefaultsParticipantIdentityStorage.key)
        authority.unavailable = true
        XCTAssertThrowsError(try storage.deleteCompletedIdentity(
            participantID: participant, installationBinding: binding
        ))
        authority.unavailable = false
        authority.failRemoval = true
        XCTAssertThrowsError(try storage.deleteCompletedIdentity(
            participantID: participant, installationBinding: binding
        ))
        XCTAssertNotNil(authority.record)
        XCTAssertEqual(defaults.data(forKey: UserDefaultsParticipantIdentityStorage.key), marker)
    }

    func testCorruptMarkerAndSameParticipantWithDifferentBindingAreNotErased() throws {
        let authority = AuthorityStorage()
        let storage = identityStorage(authority)
        saveIdentity(storage)
        let binding = try storage.deletionBinding(participantID: participant)
        saveIdentity(storage)
        XCTAssertThrowsError(try storage.deleteCompletedIdentity(
            participantID: participant, installationBinding: binding
        ))
        defaults.set(Data("corrupt".utf8), forKey: UserDefaultsParticipantIdentityStorage.key)
        XCTAssertThrowsError(try storage.deleteCompletedIdentity(
            participantID: participant, installationBinding: binding
        ))
        XCTAssertNotNil(authority.record)
        XCTAssertEqual(authority.removals, 0)
    }

    func testOwnerlessPresentationRemainsInPlaceButCannotBeRestoredOrRewrittenByOldAdapters() throws {
        let signup = UserDefaultsAlertSignupPresentationStorage(defaults: defaults)
        signup.save(AlertSignupPresentationRecord(email: "a@nyu.edu", acceptedResponseAt: Date()))
        let installation = UserDefaultsPushInstallationStorage(defaults: defaults)
        let credential = installation.installationCredential()
        installation.recordConfirmedPushEnabled(true)
        installation.setPendingReplacementEmail("a@nyu.edu")
        installation.setPendingAssociationChange(true)
        installation.setPendingAmbiguousDesiredEnabled(false)
        let before = defaults.dictionaryRepresentation()
        let generation = UUID().uuidString
        try ParticipantLocalPresentationStorage.retire(defaults: defaults, generation: generation)
        for (key, value) in before {
            XCTAssertTrue(NSDictionary(dictionary: [key: value]).isEqual(to: [
                key: try XCTUnwrap(defaults.object(forKey: key)),
            ]))
        }
        signup.save(AlertSignupPresentationRecord(email: "stale@nyu.edu", acceptedResponseAt: Date()))
        installation.setPendingReplacementEmail("stale@nyu.edu")
        installation.recordConfirmedPushEnabled(false)
        let freshSignup = UserDefaultsAlertSignupPresentationStorage(defaults: defaults)
        let freshInstallation = UserDefaultsPushInstallationStorage(defaults: defaults)
        XCTAssertNil(freshSignup.loadValidPresentation())
        XCTAssertNil(freshInstallation.pendingReplacementEmail)
        XCTAssertFalse(freshInstallation.hasPendingAssociationChange)
        XCTAssertEqual(freshInstallation.installationCredential(), credential)
        XCTAssertEqual(freshInstallation.lastConfirmedPushEnabled, true)
        XCTAssertEqual(freshInstallation.pendingAmbiguousDesiredEnabled, false)
        freshSignup.save(AlertSignupPresentationRecord(email: "b@nyu.edu", acceptedResponseAt: Date()))
        XCTAssertEqual(freshSignup.loadValidPresentation()?.email, "b@nyu.edu")
        try ParticipantLocalPresentationStorage.retire(defaults: defaults, generation: generation)
        XCTAssertEqual(freshSignup.loadValidPresentation()?.email, "b@nyu.edu")
    }

    func testOldUpdateAdapterCannotClearForeignCollidingRecordAfterFreezeRetirement() throws {
        let old = UserDefaultsPendingRequestUpdateStorage(defaults: defaults)
        let foreign = PendingRequestUpdate(
            operationId: "collision", kind: .withdraw, requestID: "request-b",
            participantIdentifier: "64c0000000000000000000b2",
            operationLedger: UUID().uuidString.lowercased(), editPayload: nil
        )
        XCTAssertTrue(old.save(foreign))
        let original = defaults.data(forKey: UserDefaultsPendingRequestUpdateStorage.key)
        try ParticipantLocalPresentationStorage.retire(defaults: defaults, generation: UUID().uuidString)
        old.clear(operationId: foreign.operationId)
        XCTAssertEqual(defaults.data(forKey: UserDefaultsPendingRequestUpdateStorage.key), original)
        XCTAssertEqual(UserDefaultsPendingRequestUpdateStorage(defaults: defaults).load().records, [foreign])
    }

    func testLateSignupResponseCannotRestoreDeletedEmailPresentation() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AlertSignupURLProtocol.self]
        let storage = UserDefaultsAlertSignupPresentationStorage(defaults: defaults)
        let store = AlertSubscriptionStore(
            service: AlertSubscriptionService(client: APIClient(
                configuration: APIConfiguration(baseURL: URL(string: "https://example.test")!),
                session: URLSession(configuration: config)
            )),
            presentationStorage: storage
        )
        AlertSignupURLProtocol.enqueue(.response(
            statusCode: 202, data: Data(#"{"accepted":true}"#.utf8), delay: 0.15
        ))
        let task = Task { await store.submit(email: "a@nyu.edu") }
        for _ in 0..<500 {
            if !AlertSignupURLProtocol.capturedRequests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertFalse(AlertSignupURLProtocol.capturedRequests.isEmpty)
        store.retireForCompletedDeletion()
        await task.value
        XCTAssertEqual(store.phase, .editing)
        XCTAssertNil(store.rememberedEmail)
        XCTAssertNil(storage.loadValidPresentation())
    }

    func testLatePushResponseCannotRewriteInstallationOrAssociationState() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InstallationPushURLProtocol.self]
        let installation = InMemoryPushInstallationStorage(lastConfirmedPushEnabled: false)
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .authorized
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://example.test")!),
            session: URLSession(configuration: config)
        )
        let store = PushSubscriptionStore(
            service: InstallationPushService(
                client: client, participantIdentityStore: installationPushIdentityFixture(client: client)
            ),
            installationStorage: installation, authorizationCoordinator: authorization,
            remoteNotificationRegistrar: StubRemoteNotificationRegistrar(),
            settingsOpener: StubPushSettingsOpener(),
            participantAuthorityProvider: { canonicalParticipantAuthorityFixture }
        )
        InstallationPushURLProtocol.enqueue(.response(
            data: Data(#"{"push":{"enabled":true}}"#.utf8), delay: 0.15
        ))
        let task = Task { await store.enable() }
        for _ in 0..<500 {
            if !InstallationPushURLProtocol.capturedRequests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertFalse(InstallationPushURLProtocol.capturedRequests.isEmpty)
        store.retireForCompletedDeletion()
        await task.value
        XCTAssertTrue(installation.recordCalls.isEmpty)
        XCTAssertFalse(installation.hasPendingAssociationChange)
        XCTAssertNil(installation.pendingAmbiguousDesiredEnabled)
        XCTAssertEqual(installation.lastConfirmedPushEnabled, false)
    }

    func testNotificationRetirementFencesCapturedAndPreCompletionTapsButKeepsLaterPushesRoutable() throws {
        let notificationDefaults = UserDefaults(suiteName: suite)!
        let notificationFence = ParticipantDeletionNotificationFence(defaults: notificationDefaults)
        let router = HelperNotificationRouter(deletionNotificationFence: notificationFence)
        let oldDelivery = Date(timeIntervalSince1970: 1_800_000_000)
        router.handleUserActedOnNotification(userInfo: [
            "type": "requester-order-placed", "requestId": "64c0000000000000000000a1",
        ], deliveredAt: oldDelivery)
        XCTAssertNotNil(try XCTUnwrap(router.pendingRequesterFulfillmentIntent))
        router.fenceForCompletedDeletion()
        XCTAssertNil(router.pendingRequesterFulfillmentIntent)
        let fencedSequence = router.latestTapSequence
        try notificationFence.recordCompletion(at: oldDelivery.addingTimeInterval(60))
        router.handleUserActedOnNotification(userInfo: [
            "type": "requester-order-placed", "requestId": "64c0000000000000000000b2",
        ], deliveredAt: oldDelivery)
        XCTAssertEqual(router.latestTapSequence, fencedSequence)
        XCTAssertNil(router.pendingRequesterFulfillmentIntent)
        router.handleUserActedOnNotification(userInfo: [
            "type": "requester-order-placed", "requestId": "64c0000000000000000000b3",
        ], deliveredAt: oldDelivery.addingTimeInterval(120))
        XCTAssertNotNil(router.pendingRequesterFulfillmentIntent)
        let relaunchedRouter = HelperNotificationRouter(deletionNotificationFence: notificationFence)
        relaunchedRouter.handleUserActedOnNotification(userInfo: [
            "type": "requester-order-placed", "requestId": "64c0000000000000000000a1",
        ], deliveredAt: oldDelivery)
        XCTAssertNil(relaunchedRouter.pendingRequesterFulfillmentIntent)
        relaunchedRouter.handleUserActedOnNotification(userInfo: [
            "type": "requester-order-placed", "requestId": "64c0000000000000000000b3",
        ], deliveredAt: oldDelivery.addingTimeInterval(120))
        XCTAssertNotNil(relaunchedRouter.pendingRequesterFulfillmentIntent)
        XCTAssertFalse(TapAuthorityFence.isStillAuthoritative(
            capturedSequence: fencedSequence - 1, currentSequence: router.latestTapSequence
        ))
    }

    func requestStore(
        creates: PendingRequestOperationStorage,
        updates: PendingRequestUpdateStorage = InMemoryPendingRequestUpdateStorage(),
        protocolClass: AnyClass = RequestFetchingURLProtocol.self
    ) -> RequestStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [protocolClass]
        return RequestStore(
            service: RequestService(client: APIClient(
                configuration: APIConfiguration(baseURL: URL(string: "https://example.test")!),
                session: URLSession(configuration: config)
            )),
            installationCredentialProvider: { "test-installation" },
            participantAuthorityProvider: { canonicalParticipantAuthorityFixture },
            participantAuthorityRejected: {}, operationStorage: creates, updateStorage: updates
        )
    }

    func testLateCreateCannotClearACollidingForeignRecordOrRestoreAmbiguity() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = requestStore(creates: storage)
        let payload = CreateRequestPayload(
            vendor: "Jasper Kane Cafe", timing: .asap, windowStart: nil,
            menuPath: .mealExchange, mealSwipes: 1, mealItems: [MealItem(name: "Original A")],
            orderDetails: nil, estimatedDiningDollarsCents: nil
        )
        let gate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost, gate: gate))
        let task = Task { try await store.createRequest(payload) }
        for _ in 0..<500 {
            if RequestFetchingURLProtocol.capturedRequestedPaths.contains("/api/request") { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let original = try XCTUnwrap(storage.load())
        store.retireForCompletedDeletion()
        storage.clear(operationId: original.operationId)
        let foreign = PendingRequestOperationRecord(
            operationId: original.operationId, participantIdentifier: "64c0000000000000000000b2",
            operationAuthority: original.operationAuthority, payload: payload
        )
        XCTAssertTrue(storage.save(foreign))
        gate.open()
        do { try await task.value; XCTFail("retired create must not publish") }
        catch is CancellationError {}
        XCTAssertEqual(storage.load(), foreign)
        XCTAssertNil(store.createdRequestContinuity)
        XCTAssertNil(store.createError)
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
    }

    func testLateUpdateCannotClearACollidingForeignRecordOrPublishSuccess() async throws {
        let updates = InMemoryPendingRequestUpdateStorage()
        let store = requestStore(creates: InMemoryPendingRequestOperationStorage(), updates: updates)
        let gate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(
            data: Data(#"{"outcome":"withdrawn","requestId":"request-a"}"#.utf8), gate: gate
        ))
        let task = Task { try await store.withdrawRequest(requestID: "request-a") }
        for _ in 0..<500 {
            if !updates.load().records.isEmpty { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let original = try XCTUnwrap(updates.load().records.first)
        store.retireForCompletedDeletion()
        updates.clear(operationId: original.operationId)
        let foreign = PendingRequestUpdate(
            operationId: original.operationId, kind: .withdraw, requestID: "request-b",
            participantIdentifier: "64c0000000000000000000b2",
            operationLedger: original.operationLedger, editPayload: nil
        )
        XCTAssertTrue(updates.save(foreign))
        gate.open()
        do { try await task.value; XCTFail("retired update must not publish") }
        catch is CancellationError {}
        XCTAssertEqual(updates.load().records, [foreign])
        XCTAssertNil(store.unresolvedUpdate)
    }

    func testLateClaimResponseCannotRestorePrivateClaimAuthority() async throws {
        let store = requestStore(
            creates: InMemoryPendingRequestOperationStorage(), protocolClass: ClaimFlowURLProtocol.self
        )
        let gate = RequestFetchingGate()
        let response = Data("""
        {
          "request": {
            "id": "request-a", "vendor": "Jasper Kane Cafe", "food": "Original A",
            "pickupWindowText": "ASAP", "mealSwipes": 1, "menuPath": "meal-exchange",
            "mealItems": [{"name": "Original A"}], "status": "claimed",
            "createdAt": "2026-10-24T20:00:00.000Z", "expiresAt": "2099-10-24T21:00:00.000Z"
          },
          "claim": {
            "pickupName": "Private A", "claimToken": "private-a-claim-token",
            "claimExpiresAt": "2099-10-24T20:15:00.000Z"
          }
        }
        """.utf8)
        ClaimFlowURLProtocol.enqueue(.response(data: response, gate: gate))
        let task = Task { try await store.claim(requestID: "request-a") }
        for _ in 0..<500 {
            if gate.isWaiting { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(gate.isWaiting)
        store.retireForCompletedDeletion()
        gate.open()
        do { try await task.value } catch {}
        XCTAssertNil(store.activeClaim)
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertTrue(store.requests.isEmpty)
    }
}
