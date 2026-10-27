//
//  RequestManagementStoreTests.swift
//  CommonPlateiosTests
//
// Focused W4-R5 coverage for the store boundary of owner requests, Withdraw and
// Edit:
//  - the owner collection is bound to the participant it was read for;
//  - an operation is durable before it is sent, and an unknown outcome is never
//    presented as a result nor retried automatically;
//  - recovery replays the same identity, only on the user's request, and only
//    for the participant who started it;
//  - another participant's record is neither shown, replayed nor overwritten.
import Foundation
import XCTest
@testable import CommonPlateios

private final class MutableAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ value: String?) { self.value = value }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: String?) { lock.lock(); value = new; lock.unlock() }
}

@MainActor
final class RequestManagementStoreTests: XCTestCase {
    private let authorityA = canonicalParticipantAuthorityFixture
    private let authorityB = replacementParticipantAuthorityFixture
    private let participantA = "64c0000000000000000000a1"

    override func tearDown() {
        ClaimFlowURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Owner requests

    func testOwnerFetchInstallsTheListAndBindsItToTheAuthority() async {
        let store = makeStore(MutableAuthority(authorityA))
        ClaimFlowURLProtocol.enqueue(.response(data: ownerList([ownerObject(id: "o1"), ownerObject(id: "o2")])))

        let outcome = await store.fetchOwnerRequests()

        XCTAssertEqual(outcome, .succeeded)
        XCTAssertEqual(store.ownerRequests.map(\.id), ["o1", "o2"])
        XCTAssertTrue(store.hasLoadedOwnerRequests)
        XCTAssertNil(store.ownerRequestsError)
    }

    func testAnEmptyOwnerAnswerIsLoadedAndEmptyWhileAFailureNeverIs() async {
        let store = makeStore(MutableAuthority(authorityA))
        ClaimFlowURLProtocol.enqueue(.failure(.timedOut))

        await store.fetchOwnerRequests()

        XCTAssertFalse(store.hasLoadedOwnerRequests, "unknown must not read as 'you have none'")
        XCTAssertNotNil(store.ownerRequestsError)

        ClaimFlowURLProtocol.enqueue(.response(data: ownerList([])))
        await store.fetchOwnerRequests()
        XCTAssertTrue(store.hasLoadedOwnerRequests)
        XCTAssertTrue(store.ownerRequests.isEmpty)
    }

    func testARefreshFailureForTheSameParticipantKeepsTheLoadedList() async {
        let store = makeStore(MutableAuthority(authorityA))
        ClaimFlowURLProtocol.enqueue(.response(data: ownerList([ownerObject(id: "o1")])))
        await store.fetchOwnerRequests()
        ClaimFlowURLProtocol.enqueue(.failure(.notConnectedToInternet))

        await store.fetchOwnerRequests()

        XCTAssertEqual(store.ownerRequests.map(\.id), ["o1"])
        XCTAssertTrue(store.hasLoadedOwnerRequests)
        XCTAssertNotNil(store.ownerRequestsError)
    }

    func testWithoutAuthorityNothingIsSentAndTheListIsNotLoaded() async {
        let store = makeStore(MutableAuthority(nil))

        let outcome = await store.fetchOwnerRequests()

        XCTAssertEqual(outcome, .didNotSucceed)
        XCTAssertTrue(ClaimFlowURLProtocol.capturedPaths.isEmpty)
        XCTAssertFalse(store.hasLoadedOwnerRequests)
    }

    func testAReplacedParticipantsOwnerListIsRetiredAtOnceAndALateAnswerInstallsNothing() async {
        let authority = MutableAuthority(authorityA)
        let store = makeStore(authority)
        ClaimFlowURLProtocol.enqueue(.response(data: ownerList([ownerObject(id: "a-own")])))
        await store.fetchOwnerRequests()

        // A refresh for A is in flight when Change Email makes B current.
        let gate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: ownerList([ownerObject(id: "a-late")]), gate: gate))
        let refresh = Task { await store.fetchOwnerRequests() }
        await waitUntil { gate.isWaiting }
        authority.set(authorityB)
        XCTAssertTrue(store.invalidateRequestDataIfIdentityReplaced())

        XCTAssertTrue(store.ownerRequests.isEmpty, "A's own requests are never B's")
        XCTAssertFalse(store.hasLoadedOwnerRequests)
        gate.open()
        _ = await refresh.value
        XCTAssertTrue(store.ownerRequests.isEmpty)
        XCTAssertFalse(store.hasLoadedOwnerRequests)
    }

    // MARK: - Withdraw

    func testWithdrawIsDurableBeforeItIsSentAndClearsOnADecidedAnswer() async throws {
        let storage = InMemoryPendingRequestUpdateStorage()
        let store = makeStore(MutableAuthority(authorityA), updateStorage: storage)
        ClaimFlowURLProtocol.enqueue(.response(data: ownerList([ownerObject(id: "r1"), ownerObject(id: "r2")])))
        await store.fetchOwnerRequests()
        let gate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: withdrawn("r1"), gate: gate))

        let task = Task { try await store.withdrawRequest(requestID: "r1") }
        await waitUntil { gate.isWaiting }

        // In flight: the identity is already durable, bound to this participant.
        let held = try XCTUnwrap(storage.load().records.first)
        XCTAssertEqual(held.kind, .withdraw)
        XCTAssertEqual(held.requestID, "r1")
        XCTAssertEqual(held.participantIdentifier, participantA)
        XCTAssertNotNil(held.operationLedger)
        XCTAssertTrue(store.isUpdatingRequest)
        XCTAssertNil(store.unresolvedUpdate, "an in-flight update is not 'unresolved'")

        gate.open()
        try await task.value

        XCTAssertTrue(storage.load().records.isEmpty)
        XCTAssertEqual(store.ownerRequests.map(\.id), ["r2"])
        XCTAssertFalse(store.isUpdatingRequest)
        let sent = try XCTUnwrap(ClaimFlowURLProtocol.capturedRequests.last)
        XCTAssertEqual(sent.headers["x-commonplate-operation-id"], held.operationId)
    }

    func testAnUnknownWithdrawOutcomeStaysDurableBlocksNewUpdatesAndIsNeverRetriedAutomatically() async throws {
        let storage = InMemoryPendingRequestUpdateStorage()
        let store = makeStore(MutableAuthority(authorityA), updateStorage: storage)
        ClaimFlowURLProtocol.enqueue(.response(data: ownerList([ownerObject(id: "r1")])))
        await store.fetchOwnerRequests()
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))

        do {
            try await store.withdrawRequest(requestID: "r1")
            XCTFail("an unknown outcome is not a success")
        } catch RequestServiceError.ambiguousUpdateOutcome {
            // Expected.
        }

        let pending = try XCTUnwrap(store.unresolvedUpdate)
        XCTAssertEqual(storage.load().records, [pending])
        // Nothing was presented as withdrawn: the card is still there.
        XCTAssertEqual(store.ownerRequests.map(\.id), ["r1"])
        // Exactly one POST so far — no automatic replay.
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/withdraw") }.count, 1)

        // A new update, of any kind, is refused while this one is unresolved.
        do {
            try await store.withdrawRequest(requestID: "r1")
            XCTFail("expected the unresolved update to block")
        } catch RequestServiceError.unresolvedUpdate {
            // Expected.
        }
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/withdraw") }.count, 1)
    }

    func testUserInitiatedRecoveryReplaysTheSameIdentityAndLedgerAndSettlesIt() async throws {
        let storage = InMemoryPendingRequestUpdateStorage()
        let store = makeStore(MutableAuthority(authorityA), updateStorage: storage)
        ClaimFlowURLProtocol.enqueue(.response(data: ownerList([ownerObject(id: "r1")])))
        await store.fetchOwnerRequests()
        ClaimFlowURLProtocol.enqueue(.failure(.timedOut))
        _ = try? await store.withdrawRequest(requestID: "r1")
        let pending = try XCTUnwrap(store.unresolvedUpdate)
        ClaimFlowURLProtocol.enqueue(.response(data: withdrawn("r1")))

        _ = try await store.retryUnresolvedUpdate(matching: pending)

        let posts = ClaimFlowURLProtocol.capturedRequests.filter { $0.path.hasSuffix("/withdraw") }
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[0].headers["x-commonplate-operation-id"], pending.operationId)
        XCTAssertEqual(posts[1].headers["x-commonplate-operation-id"], pending.operationId)
        XCTAssertEqual(
            posts[1].headers["x-commonplate-operation-authority"],
            pending.operationLedger
        )
        XCTAssertNil(store.unresolvedUpdate)
        XCTAssertTrue(storage.load().records.isEmpty)
        XCTAssertTrue(store.ownerRequests.isEmpty)
    }

    func testADecidedRefusalSettlesTheRecordAndDropsTheStaleCard() async throws {
        let storage = InMemoryPendingRequestUpdateStorage()
        let store = makeStore(MutableAuthority(authorityA), updateStorage: storage)
        ClaimFlowURLProtocol.enqueue(.response(data: ownerList([ownerObject(id: "r1")])))
        await store.fetchOwnerRequests()
        ClaimFlowURLProtocol.enqueue(.response(statusCode: 410, data: errorBody("REQUEST_EXPIRED")))

        do {
            try await store.withdrawRequest(requestID: "r1")
            XCTFail("expected a refusal")
        } catch RequestServiceError.serverError(let code, _) {
            XCTAssertEqual(code, "REQUEST_EXPIRED")
        }

        XCTAssertTrue(storage.load().records.isEmpty, "a decided refusal is not unresolved")
        XCTAssertNil(store.unresolvedUpdate)
        XCTAssertTrue(store.ownerRequests.isEmpty, "an expired request is no longer ongoing work")
    }

    func testAReservedRefusalLeavesTheRequestInPlace() async throws {
        let store = makeStore(MutableAuthority(authorityA))
        ClaimFlowURLProtocol.enqueue(.response(data: ownerList([ownerObject(id: "r1")])))
        await store.fetchOwnerRequests()
        ClaimFlowURLProtocol.enqueue(.response(statusCode: 409, data: errorBody("REQUEST_RESERVED")))

        _ = try? await store.withdrawRequest(requestID: "r1")

        XCTAssertEqual(store.ownerRequests.map(\.id), ["r1"])
        XCTAssertNil(store.unresolvedUpdate)
    }

    func testAFailedDurableSaveSendsNothing() async {
        let storage = FailingUpdateStorage()
        let store = makeStore(MutableAuthority(authorityA), updateStorage: storage)

        do {
            try await store.withdrawRequest(requestID: "r1")
            XCTFail("expected durable persistence to fail")
        } catch RequestServiceError.durablePersistenceFailed {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertTrue(ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/withdraw") }.isEmpty)
    }

    // MARK: - Edit

    func testEditReplacesTheOwnerRequestWithTheDecidedCopyAndSendsTheExpectedRevision() async throws {
        let store = makeStore(MutableAuthority(authorityA))
        ClaimFlowURLProtocol.enqueue(.response(data: ownerList([ownerObject(id: "e1", revision: 2)])))
        await store.fetchOwnerRequests()
        ClaimFlowURLProtocol.enqueue(.response(data: edited(revision: 3, request: ownerObject(id: "e1", revision: 3))))

        let outcome = try await store.editRequest(requestID: "e1", payload: payload(revision: 2))

        XCTAssertEqual(outcome.resultingRevision, 3)
        XCTAssertEqual(store.ownerRequests.first?.contentRevision, 3)
        let body = try XCTUnwrap(ClaimFlowURLProtocol.capturedRequests.last?.bodyObject)
        XCTAssertEqual(body["expectedContentRevision"] as? Int, 2)
    }

    func testAnEditRevisionConflictIsDefinitiveAndLeavesTheOwnerCopyForTheUserToReview() async {
        let storage = InMemoryPendingRequestUpdateStorage()
        let store = makeStore(MutableAuthority(authorityA), updateStorage: storage)
        ClaimFlowURLProtocol.enqueue(.response(data: ownerList([ownerObject(id: "e1", revision: 1)])))
        await store.fetchOwnerRequests()
        ClaimFlowURLProtocol.enqueue(.response(statusCode: 409, data: errorBody("REQUEST_REVISION_CONFLICT")))

        do {
            _ = try await store.editRequest(requestID: "e1", payload: payload(revision: 1))
            XCTFail("expected a conflict")
        } catch RequestServiceError.serverError(let code, _) {
            XCTAssertEqual(code, RequestUpdateErrorCode.revisionConflict)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertTrue(storage.load().records.isEmpty)
        XCTAssertEqual(store.ownerRequests.first?.contentRevision, 1, "never fabricated as edited")
    }

    func testAnUnknownEditOutcomeReplaysTheExactSubmittedPayload() async throws {
        let store = makeStore(MutableAuthority(authorityA))
        ClaimFlowURLProtocol.enqueue(.response(data: ownerList([ownerObject(id: "e1", revision: 1)])))
        await store.fetchOwnerRequests()
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        let submitted = payload(revision: 1)
        _ = try? await store.editRequest(requestID: "e1", payload: submitted)
        let pending = try XCTUnwrap(store.unresolvedUpdate)
        XCTAssertEqual(pending.editPayload, submitted)
        ClaimFlowURLProtocol.enqueue(.response(data: edited(revision: 2, request: ownerObject(id: "e1", revision: 2))))

        let outcome = try await store.retryUnresolvedUpdate(matching: pending)

        XCTAssertEqual(outcome?.resultingRevision, 2)
        let posts = ClaimFlowURLProtocol.capturedRequests.filter { $0.path.hasSuffix("/edit") }
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(
            posts[0].headers["x-commonplate-operation-id"],
            posts[1].headers["x-commonplate-operation-id"]
        )
        XCTAssertEqual(
            posts[0].bodyObject?["mealItems"] as? [[String: String]],
            posts[1].bodyObject?["mealItems"] as? [[String: String]]
        )
        XCTAssertNil(store.unresolvedUpdate)
    }

    // MARK: - Participant isolation

    func testAnotherParticipantsUnresolvedUpdateIsNeitherShownReplayedNorOverwritten() async throws {
        let authority = MutableAuthority(authorityA)
        let storage = InMemoryPendingRequestUpdateStorage()
        let store = makeStore(authority, updateStorage: storage)
        ClaimFlowURLProtocol.enqueue(.failure(.timedOut))
        _ = try? await store.withdrawRequest(requestID: "r1")
        let aRecord = try XCTUnwrap(store.unresolvedUpdate)

        // Change Email makes B current.
        authority.set(authorityB)
        store.refreshPendingCreateState()

        XCTAssertNil(store.unresolvedUpdate, "A's operation is not B's to see")
        do {
            _ = try await store.retryUnresolvedUpdate(matching: aRecord)
            XCTFail("B must not replay A's operation")
        } catch RequestServiceError.operationInProgress {
            // Expected.
        }
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/withdraw") }.count, 1)

        // B can still act, and A's record survives untouched beside B's.
        ClaimFlowURLProtocol.enqueue(.response(data: withdrawn("b-request")))
        try await store.withdrawRequest(requestID: "b-request")
        XCTAssertEqual(storage.load().records, [aRecord])

        // When A is current again, A's record is theirs again.
        authority.set(authorityA)
        store.refreshPendingCreateState()
        XCTAssertEqual(store.unresolvedUpdate, aRecord)
    }

    func testAnUnreadableHeldRecordBlocksAnyNewUpdate() async {
        let store = makeStore(
            MutableAuthority(authorityA),
            updateStorage: UnreadableUpdateStorage()
        )

        do {
            try await store.withdrawRequest(requestID: "r1")
            XCTFail("an unreadable record could be this participant's operation")
        } catch RequestServiceError.unresolvedUpdate {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/withdraw") }.isEmpty)
    }

    func testTheDurableRecordSurvivesARelaunchAndIsRecoveredForTheSameParticipant() async throws {
        let defaults = UserDefaults(suiteName: "com.commonplate.tests.update.\(UUID().uuidString)")!
        let first = makeStore(
            MutableAuthority(authorityA),
            updateStorage: UserDefaultsPendingRequestUpdateStorage(defaults: defaults)
        )
        ClaimFlowURLProtocol.enqueue(.failure(.timedOut))
        _ = try? await first.withdrawRequest(requestID: "r1")
        let before = try XCTUnwrap(first.unresolvedUpdate)

        let relaunched = makeStore(
            MutableAuthority(authorityA),
            updateStorage: UserDefaultsPendingRequestUpdateStorage(defaults: defaults)
        )

        XCTAssertEqual(relaunched.unresolvedUpdate, before)
        XCTAssertFalse(String(describing: before).contains(authorityA), "no credential in the record")
    }

    // MARK: - Replay discipline (R5 review F1, F2)

    func testAReplayMustNameTheOriginalOperationAndAnythingElseSendsNothing() async throws {
        let store = makeStore(MutableAuthority(authorityA))
        ClaimFlowURLProtocol.enqueue(.response(data: ownerList([ownerObject(id: "r1"), ownerObject(id: "r2")])))
        await store.fetchOwnerRequests()
        ClaimFlowURLProtocol.enqueue(.failure(.timedOut))
        _ = try? await store.withdrawRequest(requestID: "r1")
        let pending = try XCTUnwrap(store.unresolvedUpdate)
        let other = PendingRequestUpdate(
            operationId: UUID().uuidString.lowercased(),
            kind: .withdraw,
            requestID: "r2",
            participantIdentifier: pending.participantIdentifier,
            operationLedger: pending.operationLedger,
            editPayload: nil
        )

        do {
            _ = try await store.retryUnresolvedUpdate(matching: other)
            XCTFail("a different action is not a replay of the unresolved one")
        } catch RequestServiceError.unresolvedUpdate {
            // Expected.
        }

        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.filter { $0.hasSuffix("/withdraw") }.count, 1)
        XCTAssertEqual(store.unresolvedUpdate, pending)
    }

    func testAReplayAnsweredBeforeTheLedgerKeepsTheRecordAndStaysUnconfirmed() async throws {
        for (status, code) in [(429, "RATE_LIMITED"), (503, "PARTICIPANT_VERIFICATION_UNAVAILABLE")] {
            ClaimFlowURLProtocol.reset()
            let storage = InMemoryPendingRequestUpdateStorage()
            let store = makeStore(MutableAuthority(authorityA), updateStorage: storage)
            ClaimFlowURLProtocol.enqueue(.response(data: ownerList([ownerObject(id: "r1")])))
            await store.fetchOwnerRequests()
            ClaimFlowURLProtocol.enqueue(.failure(.timedOut))
            _ = try? await store.withdrawRequest(requestID: "r1")
            let pending = try XCTUnwrap(store.unresolvedUpdate)
            ClaimFlowURLProtocol.enqueue(.response(statusCode: status, data: errorBody(code)))

            do {
                _ = try await store.retryUnresolvedUpdate(matching: pending)
                XCTFail("a gate refusal is not a decision")
            } catch RequestServiceError.ambiguousUpdateOutcome {
                // Expected: still unconfirmed.
            }

            XCTAssertEqual(store.unresolvedUpdate, pending, "\(code) must not settle the record")
            XCTAssertEqual(storage.load().records, [pending])
            XCTAssertEqual(store.ownerRequests.map(\.id), ["r1"])
        }
    }

    func testAReplayAnsweredByTheLedgerSettlesTheRecord() async throws {
        let storage = InMemoryPendingRequestUpdateStorage()
        let store = makeStore(MutableAuthority(authorityA), updateStorage: storage)
        ClaimFlowURLProtocol.enqueue(.response(data: ownerList([ownerObject(id: "e1", revision: 1)])))
        await store.fetchOwnerRequests()
        ClaimFlowURLProtocol.enqueue(.failure(.timedOut))
        _ = try? await store.editRequest(requestID: "e1", payload: payload(revision: 1))
        let pending = try XCTUnwrap(store.unresolvedUpdate)
        ClaimFlowURLProtocol.enqueue(.response(statusCode: 409, data: errorBody("REQUEST_REVISION_CONFLICT")))

        do {
            _ = try await store.retryUnresolvedUpdate(matching: pending)
            XCTFail("expected the decided refusal")
        } catch RequestServiceError.serverError(let code, _) {
            XCTAssertEqual(code, RequestUpdateErrorCode.revisionConflict)
        }

        XCTAssertNil(store.unresolvedUpdate)
        XCTAssertTrue(storage.load().records.isEmpty)
    }

    func testAnExpiredOperationOnReplayRetiresTheRecordAndTheCard() async throws {
        let storage = InMemoryPendingRequestUpdateStorage()
        let store = makeStore(MutableAuthority(authorityA), updateStorage: storage)
        ClaimFlowURLProtocol.enqueue(.response(data: ownerList([ownerObject(id: "r1")])))
        await store.fetchOwnerRequests()
        ClaimFlowURLProtocol.enqueue(.failure(.timedOut))
        _ = try? await store.withdrawRequest(requestID: "r1")
        let pending = try XCTUnwrap(store.unresolvedUpdate)
        ClaimFlowURLProtocol.enqueue(.response(statusCode: 410, data: errorBody("OPERATION_EXPIRED")))

        _ = try? await store.retryUnresolvedUpdate(matching: pending)

        XCTAssertNil(store.unresolvedUpdate)
        XCTAssertTrue(storage.load().records.isEmpty)
        XCTAssertTrue(store.ownerRequests.isEmpty)
    }

    func testAnAuthoritativeOwnerListWithoutTheRequestRetiresItsUnresolvedRecord() async throws {
        let storage = InMemoryPendingRequestUpdateStorage()
        let store = makeStore(MutableAuthority(authorityA), updateStorage: storage)
        ClaimFlowURLProtocol.enqueue(.response(data: ownerList([ownerObject(id: "r1"), ownerObject(id: "r2")])))
        await store.fetchOwnerRequests()
        ClaimFlowURLProtocol.enqueue(.failure(.timedOut))
        _ = try? await store.withdrawRequest(requestID: "r1")
        XCTAssertNotNil(store.unresolvedUpdate)

        // r1 is still ongoing: the record must survive a refresh that lists it.
        ClaimFlowURLProtocol.enqueue(.response(data: ownerList([ownerObject(id: "r1"), ownerObject(id: "r2")])))
        await store.fetchOwnerRequests()
        XCTAssertNotNil(store.unresolvedUpdate)

        // r1 has left ongoing work: nothing is left to replay and nothing may stay blocked.
        ClaimFlowURLProtocol.enqueue(.response(data: ownerList([ownerObject(id: "r2")])))
        await store.fetchOwnerRequests()

        XCTAssertNil(store.unresolvedUpdate)
        XCTAssertTrue(storage.load().records.isEmpty)
        ClaimFlowURLProtocol.enqueue(.response(data: withdrawn("r2")))
        try await store.withdrawRequest(requestID: "r2")
        XCTAssertTrue(store.ownerRequests.isEmpty)
    }

    func testAFailedOwnerListNeverRetiresAnUnresolvedRecord() async throws {
        let storage = InMemoryPendingRequestUpdateStorage()
        let store = makeStore(MutableAuthority(authorityA), updateStorage: storage)
        ClaimFlowURLProtocol.enqueue(.response(data: ownerList([ownerObject(id: "r1")])))
        await store.fetchOwnerRequests()
        ClaimFlowURLProtocol.enqueue(.failure(.timedOut))
        _ = try? await store.withdrawRequest(requestID: "r1")
        ClaimFlowURLProtocol.enqueue(.failure(.notConnectedToInternet))

        await store.fetchOwnerRequests()

        XCTAssertNotNil(store.unresolvedUpdate, "unknown is not absence")
    }

    func testVerifiedTerminalReportsRetireTheUnresolvedRecordOfThatRequestOnly() async throws {
        let storage = InMemoryPendingRequestUpdateStorage()
        let store = makeStore(MutableAuthority(authorityA), updateStorage: storage)
        ClaimFlowURLProtocol.enqueue(.response(data: ownerList([ownerObject(id: "r1")])))
        await store.fetchOwnerRequests()
        ClaimFlowURLProtocol.enqueue(.failure(.timedOut))
        _ = try? await store.withdrawRequest(requestID: "r1")

        store.reportOwnRequestWithdrawn(requestID: "someone-else")
        XCTAssertNotNil(store.unresolvedUpdate)

        store.reportOwnRequestNoLongerOngoing(requestID: "r1")
        XCTAssertNil(store.unresolvedUpdate)
        XCTAssertTrue(storage.load().records.isEmpty)
        XCTAssertTrue(store.ownerRequests.isEmpty)
    }

    func testAWithdrawnClaimRefusalMapsToTheWithdrawnReasonNotATryAgain() {
        let error = RequestServiceError.serverError(code: "REQUEST_WITHDRAWN", message: "x")
        XCTAssertEqual(RequestStore.unavailableReason(for: error), .withdrawn)
        XCTAssertEqual(ClaimPresentationError.map(error), .noLongerAvailable)
    }

    // MARK: - Fixtures

    private func makeStore(
        _ authority: MutableAuthority,
        updateStorage: PendingRequestUpdateStorage = InMemoryPendingRequestUpdateStorage()
    ) -> RequestStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaimFlowURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
        return RequestStore(
            service: RequestService(client: client),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { authority.get() },
            participantAuthorityRejected: {},
            updateStorage: updateStorage
        )
    }

    private func payload(revision: Int) -> EditRequestPayload {
        EditRequestPayload(
            vendor: "Crave NYU",
            menuPath: .mealExchange,
            mealSwipes: 2,
            mealItems: [MealItem(name: "Chicken bowl"), MealItem(name: "Side salad")],
            orderDetails: nil,
            estimatedDiningDollarsCents: nil,
            timing: .unchanged,
            windowStart: nil,
            expectedContentRevision: revision
        )
    }

    private func waitUntil(timeoutIterations: Int = 200, condition: @MainActor () -> Bool) async {
        for _ in 0..<timeoutIterations {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }

    private func errorBody(_ code: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"detail","fields":null}}"#.utf8)
    }

    private func ownerList(_ objects: [String]) -> Data {
        Data(#"{"requests":[\#(objects.joined(separator: ","))]}"#.utf8)
    }

    private func withdrawn(_ id: String) -> Data {
        Data(#"{"outcome":"withdrawn","requestId":"\#(id)"}"#.utf8)
    }

    private func edited(revision: Int, request: String) -> Data {
        Data(#"{"outcome":"edited","resultingRevision":\#(revision),"request":\#(request)}"#.utf8)
    }

    private func ownerObject(id: String, revision: Int = 1) -> String {
        """
        {
          "id": "\(id)", "vendor": "Crave NYU", "food": "Rice bowl",
          "pickupWindowText": "ASAP", "mealSwipes": 1, "menuPath": "meal-exchange",
          "mealItems": [{"name": "Rice bowl"}], "orderDetails": null,
          "estimatedDiningDollarsCents": null, "windowStart": null, "windowEnd": null,
          "createdAt": "2026-07-20T18:30:00.000Z", "expiresAt": "2099-07-20T23:30:00.000Z",
          "timing": "asap", "phase": "available", "contentRevision": \(revision),
          "canEdit": true, "canWithdraw": true,
          "latestScheduledStart": "2026-07-21T03:30:00.000Z"
        }
        """
    }
}

private final class FailingUpdateStorage: PendingRequestUpdateStorage {
    func load() -> PendingRequestUpdateLoad { .records([]) }
    func save(_ update: PendingRequestUpdate) -> Bool { false }
    func clear(operationId: String) {}
}

private final class UnreadableUpdateStorage: PendingRequestUpdateStorage {
    func load() -> PendingRequestUpdateLoad { .unreadable }
    func save(_ update: PendingRequestUpdate) -> Bool { false }
    func clear(operationId: String) {}
}
