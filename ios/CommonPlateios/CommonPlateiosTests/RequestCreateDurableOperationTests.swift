//
//  RequestCreateDurableOperationTests.swift
//  CommonPlateiosTests
//
// Focused W3-D1 Pass 2 coverage: the exact logical request-create operation
// identity, its durable recovery record, and relaunch reconciliation. Reuses
// `RequestFetchingURLProtocol` from `RequestFetchingTests.swift` — the same
// stubbed-transport double every other request-flow test file already uses —
// rather than inventing a second one.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class RequestCreateDurableOperationTests: XCTestCase {
    /// Two distinct verified participants. Only the leading (participant-ID)
    /// segment before the first "." matters to `RequestStore`'s binding
    /// check; the remainder is shape filler.
    private let authorityA = "64c0000000000000000000a1.1." + String(repeating: "A", count: 42) + "A"
    private let authorityB = "64c0000000000000000000b2.1." + String(repeating: "B", count: 42) + "A"
    private let participantIdentifierA = "64c0000000000000000000a1"
    /// W4-D2: the authority `makeService()` sends to, as a pending record
    /// written by this build records it — its origin and the ledger
    /// `RequestFetchingURLProtocol` reports by default.
    private let operationAuthority = RequestOperationAuthorityIdentity(
        origin: RequestService.operationAuthorityOrigin(for: URL(string: "https://commonplate.test")!),
        ledger: RequestFetchingURLProtocol.defaultOperationLedger
    )

    /// A fresh `UserDefaults` suite per test, removed in `tearDown` — matching
    /// `PushInstallationStorageTests`/`AlertSignupPresentationTests`: nothing
    /// here can read or write the developer's real preferences (required
    /// proof: persistence isolated in tests).
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        suiteName = "RequestCreateDurableOperationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Ordinary success retires durable state (proofs 1, 2, 3)

    func testOrdinarySuccessfulCreateSendsOneValidOperationHeaderAndRetiresDurableState() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: requestObject(food: "Fresh create food"))
        ))

        try await store.createRequest(asapPayload(food: "Fresh create food"))

        let headers = try XCTUnwrap(RequestFetchingURLProtocol.lastCapturedHeaders)
        let sentOperationId = try XCTUnwrap(headers[RequestService.operationIdentityHeader])
        XCTAssertTrue(Self.looksLikeAValidOperationId(sentOperationId))
        XCTAssertNil(storage.load())
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        // W4-D2 Success→Home continuity (narrowly supersedes the W4-R2
        // 2026-09-05 sync item 5 behavior this replaces): a fresh create now
        // inserts immediately, ownership-resolved `.own`, so the
        // Success→Home continuity sequence has a real, correctly-slotted
        // Home card to land on without waiting for H4's own authoritative
        // fetch.
        XCTAssertEqual(store.requests.map(\.id), ["64b0000000000000000000a1"])
        XCTAssertTrue(store.requests[0].isOwnRequest)
        XCTAssertEqual(store.createdRequestContinuity?.request.id, "64b0000000000000000000a1")
    }

    // MARK: - Ambiguous transport persists the exact operation and blocks a
    // second ordinary create (proofs 5, 10, 14)

    func testAmbiguousTransportPersistsExactOperationAndBlocksSecondCreate() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))

        do {
            try await store.createRequest(asapPayload(food: "Ambiguous distinct food", mealSwipes: 4))
            XCTFail("Transport loss after submission should be ambiguous")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected.
        }

        let headers = try XCTUnwrap(RequestFetchingURLProtocol.lastCapturedHeaders)
        let sentOperationId = try XCTUnwrap(headers[RequestService.operationIdentityHeader])
        XCTAssertTrue(Self.looksLikeAValidOperationId(sentOperationId))

        let record = try XCTUnwrap(storage.load())
        XCTAssertEqual(record, PendingRequestOperationRecord(
            operationId: sentOperationId,
            participantIdentifier: participantIdentifierA,
            operationAuthority: operationAuthority,
            payload: CreateRequestPayload(
                vendor: "Jasper Kane Cafe",
                timing: .asap,
                windowStart: nil,
                menuPath: .mealExchange,
                mealSwipes: 4,
                mealItems: [
                    "Ambiguous distinct food", "Additional meal 1",
                    "Additional meal 2", "Additional meal 3",
                ],
                orderDetails: nil,
                estimatedDiningDollarsCents: nil
            )
        ))
        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity)

        // A second ordinary submission — including one whose transport would
        // have succeeded — must never reach the network while the durable
        // operation is unresolved.
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: requestObject(food: "Would-be second request"))
        ))
        do {
            try await store.createRequest(asapPayload(food: "Would-be second request"))
            XCTFail("A second create must be blocked while the operation is unresolved")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected: the store republishes the same unresolved ambiguity.
        }
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths.filter { $0 == "/api/request" }.count,
            1
        )
    }

    // MARK: - Relaunch reconciliation (proofs 6, 7, 8, 9, 17)

    func testRelaunchReconciliationReusesExactOperationIdentityAndPayload() async throws {
        let windowStart = try iso8601Date("2026-08-10T19:00:00.000Z")
        let sharedStorage = UserDefaultsPendingRequestOperationStorage(defaults: defaults)

        // "First process": an intentional scheduled submission whose response
        // is lost.
        let storeBeforeTermination = makeStore(authority: authorityA, operationStorage: sharedStorage)
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))
        do {
            try await storeBeforeTermination.createRequest(
                scheduledPayload(food: "Later distinct food", windowStart: windowStart, mealSwipes: 5)
            )
            XCTFail("Expected an ambiguous outcome")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected.
        }
        let firstAttemptHeaders = try XCTUnwrap(RequestFetchingURLProtocol.lastCapturedHeaders)
        let originalOperationId = try XCTUnwrap(firstAttemptHeaders[RequestService.operationIdentityHeader])

        // "Relaunch": a brand-new store, reading the same durable storage —
        // in-memory state from the terminated process is gone, but the
        // durable record survives the round trip through real UserDefaults
        // JSON encoding/decoding.
        let storeAfterRelaunch = makeStore(
            authority: authorityA,
            operationStorage: UserDefaultsPendingRequestOperationStorage(defaults: defaults)
        )
        XCTAssertFalse(storeAfterRelaunch.hasUnresolvedCreateAmbiguity)

        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 200,
            data: createResponse(requestObject: requestObject(
                id: "reconciled-request",
                food: "Later distinct food",
                pickupWindowText: "7:00 PM",
                mealSwipes: 5,
                windowStart: "2026-08-10T19:00:00.000Z",
                windowEnd: "2026-08-10T22:00:00.000Z"
            ))
        ))
        let didCreate = await storeAfterRelaunch.reconcilePendingCreateOperationIfNeeded()

        XCTAssertTrue(didCreate)
        let secondAttemptHeaders = try XCTUnwrap(RequestFetchingURLProtocol.lastCapturedHeaders)
        XCTAssertEqual(
            secondAttemptHeaders[RequestService.operationIdentityHeader],
            originalOperationId,
            "Reconciliation must reuse the exact original operation identity, never mint a new one"
        )

        let secondBody = try XCTUnwrap(RequestFetchingURLProtocol.lastCapturedBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: secondBody) as? [String: Any])
        XCTAssertEqual(json["vendor"] as? String, "Jasper Kane Cafe")
        XCTAssertEqual(json["mealSwipes"] as? Int, 5)
        XCTAssertEqual(json["timing"] as? String, "scheduled")
        XCTAssertNotNil(json["windowStart"])
        // W4-R4: the replayed body carries the exact structured request the
        // original attempt submitted — every meal entry, in order — and
        // neither the removed `pickupName` nor a client-composed `food`.
        XCTAssertEqual(json["menuPath"] as? String, "meal-exchange")
        // W4-R4 sends structured `{ name, details }` objects on the wire, not
        // bare strings.
        let mealItemsJSON = try XCTUnwrap(json["mealItems"] as? [[String: Any]])
        let decodedMealItems = try mealItemsJSON.map { entry -> MealItem in
            MealItem(name: try XCTUnwrap(entry["name"] as? String), details: entry["details"] as? String)
        }
        XCTAssertEqual(
            decodedMealItems,
            ["Later distinct food", "Additional meal 1", "Additional meal 2",
             "Additional meal 3", "Additional meal 4"]
        )
        XCTAssertNil(json["pickupName"])
        XCTAssertNil(json["food"])

        XCTAssertFalse(storeAfterRelaunch.hasUnresolvedCreateAmbiguity)
        XCTAssertNil(sharedStorage.load())
        // W4-D2 Success→Home continuity: a reconciled D1 create under the
        // still-current authority now inserts immediately, ownership-
        // resolved `.own`.
        XCTAssertEqual(storeAfterRelaunch.requests.map(\.id), ["reconciled-request"])
        XCTAssertEqual(storeAfterRelaunch.requests.first?.ownership, .own)
    }

    func testReconciliationWithNothingDurableIsANoOp() async {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)

        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertFalse(didCreate)
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
    }

    func testRepeatedReconciliationCannotProduceMultipleLogicalOperations() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))
        do {
            try await store.createRequest(asapPayload(food: "Racing recovery food"))
            XCTFail("Expected an ambiguous outcome")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected.
        }

        let gate = RequestFetchingGate()
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 200,
            data: createResponse(requestObject: requestObject(food: "Racing recovery food")),
            gate: gate
        ))

        let inFlightReconciliation = Task {
            await store.reconcilePendingCreateOperationIfNeeded()
        }
        await waitUntil { gate.isWaiting }

        // A second reconciliation attempt while the first is still in flight
        // must not start its own network call.
        let concurrentResult = await store.reconcilePendingCreateOperationIfNeeded()
        XCTAssertFalse(concurrentResult)
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths.filter { $0 == "/api/request" }.count,
            2 // the original ambiguous attempt, plus the one in-flight reconciliation
        )

        gate.open()
        let firstResult = await inFlightReconciliation.value
        XCTAssertTrue(firstResult)
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths.filter { $0 == "/api/request" }.count,
            2
        )
    }

    // MARK: - Terminal expiry (proofs 11, 12)

    func testOperationExpiredRetiresTheOperationAndCreatesNothing() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))
        do {
            try await store.createRequest(asapPayload(food: "Will expire"))
            XCTFail("Expected an ambiguous outcome")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected.
        }

        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 410,
            data: errorResponse(code: RequestOperationErrorCode.operationExpired)
        ))
        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertFalse(didCreate)
        XCTAssertNil(storage.load())
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertTrue(store.requests.isEmpty)
    }

    func testLaterIntentionalSubmissionAfterExpiryMintsADifferentOperationIdentityAndSucceeds() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))
        do {
            try await store.createRequest(asapPayload(food: "Will expire"))
            XCTFail("Expected an ambiguous outcome")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected.
        }
        let originalOperationId = try XCTUnwrap(
            RequestFetchingURLProtocol.lastCapturedHeaders?[RequestService.operationIdentityHeader]
        )

        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 410,
            data: errorResponse(code: RequestOperationErrorCode.operationExpired)
        ))
        _ = await store.reconcilePendingCreateOperationIfNeeded()
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)

        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: requestObject(
                id: "fresh-after-expiry",
                food: "A brand new request"
            ))
        ))
        try await store.createRequest(asapPayload(food: "A brand new request"))

        let newOperationId = try XCTUnwrap(
            RequestFetchingURLProtocol.lastCapturedHeaders?[RequestService.operationIdentityHeader]
        )
        XCTAssertNotEqual(newOperationId, originalOperationId)
        // W4-D2 Success→Home continuity: a fresh create under the still-
        // current authority now inserts immediately, ownership-resolved
        // `.own`.
        XCTAssertEqual(store.requests.map(\.id), ["fresh-after-expiry"])
        XCTAssertEqual(store.requests.first?.ownership, .own)
    }

    // MARK: - Invalid operation identity (proof 13)

    func test400InvalidOperationIdIsDefinitiveNonCreateAndRetiresDurableState() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 400,
            data: errorResponse(code: RequestOperationErrorCode.invalidOperationId)
        ))

        do {
            try await store.createRequest(asapPayload(food: "Malformed identity"))
            XCTFail("Expected a definitive INVALID_OPERATION_ID refusal")
        } catch RequestServiceError.serverError(let code, _) {
            XCTAssertEqual(code, RequestOperationErrorCode.invalidOperationId)
        }

        // Definitive, not ambiguous: nothing is left durable, and the block
        // is never armed.
        XCTAssertNil(storage.load())
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
    }

    // MARK: - Unauthorized (proof 15)

    func test403OperationUnauthorizedCannotLeakStateOrAutoRetryAndRetiresOperation() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))
        do {
            try await store.createRequest(asapPayload(food: "Later refused"))
            XCTFail("Expected an ambiguous outcome")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected.
        }

        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 403,
            data: errorResponse(code: RequestOperationErrorCode.operationUnauthorized)
        ))
        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertFalse(didCreate)
        XCTAssertNil(storage.load())
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertTrue(store.requests.isEmpty)

        // No automatic follow-up: with nothing durable left, a later
        // reconciliation call is a pure no-op.
        let requestCountAfterUnauthorized = RequestFetchingURLProtocol.capturedRequestedPaths
            .filter { $0 == "/api/request" }.count
        let secondAttempt = await store.reconcilePendingCreateOperationIfNeeded()
        XCTAssertFalse(secondAttempt)
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths.filter { $0 == "/api/request" }.count,
            requestCountAfterUnauthorized
        )
    }

    // MARK: - Wrong-participant restoration (proof 16)

    func testRestoredRecordCannotBeReconciledUnderADifferentParticipant() async throws {
        let sharedStorage = UserDefaultsPendingRequestOperationStorage(defaults: defaults)
        let storeForA = makeStore(authority: authorityA, operationStorage: sharedStorage)
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))
        do {
            try await storeForA.createRequest(asapPayload(food: "Belongs to participant A"))
            XCTFail("Expected an ambiguous outcome")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected.
        }
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths.filter { $0 == "/api/request" }.count,
            1
        )

        // A different verified participant on the same installation (however
        // that came to be) must not be able to reconcile, discover, or act
        // on participant A's still-unresolved operation.
        let storeForB = makeStore(authority: authorityB, operationStorage: sharedStorage)
        let didCreate = await storeForB.reconcilePendingCreateOperationIfNeeded()

        XCTAssertFalse(didCreate)
        XCTAssertFalse(storeForB.hasUnresolvedCreateAmbiguity)
        XCTAssertTrue(storeForB.requests.isEmpty)
        // No network call was made on B's behalf against A's operation.
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths.filter { $0 == "/api/request" }.count,
            1
        )
        // A's durable record is left exactly as it was — not deleted, not
        // exposed, not folded into a fresh create.
        XCTAssertNotNil(sharedStorage.load())

        // Participant B, meanwhile, is not blocked from an ordinary create of
        // their own.
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: requestObject(
                id: "participant-b-request",
                food: "Belongs to participant B"
            ))
        ))
        try await storeForB.createRequest(asapPayload(food: "Belongs to participant B"))
        // W4-D2 Success→Home continuity: B's own fresh create, under B's
        // still-current authority, now inserts immediately, ownership-
        // resolved `.own` — distinct from A's untouched, unexposed operation
        // above.
        XCTAssertEqual(storeForB.requests.map(\.id), ["participant-b-request"])
        XCTAssertEqual(storeForB.requests.first?.ownership, .own)
    }

    // MARK: - Ordinary pre-write rejections are also definitive non-create
    // (independent-review MUST FIX 1)

    /// The daily-limit refusal — the most easily reachable ordinary rejection
    /// in real use — must retire durable state exactly like the three
    /// operation-identity-specific codes do, so a quota-refused attempt
    /// cannot resurface as an unintended creation once quota resets, nor
    /// permanently block later intentional submissions.
    func testQuotaRejectionOnFreshCreateRetiresDurableStateAndDoesNotBlockLaterCreate() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 429,
            data: errorResponse(code: RequestOperationErrorCode.requestLimitReached)
        ))

        do {
            try await store.createRequest(asapPayload(food: "Over quota"))
            XCTFail("Expected a definitive REQUEST_LIMIT_REACHED refusal")
        } catch RequestServiceError.serverError(let code, _) {
            XCTAssertEqual(code, RequestOperationErrorCode.requestLimitReached)
        }

        // Definitive, not ambiguous: nothing is left durable that a later
        // relaunch could replay as an unintended, quota-refused-then-forgotten
        // creation, and the requester is not blocked from a real next attempt.
        XCTAssertNil(storage.load())
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)

        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: requestObject(
                id: "after-quota-refusal",
                food: "A different request"
            ))
        ))
        try await store.createRequest(asapPayload(food: "A different request"))
        // W4-D2 Success→Home continuity: a fresh create under the still-
        // current authority now inserts immediately, ownership-resolved
        // `.own`.
        XCTAssertEqual(store.requests.map(\.id), ["after-quota-refusal"])
        XCTAssertEqual(store.requests.first?.ownership, .own)
    }

    /// The same property for the remaining pre-write ordinary rejections
    /// `createRequestRoute.ts` can return before any write: an unsupported
    /// vendor, a generic shape failure, and a submitted address that does not
    /// match the verified principal. `PARTICIPANT_PRINCIPAL_MISMATCH` and
    /// `INVALID_REQUEST`/`INVALID_VENDOR` are not reachable through this
    /// app's own payload construction, but the classifier must still resolve
    /// them correctly if the backend ever returns one — for example against
    /// an older installed build with a stale vendor list.
    func testRemainingOrdinaryPreWriteRejectionsAreDefinitiveNonCreate() async throws {
        for code in [
            RequestOperationErrorCode.invalidVendor,
            RequestOperationErrorCode.invalidRequest,
            RequestOperationErrorCode.participantPrincipalMismatch,
        ] {
            let storage = InMemoryPendingRequestOperationStorage()
            let store = makeStore(authority: authorityA, operationStorage: storage)
            RequestFetchingURLProtocol.enqueue(.response(
                statusCode: 400,
                data: errorResponse(code: code)
            ))

            do {
                try await store.createRequest(asapPayload(food: "Refused: \(code)"))
                XCTFail("Expected a definitive \(code) refusal")
            } catch RequestServiceError.serverError(let receivedCode, _) {
                XCTAssertEqual(receivedCode, code)
            }

            XCTAssertNil(storage.load())
            XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        }
    }

    // MARK: - Route-level definitive pre-write refusals

    func testRateLimitedRetiresDurableStateAndCannotReplayAfterRelaunch() async throws {
        try await assertRouteLevelDefinitiveNonCreate(
            label: "RATE_LIMITED",
            firstResponse: .response(
                statusCode: 429,
                data: errorResponse(code: RequestOperationErrorCode.rateLimited)
            ),
            matchesExpectedError: { error in
                guard case RequestServiceError.serverError(let code, _) = error else { return false }
                return code == RequestOperationErrorCode.rateLimited
            }
        )
    }

    func testBareNotFoundRetiresDurableStateAndCannotReplayAfterRelaunch() async throws {
        try await assertRouteLevelDefinitiveNonCreate(
            label: "bare 404",
            firstResponse: .response(
                statusCode: 404,
                data: Data("Cannot POST /api/request".utf8)
            ),
            matchesExpectedError: { error in
                guard case RequestServiceError.notFound = error else { return false }
                return true
            }
        )
    }

    /// W4-D2: during recovery of an already-issued operation, a route-level
    /// refusal proves only that *this* replay created nothing; an earlier
    /// transmission may still have reached an authority that had the route.
    /// The operation stays pending and checkable, and no terminal
    /// reconciliation is attempted on its strength.
    func testRouteLevelRefusalsDuringReconciliationKeepTheOperationPending() async {
        let cases: [(String, RequestFetchingURLProtocol.Stub)] = [
            (
                "RATE_LIMITED",
                .response(
                    statusCode: 429,
                    data: errorResponse(code: RequestOperationErrorCode.rateLimited)
                )
            ),
            (
                "bare 404",
                .response(statusCode: 404, data: Data("Cannot POST /api/request".utf8))
            ),
            (
                "PUBLIC_ACTIONS_PAUSED",
                .response(
                    statusCode: 503,
                    data: errorResponse(code: "PUBLIC_ACTIONS_PAUSED")
                )
            ),
        ]

        for (label, response) in cases {
            RequestFetchingURLProtocol.reset()
            let storage = InMemoryPendingRequestOperationStorage()
            storage.save(PendingRequestOperationRecord(
                operationId: "reconcile-\(label.replacingOccurrences(of: " ", with: "-"))",
                participantIdentifier: participantIdentifierA,
                operationAuthority: operationAuthority,
                payload: CreateRequestPayload(
                    vendor: "Jasper Kane Cafe",
                    timing: .asap,
                    windowStart: nil,
                    menuPath: .mealExchange,
                    // One entry per swipe, so the payload is replayable and
                    // this exercises the replay classification itself.
                    mealSwipes: 1,
                    mealItems: [MealItem(name: "Previously unresolved \(label)")],
                    orderDetails: nil,
                    estimatedDiningDollarsCents: nil
                )
            ))
            let store = makeStore(authority: authorityA, operationStorage: storage)
            RequestFetchingURLProtocol.enqueue(response)

            let before = storage.load()
            let didCreate = await store.reconcilePendingCreateOperationIfNeeded()
            XCTAssertFalse(didCreate)
            XCTAssertNotNil(before)
            XCTAssertEqual(storage.load(), before, "\(label) must keep the restored operation")
            XCTAssertTrue(store.hasUnresolvedCreateAmbiguity, "\(label) must keep the create block")
            XCTAssertEqual(store.createRecoveryPresentation, .unresolved(canCheckAgain: true), label)
            XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, ["/api/request"], label)
        }
    }

    /// `REQUEST_CREATION_FAILED` must never be treated as definitive-non-create:
    /// `createRequestRoute.ts` returns that same code from the outer catch
    /// wrapping the write itself, so a client that received it cannot prove
    /// no write occurred. `RequestService.createRequest` decodes a readable
    /// error envelope here as `.serverError` — pre-existing, accepted
    /// behavior this fix must not touch (`RequestFetchingTests.swift`'s
    /// `testCreatePreservesStructuredBackendErrorCodes` already pins it, and
    /// `RequestCreationViewTests.swift` already pins the resulting
    /// "please try again" presentation) — so the *presented* error is
    /// unchanged. But because the write outcome remains unproven, D1 requires
    /// more than record preservation: the exact operation X this attempt
    /// began must stay unresolved and blocking, exactly like an ambiguous
    /// transport outcome, so a same-session retry cannot mint a replacement
    /// operation Y that silently overwrites X's only durable recovery state
    /// (independent-review MUST FIX: received `REQUEST_CREATION_FAILED`).
    func testGenericCreationFailureDoesNotRetireTheDurableRecordAndBlocksASecondCreate() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 500,
            data: errorResponse(code: "REQUEST_CREATION_FAILED")
        ))

        do {
            try await store.createRequest(asapPayload(food: "Uncertain outcome X"))
            XCTFail("Expected REQUEST_CREATION_FAILED to surface as a server error")
        } catch RequestServiceError.serverError(let code, _) {
            XCTAssertEqual(code, "REQUEST_CREATION_FAILED")
        }

        // Not classified as definitive-non-create, so the record this
        // attempt (X) wrote is preserved rather than discarded — a relaunch
        // can still reconcile it if the write this response could not rule
        // out actually happened.
        let recordForX = try XCTUnwrap(storage.load())
        // W4-R4: the record holds the frozen payload, so the preserved
        // content is the exact structured request X submitted.
        XCTAssertEqual(
            recordForX.payload.mealItems,
            ["Uncertain outcome X", "Additional meal 1"]
        )

        // The write result is unproven, so this must block exactly like an
        // in-process ambiguous transport outcome does.
        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity)

        // A second intentional submission (Y) must never reach the network,
        // and must never overwrite X's durable record, while X remains
        // unresolved. Deliberately nothing enqueued for it: if it were ever
        // transmitted, `RequestFetchingURLProtocol` would fail the test on
        // an unconfigured request rather than let it silently succeed.
        do {
            try await store.createRequest(asapPayload(food: "Would-be second request Y"))
            XCTFail("A second create must be blocked while operation X is unresolved")
        } catch RequestServiceError.serverError(let code, _) {
            // The store republishes the same unresolved error rather than
            // attempting Y.
            XCTAssertEqual(code, "REQUEST_CREATION_FAILED")
        }
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths.filter { $0 == "/api/request" }.count,
            1,
            "Y must never be transmitted while X is unresolved"
        )

        // X's exact durable record — operation identity and payload — must
        // be untouched by the blocked attempt at Y.
        XCTAssertEqual(storage.load(), recordForX)

        // Authoritative reconciliation can still resolve X, exactly as any
        // other unresolved operation would be recovered — proven generally
        // by `testRelaunchReconciliationReusesExactOperationIdentityAndPayload`
        // and `testRepeatedReconciliationCannotProduceMultipleLogicalOperations`;
        // confirmed directly here for this exact code path.
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: requestObject(
                id: "recovered-x",
                food: "Uncertain outcome X"
            ))
        ))
        let didRecoverX = await store.reconcilePendingCreateOperationIfNeeded()
        XCTAssertTrue(didRecoverX)
        XCTAssertNil(storage.load())
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        // W4-D2 Success→Home continuity: a reconciled D1 create under the
        // still-current authority now inserts immediately, ownership-
        // resolved `.own`.
        XCTAssertEqual(store.requests.map(\.id), ["recovered-x"])
        XCTAssertEqual(store.requests.first?.ownership, .own)
    }

    /// W4-D2: during relaunch reconciliation a quota refusal follows a
    /// not-found lookup, which is not terminal on its own — the original
    /// transmission may still commit. The operation converges through exact
    /// terminal reconciliation instead of leaving the requester stuck.
    func testQuotaRejectionDuringReconciliationConvergesThroughTerminalReconciliation() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))
        do {
            try await store.createRequest(asapPayload(food: "Will be over quota on relaunch"))
            XCTFail("Expected an ambiguous outcome")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected.
        }

        let operationId = try XCTUnwrap(storage.load()?.operationId)

        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 429,
            data: errorResponse(code: RequestOperationErrorCode.requestLimitReached)
        ))
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 200,
            data: Data(#"{"outcome":"not-created"}"#.utf8)
        ))
        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertFalse(didCreate)
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            ["/api/request", "/api/request", "/api/request-operation/terminal"]
        )
        XCTAssertEqual(
            RequestFetchingURLProtocol.lastCapturedHeaders?[RequestService.operationIdentityHeader],
            operationId
        )
        XCTAssertNil(storage.load())
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        // Path A: the replayed payload was known and readable throughout.
        // The raw payload never leaves the store (independent-review MUST
        // FIX 1) — presentation carries only the discriminator, and the
        // store-owned consume operation is the sole way to see the exact
        // restored content.
        XCTAssertEqual(store.createRecoveryPresentation, .notCreatedRecoverable)
        // `RequestFoodFormDraft(restoring:)` falls back to `Date()` for this
        // ASAP payload's `preferredPickupTime` (there is no frozen
        // `windowStart`), so the two independent restorations below cannot be
        // asserted equal on that one field; every other field is exact.
        let restored = try XCTUnwrap(store.consumeRecoverableDraftForReturnToRequest())
        let expected = RequestFoodFormDraft(restoring: asapPayload(food: "Will be over quota on relaunch"))
        XCTAssertEqual(restored.selectedDiningSpot, expected.selectedDiningSpot)
        XCTAssertEqual(restored.menuPath, expected.menuPath)
        XCTAssertEqual(restored.timing, expected.timing)
        XCTAssertEqual(restored.mealSwipes, expected.mealSwipes)
        XCTAssertEqual(restored.activeMealEntries, expected.activeMealEntries)
        XCTAssertEqual(restored.orderDetails, expected.orderDetails)
        XCTAssertEqual(restored.diningDollarsText, expected.diningDollarsText)
    }

    // MARK: - Pre-transmission cancellation (independent-review MUST FIX 2)

    /// `RequestService.createRequest`'s own leading `Task.checkCancellation()`
    /// is the only point that lets a raw `CancellationError` reach
    /// `RequestStore`; every later cancellation is wrapped as
    /// `.ambiguousCreateOutcome`. Cancelling before the task's synchronous
    /// prefix (mint id, persist record) has a chance to run guarantees this
    /// exact pre-transmission boundary, since the newly created unstructured
    /// `Task` cannot begin running until this synchronous test method
    /// suspends.
    func testCancellationBeforeTransmissionRetiresTheJustSavedRecordAndSendsNothing() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)
        // Deliberately nothing enqueued: if this ever reached the network,
        // `RequestFetchingURLProtocol` would fail the test on an unconfigured
        // request rather than let it silently succeed.

        let task = Task { @MainActor in
            try await store.createRequest(asapPayload(food: "Cancelled before it could be sent"))
        }
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertNil(storage.load())
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)

        // Nothing was left behind to interfere with a real later submission.
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: requestObject(
                id: "after-cancelled-attempt",
                food: "The real submission"
            ))
        ))
        try await store.createRequest(asapPayload(food: "The real submission"))
        // W4-D2 Success→Home continuity: a fresh create under the still-
        // current authority now inserts immediately, ownership-resolved
        // `.own`.
        XCTAssertEqual(store.requests.map(\.id), ["after-cancelled-attempt"])
        XCTAssertEqual(store.requests.first?.ownership, .own)
    }

    /// Reconciliation's own cancellation handling is unchanged: a record that
    /// predates the recovery attempt (restored from a previous process) must
    /// survive cancellation of that attempt untouched, so a later relaunch or
    /// retry can still reconcile the exact same operation.
    func testCancellationDuringReconciliationLeavesThePredatingRecordUntouched() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        storage.save(PendingRequestOperationRecord(
            operationId: "predates-this-reconciliation-attempt",
            participantIdentifier: participantIdentifierA,
            operationAuthority: operationAuthority,
            payload: CreateRequestPayload(
                vendor: "Jasper Kane Cafe",
                timing: .asap,
                windowStart: nil,
                menuPath: .mealExchange,
                mealSwipes: 2,
                mealItems: ["Still recoverable", "Additional meal 1"],
                orderDetails: nil,
                estimatedDiningDollarsCents: nil
            )
        ))
        let store = makeStore(authority: authorityA, operationStorage: storage)

        let task = Task { @MainActor in
            await store.reconcilePendingCreateOperationIfNeeded()
        }
        task.cancel()
        let didCreate = await task.value

        XCTAssertFalse(didCreate)
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
        // Unchanged from before the attempt: still present, still armed.
        XCTAssertEqual(storage.load()?.operationId, "predates-this-reconciliation-attempt")
        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity)
    }

    // MARK: - Replay preserves the current installation association
    // (independent-review SHOULD FIX 3)

    func testReconciliationReplaySendsTheCurrentInstallationCredential() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        storage.save(PendingRequestOperationRecord(
            operationId: "needs-installation-association",
            participantIdentifier: participantIdentifierA,
            operationAuthority: operationAuthority,
            payload: CreateRequestPayload(
                vendor: "Jasper Kane Cafe",
                timing: .asap,
                windowStart: nil,
                menuPath: .mealExchange,
                mealSwipes: 2,
                mealItems: ["Never actually transmitted originally", "Additional meal 1"],
                orderDetails: nil,
                estimatedDiningDollarsCents: nil
            )
        ))
        let store = makeStore(authority: authorityA, operationStorage: storage)
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: requestObject(
                id: "recovered-with-installation",
                food: "Never actually transmitted originally"
            ))
        ))

        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertTrue(didCreate)
        let body = try XCTUnwrap(RequestFetchingURLProtocol.lastCapturedBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(
            json["installationCredential"] as? String,
            "test-installation-credential",
            "Reconciliation must re-attach the current installation credential, exactly like a fresh create"
        )
    }

    // MARK: - Malformed restored state fails safely

    /// W4-D2: a readable identity with an unusable payload is never retired
    /// locally and never resent; backend authority resolves it by identity.
    func testMalformedDurableRecordIsResolvedByIdentityRatherThanRetiredLocally() async {
        let storage = InMemoryPendingRequestOperationStorage()
        // A scheduled record with no window start can never have been
        // produced by `createRequest` itself — simulates corrupted or
        // otherwise unusable restored state.
        storage.save(PendingRequestOperationRecord(
            operationId: "not-a-real-operation-id",
            participantIdentifier: participantIdentifierA,
            operationAuthority: operationAuthority,
            payload: CreateRequestPayload(
                vendor: "Jasper Kane Cafe",
                timing: .scheduled,
                windowStart: nil,
                menuPath: .mealExchange,
                mealSwipes: 2,
                mealItems: ["Corrupted"],
                orderDetails: nil,
                estimatedDiningDollarsCents: nil
            )
        ))
        let store = makeStore(authority: authorityA, operationStorage: storage)
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 200,
            data: Data(#"{"outcome":"not-created"}"#.utf8)
        ))

        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertFalse(didCreate)
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            ["/api/request-operation/terminal"]
        )
        XCTAssertEqual(
            RequestFetchingURLProtocol.lastCapturedHeaders?[RequestService.operationIdentityHeader],
            "not-a-real-operation-id"
        )
        XCTAssertNil(storage.load())
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        // Path B: the payload was structurally invalid, so it was never
        // resent and is never restored.
        XCTAssertEqual(store.createRecoveryPresentation, .notCreatedUnavailable)
    }

    // MARK: - Helpers

    // MARK: - W4-R4 exact structured payload survives recovery

    /// A deliberately distinctive Dining-Dollars-only payload: zero swipes, a
    /// specific order-details string, and an exact odd cent amount, so a
    /// field that silently dropped, defaulted, or rounded during freeze and
    /// replay would be visible rather than plausible.
    private func diningDollarsPayload() -> CreateRequestPayload {
        CreateRequestPayload(
            vendor: "Jasper Kane Cafe",
            timing: .asap,
            windowStart: nil,
            menuPath: .diningDollars,
            mealSwipes: 0,
            mealItems: [],
            orderDetails: "Grain bowl with extra avocado, no onions",
            estimatedDiningDollarsCents: 4_999
        )
    }

    private func fiveMealPayload() -> CreateRequestPayload {
        CreateRequestPayload(
            vendor: "Jasper Kane Cafe",
            timing: .asap,
            windowStart: nil,
            menuPath: .mealExchange,
            mealSwipes: 5,
            mealItems: [
                "Chicken over rice, no onions",
                "Falafel wrap with extra tahini",
                "Large iced coffee",
                "Side of plantains",
                "Bottled water",
            ],
            orderDetails: nil,
            estimatedDiningDollarsCents: 1_337
        )
    }

    func testAnAmbiguousStructuredCreateFreezesTheExactPayload() async throws {
        let storage = RecordingPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))

        do {
            try await store.createRequest(fiveMealPayload())
            XCTFail("Transport loss after submission should be ambiguous")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected.
        }

        let record = try XCTUnwrap(storage.load())
        // Frozen verbatim: every structured field, unchanged and in order.
        XCTAssertEqual(record.payload, fiveMealPayload())
        XCTAssertEqual(record.payload.mealItems, fiveMealPayload().mealItems)
        XCTAssertEqual(record.payload.estimatedDiningDollarsCents, 1_337)
        // The installation credential is store-owned identity, not request
        // content, and is deliberately never written to durable storage.
        XCTAssertNil(record.payload.installationCredential)
    }

    func testDiningDollarsOnlyRecoveryPreservesZeroSwipesAndExactCents() async throws {
        let storage = RecordingPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))

        do {
            try await store.createRequest(diningDollarsPayload())
            XCTFail("Transport loss after submission should be ambiguous")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected.
        }

        let record = try XCTUnwrap(storage.load())
        XCTAssertEqual(record.payload.menuPath, .diningDollars)
        XCTAssertEqual(record.payload.mealSwipes, 0)
        XCTAssertEqual(record.payload.mealItems, [])
        XCTAssertEqual(
            record.payload.orderDetails,
            "Grain bowl with extra avocado, no onions"
        )
        XCTAssertEqual(record.payload.estimatedDiningDollarsCents, 4_999)
    }

    func testReplayResendsTheExactStructuredPayloadAfterARealRelaunchRoundTrip() async throws {
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "w4-r4-structured-replay-\(UUID().uuidString)")
        )
        defer {
            defaults.removeObject(forKey: UserDefaultsPendingRequestOperationStorage.collectionKey)
            defaults.removeObject(forKey: UserDefaultsPendingRequestOperationStorage.singleRecordKey)
        }
        let storage = UserDefaultsPendingRequestOperationStorage(defaults: defaults)
        let storeBeforeTermination = makeStore(
            authority: authorityA,
            operationStorage: storage
        )
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))

        do {
            try await storeBeforeTermination.createRequest(fiveMealPayload())
            XCTFail("Expected an ambiguous outcome")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected.
        }
        let firstHeaders = try XCTUnwrap(RequestFetchingURLProtocol.lastCapturedHeaders)
        let originalOperationId = try XCTUnwrap(
            firstHeaders[RequestService.operationIdentityHeader]
        )

        // "Relaunch": a new store reading the same durable storage, so the
        // payload makes a real JSON encode/decode round trip on the way.
        let storeAfterRelaunch = makeStore(
            authority: authorityA,
            operationStorage: UserDefaultsPendingRequestOperationStorage(defaults: defaults)
        )
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 200,
            data: createResponse(requestObject: requestObject(id: "structured-replayed"))
        ))

        let didCreate = await storeAfterRelaunch.reconcilePendingCreateOperationIfNeeded()

        XCTAssertTrue(didCreate)
        let replayHeaders = try XCTUnwrap(RequestFetchingURLProtocol.lastCapturedHeaders)
        XCTAssertEqual(
            replayHeaders[RequestService.operationIdentityHeader],
            originalOperationId,
            "Replay must reuse the exact original operation identity"
        )

        let body = try XCTUnwrap(RequestFetchingURLProtocol.lastCapturedBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["menuPath"] as? String, "meal-exchange")
        XCTAssertEqual(json["mealSwipes"] as? Int, 5)
        // W4-R4 sends structured `{ name, details }` objects on the wire, not
        // bare strings — decode the same way the backend does before
        // comparing to the canonical payload's `mealItems`.
        let mealItemsJSON = try XCTUnwrap(json["mealItems"] as? [[String: Any]])
        let decodedMealItems = try mealItemsJSON.map { entry -> MealItem in
            MealItem(name: try XCTUnwrap(entry["name"] as? String), details: entry["details"] as? String)
        }
        XCTAssertEqual(decodedMealItems, fiveMealPayload().mealItems)
        XCTAssertEqual(json["estimatedDiningDollarsCents"] as? Int, 1_337)
        // The credential is re-attached from the live provider, not restored
        // from disk.
        XCTAssertEqual(
            json["installationCredential"] as? String,
            "test-installation-credential"
        )
        // And the removed fields never reappear.
        XCTAssertNil(json["pickupName"])
        XCTAssertNil(json["food"])
    }

    func testDiningDollarCentsSurviveARealDurableRoundTripExactly() throws {
        // Every accepted amount, through the same encoder/decoder the durable
        // record actually uses: an amount that changed by even one cent
        // between submission and replay would be a different request.
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "w4-r4-cents-round-trip-\(UUID().uuidString)")
        )
        defer {
            defaults.removeObject(forKey: UserDefaultsPendingRequestOperationStorage.collectionKey)
            defaults.removeObject(forKey: UserDefaultsPendingRequestOperationStorage.singleRecordKey)
        }
        let storage = UserDefaultsPendingRequestOperationStorage(defaults: defaults)

        for cents in [1, 5, 99, 100, 1_337, 2_500, 4_999, 5_000] {
            let payload = CreateRequestPayload(
                vendor: "Jasper Kane Cafe",
                timing: .asap,
                windowStart: nil,
                menuPath: .diningDollars,
                mealSwipes: 0,
                mealItems: [],
                orderDetails: "Grain bowl",
                estimatedDiningDollarsCents: cents
            )
            storage.save(PendingRequestOperationRecord(
                operationId: "cents-round-trip",
                participantIdentifier: participantIdentifierA,
                operationAuthority: operationAuthority,
                payload: payload
            ))

            let restored = try XCTUnwrap(storage.load())
            XCTAssertEqual(restored.payload.estimatedDiningDollarsCents, cents)
            XCTAssertEqual(restored.payload, payload)
        }
    }

    func testAStructurallyInvalidRestoredRecordIsNeitherRepairedNorResent() async {
        // A record whose frozen payload does not describe exactly one
        // coherent menu path is never "fixed" into a request the requester
        // never composed, and never resent. W4-D2: it is not discarded
        // locally either — only backend authority can retire it.
        let storage = InMemoryPendingRequestOperationStorage()
        storage.save(PendingRequestOperationRecord(
            operationId: "structurally-invalid",
            participantIdentifier: participantIdentifierA,
            operationAuthority: operationAuthority,
            payload: CreateRequestPayload(
                vendor: "Jasper Kane Cafe",
                timing: .asap,
                windowStart: nil,
                menuPath: .mealExchange,
                // Three swipes but only one entry: never a submittable shape.
                mealSwipes: 3,
                mealItems: ["Only one entry"],
                orderDetails: nil,
                estimatedDiningDollarsCents: nil
            )
        ))
        let store = makeStore(authority: authorityA, operationStorage: storage)
        let before = storage.load()
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))

        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertFalse(didCreate)
        XCTAssertFalse(RequestFetchingURLProtocol.capturedRequestedPaths.contains("/api/request"))
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths,
            ["/api/request-operation/terminal"]
        )
        // Inconclusive: kept exactly, still blocking, still checkable.
        XCTAssertEqual(storage.load(), before)
        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity)
        XCTAssertEqual(store.createRecoveryPresentation, .unresolved(canCheckAgain: true))
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

    private func assertRouteLevelDefinitiveNonCreate(
        label: String,
        firstResponse: RequestFetchingURLProtocol.Stub,
        matchesExpectedError: (Error) -> Bool
    ) async throws {
        let storage = RecordingPendingRequestOperationStorage()
        let store = makeStore(authority: authorityA, operationStorage: storage)
        RequestFetchingURLProtocol.enqueue(firstResponse)

        do {
            try await store.createRequest(asapPayload(food: "Refused operation X: \(label)"))
            XCTFail("Expected \(label) to refuse operation X")
        } catch {
            XCTAssertTrue(matchesExpectedError(error), "Unexpected \(label) error: \(error)")
        }

        // X was durably saved before its POST, then retired because the
        // received response proves no create handler write could have begun.
        let operationX = try XCTUnwrap(storage.savedRecords.last)
        XCTAssertEqual(storage.savedRecords.count, 1)
        XCTAssertNil(storage.load())
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)

        // A reconstructed store has nothing to reconcile, so X cannot be
        // replayed after termination/relaunch.
        let relaunchedStore = makeStore(authority: authorityA, operationStorage: storage)
        let didReplayX = await relaunchedStore.reconcilePendingCreateOperationIfNeeded()
        XCTAssertFalse(didReplayX)
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths.filter { $0 == "/api/request" }.count,
            1
        )

        // A later intentional submission is a new logical operation.
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse(requestObject: requestObject(
                id: "after-\(label)",
                food: "Later operation Y: \(label)"
            ))
        ))
        try await store.createRequest(asapPayload(food: "Later operation Y: \(label)"))
        let operationY = try XCTUnwrap(
            RequestFetchingURLProtocol.lastCapturedHeaders?[RequestService.operationIdentityHeader]
        )
        XCTAssertNotEqual(operationY, operationX.operationId)
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
    }

    private func makeService() -> RequestService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return RequestService(client: client)
    }

    private func asapPayload(food: String, mealSwipes: Int = 2) -> CreateRequestPayload {
        CreateRequestPayload(
            vendor: "Jasper Kane Cafe",
            timing: .asap,
            windowStart: nil,
            menuPath: .mealExchange,
            mealSwipes: mealSwipes,
            // W4-R4 requires exactly one structured entry per selected swipe;
            // the first carries the distinguishing text each case asserts on.
            mealItems: [MealItem(name: food)]
                + (1..<mealSwipes).map { MealItem(name: "Additional meal \($0)") },
            orderDetails: nil,
            estimatedDiningDollarsCents: nil
        )
    }

    private func scheduledPayload(
        food: String,
        windowStart: Date,
        mealSwipes: Int = 3
    ) -> CreateRequestPayload {
        CreateRequestPayload(
            vendor: "Jasper Kane Cafe",
            timing: .scheduled,
            windowStart: windowStart,
            menuPath: .mealExchange,
            mealSwipes: mealSwipes,
            // W4-R4 requires exactly one structured entry per selected swipe;
            // the first carries the distinguishing text each case asserts on.
            mealItems: [MealItem(name: food)]
                + (1..<mealSwipes).map { MealItem(name: "Additional meal \($0)") },
            orderDetails: nil,
            estimatedDiningDollarsCents: nil
        )
    }

    private func requestObject(
        id: String = "64b0000000000000000000a1",
        vendor: String = "Jasper Kane Cafe",
        food: String = "Chicken bowl",
        pickupWindowText: String = "ASAP",
        mealSwipes: Int = 2,
        windowStart: String? = nil,
        windowEnd: String? = nil,
        status: String = "open",
        createdAt: String = "2026-08-09T17:00:00.000Z",
        expiresAt: String = "2026-08-09T20:00:00.000Z"
    ) -> String {
        let windowStartJSON = windowStart.map { "\"\($0)\"" } ?? "null"
        let windowEndJSON = windowEnd.map { "\"\($0)\"" } ?? "null"
        return """
        {
          "id": "\(id)",
          "vendor": "\(vendor)",
          "food": "\(food)",
          "pickupWindowText": "\(pickupWindowText)",
          "mealSwipes": \(mealSwipes),
          "menuPath": "meal-exchange",
          "mealItems": [],
          "orderDetails": null,
          "estimatedDiningDollarsCents": null,
          "windowStart": \(windowStartJSON),
          "windowEnd": \(windowEndJSON),
          "status": "\(status)",
          "createdAt": "\(createdAt)",
          "expiresAt": "\(expiresAt)"
        }
        """
    }

    private func createResponse(requestObject: String) -> Data {
        Data(#"{"request":\#(requestObject)}"#.utf8)
    }

    private func errorResponse(code: String, message: String = "backend detail") -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"\#(message)"}}"#.utf8)
    }

    private func iso8601Date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try XCTUnwrap(formatter.date(from: value))
    }

    private func waitUntil(
        timeoutIterations: Int = 100,
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

    private static func looksLikeAValidOperationId(_ value: String) -> Bool {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return (1...128).contains(value.count) && value.allSatisfy { allowed.contains($0) }
    }
}

private final class RecordingPendingRequestOperationStorage: PendingRequestOperationStorage {
    private let storage = InMemoryPendingRequestOperationStorage()
    private(set) var savedRecords: [PendingRequestOperationRecord] = []

    func restoreAll() -> [PendingRequestOperationEntry] {
        storage.restoreAll()
    }

    func save(_ record: PendingRequestOperationRecord) -> Bool {
        savedRecords.append(record)
        return storage.save(record)
    }

    func clear(operationId: String) {
        storage.clear(operationId: operationId)
    }
}
