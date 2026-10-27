import Foundation
import UserNotifications
import XCTest
@testable import CommonPlateios

@MainActor
final class N1InstallationIdentityTests: XCTestCase {
    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        InstallationPushURLProtocol.reset()
        super.tearDown()
    }

    func testRemovalConfirmsDisassociationBeforeForgettingIdentity() async {
        let (store, storage) = identityStore()
        var completed = false
        store.configureInstallationAssociation(onIdentityCommitted: { completed = true }) { authority in
            XCTAssertNil(authority)
            XCTAssertEqual(store.currentAuthority(), canonicalParticipantAuthorityFixture)
            XCTAssertNotNil(storage.stored)
        }
        await store.removeIdentity()
        XCTAssertTrue(completed)
        XCTAssertNil(store.identity)
        XCTAssertNil(storage.stored)
        XCTAssertFalse(store.removalFailed)
    }

    func testRemovalFailureKeepsVerifiedIdentityAndAllowsExplicitRetry() async {
        let (store, storage) = identityStore()
        var attempts = 0
        store.configureInstallationAssociation { _ in
            attempts += 1
            if attempts == 1 { throw ParticipantVerificationError.temporarilyUnavailable }
        }
        await store.removeIdentity()
        XCTAssertTrue(store.removalFailed)
        XCTAssertEqual(store.currentAuthority(), canonicalParticipantAuthorityFixture)
        XCTAssertNotNil(storage.stored)
        await store.removeIdentity()
        XCTAssertFalse(store.removalFailed)
        XCTAssertFalse(store.isVerified)
        XCTAssertEqual(attempts, 2)
    }

    func testRemovalRechecksExistingActivitySafetyAfterDisassociation() async {
        let (store, storage) = identityStore()
        var safe = true
        var completed = false
        store.configureInstallationAssociation(onIdentityCommitted: { completed = true }) { _ in
            safe = false
        }
        await store.removeIdentity(ifSafe: { safe })
        XCTAssertTrue(store.removalFailed)
        XCTAssertEqual(store.currentAuthority(), canonicalParticipantAuthorityFixture)
        XCTAssertNotNil(storage.stored)
        XCTAssertFalse(completed)
    }

    func testHandoffPreservesTheUnresolvedOffChoiceWithoutAnAutomaticEnable() async throws {
        let storage = InMemoryPushInstallationStorage(
            lastConfirmedPushEnabled: true, pendingAmbiguousDesiredEnabled: false
        )
        let store = pushStore(storage)
        InstallationPushURLProtocol.enqueue(.response(data: associationBody(enabled: true)))
        try await store.synchronizeParticipantAssociation(authority: replacementParticipantAuthorityFixture)
        store.completeParticipantAssociationChange()
        await store.refreshAuthorizationStatus()
        XCTAssertEqual(store.state, .ambiguous(desiredEnabled: false))
        XCTAssertEqual(storage.pendingAmbiguousDesiredEnabled, false)
        XCTAssertEqual(InstallationPushURLProtocol.capturedRequests.count, 1)
        InstallationPushURLProtocol.enqueue(.response(data: Data(#"{"push":{"enabled":false}}"#.utf8)))
        await store.retryUpdate()
        XCTAssertEqual(store.state, .off)
        XCTAssertNil(storage.pendingAmbiguousDesiredEnabled)
        let request = try XCTUnwrap(InstallationPushURLProtocol.capturedRequests.last?.body)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
        XCTAssertEqual(body["enabled"] as? Bool, false)
    }

    func testHandoffPreservesDefiniteDisableFailureRecovery() async throws {
        let storage = InMemoryPushInstallationStorage(lastConfirmedPushEnabled: true)
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .authorized
        let store = pushStore(storage, authorization: authorization)
        InstallationPushURLProtocol.enqueue(.response(data: Data(#"{"push":{"enabled":true}}"#.utf8)))
        await store.refreshAuthorizationStatus()
        InstallationPushURLProtocol.enqueue(.response(
            statusCode: 429,
            data: Data(#"{"error":{"code":"RATE_LIMITED","message":"Wait","fields":null}}"#.utf8)
        ))
        await store.disable()
        XCTAssertEqual(store.failure, .couldNotDisable)
        InstallationPushURLProtocol.enqueue(.response(data: associationBody(enabled: true)))
        try await store.synchronizeParticipantAssociation(authority: replacementParticipantAuthorityFixture)
        store.completeParticipantAssociationChange()
        XCTAssertEqual(store.state, .failed)
        XCTAssertEqual(store.failure, .couldNotDisable)
        InstallationPushURLProtocol.enqueue(.response(data: Data(#"{"push":{"enabled":false}}"#.utf8)))
        await store.retryUpdate()
        XCTAssertEqual(store.state, .off)
        XCTAssertNil(store.failure)
    }

    func testBackendFailurePresentationPrecedesDeniedSettingsRecovery() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios/Views/PushNotificationSection.swift"), encoding: .utf8)
        let failure = try XCTUnwrap(source.range(of: "if store.state != .settingUp && showsFailure {"))
        let denied = try XCTUnwrap(source.range(of: "} else if store.state == .denied {"))
        XCTAssertLessThan(failure.lowerBound, denied.lowerBound)
        XCTAssertTrue(source.contains("await store.retryUpdate()"))
    }

    func testDeniedPermissionBackendFailureHasExplicitDisableRecovery() async throws {
        let storage = InMemoryPushInstallationStorage(lastConfirmedPushEnabled: true)
        let authorization = StubPushAuthorizationCoordinator()
        authorization.status = .denied
        let store = pushStore(storage, authorization: authorization)
        InstallationPushURLProtocol.enqueue(.response(
            statusCode: 429,
            data: Data(#"{"error":{"code":"RATE_LIMITED","message":"Wait","fields":null}}"#.utf8)
        ))
        await store.refreshAuthorizationStatus()
        XCTAssertEqual(store.state, .denied)
        XCTAssertEqual(store.failure, .couldNotDisable)
        InstallationPushURLProtocol.enqueue(.response(data: Data(#"{"push":{"enabled":false}}"#.utf8)))
        await store.retryUpdate()
        XCTAssertEqual(store.state, .off)
        XCTAssertNil(store.failure)
        let request = try XCTUnwrap(InstallationPushURLProtocol.capturedRequests.last?.body)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
        XCTAssertEqual(body["enabled"] as? Bool, false)
    }

    func testMutationSequencePersistsBeforeTransportAcrossAllUpdateKinds() async throws {
        let name = "n1.push-ordering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let storage = UserDefaultsPushInstallationStorage(defaults: defaults)
        let service = InstallationPushService(
            client: client(InstallationPushURLProtocol.self),
            nextMutationVersion: { storage.nextMutationVersion() },
            participantIdentityStore: identityStore().0
        )
        InstallationPushURLProtocol.enqueue(.response(data: Data(#"{"push":{"enabled":true}}"#.utf8)))
        _ = try await service.synchronizeEnabled(
            credential: storage.installationCredential(), apnsToken: "aabb", environment: .current
        )
        InstallationPushURLProtocol.enqueue(.response(data: Data(#"{"push":{"enabled":false}}"#.utf8)))
        _ = try await service.synchronizeDisabled(credential: storage.installationCredential())
        InstallationPushURLProtocol.enqueue(.response(data: associationBody(enabled: false)))
        _ = try await service.synchronizeAssociation(
            credential: storage.installationCredential(), authority: replacementParticipantAuthorityFixture
        )
        let versions = try InstallationPushURLProtocol.capturedRequests.map {
            let body = try XCTUnwrap($0.body)
            return try XCTUnwrap((JSONSerialization.jsonObject(with: body) as? [String: Any])?["mutationVersion"] as? Int)
        }
        XCTAssertEqual(versions, [1, 2, 3])
        XCTAssertEqual(UserDefaultsPushInstallationStorage(defaults: defaults).nextMutationVersion(), 4)
    }

    func testReplacementHandoffPrecedesLocalBAndRetryDoesNotRedeemTwice() async {
        let (store, storage) = identityStore()
        var attempts = 0
        var completed = 0
        store.configureInstallationAssociation(onIdentityCommitted: { completed += 1 }) { authority in
            attempts += 1
            XCTAssertEqual(authority, replacementParticipantAuthorityFixture)
            XCTAssertEqual(store.currentAuthority(), canonicalParticipantAuthorityFixture)
            XCTAssertEqual(storage.stored?.principal, "a@nyu.edu")
            if attempts == 1 { throw ParticipantVerificationError.temporarilyUnavailable }
        }
        await beginReplacement(store)
        let first = await store.submitCode("123456")
        XCTAssertFalse(first)
        XCTAssertEqual(store.identity?.principal, "a@nyu.edu")
        XCTAssertEqual(completed, 0)
        let retried = await store.submitCode("123456")
        XCTAssertTrue(retried)
        XCTAssertEqual(store.identity?.principal, "b@nyu.edu")
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths.count, 2)
    }

    func testCancelledHandoffCannotAdoptBOrCompletePendingPushState() async {
        let (store, _) = identityStore()
        var completed = false
        store.configureInstallationAssociation(onIdentityCommitted: { completed = true }) { _ in
            store.cancelVerification()
        }
        await beginReplacement(store)
        let result = await store.submitCode("123456")
        XCTAssertFalse(result)
        XCTAssertEqual(store.currentAuthority(), canonicalParticipantAuthorityFixture)
        XCTAssertFalse(completed)
    }

    func testCancelledOrRelaunchedHandoffExplicitlyReverifiesTheSameBWithAFreshCode() async throws {
        for relaunch in [false, true] {
            RequestFetchingURLProtocol.reset()
            InstallationPushURLProtocol.reset()
            let (initialIdentity, identityStorage) = identityStore()
            let pushStorage = InMemoryPushInstallationStorage(
                lastConfirmedPushEnabled: true, pendingAmbiguousDesiredEnabled: false
            )
            let initialPush = pushStore(pushStorage)
            wireRecovery(identity: initialIdentity, push: initialPush)
            await beginReplacement(initialIdentity)
            InstallationPushURLProtocol.enqueue(.failure(.networkConnectionLost))
            let initialResult = await initialIdentity.submitCode("123456")
            XCTAssertFalse(initialResult)
            XCTAssertEqual(pushStorage.pendingReplacementEmail, "b@nyu.edu")
            XCTAssertTrue(pushStorage.hasPendingAssociationChange)
            initialIdentity.cancelVerification()
            let identity: ParticipantIdentityStore
            let push: PushSubscriptionStore
            if relaunch {
                identity = ParticipantIdentityStore(
                    service: ParticipantVerificationService(client: client(RequestFetchingURLProtocol.self)),
                    storage: identityStorage
                )
                push = pushStore(pushStorage)
                wireRecovery(identity: identity, push: push)
            } else {
                identity = initialIdentity
                push = initialPush
            }
            await push.refreshAuthorizationStatus()
            XCTAssertNil(identity.flow)
            XCTAssertEqual(InstallationPushURLProtocol.capturedRequests.count, 1)
            await push.retryUpdate()
            XCTAssertEqual(identity.flow?.purpose, .emailReplacement)
            XCTAssertEqual(identity.flow?.stage, .enteringEmail)
            XCTAssertEqual(identity.replacementRecoveryEmail, "b@nyu.edu")
            XCTAssertEqual(identity.currentAuthority(), canonicalParticipantAuthorityFixture)
            XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths.count, 2,
                           "Try Again opens verification without sending a code or retrying the mutation")
            await identity.requestCode(for: "c@nyu.edu")
            XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths.count, 2,
                           "Recovery cannot silently switch the original desired B")
            RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: Data(
                #"{"verification":{"expiresAt":"2026-10-22T23:10:00Z","resendAvailableAt":"2026-10-22T23:01:00Z"}}"#.utf8
            )))
            RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: Data(
                #"{"participant":{"email":"b@nyu.edu"},"authority":"\#(replacementParticipantAuthorityFixture)"}"#.utf8
            )))
            await identity.requestCode(for: "b@nyu.edu")
            InstallationPushURLProtocol.enqueue(.response(data: associationBody(enabled: false)))
            let recovered = await identity.submitCode("654321")
            XCTAssertTrue(recovered)
            XCTAssertEqual(identity.identity?.principal, "b@nyu.edu")
            XCTAssertFalse(pushStorage.hasPendingAssociationChange)
            XCTAssertNil(pushStorage.pendingReplacementEmail)
            XCTAssertEqual(push.state, .ambiguous(desiredEnabled: false))
            XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths.count, 4)
            XCTAssertEqual(InstallationPushURLProtocol.capturedRequests.count, 2)
            await push.refreshAuthorizationStatus()
            XCTAssertEqual(InstallationPushURLProtocol.capturedRequests.count, 2)
            InstallationPushURLProtocol.enqueue(.response(data: Data(#"{"push":{"enabled":false}}"#.utf8)))
            await push.retryUpdate()
            XCTAssertEqual(push.state, .off)
            XCTAssertNil(pushStorage.pendingAmbiguousDesiredEnabled)
        }
    }

    func testConfirmedHandoffCancelledBeforeIdentityCommitRetainsSameBRecovery() async {
        let (identity, _) = identityStore()
        let storage = InMemoryPushInstallationStorage(lastConfirmedPushEnabled: true)
        let push = pushStore(storage)
        identity.configureInstallationAssociation(
            pendingReplacementEmail: { push.pendingReplacementEmail },
            prepareReplacement: { push.prepareParticipantReplacement(email: $0) },
            onIdentityCommitted: { push.completeParticipantAssociationChange() }
        ) { authority in
            try await push.synchronizeParticipantAssociation(authority: authority)
            identity.cancelVerification()
        }
        push.configureAssociationRecovery { identity.resumePendingInstallationReplacement() }
        await beginReplacement(identity)
        InstallationPushURLProtocol.enqueue(.response(data: associationBody(enabled: true)))
        let verified = await identity.submitCode("123456")
        XCTAssertFalse(verified)
        XCTAssertEqual(identity.identity?.principal, "a@nyu.edu")
        XCTAssertEqual(push.pendingReplacementEmail, "b@nyu.edu")
        XCTAssertEqual(push.state, .failed)
        await push.retryUpdate()
        XCTAssertEqual(identity.replacementRecoveryEmail, "b@nyu.edu")
        XCTAssertEqual(identity.flow?.stage, .enteringEmail)
        XCTAssertEqual(InstallationPushURLProtocol.capturedRequests.count, 1)
    }

    func testInterruptedReplacementCooldownCannotReenterTheAlreadyRedeemedCode() async {
        let (identity, _) = identityStore()
        let storage = InMemoryPushInstallationStorage(lastConfirmedPushEnabled: true)
        storage.setPendingAssociationChange(true)
        storage.setPendingReplacementEmail("b@nyu.edu")
        let push = pushStore(storage)
        wireRecovery(identity: identity, push: push)
        await push.retryUpdate()
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 429,
            data: Data(#"{"error":{"code":"VERIFICATION_RESEND_TOO_SOON","message":"Wait","fields":null}}"#.utf8)
        ))
        await identity.requestCode(for: "b@nyu.edu")
        XCTAssertEqual(identity.flow?.stage, .enteringEmail)
        XCTAssertEqual(identity.verificationError, .resendTooSoon)
        let verified = await identity.submitCode("123456")
        XCTAssertFalse(verified)
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths.count, 1)
        XCTAssertTrue(InstallationPushURLProtocol.capturedRequests.isEmpty)
    }

    func testBackToEmailAfterFailedHandoffPreservesSameBAndPrivateRetryAuthority() async {
        let (identity, _) = identityStore()
        let storage = InMemoryPushInstallationStorage(lastConfirmedPushEnabled: true)
        let push = pushStore(storage)
        wireRecovery(identity: identity, push: push)
        await beginReplacement(identity)
        InstallationPushURLProtocol.enqueue(.failure(.networkConnectionLost))
        let first = await identity.submitCode("123456")
        XCTAssertFalse(first)

        identity.returnToEmailEntry()
        XCTAssertEqual(identity.flow?.stage, .enteringEmail)
        XCTAssertEqual(identity.replacementRecoveryEmail, "b@nyu.edu")
        XCTAssertEqual(identity.currentAuthority(), canonicalParticipantAuthorityFixture)
        await identity.requestCode(for: "c@nyu.edu")
        XCTAssertEqual(identity.verificationError, .temporarilyUnavailable)
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths.count, 2)
        XCTAssertEqual(InstallationPushURLProtocol.capturedRequests.count, 1)

        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: Data(
            #"{"verification":{"expiresAt":"2026-10-22T23:10:00Z","resendAvailableAt":"2026-10-22T23:01:00Z"}}"#.utf8
        )))
        await identity.requestCode(for: "b@nyu.edu")
        InstallationPushURLProtocol.enqueue(.response(data: associationBody(enabled: true)))
        let recovered = await identity.submitCode("654321")
        XCTAssertTrue(recovered)
        XCTAssertEqual(identity.identity?.principal, "b@nyu.edu")
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths.count, 3,
                       "The same flow retries its private verified B without redeeming another code")
        XCTAssertFalse(storage.hasPendingAssociationChange)
    }

    func testBackToEmailDuringInterruptedRecoveryStillRequiresFreshCode() async {
        let (identity, _) = identityStore()
        let storage = InMemoryPushInstallationStorage(lastConfirmedPushEnabled: true)
        storage.setPendingAssociationChange(true)
        storage.setPendingReplacementEmail("b@nyu.edu")
        let push = pushStore(storage)
        wireRecovery(identity: identity, push: push)
        await push.retryUpdate()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: Data(
            #"{"verification":{"expiresAt":"2026-10-22T23:10:00Z","resendAvailableAt":"2026-10-22T23:01:00Z"}}"#.utf8
        )))
        await identity.requestCode(for: "b@nyu.edu")

        identity.returnToEmailEntry()
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 429,
            data: Data(#"{"error":{"code":"VERIFICATION_RESEND_TOO_SOON","message":"Wait","fields":null}}"#.utf8)
        ))
        await identity.requestCode(for: "b@nyu.edu")
        XCTAssertEqual(identity.flow?.stage, .enteringEmail)
        XCTAssertEqual(identity.verificationError, .resendTooSoon)
        let verified = await identity.submitCode("123456")
        XCTAssertFalse(verified)
        XCTAssertEqual(identity.currentAuthority(), canonicalParticipantAuthorityFixture)
        XCTAssertEqual(identity.replacementRecoveryEmail, "b@nyu.edu")
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths.count, 2)
        XCTAssertTrue(InstallationPushURLProtocol.capturedRequests.isEmpty)
    }

    func testInterruptedRemovalTryAgainUsesClearAndHonorsExistingSafety() async {
        let (identity, identityStorage) = identityStore()
        let storage = InMemoryPushInstallationStorage(lastConfirmedPushEnabled: true)
        let initialPush = pushStore(storage)
        wireRecovery(identity: identity, push: initialPush)
        InstallationPushURLProtocol.enqueue(.failure(.networkConnectionLost))
        await identity.removeIdentity()
        XCTAssertTrue(storage.hasPendingAssociationChange)
        XCTAssertNil(storage.pendingReplacementEmail)
        let relaunched = pushStore(storage)
        wireRecovery(identity: identity, push: relaunched)
        var safe = false
        relaunched.configureAssociationRecovery { await identity.removeIdentity(ifSafe: { safe }) }
        await relaunched.refreshAuthorizationStatus()
        await relaunched.retryUpdate()
        XCTAssertEqual(InstallationPushURLProtocol.capturedRequests.count, 1)
        XCTAssertEqual(identity.identity?.principal, "a@nyu.edu")
        safe = true
        InstallationPushURLProtocol.enqueue(.response(data: associationBody(enabled: false)))
        await relaunched.retryUpdate()
        XCTAssertNil(identity.identity)
        XCTAssertNil(identityStorage.stored)
        XCTAssertFalse(storage.hasPendingAssociationChange)
        XCTAssertEqual(relaunched.state, .off)
        XCTAssertEqual(InstallationPushURLProtocol.capturedRequests.count, 2)
    }

    func testCancelledCodeRequestCannotInstallItsStageIntoARecoveryFlow() async {
        let (identity, _) = identityStore()
        identity.beginEmailReplacement()
        let gate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: Data(
            #"{"verification":{"expiresAt":"2026-10-22T23:10:00Z","resendAvailableAt":"2026-10-22T23:01:00Z"}}"#.utf8
        ), gate: gate))
        let request = Task { await identity.requestCode(for: "b@nyu.edu") }
        for _ in 0..<500 where !gate.isWaiting {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(gate.isWaiting)
        identity.cancelVerification()
        identity.beginEmailReplacement()
        gate.open()
        await request.value
        XCTAssertEqual(identity.flow?.stage, .enteringEmail)
        XCTAssertEqual(identity.currentAuthority(), canonicalParticipantAuthorityFixture)
    }

    func testPendingReplacementEmailSurvivesStorageReopenWithoutACredential() throws {
        let name = "n1.pending-replacement.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let storage = UserDefaultsPushInstallationStorage(defaults: defaults)
        storage.setPendingReplacementEmail("b@nyu.edu")
        storage.setPendingAssociationChange(true)
        let reopened = UserDefaultsPushInstallationStorage(defaults: defaults)
        XCTAssertEqual(reopened.pendingReplacementEmail, "b@nyu.edu")
        XCTAssertTrue(reopened.hasPendingAssociationChange)
        let contents = String(describing: defaults.dictionaryRepresentation())
        XCTAssertFalse(contents.contains(replacementParticipantAuthorityFixture))
        reopened.setPendingReplacementEmail(nil)
        XCTAssertNil(storage.pendingReplacementEmail)
    }

    func testAnotherReplacementAddressCannotReuseTheVerifiedBResult() async {
        let (store, _) = identityStore()
        let cAuthority = "64c0000000000000000000c3.1." + String(repeating: "C", count: 42) + "A"
        var attempts: [String?] = []
        store.configureInstallationAssociation { authority in
            attempts.append(authority)
            if attempts.count == 1 { throw ParticipantVerificationError.temporarilyUnavailable }
        }
        await beginReplacement(store)
        let first = await store.submitCode("123456")
        XCTAssertFalse(first)
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: Data(
            #"{"verification":{"expiresAt":"2026-10-22T23:10:00Z","resendAvailableAt":"2026-10-22T23:01:00Z"}}"#.utf8
        )))
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: Data(
            #"{"participant":{"email":"c@nyu.edu"},"authority":"\#(cAuthority)"}"#.utf8
        )))
        await store.requestCode(for: "c@nyu.edu")
        let result = await store.submitCode("654321")
        XCTAssertTrue(result)
        XCTAssertEqual(store.identity?.principal, "c@nyu.edu")
        XCTAssertEqual(attempts, [replacementParticipantAuthorityFixture, cAuthority])
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths.count, 4)
    }

    func testAmbiguousAssociationSurvivesRelaunchWithoutAutomaticMutation() async throws {
        let storage = InMemoryPushInstallationStorage(lastConfirmedPushEnabled: true)
        let store = pushStore(storage)
        InstallationPushURLProtocol.enqueue(.failure(.networkConnectionLost))
        do {
            try await store.synchronizeParticipantAssociation(authority: replacementParticipantAuthorityFixture)
            XCTFail("A lost response cannot confirm B")
        } catch {}
        XCTAssertTrue(storage.hasPendingAssociationChange)
        XCTAssertEqual(store.state, .failed)
        let relaunched = pushStore(storage)
        await relaunched.refreshAuthorizationStatus()
        XCTAssertEqual(relaunched.state, .failed)
        XCTAssertEqual(InstallationPushURLProtocol.capturedRequests.count, 1)
        InstallationPushURLProtocol.enqueue(.response(data: associationBody(enabled: true)))
        try await relaunched.synchronizeParticipantAssociation(authority: replacementParticipantAuthorityFixture)
        XCTAssertTrue(storage.hasPendingAssociationChange, "Identity must commit before Push can be stable")
        relaunched.completeParticipantAssociationChange()
        XCTAssertFalse(storage.hasPendingAssociationChange)
        XCTAssertNotEqual(relaunched.state, .on, "Apple permission and APNs still require reconciliation")
    }

    func testDefiniteHandoffFailurePreservesPreviousPushState() async {
        let storage = InMemoryPushInstallationStorage(lastConfirmedPushEnabled: false)
        let store = pushStore(storage)
        InstallationPushURLProtocol.enqueue(.response(
            statusCode: 429,
            data: Data(#"{"error":{"code":"RATE_LIMITED","message":"Wait","fields":null}}"#.utf8)
        ))
        do {
            try await store.synchronizeParticipantAssociation(authority: replacementParticipantAuthorityFixture)
            XCTFail("A refusal cannot complete handoff")
        } catch {}
        XCTAssertFalse(storage.hasPendingAssociationChange)
        XCTAssertEqual(store.state, .off)
    }

    func testClearCannotConfirmWithAnEnabledResponse() async {
        InstallationPushURLProtocol.enqueue(.response(data: associationBody(enabled: true)))
        let service = InstallationPushService(client: client(InstallationPushURLProtocol.self))
        do {
            _ = try await service.synchronizeAssociation(
                credential: InstallationCredentialGenerator.generate(), authority: nil
            )
            XCTFail("Contradictory clear truth must not remove identity")
        } catch InstallationPushSyncError.ambiguousOutcome {
        } catch {
            XCTFail("Expected unresolved mutation, received \(type(of: error))")
        }
    }

    func testForegroundPermissionReadCannotOverwriteAnInterveningHandoff() async throws {
        let authorization = DeferredN1Authorization()
        let storage = InMemoryPushInstallationStorage(lastConfirmedPushEnabled: true)
        let store = pushStore(storage, authorization: authorization)
        let refresh = Task { await store.refreshAuthorizationStatus() }
        await fulfillment(of: [authorization.entered], timeout: 2)
        InstallationPushURLProtocol.enqueue(.response(data: associationBody(enabled: false)))
        try await store.synchronizeParticipantAssociation(authority: replacementParticipantAuthorityFixture)
        authorization.complete(.authorized)
        await refresh.value
        XCTAssertTrue(storage.hasPendingAssociationChange)
        XCTAssertEqual(store.state, .failed)
        XCTAssertEqual(InstallationPushURLProtocol.capturedRequests.count, 1)
    }

    private func identityStore() -> (ParticipantIdentityStore, InMemoryParticipantIdentityStorage) {
        let storage = InMemoryParticipantIdentityStorage(stored: ParticipantIdentityRecord(
            principal: "a@nyu.edu", authority: canonicalParticipantAuthorityFixture, verifiedAt: Date()
        ))
        let store = ParticipantIdentityStore(
            service: ParticipantVerificationService(client: client(RequestFetchingURLProtocol.self)),
            storage: storage
        )
        return (store, storage)
    }

    private func wireRecovery(identity: ParticipantIdentityStore, push: PushSubscriptionStore) {
        identity.configureInstallationAssociation(
            pendingReplacementEmail: { push.pendingReplacementEmail },
            prepareReplacement: { push.prepareParticipantReplacement(email: $0) },
            onIdentityCommitted: { push.completeParticipantAssociationChange() }
        ) { authority in
            try await push.synchronizeParticipantAssociation(authority: authority)
        }
        push.configureAssociationRecovery { identity.resumePendingInstallationReplacement() }
    }

    private func beginReplacement(_ store: ParticipantIdentityStore) async {
        store.beginEmailReplacement()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: Data(
            #"{"verification":{"expiresAt":"2026-10-22T23:10:00Z","resendAvailableAt":"2026-10-22T23:01:00Z"}}"#.utf8
        )))
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: Data(
            #"{"participant":{"email":"b@nyu.edu"},"authority":"\#(replacementParticipantAuthorityFixture)"}"#.utf8
        )))
        await store.requestCode(for: "b@nyu.edu")
    }

    private func pushStore(
        _ storage: InMemoryPushInstallationStorage,
        authorization: PushAuthorizationCoordinator? = nil
    ) -> PushSubscriptionStore {
        PushSubscriptionStore(
            service: InstallationPushService(
                client: client(InstallationPushURLProtocol.self),
                participantIdentityStore: identityStore().0
            ),
            installationStorage: storage,
            authorizationCoordinator: authorization ?? StubPushAuthorizationCoordinator(),
            remoteNotificationRegistrar: StubRemoteNotificationRegistrar(),
            settingsOpener: StubPushSettingsOpener(),
            participantAuthorityProvider: { canonicalParticipantAuthorityFixture }
        )
    }

    private func associationBody(enabled: Bool) -> Data {
        Data(#"{"association":{"confirmed":true},"push":{"enabled":\#(enabled)}}"#.utf8)
    }

    private func client(_ protocolClass: URLProtocol.Type) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        return APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
    }
}

@MainActor
private final class DeferredN1Authorization: PushAuthorizationCoordinator {
    let entered = XCTestExpectation(description: "authorization read started")
    private var continuation: CheckedContinuation<UNAuthorizationStatus, Never>?

    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation {
            continuation = $0
            entered.fulfill()
        }
    }

    func requestAuthorization() async throws -> Bool { false }

    func complete(_ status: UNAuthorizationStatus) {
        continuation?.resume(returning: status)
        continuation = nil
    }
}
