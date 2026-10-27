//
//  RequestCreatePendingOperationScopeTests.swift
//  CommonPlateiosTests
//
// W4-D2 corrections: which participant an unresolved request-create
// operation blocks, how per-operation durable storage keeps one participant's
// lifecycle from disturbing another's, how a fresh create's outcome decides
// whether its record survives, and when `Check again` is genuinely available.
// Reuses `RequestFetchingURLProtocol`; ledger authority reads are answered and
// counted separately from its queued requests.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class RequestCreatePendingOperationScopeTests: XCTestCase {
    private let authorityA = "64c0000000000000000000a1.1." + String(repeating: "A", count: 42) + "A"
    private let authorityB = "64c0000000000000000000b2.1." + String(repeating: "B", count: 42) + "A"
    private let participantA = "64c0000000000000000000a1"
    private let participantB = "64c0000000000000000000b2"
    private let baseURL = URL(string: "https://commonplate.test")!

    private static let createPath = "/api/request"
    private static let terminalPath = "/api/request-operation/terminal"

    private var suiteName = ""
    private var defaults = UserDefaults.standard
    /// The participant authority the store sees; tests change it to model
    /// verification, Change Email, and credential loss.
    private var currentAuthority: String?
    private var rejectionCount = 0

    override func setUp() {
        super.setUp()
        suiteName = "RequestCreatePendingOperationScopeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        currentAuthority = nil
        rejectionCount = 0
    }

    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Pending A, participant unavailable

    func testPendingAWithNoParticipantBlocksWithoutACheckAndWithoutANetworkCall() async throws {
        let storage = durableStorage()
        storage.save(record(operationId: "A-PENDING", participant: participantA))
        let store = makeStore(storage: storage)

        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertFalse(didCreate)
        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity, "Never treated as safely unrelated")
        XCTAssertEqual(store.createRecoveryPresentation, .unresolved(canCheckAgain: false))
        XCTAssertTrue(store.hasResolvedPendingCreateStateForRemoval)
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
        XCTAssertEqual(RequestFetchingURLProtocol.capturedOperationLedgerReadCount, 0)
        XCTAssertEqual(storage.loadAll().map(\.operationId), ["A-PENDING"])
    }

    func testVerifyingAAfterLaunchCannotBypassAsUnresolvedOperation() async throws {
        let storage = durableStorage()
        let pending = record(operationId: "A-PENDING", participant: participantA)
        storage.save(pending)
        let store = makeStore(storage: storage)
        _ = await store.reconcilePendingCreateOperationIfNeeded()

        // A verifies (or is restored) later in the session.
        currentAuthority = authorityA
        store.refreshPendingCreateState()

        // The operation becomes A's to check — but nothing is sent merely
        // because the identity arrived.
        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity)
        XCTAssertEqual(store.createRecoveryPresentation, .unresolved(canCheckAgain: true))
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
        XCTAssertEqual(RequestFetchingURLProtocol.capturedOperationLedgerReadCount, 0)

        do {
            try await store.createRequest(payload("A's would-be second request"))
            XCTFail("A must not create past its own unresolved operation")
        } catch RequestServiceError.ambiguousCreateOutcome {}
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
        XCTAssertEqual(storage.loadAll(), [pending])

        // The explicit check reconciles exactly A's operation.
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 201, data: createResponse(id: "a-created")))
        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()
        XCTAssertTrue(didCreate)
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, [Self.createPath])
        XCTAssertEqual(
            RequestFetchingURLProtocol.lastCapturedHeaders?[RequestService.operationIdentityHeader],
            "A-PENDING"
        )
        XCTAssertTrue(storage.loadAll().isEmpty)
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
    }

    func testTheFreshCreateGateReEvaluatesEvenWithoutAnIdentityChangeNotification() async throws {
        let storage = durableStorage()
        storage.save(record(operationId: "A-PENDING", participant: participantA))
        // Launch as B: A's operation is someone else's, so nothing blocks.
        currentAuthority = authorityB
        let store = makeStore(storage: storage)
        _ = await store.reconcilePendingCreateOperationIfNeeded()
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)

        // Change Email to A with no refresh hook having run.
        currentAuthority = authorityA

        do {
            try await store.createRequest(payload("Unrefreshed attempt"))
            XCTFail("The gate must re-derive the block immediately before creating")
        } catch RequestServiceError.ambiguousCreateOutcome {}
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
        XCTAssertEqual(RequestFetchingURLProtocol.capturedOperationLedgerReadCount, 0)
    }

    // MARK: - Pending A, confirmed different participant B

    func testConfirmedBMayCreateWhileAIsPendingAndNeverDisturbsA() async throws {
        let storage = durableStorage()
        let pendingA = record(operationId: "A-PENDING", participant: participantA)
        storage.save(pendingA)
        let bytesA = try XCTUnwrap(collectionEntries().first)
        currentAuthority = authorityB
        let store = makeStore(storage: storage)

        _ = await store.reconcilePendingCreateOperationIfNeeded()
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertEqual(store.createRecoveryPresentation, .none)
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)

        // B's success.
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 201, data: createResponse(id: "b-1")))
        try await store.createRequest(payload("B's first"))
        XCTAssertEqual(collectionEntries(), [bytesA], "B's resolution cleared only B")

        // B's definitive refusal.
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 400,
            data: errorBody(code: RequestOperationErrorCode.invalidRequest)
        ))
        do {
            try await store.createRequest(payload("B's refused"))
            XCTFail("Expected a definitive refusal")
        } catch RequestServiceError.serverError {}
        XCTAssertEqual(collectionEntries(), [bytesA])
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)

        // B's own ambiguous create is kept beside A's, never over it.
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))
        do {
            try await store.createRequest(payload("B's ambiguous"))
            XCTFail("Expected an ambiguous outcome")
        } catch RequestServiceError.ambiguousCreateOutcome {}
        let bOperationId = try XCTUnwrap(
            RequestFetchingURLProtocol.lastCapturedHeaders?[RequestService.operationIdentityHeader]
        )
        let afterB = storage.loadAll()
        XCTAssertEqual(afterB.count, 2)
        XCTAssertEqual(afterB.first(where: { $0.operationId == "A-PENDING" }), pendingA)
        XCTAssertEqual(afterB.first(where: { $0.operationId == bOperationId })?.participantIdentifier, participantB)
        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity, "B is blocked by its own operation")
        XCTAssertEqual(store.createRecoveryPresentation, .unresolved(canCheckAgain: true))

        // B's recovery sends only B's operation and retires only B's.
        RequestFetchingURLProtocol.reset()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 201, data: createResponse(id: "b-2")))
        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()
        XCTAssertTrue(didCreate)
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, [Self.createPath])
        XCTAssertEqual(
            RequestFetchingURLProtocol.lastCapturedHeaders?[RequestService.operationIdentityHeader],
            bOperationId
        )
        XCTAssertEqual(collectionEntries(), [bytesA], "A survives B's whole lifecycle byte for byte")
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)

        // Back to A: A's exact recovery is intact.
        currentAuthority = authorityA
        store.refreshPendingCreateState()
        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity)
        XCTAssertEqual(store.createRecoveryPresentation, .unresolved(canCheckAgain: true))
        RequestFetchingURLProtocol.reset()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 201, data: createResponse(id: "a-1")))
        let aCreated = await store.reconcilePendingCreateOperationIfNeeded()
        XCTAssertTrue(aCreated)
        XCTAssertEqual(
            RequestFetchingURLProtocol.lastCapturedHeaders?[RequestService.operationIdentityHeader],
            "A-PENDING"
        )
        let sent = try XCTUnwrap(RequestFetchingURLProtocol.lastCapturedBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: Any])
        // W4-R4 sends structured `{ name, details }` objects on the wire, not
        // bare strings.
        let mealItemsJSON = try XCTUnwrap(json["mealItems"] as? [[String: Any]])
        let decodedMealItems = try mealItemsJSON.map { entry -> MealItem in
            MealItem(name: try XCTUnwrap(entry["name"] as? String), details: entry["details"] as? String)
        }
        XCTAssertEqual(decodedMealItems, ["A-PENDING meal"], "A's exact payload, never merged")
        XCTAssertTrue(storage.loadAll().isEmpty)
    }

    func testAnUnreadableEntryBesideReadableOnesBlocksEveryParticipantAndIsNeverCleared() async throws {
        let storage = durableStorage()
        storage.save(record(operationId: "A-PENDING", participant: participantA))
        var entries = collectionEntries()
        entries.append(Data("not a record".utf8))
        defaults.set(entries, forKey: UserDefaultsPendingRequestOperationStorage.collectionKey)

        for authority in [nil, authorityB] as [String?] {
            currentAuthority = authority
            let store = makeStore(storage: storage)
            _ = await store.reconcilePendingCreateOperationIfNeeded()
            XCTAssertEqual(store.createRecoveryPresentation, .identityUnavailable)
            XCTAssertTrue(store.hasUnresolvedCreateAmbiguity)
        }
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)

        // A's own readable operation can still be resolved exactly; the
        // unreadable entry is never touched and keeps everything blocked.
        currentAuthority = authorityA
        let store = makeStore(storage: storage)
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 201, data: createResponse(id: "a-1")))
        _ = await store.reconcilePendingCreateOperationIfNeeded()
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, [Self.createPath])
        XCTAssertEqual(collectionEntries(), [Data("not a record".utf8)])
        XCTAssertEqual(store.createRecoveryPresentation, .identityUnavailable)
        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity)
    }

    // MARK: - Remove Email follows the current participant

    func testRemoveEmailBlockingFollowsTheCurrentParticipantAndUnavailableIdentity() async throws {
        let storage = durableStorage()
        storage.save(record(operationId: "A-PENDING", participant: participantA))
        currentAuthority = authorityB
        let store = makeStore(storage: storage)
        _ = await store.reconcilePendingCreateOperationIfNeeded()
        XCTAssertTrue(store.hasResolvedPendingCreateStateForRemoval)
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity, "B's Remove Email is not blocked by A")

        currentAuthority = authorityA
        store.refreshPendingCreateState()
        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity, "A's Remove Email is blocked")

        currentAuthority = nil
        store.refreshPendingCreateState()
        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity, "Unknown relationship stays blocked")

        currentAuthority = authorityB
        store.refreshPendingCreateState()
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)

        defaults.set(
            collectionEntries() + [Data("{}".utf8)],
            forKey: UserDefaultsPendingRequestOperationStorage.collectionKey
        )
        store.refreshPendingCreateState()
        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity, "Unavailable identity blocks B too")
    }

    // MARK: - Per-operation storage

    func testStorageRetiresOnlyTheNamedReadableOperation() throws {
        let storage = durableStorage()
        let a = record(operationId: "A-1", participant: participantA)
        let b = record(operationId: "B-1", participant: participantB)
        XCTAssertTrue(storage.save(a))
        XCTAssertTrue(storage.save(b))
        XCTAssertEqual(Set(storage.loadAll().map(\.operationId)), ["A-1", "B-1"])

        storage.clear(operationId: "B-1")
        XCTAssertEqual(storage.loadAll(), [a])
        storage.clear(operationId: "UNKNOWN")
        XCTAssertEqual(storage.loadAll(), [a])

        // An earlier build's single record is one more entry, retired only
        // by its own identity and never rewritten.
        let legacy = #"{"operationId":"LEGACY-1","participantIdentifier":"64c0000000000000000000b2","payload":{"vendor":"Jasper Kane Cafe","timing":"asap","menuPath":"meal-exchange","mealSwipes":1,"mealItems":["x"]}}"#
        defaults.set(Data(legacy.utf8), forKey: UserDefaultsPendingRequestOperationStorage.singleRecordKey)
        XCTAssertEqual(storage.restoreAll().count, 2)
        storage.clear(operationId: "A-1")
        XCTAssertEqual(storage.restoreAll().count, 1)
        XCTAssertNotNil(defaults.data(forKey: UserDefaultsPendingRequestOperationStorage.singleRecordKey))
        XCTAssertNil(defaults.object(forKey: UserDefaultsPendingRequestOperationStorage.collectionKey))
        storage.clear(operationId: "LEGACY-1")
        XCTAssertTrue(storage.restoreAll().isEmpty)

        // An unreadable single record is never matched.
        defaults.set(Data("garbage".utf8), forKey: UserDefaultsPendingRequestOperationStorage.singleRecordKey)
        storage.clear(operationId: "garbage")
        XCTAssertEqual(storage.restoreAll(), [.identityUnavailable])
    }

    func testAnUnreadableContainerIsNeverReplacedToMakeRoom() {
        let storage = durableStorage()
        defaults.set("not an array", forKey: UserDefaultsPendingRequestOperationStorage.collectionKey)
        XCTAssertEqual(storage.restoreAll(), [.identityUnavailable])

        XCTAssertFalse(storage.save(record(operationId: "A-1", participant: participantA)))
        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsPendingRequestOperationStorage.collectionKey),
            "not an array"
        )
        storage.clear(operationId: "A-1")
        XCTAssertEqual(storage.restoreAll(), [.identityUnavailable])
    }

    // MARK: - Fresh create outcomes never leave a silent record

    func testAFreshCreateRecordsAndSendsTheLedgerItReadFirst() async throws {
        let storage = RecordingStorage()
        currentAuthority = authorityA
        let store = makeStore(storage: storage)
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 201, data: createResponse(id: "fresh")))

        try await store.createRequest(payload("Fresh"))

        XCTAssertEqual(RequestFetchingURLProtocol.capturedOperationLedgerReadCount, 1)
        let saved = try XCTUnwrap(storage.savedRecords.first)
        XCTAssertEqual(saved.operationAuthority, RequestOperationAuthorityIdentity(
            origin: "https://commonplate.test:443",
            ledger: RequestFetchingURLProtocol.defaultOperationLedger
        ))
        let headers = try XCTUnwrap(RequestFetchingURLProtocol.lastCapturedHeaders)
        XCTAssertEqual(headers[RequestService.operationAuthorityHeader], saved.operationAuthority.ledger)
        XCTAssertEqual(headers[RequestService.operationIdentityHeader], saved.operationId)
        XCTAssertTrue(storage.inner.restoreAll().isEmpty)
    }

    func testAnUnreadableLedgerBeforeAFreshCreateSendsAndRecordsNothing() async throws {
        let cases: [(String, RequestFetchingURLProtocol.Stub)] = [
            ("transport", .failure(.networkConnectionLost)),
            ("unavailable", .response(statusCode: 503, data: errorBody(code: RequestOperationErrorCode.operationAuthorityUnavailable))),
            ("absent route", .response(statusCode: 404, data: Data("Cannot GET".utf8))),
            ("malformed", RequestFetchingURLProtocol.operationLedgerResponse("nope")),
        ]
        for (label, stub) in cases {
            RequestFetchingURLProtocol.reset()
            let storage = RecordingStorage()
            currentAuthority = authorityA
            let store = makeStore(storage: storage)
            RequestFetchingURLProtocol.enqueueOperationLedger(stub)

            do {
                try await store.createRequest(payload("Never sent"))
                XCTFail("Expected a failure: \(label)")
            } catch let error as RequestServiceError {
                if case .ambiguousCreateOutcome = error {
                    XCTFail("Nothing was sent, so nothing is ambiguous: \(label)")
                }
                XCTAssertEqual(RequestCreatePresentationError.map(error), .creationFailed, label)
            }
            XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty, label)
            XCTAssertTrue(storage.savedRecords.isEmpty, label)
            XCTAssertFalse(store.hasUnresolvedCreateAmbiguity, label)
            XCTAssertFalse(store.isCreating, label)
        }
    }

    func testAFreshCreateWithoutAParticipantIdentifierReadsNoLedgerAndNamesNone() async throws {
        currentAuthority = nil
        let storage = RecordingStorage()
        let store = makeStore(storage: storage)
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 401,
            data: errorBody(code: ParticipantErrorCode.verificationRequired)
        ))

        do {
            try await store.createRequest(payload("Unverified"))
            XCTFail("Expected a refusal")
        } catch RequestServiceError.serverError {}

        XCTAssertEqual(RequestFetchingURLProtocol.capturedOperationLedgerReadCount, 0)
        XCTAssertNil(RequestFetchingURLProtocol.lastCapturedHeaders?[RequestService.operationAuthorityHeader])
        XCTAssertTrue(storage.savedRecords.isEmpty)
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
    }

    func testPreLedgerRefusalsRetireTheFreshRecordWithoutBlocking() async throws {
        let codes = [
            RequestOperationErrorCode.publicActionsPaused,
            ParticipantErrorCode.verificationRequired,
            ParticipantErrorCode.verificationUnavailable,
            ParticipantErrorCode.authorityInvalid,
            RequestOperationErrorCode.operationAuthorityMismatch,
            RequestOperationErrorCode.operationAuthorityUnavailable,
        ]
        for code in codes {
            RequestFetchingURLProtocol.reset()
            let storage = RecordingStorage()
            currentAuthority = authorityA
            rejectionCount = 0
            let store = makeStore(storage: storage)
            RequestFetchingURLProtocol.enqueue(.response(statusCode: 409, data: errorBody(code: code)))

            do {
                try await store.createRequest(payload("Refused before the ledger"))
                XCTFail("Expected a refusal: \(code)")
            } catch RequestServiceError.serverError(let received, _) {
                XCTAssertEqual(received, code)
            }

            XCTAssertEqual(storage.savedRecords.count, 1, code)
            XCTAssertTrue(storage.inner.restoreAll().isEmpty, "Proven non-create is retired: \(code)")
            XCTAssertFalse(store.hasUnresolvedCreateAmbiguity, code)
            XCTAssertEqual(store.createRecoveryPresentation, .none, code)
            XCTAssertEqual(rejectionCount, code == ParticipantErrorCode.authorityInvalid ? 1 : 0, code)
        }
    }

    func testAnUnclassifiedFreshAnswerKeepsTheRecordAndBlocks() async throws {
        let storage = RecordingStorage()
        currentAuthority = authorityA
        let store = makeStore(storage: storage)
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 500, data: errorBody(code: "SOMETHING_NEW")))

        do {
            try await store.createRequest(payload("Unclassified"))
            XCTFail("Expected a refusal")
        } catch RequestServiceError.serverError {}

        XCTAssertEqual(storage.inner.restoreAll().count, 1, "Not proven non-create, so kept")
        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity)
        XCTAssertEqual(store.createRecoveryPresentation, .unresolved(canCheckAgain: true))
    }

    func testTheCreateBeingPostedIsNotItsOwnBlock() async throws {
        let storage = durableStorage()
        currentAuthority = authorityA
        let store = makeStore(storage: storage)
        let gate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 201, data: createResponse(id: "gated"), gate: gate))

        let task = Task { try await store.createRequest(payload("In flight")) }
        try await waitUntil { gate.isWaiting }
        XCTAssertEqual(storage.loadAll().count, 1, "Recorded before transmission")

        // An identity notification or a launch reconciliation while posting.
        store.refreshPendingCreateState()
        let reconciled = await store.reconcilePendingCreateOperationIfNeeded()
        XCTAssertFalse(reconciled)
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertEqual(store.createRecoveryPresentation, .none)

        gate.open()
        try await task.value
        XCTAssertTrue(storage.loadAll().isEmpty)
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, [Self.createPath])
    }

    // MARK: - Check again tracks usable exact authority

    func testARejectedCredentialHidesCheckAgainUntilMatchingAuthorityReturns() async throws {
        let storage = durableStorage()
        // Unreadable payload, so recovery uses terminal reconciliation.
        let json = #"{"recoveryVersion":2,"operationId":"A-CHECK","participantIdentifier":"64c0000000000000000000a1","authorityOrigin":"https://commonplate.test:443","authorityLedger":"\#(RequestFetchingURLProtocol.defaultOperationLedger)","payloadVersion":1,"payload":null}"#
        defaults.set([Data(json.utf8)], forKey: UserDefaultsPendingRequestOperationStorage.collectionKey)
        currentAuthority = authorityA
        let store = makeStore(storage: storage, discardOnRejection: true)
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 401,
            data: errorBody(code: ParticipantErrorCode.authorityInvalid)
        ))

        _ = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertEqual(rejectionCount, 1)
        XCTAssertNil(currentAuthority)
        XCTAssertEqual(collectionEntries(), [Data(json.utf8)], "Pending operation retained")
        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity, "Create and Remove Email stay blocked")
        XCTAssertEqual(store.createRecoveryPresentation, .unresolved(canCheckAgain: false))
        XCTAssertNil(
            RequestFoodView.recoveryCopy(for: store.createRecoveryPresentation)?.actionLabel,
            "No Check again while no authenticated exact call is possible"
        )
        let pathsAfterRejection = RequestFetchingURLProtocol.capturedRequestedPaths
        let ledgerReadsAfterRejection = RequestFetchingURLProtocol.capturedOperationLedgerReadCount

        // Another tap cannot make a meaningless call.
        _ = await store.reconcilePendingCreateOperationIfNeeded()
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, pathsAfterRejection)
        XCTAssertEqual(RequestFetchingURLProtocol.capturedOperationLedgerReadCount, ledgerReadsAfterRejection)
        XCTAssertEqual(store.createRecoveryPresentation, .unresolved(canCheckAgain: false))

        // A different participant verifying does not make it checkable.
        currentAuthority = authorityB
        store.refreshPendingCreateState()
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertEqual(store.createRecoveryPresentation, .none)

        // Matching authority restored: eligibility recomputes, nothing is
        // sent automatically.
        currentAuthority = authorityA
        store.refreshPendingCreateState()
        XCTAssertEqual(store.createRecoveryPresentation, .unresolved(canCheckAgain: true))
        XCTAssertEqual(
            RequestFoodView.recoveryCopy(for: store.createRecoveryPresentation)?.actionLabel,
            RequestFoodView.checkAgainLabel
        )
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, pathsAfterRejection)
        XCTAssertEqual(RequestFetchingURLProtocol.capturedOperationLedgerReadCount, ledgerReadsAfterRejection)

        // The explicit check then performs exact reconciliation.
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: Data(#"{"outcome":"not-created"}"#.utf8)))
        _ = await store.reconcilePendingCreateOperationIfNeeded()
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            pathsAfterRejection + [Self.terminalPath]
        )
        XCTAssertEqual(
            RequestFetchingURLProtocol.lastCapturedHeaders?[RequestService.operationIdentityHeader],
            "A-CHECK"
        )
        XCTAssertEqual(
            RequestFetchingURLProtocol.lastCapturedHeaders?[RequestService.participantAuthorityHeader],
            authorityA
        )
        XCTAssertNil(defaults.object(forKey: UserDefaultsPendingRequestOperationStorage.collectionKey))
        // Path B: this record's payload was never readable.
        XCTAssertEqual(store.createRecoveryPresentation, .notCreatedUnavailable)
    }

    func testARejectionDuringAFreshCreateLeavesAnOlderPendingOperationBlockingWithoutCheck() async throws {
        let storage = durableStorage()
        storage.save(record(operationId: "A-OLD", participant: participantA))
        currentAuthority = authorityB
        let store = makeStore(storage: storage, discardOnRejection: true)
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 401,
            data: errorBody(code: ParticipantErrorCode.authorityInvalid)
        ))

        do {
            try await store.createRequest(payload("B refused"))
            XCTFail("Expected a refusal")
        } catch RequestServiceError.serverError {}

        XCTAssertNil(currentAuthority)
        XCTAssertEqual(storage.loadAll().map(\.operationId), ["A-OLD"], "B's own record retired, A's kept")
        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity)
        XCTAssertEqual(store.createRecoveryPresentation, .unresolved(canCheckAgain: false))
    }

    func testTheAppRederivesTheBlockWheneverParticipantIdentityChanges() throws {
        // Source inspection only: `ContentView` is the one place the live
        // identity store and request store meet.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("CommonPlateios/ContentView.swift"),
            encoding: .utf8
        )
        let hook = try XCTUnwrap(source.range(of: ".onChange(of: participantIdentityStore.identity) { _, _ in"))
        let body = source[hook.upperBound...].prefix(120)
        XCTAssertTrue(body.contains("requestStore.refreshPendingCreateState()"))
        XCTAssertFalse(body.contains("reconcilePendingCreateOperationIfNeeded"), "Identity arriving never reconciles by itself")
    }

    // MARK: - Helpers

    private func durableStorage() -> UserDefaultsPendingRequestOperationStorage {
        UserDefaultsPendingRequestOperationStorage(defaults: defaults)
    }

    private func collectionEntries() -> [Data] {
        (defaults.array(forKey: UserDefaultsPendingRequestOperationStorage.collectionKey) ?? [])
            .compactMap { $0 as? Data }
    }

    private func makeStore(
        storage: PendingRequestOperationStorage,
        discardOnRejection: Bool = false
    ) -> RequestStore {
        RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { [unowned self] in self.currentAuthority },
            participantAuthorityRejected: { [unowned self] in
                self.rejectionCount += 1
                if discardOnRejection {
                    self.currentAuthority = nil
                }
            },
            operationStorage: storage
        )
    }

    private func makeService() -> RequestService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        return RequestService(client: APIClient(
            configuration: APIConfiguration(baseURL: baseURL),
            session: URLSession(configuration: configuration)
        ))
    }

    private func record(operationId: String, participant: String) -> PendingRequestOperationRecord {
        PendingRequestOperationRecord(
            operationId: operationId,
            participantIdentifier: participant,
            operationAuthority: RequestOperationAuthorityIdentity(
                origin: RequestService.operationAuthorityOrigin(for: baseURL),
                ledger: RequestFetchingURLProtocol.defaultOperationLedger
            ),
            payload: payload("\(operationId) meal")
        )
    }

    private func payload(_ meal: String) -> CreateRequestPayload {
        CreateRequestPayload(
            vendor: "Jasper Kane Cafe",
            timing: .asap,
            windowStart: nil,
            menuPath: .mealExchange,
            mealSwipes: 1,
            mealItems: [MealItem(name: meal)],
            orderDetails: nil,
            estimatedDiningDollarsCents: nil
        )
    }

    private func createResponse(id: String) -> Data {
        Data("""
        {"request":{"id":"\(id)","vendor":"Jasper Kane Cafe","food":"Meal","pickupWindowText":"ASAP","mealSwipes":1,"menuPath":"meal-exchange","mealItems":["Meal"],"orderDetails":null,"estimatedDiningDollarsCents":null,"windowStart":null,"windowEnd":null,"status":"open","createdAt":"2026-09-16T17:00:00.000Z","expiresAt":"2026-09-16T20:00:00.000Z"}}
        """.utf8)
    }

    private func errorBody(code: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"backend detail"}}"#.utf8)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}

/// Records every save while delegating to the in-memory storage.
private final class RecordingStorage: PendingRequestOperationStorage {
    let inner = InMemoryPendingRequestOperationStorage()
    private(set) var savedRecords: [PendingRequestOperationRecord] = []

    func restoreAll() -> [PendingRequestOperationEntry] {
        inner.restoreAll()
    }

    func save(_ record: PendingRequestOperationRecord) -> Bool {
        savedRecords.append(record)
        return inner.save(record)
    }

    func clear(operationId: String) {
        inner.clear(operationId: operationId)
    }
}
