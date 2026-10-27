import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class ParticipantDeletionCleanupTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    let a = "64c0000000000000000000a1"
    let b = "64c0000000000000000000b2"
    let ledger = "b3f1c2b4-5e6d-4a1b-8c9d-0e1f2a3b4c5d"
    let foreignLedger = "c3f1c2b4-5e6d-4a1b-8c9d-0e1f2a3b4c5d"
    let origin = "https://example.test"

    override func setUp() {
        super.setUp()
        suite = "ParticipantDeletionCleanupTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func journal(ledger: String? = nil, stage: ParticipantDeletionRecord.Stage = .completedCleanupPending) -> ParticipantDeletionRecord {
        ParticipantDeletionRecord(
            context: ParticipantDeletionContext(
                freezeID: UUID().uuidString, participantID: a,
                identityBinding: UUID().uuidString, origin: origin,
                operationID: UUID().uuidString,
                namespace: "dn1_" + String(repeating: "a", count: 64),
                attestedLedger: ledger ?? self.ledger
            ),
            stage: stage, status: nil, capability: nil
        )
    }

    func create(owner: String, ledger: String? = nil, origin: String? = nil, operation: String = "collision") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "recoveryVersion": 2, "operationId": operation, "participantIdentifier": owner,
            "authorityLedger": ledger ?? self.ledger, "authorityOrigin": origin ?? self.origin,
            "payloadVersion": 1, "payload": ["futureUnreadablePayload": true],
            "unknownField": ["keep": [1, 2, 3]],
        ])
    }

    func update(owner: String, ledger: String? = nil, operation: String = "collision") -> [String: Any] {
        [
            "operationId": operation, "kind": "withdraw", "requestID": "request",
            "participantIdentifier": owner, "operationLedger": ledger ?? self.ledger,
            "futureUnknown": ["preserve": [1, 2, 3]],
        ]
    }

    func testCreatesRequireExactOwnerOriginAndServerAttestedLedgerPreservingDuplicateForeignBytes() throws {
        let own = try create(owner: a)
        let foreign = try create(owner: b)
        let collided = try create(owner: a, ledger: foreignLedger)
        let wrongOrigin = try create(owner: a, origin: "https://other.test")
        let opaque = Data("unreadable".utf8)
        defaults.set([foreign, own, collided, foreign, own, opaque, wrongOrigin],
                     forKey: UserDefaultsPendingRequestOperationStorage.collectionKey)
        defaults.set(own, forKey: UserDefaultsPendingRequestOperationStorage.singleRecordKey)
        let result = try ParticipantDeletionCleanup(defaults: defaults).run(journal: journal())
        XCTAssertEqual(result.removedCreates, 3)
        XCTAssertNil(defaults.object(forKey: UserDefaultsPendingRequestOperationStorage.singleRecordKey))
        XCTAssertEqual(defaults.array(forKey: UserDefaultsPendingRequestOperationStorage.collectionKey) as? [Data],
                       [foreign, collided, foreign, opaque, wrongOrigin])
        XCTAssertTrue(result.retainedUnavailable)
        XCTAssertTrue(UserDefaultsPendingRequestOperationStorage(defaults: defaults).restoreAll().contains(.identityUnavailable))
    }

    func testReadableCollectionWithWrongTypedNeighborStillRemovesOnlyProvenEntries() throws {
        let own = try create(owner: a)
        defaults.set([own, "opaque neighbor", try create(owner: b)] as [Any],
                     forKey: UserDefaultsPendingRequestOperationStorage.collectionKey)
        let result = try ParticipantDeletionCleanup(defaults: defaults).run(journal: journal())
        XCTAssertEqual(result.removedCreates, 1)
        let remaining = try XCTUnwrap(defaults.array(forKey: UserDefaultsPendingRequestOperationStorage.collectionKey))
        XCTAssertEqual(remaining.first as? String, "opaque neighbor")
        XCTAssertEqual(remaining.count, 2)
    }

    func testMissingAttestationNeverUsesParticipantIDAlone() throws {
        let own = try create(owner: a)
        defaults.set([own], forKey: UserDefaultsPendingRequestOperationStorage.collectionKey)
        var completed = journal()
        completed.context.attestedLedger = nil
        let result = try ParticipantDeletionCleanup(defaults: defaults).run(journal: completed)
        XCTAssertEqual(result.removedCreates, 0)
        XCTAssertEqual(defaults.array(forKey: UserDefaultsPendingRequestOperationStorage.collectionKey) as? [Data], [own])
    }

    func testUpdatesPreserveUnknownFieldsOrderAndMultiplicityAcrossCollidingOperationIDs() throws {
        let own = update(owner: a)
        let foreign = update(owner: b)
        let collision = update(owner: a, ledger: foreignLedger)
        defaults.set(try JSONSerialization.data(withJSONObject: [foreign, own, foreign, collision, own]),
                     forKey: UserDefaultsPendingRequestUpdateStorage.key)
        let result = try ParticipantDeletionCleanup(defaults: defaults).run(journal: journal())
        XCTAssertEqual(result.removedUpdates, 2)
        let data = try XCTUnwrap(defaults.data(forKey: UserDefaultsPendingRequestUpdateStorage.key))
        let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSArray)
        XCTAssertTrue(actual.isEqual(to: [foreign, foreign, collision]))
        XCTAssertEqual(UserDefaultsPendingRequestUpdateStorage(defaults: defaults).load(), .unreadable)
    }

    func testUnreadableWholeUpdateArrayRemainsByteIdentical() throws {
        let original = try JSONSerialization.data(withJSONObject: [update(owner: a), ["undecodable": true]])
        defaults.set(original, forKey: UserDefaultsPendingRequestUpdateStorage.key)
        let result = try ParticipantDeletionCleanup(defaults: defaults).run(journal: journal())
        XCTAssertEqual(result.removedUpdates, 0)
        XCTAssertEqual(defaults.data(forKey: UserDefaultsPendingRequestUpdateStorage.key), original)
        XCTAssertTrue(result.retainedUnavailable)
    }

    func testLegacyCreateAndEmailOnlyPickupAreRetainedUnavailableAcrossReconstruction() throws {
        let legacy = try JSONSerialization.data(withJSONObject: [
            "operationId": "old-operation", "participantIdentifier": a,
            "vendor": "unused", "food": "legacy",
        ])
        let pickup = try JSONEncoder().encode([PendingPlacedPickup(requestID: "request", participantPrincipal: "a@nyu.edu")])
        defaults.set(legacy, forKey: UserDefaultsPendingRequestOperationStorage.singleRecordKey)
        defaults.set(pickup, forKey: UserDefaultsPendingPlacedPickupStorage.key)
        _ = try ParticipantDeletionCleanup(defaults: defaults).run(journal: journal())
        XCTAssertEqual(defaults.data(forKey: UserDefaultsPendingRequestOperationStorage.singleRecordKey), legacy)
        XCTAssertEqual(defaults.data(forKey: UserDefaultsPendingPlacedPickupStorage.key), pickup)
        XCTAssertEqual(UserDefaultsPendingPlacedPickupStorage(defaults: defaults).load(), .unreadable)
    }

    func testCleanupIsIdempotentAndDoesNotTouchInstallationOrScreenshotPreferences() throws {
        defaults.set([try create(owner: a)], forKey: UserDefaultsPendingRequestOperationStorage.collectionKey)
        defaults.set("installation-sentinel", forKey: "installation-credential")
        defaults.set("push-token-sentinel", forKey: "push-token")
        let screenshotPreferences = UserDefaultsScreenshotProposalPreferencesStorage(defaults: defaults)
        screenshotPreferences.grantScreenshotAssistanceConsent()
        screenshotPreferences.hasCompletedScreenshotHelp = true
        let cleanup = ParticipantDeletionCleanup(defaults: defaults)
        let completed = journal()
        _ = try cleanup.run(journal: completed)
        let again = try cleanup.run(journal: completed)
        XCTAssertEqual(again.removedCreates, 0)
        XCTAssertEqual(again.removedUpdates, 0)
        XCTAssertEqual(defaults.string(forKey: "installation-credential"), "installation-sentinel")
        XCTAssertEqual(defaults.string(forKey: "push-token"), "push-token-sentinel")
        XCTAssertTrue(screenshotPreferences.hasValidScreenshotAssistanceConsent)
        XCTAssertTrue(screenshotPreferences.hasCompletedScreenshotHelp)
    }

    func testCleanupRemovesOnlyDeletedParticipantsFirstRequestMarkerAndFencesStaleLedger() throws {
        let ownEntry = try XCTUnwrap(FirstRequestGuidanceLedger.entry(forParticipantIdentifier: a))
        let foreignEntry = try XCTUnwrap(FirstRequestGuidanceLedger.entry(forParticipantIdentifier: b))
        defaults.set([ownEntry, foreignEntry], forKey: FirstRequestGuidanceLedger.defaultsKey)
        let staleLedger = FirstRequestGuidanceLedger(defaults: defaults)

        _ = try ParticipantDeletionCleanup(defaults: defaults).run(journal: journal())

        XCTAssertEqual(defaults.stringArray(forKey: FirstRequestGuidanceLedger.defaultsKey), [foreignEntry])
        XCTAssertFalse(staleLedger.recordGuidanceShown(
            forAuthority: "\(a).1.\(String(repeating: "A", count: 43))",
            currentAuthority: "\(a).1.\(String(repeating: "A", count: 43))",
            deletionFrozen: false
        ))

        let currentLedger = FirstRequestGuidanceLedger(defaults: defaults)
        XCTAssertTrue(currentLedger.showsGuidance(
            forAuthority: "\(a).1.\(String(repeating: "A", count: 43))",
            currentAuthority: "\(a).1.\(String(repeating: "A", count: 43))",
            deletionFrozen: false
        ))
        XCTAssertFalse(currentLedger.showsGuidance(
            forAuthority: "\(b).1.\(String(repeating: "A", count: 43))",
            currentAuthority: "\(b).1.\(String(repeating: "A", count: 43))",
            deletionFrozen: false
        ))
        XCTAssertEqual(defaults.stringArray(forKey: FirstRequestGuidanceLedger.defaultsKey), [foreignEntry])
    }

    func testForeignParticipantCleanupPreservesTheirMarkerAndRejectsDeletedCallback() throws {
        let ownEntry = try XCTUnwrap(FirstRequestGuidanceLedger.entry(forParticipantIdentifier: a))
        let foreignEntry = try XCTUnwrap(FirstRequestGuidanceLedger.entry(forParticipantIdentifier: b))
        defaults.set([ownEntry, foreignEntry], forKey: FirstRequestGuidanceLedger.defaultsKey)
        let staleLedger = FirstRequestGuidanceLedger(defaults: defaults)

        _ = try ParticipantDeletionCleanup(defaults: defaults).run(
            journal: journal(),
            retireUnboundPresentation: false
        )

        XCTAssertEqual(defaults.stringArray(forKey: FirstRequestGuidanceLedger.defaultsKey), [foreignEntry])
        XCTAssertFalse(staleLedger.recordGuidanceShown(
            forAuthority: "\(a).1.\(String(repeating: "A", count: 43))",
            currentAuthority: "\(b).1.\(String(repeating: "A", count: 43))",
            deletionFrozen: false
        ))
        XCTAssertEqual(defaults.stringArray(forKey: FirstRequestGuidanceLedger.defaultsKey), [foreignEntry])
    }

    func testUnreadableGuidanceLedgerBlocksDeletionCleanupWithoutErasingIt() throws {
        let original: [Any] = ["opaque", 7]
        defaults.set(original, forKey: FirstRequestGuidanceLedger.defaultsKey)

        XCTAssertThrowsError(try ParticipantDeletionCleanup(defaults: defaults).run(journal: journal()))

        XCTAssertTrue((defaults.array(forKey: FirstRequestGuidanceLedger.defaultsKey) as NSArray?)?.isEqual(to: original) == true)
        XCTAssertNil(defaults.string(forKey: ParticipantLocalPresentationStorage.generationKey))
    }

    func testMalformedStringGuidanceLedgerBlocksDeletionCleanupWithoutErasingIt() {
        let original = ["not-a-digest", String(repeating: "g", count: 64)]
        defaults.set(original, forKey: FirstRequestGuidanceLedger.defaultsKey)

        XCTAssertThrowsError(try ParticipantDeletionCleanup(defaults: defaults).run(journal: journal()))

        XCTAssertEqual(defaults.stringArray(forKey: FirstRequestGuidanceLedger.defaultsKey), original)
        XCTAssertNil(defaults.string(forKey: ParticipantLocalPresentationStorage.generationKey))
    }

    func testNonCompletedContextCannotAuthorizeCleanup() throws {
        let own = try create(owner: a)
        defaults.set([own], forKey: UserDefaultsPendingRequestOperationStorage.collectionKey)
        XCTAssertThrowsError(try ParticipantDeletionCleanup(defaults: defaults).run(journal: journal(stage: .active)))
        XCTAssertEqual(defaults.array(forKey: UserDefaultsPendingRequestOperationStorage.collectionKey) as? [Data], [own])
    }

    func testFreezePreventsOldOrdinaryWritersAndOperationIDOnlyClears() throws {
        let foreign = try create(owner: b)
        defaults.set([foreign], forKey: UserDefaultsPendingRequestOperationStorage.collectionKey)
        let freeze = ParticipantDeletionFreeze(defaults: defaults)
        let id = UUID().uuidString
        try freeze.write(id)
        UserDefaultsPendingRequestOperationStorage(defaults: defaults).clear(operationId: "collision")
        XCTAssertEqual(defaults.array(forKey: UserDefaultsPendingRequestOperationStorage.collectionKey) as? [Data], [foreign])
        let update = PendingRequestUpdate(
            operationId: "collision", kind: .withdraw, requestID: "request",
            participantIdentifier: a, operationLedger: ledger, editPayload: nil
        )
        XCTAssertFalse(UserDefaultsPendingRequestUpdateStorage(defaults: defaults).save(update))
        XCTAssertFalse(UserDefaultsPendingPlacedPickupStorage(defaults: defaults).save(
            PendingPlacedPickup(requestID: "request", participantPrincipal: "a@nyu.edu")
        ))
        try freeze.remove(id)
    }
}
