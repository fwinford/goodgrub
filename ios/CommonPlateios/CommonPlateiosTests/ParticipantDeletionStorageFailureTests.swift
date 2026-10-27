import Foundation
import XCTest
@testable import CommonPlateios

final class DeletionFaultDefaults: UserDefaults, @unchecked Sendable {
    nonisolated(unsafe) var rejectedKey: String?

    override func set(_ value: Any?, forKey defaultName: String) {
        guard defaultName != rejectedKey else { return }
        super.set(value, forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        guard defaultName != rejectedKey else { return }
        super.removeObject(forKey: defaultName)
    }

    override func set(_ value: Bool, forKey defaultName: String) {
        guard defaultName != rejectedKey else { return }
        super.set(value, forKey: defaultName)
    }
}

@MainActor
final class ParticipantDeletionStorageFailureTests: XCTestCase {
    var defaults: DeletionFaultDefaults!
    var suite: String!
    let participant = "64c0000000000000000000a1"
    let ledger = "b3f1c2b4-5e6d-4a1b-8c9d-0e1f2a3b4c5d"
    let origin = "https://example.test"

    override func setUp() {
        super.setUp()
        suite = "ParticipantDeletionStorageFailureTests.\(UUID().uuidString)"
        defaults = DeletionFaultDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.rejectedKey = nil
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func journal() -> ParticipantDeletionRecord {
        ParticipantDeletionRecord(
            context: ParticipantDeletionContext(
                freezeID: UUID().uuidString, participantID: participant,
                identityBinding: UUID().uuidString, origin: origin, operationID: UUID().uuidString,
                namespace: "dn1_" + String(repeating: "a", count: 64), attestedLedger: ledger
            ),
            stage: .completedCleanupPending, status: nil, capability: nil
        )
    }

    func createData() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "recoveryVersion": 2, "operationId": "operation-a", "participantIdentifier": participant,
            "authorityOrigin": origin, "authorityLedger": ledger, "payloadVersion": 1,
            "payload": ["future": true],
        ])
    }

    func testEachCheckedCreateRemovalFailureIsDetectedAndCanResumeWithoutReplay() throws {
        for key in [
            UserDefaultsPendingRequestOperationStorage.singleRecordKey,
            UserDefaultsPendingRequestOperationStorage.collectionKey,
        ] {
            let own = try createData()
            if key == UserDefaultsPendingRequestOperationStorage.singleRecordKey {
                defaults.set(own, forKey: key)
            } else { defaults.set([own], forKey: key) }
            let original = try XCTUnwrap(defaults.object(forKey: key))
            defaults.rejectedKey = key
            let completed = journal()
            XCTAssertThrowsError(try ParticipantDeletionCleanup(defaults: defaults).run(journal: completed))
            XCTAssertTrue(NSDictionary(dictionary: ["record": original]).isEqual(to: [
                "record": try XCTUnwrap(defaults.object(forKey: key)),
            ]))
            defaults.rejectedKey = nil
            _ = try ParticipantDeletionCleanup(defaults: defaults).run(journal: completed)
            XCTAssertNil(defaults.object(forKey: key))
        }
    }

    func testPartialCreateCleanupThenFailedUpdateWritePreservesForeignAndResumesIdempotently() throws {
        defaults.set([try createData()], forKey: UserDefaultsPendingRequestOperationStorage.collectionKey)
        let own = PendingRequestUpdate(
            operationId: "collision", kind: .withdraw, requestID: "request-a",
            participantIdentifier: participant, operationLedger: ledger, editPayload: nil
        )
        let foreign = PendingRequestUpdate(
            operationId: "collision", kind: .withdraw, requestID: "request-b",
            participantIdentifier: "64c0000000000000000000b2",
            operationLedger: ledger, editPayload: nil
        )
        let original = try JSONEncoder().encode([own, foreign, foreign])
        defaults.set(original, forKey: UserDefaultsPendingRequestUpdateStorage.key)
        defaults.rejectedKey = UserDefaultsPendingRequestUpdateStorage.key
        let completed = journal()
        let cleanup = ParticipantDeletionCleanup(defaults: defaults)
        XCTAssertThrowsError(try cleanup.run(journal: completed))
        XCTAssertNil(defaults.object(forKey: UserDefaultsPendingRequestOperationStorage.collectionKey))
        XCTAssertEqual(defaults.data(forKey: UserDefaultsPendingRequestUpdateStorage.key), original)
        defaults.rejectedKey = nil
        _ = try cleanup.run(journal: completed)
        XCTAssertEqual(UserDefaultsPendingRequestUpdateStorage(defaults: defaults).load().records, [foreign, foreign])
        XCTAssertEqual(try cleanup.run(journal: completed).removedUpdates, 0)
    }

    func testQuarantineAndPresentationBarrierWriteFailuresAreNotSuccessfulCleanup() throws {
        let key = UserDefaultsPendingRequestOperationStorage.singleRecordKey
        defaults.set(Data("unreadable".utf8), forKey: key)
        defaults.rejectedKey = ParticipantDeletionCleanup.createUnavailableKey
        XCTAssertThrowsError(try ParticipantDeletionCleanup(defaults: defaults).run(journal: journal()))
        XCTAssertEqual(defaults.data(forKey: key), Data("unreadable".utf8))
        defaults.rejectedKey = ParticipantLocalPresentationStorage.generationKey
        XCTAssertThrowsError(try ParticipantDeletionCleanup(defaults: defaults).run(journal: journal()))
        XCTAssertNil(defaults.object(forKey: ParticipantLocalPresentationStorage.generationKey))
        defaults.rejectedKey = nil
        XCTAssertTrue(try ParticipantDeletionCleanup(defaults: defaults).run(journal: journal()).retainedUnavailable)
    }

    func testNotificationNavigationFenceWriteFailureBlocksLocalCleanup() throws {
        defaults.rejectedKey = ParticipantDeletionNotificationFence.key
        XCTAssertThrowsError(try ParticipantDeletionCleanup(defaults: defaults).run(journal: journal()))
        XCTAssertNil(defaults.object(forKey: ParticipantDeletionNotificationFence.key))
        defaults.rejectedKey = nil
        _ = try ParticipantDeletionCleanup(defaults: defaults).run(journal: journal())
        XCTAssertNotNil(defaults.object(forKey: ParticipantDeletionNotificationFence.key) as? Date)
    }

    func testFreezeWriteAndRemovalFailuresPreserveFailClosedBoundaries() throws {
        let freeze = ParticipantDeletionFreeze(defaults: defaults)
        let id = UUID().uuidString
        defaults.rejectedKey = ParticipantDeletionFreeze.key
        XCTAssertThrowsError(try freeze.write(id))
        defaults.rejectedKey = nil
        try freeze.write(id)
        defaults.rejectedKey = ParticipantDeletionFreeze.key
        XCTAssertThrowsError(try freeze.remove(id))
        XCTAssertTrue(freeze.isPresent)
        defaults.rejectedKey = nil
        try freeze.remove(id)
        XCTAssertFalse(freeze.isPresent)
    }

    func testMarkerRemovalFailureAfterKeychainErasureResumesWithoutAnotherCredential() throws {
        let authority = ParticipantDeletionCompanionTests.AuthorityStorage()
        let identity = UserDefaultsParticipantIdentityStorage(defaults: defaults, authorityStorage: authority)
        XCTAssertTrue(identity.save(ParticipantIdentityRecord(
            principal: "a@nyu.edu", authority: canonicalParticipantAuthorityFixture, verifiedAt: Date()
        )))
        let binding = try identity.deletionBinding(participantID: participant)
        defaults.rejectedKey = UserDefaultsParticipantIdentityStorage.key
        XCTAssertThrowsError(try identity.deleteCompletedIdentity(
            participantID: participant, installationBinding: binding
        ))
        XCTAssertNil(authority.record)
        XCTAssertNotNil(defaults.object(forKey: UserDefaultsParticipantIdentityStorage.key))
        defaults.rejectedKey = nil
        XCTAssertEqual(try identity.deleteCompletedIdentity(
            participantID: participant, installationBinding: binding
        ), .removedOrAbsent)
        XCTAssertNil(defaults.object(forKey: UserDefaultsParticipantIdentityStorage.key))
        XCTAssertEqual(authority.removals, 1)
    }
}
