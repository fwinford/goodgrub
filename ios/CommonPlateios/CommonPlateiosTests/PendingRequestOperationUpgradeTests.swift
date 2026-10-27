//
//  PendingRequestOperationUpgradeTests.swift
//  CommonPlateiosTests
//
// Upgrade coverage for W3-D1 durable request-create recovery across record
// shapes written by earlier builds: the pre-R4 flat record and the pre-D2 R4
// record (`payload` nested, no recovery envelope). Every fixture below is
// literal JSON in the exact shape those encoders wrote.
//
// W4-D2: both shapes still restore their stable recovery identity, but
// neither recorded the backend authority that received the create, so no
// answer from any authority can resolve them (recovery matrix row 8). They
// fail closed — no network call, no clear, a new logical create and Remove
// Email stay blocked, and no check action is offered.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class PendingRequestOperationUpgradeTests: XCTestCase {
    private let authorityA = "64c0000000000000000000a1.1." + String(repeating: "A", count: 42) + "A"
    private let authorityB = "64c0000000000000000000b2.1." + String(repeating: "B", count: 42) + "A"

    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        suiteName = "PendingRequestOperationUpgradeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Literal pre-D2 fixtures

    /// Byte-for-byte the shape the pre-R4 encoder produced for an ASAP
    /// request: flat create fields, `windowStart` omitted because it was nil.
    private let legacyAsapJSON = #"""
    {"operationId":"LEGACY-ASAP-0001","participantIdentifier":"64c0000000000000000000a1","vendor":"Jasper Kane Cafe","food":"Chicken over rice","pickupName":"Test Requester","timing":"asap","mealSwipes":2}
    """#

    /// A pre-R4 scheduled record, `windowStart` in the storage encoder's
    /// `.iso8601` form.
    private let legacyScheduledJSON = #"""
    {"operationId":"LEGACY-SCHEDULED-0002","participantIdentifier":"64c0000000000000000000a1","vendor":"Jasper Kane Cafe","food":"Two falafel wraps","pickupName":"Test Requester","timing":"scheduled","windowStart":"2026-08-10T19:00:00Z","mealSwipes":3}
    """#

    /// The pre-D2 R4 record: identity at top level, frozen payload nested,
    /// no recovery version and no recorded authority.
    private let preD2CurrentJSON = #"""
    {"operationId":"R4-PRE-D2-0003","participantIdentifier":"64c0000000000000000000a1","payload":{"vendor":"Jasper Kane Cafe","timing":"asap","menuPath":"meal-exchange","mealSwipes":1,"mealItems":["Bagel"]}}
    """#

    /// Earlier builds kept their one record under the single-record key.
    private func writeRaw(_ json: String) {
        defaults.set(Data(json.utf8), forKey: UserDefaultsPendingRequestOperationStorage.singleRecordKey)
    }

    private var rawStoredValue: Data? {
        defaults.data(forKey: UserDefaultsPendingRequestOperationStorage.singleRecordKey)
    }

    private func preD2Identity(_ operationId: String) -> PendingRequestOperationIdentity {
        PendingRequestOperationIdentity(
            operationId: operationId,
            participantIdentifier: "64c0000000000000000000a1",
            operationAuthority: nil
        )
    }

    // MARK: - Restoration recovers identity from every earlier shape

    func testRestorationRecoversIdentityFromLegacyAndPreD2Records() throws {
        let storage = UserDefaultsPendingRequestOperationStorage(defaults: defaults)
        XCTAssertEqual(storage.restore(), .absent)

        writeRaw(legacyAsapJSON)
        XCTAssertEqual(storage.restore(), .restored(RestoredPendingRequestOperation(
            identity: preD2Identity("LEGACY-ASAP-0001"),
            payload: .legacy(LegacyCreateRequestPayload(
                vendor: "Jasper Kane Cafe",
                food: "Chicken over rice",
                pickupName: "Test Requester",
                timing: .asap,
                windowStart: nil,
                mealSwipes: 2
            ))
        )))
        // The current-only convenience never reports a legacy record.
        XCTAssertNil(storage.load())

        writeRaw(preD2CurrentJSON)
        XCTAssertEqual(storage.restore(), .restored(RestoredPendingRequestOperation(
            identity: preD2Identity("R4-PRE-D2-0003"),
            payload: .current(CreateRequestPayload(
                vendor: "Jasper Kane Cafe",
                timing: .asap,
                windowStart: nil,
                menuPath: .mealExchange,
                mealSwipes: 1,
                mealItems: ["Bagel"],
                orderDetails: nil,
                estimatedDiningDollarsCents: nil
            ))
        )))
        // No recorded authority, so not a record this build wrote.
        XCTAssertNil(storage.load())
    }

    func testAPreD2RecordWhosePayloadCannotBeReadStillRestoresItsIdentity() {
        let storage = UserDefaultsPendingRequestOperationStorage(defaults: defaults)
        for (json, operationId) in [
            // Claims the R4 representation but its payload is malformed: it
            // is never retried as a legacy record.
            (#"{"operationId":"X1","participantIdentifier":"64c0000000000000000000a1","payload":{"vendor":"Jasper Kane Cafe"}}"#, "X1"),
            // Flat, but missing a pre-R4 field: not a legacy record either.
            (#"{"operationId":"X2","participantIdentifier":"64c0000000000000000000a1","vendor":"Jasper Kane Cafe","food":"Bagel","timing":"asap","mealSwipes":1}"#, "X2"),
        ] {
            writeRaw(json)
            XCTAssertEqual(
                storage.restore(),
                .restored(RestoredPendingRequestOperation(
                    identity: preD2Identity(operationId),
                    payload: .unreadable
                )),
                json
            )
        }
    }

    func testRecordsWithNoReadableIdentityAreIdentityUnavailableNeverAbsent() {
        let storage = UserDefaultsPendingRequestOperationStorage(defaults: defaults)
        for unreadable in [
            "not json at all",
            "[1,2,3]",
            #"{}"#,
            #"{"participantIdentifier":"64c0000000000000000000a1","payload":{"vendor":"Jasper Kane Cafe"}}"#,
            #"{"operationId":"X","payload":{"vendor":"Jasper Kane Cafe"}}"#,
            #"{"operationId":7,"participantIdentifier":"64c0000000000000000000a1"}"#,
        ] {
            writeRaw(unreadable)
            XCTAssertEqual(storage.restore(), .identityUnavailable, "Expected identity unavailable: \(unreadable)")
        }

        defaults.set("a string, not data", forKey: UserDefaultsPendingRequestOperationStorage.singleRecordKey)
        XCTAssertEqual(storage.restore(), .identityUnavailable)
    }

    // MARK: - Pre-D2 records fail closed (matrix row 8)

    func testPreD2RecordsAreNeverSentAnywhereAndStayBlocking() async throws {
        for json in [legacyAsapJSON, legacyScheduledJSON, preD2CurrentJSON] {
            RequestFetchingURLProtocol.reset()
            writeRaw(json)
            let originalBytes = try XCTUnwrap(rawStoredValue)
            let store = makeStore(
                authority: authorityA,
                operationStorage: UserDefaultsPendingRequestOperationStorage(defaults: defaults)
            )
            // Nothing is enqueued: any request at all would be visible below.

            let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

            XCTAssertFalse(didCreate, json)
            XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty, "No replay and no terminalization: \(json)")
            XCTAssertEqual(RequestFetchingURLProtocol.capturedOperationLedgerReadCount, 0, "No authority read either: \(json)")
            XCTAssertEqual(rawStoredValue, originalBytes, "Never cleared or rewritten: \(json)")
            XCTAssertTrue(store.hasUnresolvedCreateAmbiguity, json)
            XCTAssertTrue(store.hasResolvedPendingCreateStateForRemoval, json)
            // Known identity, but no check from here can change the answer.
            XCTAssertEqual(store.createRecoveryPresentation, .unresolved(canCheckAgain: false), json)

            // Repeated reconciliation still sends nothing.
            _ = await store.reconcilePendingCreateOperationIfNeeded()
            XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty, json)

            // And no new logical create can begin beside it.
            do {
                try await store.createRequest(structuredPayload())
                XCTFail("A new logical create must be blocked: \(json)")
            } catch RequestServiceError.ambiguousCreateOutcome {
                // Expected.
            }
            XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty, json)
            XCTAssertEqual(rawStoredValue, originalBytes, json)
        }
    }

    func testLegacyRecordForAnotherParticipantIsLeftUntouchedAndNotSent() async throws {
        writeRaw(legacyAsapJSON)
        let originalBytes = try XCTUnwrap(rawStoredValue)
        let store = makeStore(
            authority: authorityB,
            operationStorage: UserDefaultsPendingRequestOperationStorage(defaults: defaults)
        )

        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertFalse(didCreate)
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
        XCTAssertEqual(rawStoredValue, originalBytes)
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertEqual(store.createRecoveryPresentation, .none)
    }

    // MARK: - Unreadable identity fails closed (matrix row 7)

    func testUnreadableIdentityFailsClosedWithoutNetworkOrClear() async throws {
        let unreadable = #"{"participantIdentifier":"64c0000000000000000000a1","payload":{"vendor":"Jasper Kane Cafe"}}"#
        writeRaw(unreadable)
        let store = makeStore(
            authority: authorityA,
            operationStorage: UserDefaultsPendingRequestOperationStorage(defaults: defaults)
        )

        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertFalse(didCreate)
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty, "No network guess")
        XCTAssertEqual(RequestFetchingURLProtocol.capturedOperationLedgerReadCount, 0, "No network guess")
        XCTAssertEqual(rawStoredValue, Data(unreadable.utf8), "Unreadable state is never cleared or rewritten")
        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity)
        XCTAssertEqual(store.createRecoveryPresentation, .identityUnavailable)
        XCTAssertTrue(
            store.hasResolvedPendingCreateStateForRemoval,
            "Readiness is determined — and the unresolved block keeps Remove Email unavailable"
        )

        do {
            try await store.createRequest(structuredPayload())
            XCTFail("A new logical create must be blocked by unreadable pending state")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected.
        }
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
        XCTAssertEqual(rawStoredValue, Data(unreadable.utf8))

        _ = await store.reconcilePendingCreateOperationIfNeeded()
        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity)
        XCTAssertEqual(store.createRecoveryPresentation, .identityUnavailable)
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
    }

    func testCorruptBytesFailClosedForEveryParticipant() async throws {
        writeRaw("\u{0}\u{1}not json")
        let store = makeStore(
            authority: authorityB,
            operationStorage: UserDefaultsPendingRequestOperationStorage(defaults: defaults)
        )

        _ = await store.reconcilePendingCreateOperationIfNeeded()

        // Whose operation it is cannot be read, so it cannot be dismissed as
        // someone else's.
        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity)
        XCTAssertEqual(store.createRecoveryPresentation, .identityUnavailable)
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
        XCTAssertNotNil(rawStoredValue)
    }

    // MARK: - Helpers

    private func structuredPayload() -> CreateRequestPayload {
        CreateRequestPayload(
            vendor: "Jasper Kane Cafe",
            timing: .asap,
            windowStart: nil,
            menuPath: .mealExchange,
            mealSwipes: 1,
            mealItems: ["Would-be second"],
            orderDetails: nil,
            estimatedDiningDollarsCents: nil
        )
    }

    private func makeStore(
        authority: String?,
        operationStorage: PendingRequestOperationStorage
    ) -> RequestStore {
        RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { authority },
            participantAuthorityRejected: {},
            operationStorage: operationStorage
        )
    }

    private func makeService() -> RequestService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
        return RequestService(client: client)
    }
}
