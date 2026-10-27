//
//  RequestCreationContinuityTests.swift
//  CommonPlateiosTests
//
// Focused W4-D2 coverage for the *lifetime* of the Success→Home continuity
// presentation state — the boundary `RequestOwnershipLifecycleTests`
// (ownership resolution and insertion) does not reach.
//
// The invariant under test: a continuity presentation always represents the
// exact operation just authoritatively confirmed CREATED for the authority
// current now. A card from an earlier, interrupted, superseded, or
// differently-authorized operation can never be presented for a later create,
// participant, or session, and a create whose authority changed mid-flight
// publishes no continuity at all rather than a fabricated one.
//
// Behavioural throughout: every case drives the real
// `RequestStore`/`RequestService` path over a stubbed transport, rather than
// asserting on source text.
import Foundation
import XCTest
@testable import CommonPlateios

/// A participant-authority provider whose value changes between reads, exactly
/// as a successful verification, Change Email, or Remove Email does.
private final class ContinuityScriptedAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [String?]
    private var index = 0

    init(_ values: [String?]) {
        self.values = values
    }

    func next() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let value = values[min(index, values.count - 1)]
        index += 1
        return value
    }
}

/// A participant authority that is stable until a test changes it — the shape
/// of a verification, Change Email, or Remove Email landing *between* store
/// operations rather than during one.
private final class MutableAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    init(_ value: String?) {
        stored = value
    }

    var value: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

@MainActor
final class RequestCreationContinuityTests: XCTestCase {
    private let authorityA = "64c0000000000000000000a1.1.credential"
    private let authorityB = "64c0000000000000000000b2.1.credential"

    override func tearDown() {
        ClaimFlowURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Publication under the current authority

    /// The ordinary accepted path: a create authoritatively confirmed CREATED
    /// under the still-current authority publishes continuity for *that*
    /// request, bound to the operation identity that was actually sent and to
    /// the authority that created it — and that request really is in the
    /// collection Home renders, resolved as this participant's own, so the
    /// presentation has a real first slot to land in.
    func testSuccessfulCurrentAuthorityCreatePublishesTheCreatedRequestContinuity() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: createResponse(id: "new-1")))
        let store = makeStore(ContinuityScriptedAuthority([authorityA]))

        try await store.createRequest(payload())

        let continuity = try XCTUnwrap(store.createdRequestContinuity)
        XCTAssertEqual(continuity.request.id, "new-1")
        XCTAssertEqual(continuity.participantAuthority, authorityA)
        XCTAssertFalse(continuity.operationId.isEmpty)
        XCTAssertTrue(continuity.request.isOwnRequest)
        XCTAssertEqual(store.requests.map(\.id), ["new-1"])
    }

    /// A reconciled CREATED — `Check again`, or cold-launch reconciliation —
    /// obeys exactly the same rule as a fresh create, including carrying the
    /// recovered operation's own identity rather than a new one.
    func testReconciledCreatedPublishesContinuityUnderTheSameRule() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        storage.save(pendingRecord(operationId: "recover-1"))
        ClaimFlowURLProtocol.enqueue(.response(data: createResponse(id: "recovered-1")))
        let store = makeStore(ContinuityScriptedAuthority([authorityA]), operationStorage: storage)

        let reconciled = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertTrue(reconciled)
        let continuity = try XCTUnwrap(store.createdRequestContinuity)
        XCTAssertEqual(continuity.request.id, "recovered-1")
        XCTAssertEqual(continuity.operationId, "recover-1")
        XCTAssertEqual(continuity.participantAuthority, authorityA)
        XCTAssertTrue(continuity.request.isOwnRequest)
    }

    // MARK: - Authority cannot publish an invalid continuity

    /// An authority that changed while the create was in flight publishes no
    /// continuity: `applyConfirmed` correctly refuses to resolve the created
    /// request as this participant's own or to insert it, so there is no
    /// current-authority card to present and none is fabricated. The Success
    /// presentation is therefore never entered with a missing card.
    func testAuthorityChangeMidCreatePublishesNoContinuity() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: createResponse(id: "new-2")))
        // Reads, in order: the leading `refreshPendingCreateState()`, this
        // call's own captured authority, and `applyConfirmed`'s single
        // still-current read — genuinely different by then.
        let store = makeStore(ContinuityScriptedAuthority([authorityA, authorityA, authorityB]))

        try await store.createRequest(payload())

        XCTAssertNil(store.createdRequestContinuity)
        XCTAssertTrue(store.requests.isEmpty)
    }

    /// The same rule for reconciliation, in its fail-closed direction: an
    /// operation recorded for a participant who is no longer the one current
    /// is not this authority's to act on. Nothing is sent, nothing is
    /// retired, and — the property under test here — no continuity is
    /// published for it, so a request created for someone else can never be
    /// presented to whoever is verified now.
    func testReconciliationForANonCurrentParticipantPublishesNoContinuity() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        storage.save(pendingRecord(operationId: "recover-2"))
        ClaimFlowURLProtocol.enqueue(.response(data: createResponse(id: "recovered-2")))
        let store = makeStore(MutableAuthority(authorityB), operationStorage: storage)

        let reconciled = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertFalse(reconciled)
        XCTAssertTrue(
            ClaimFlowURLProtocol.capturedPaths.isEmpty,
            "another participant's operation must not be acted on from here"
        )
        XCTAssertNil(store.createdRequestContinuity)
        XCTAssertTrue(store.requests.isEmpty)
    }

    /// And the genuinely mid-flight direction: the participant is replaced
    /// while the reconciliation's own request is in flight, so the CREATED
    /// answer that lands is A's conclusion, not B's. It resolves ownership
    /// closed and publishes no continuity.
    func testAuthorityChangeMidReconciliationPublishesNoContinuity() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        storage.save(pendingRecord(operationId: "recover-3"))
        ClaimFlowURLProtocol.enqueue(.response(data: createResponse(id: "recovered-3")))
        // Reads, in order: the leading refresh, the pass's own captured
        // authority, and the per-operation guard that keeps the pass acting
        // only for the authority it started as — all still A, so the
        // reconciliation genuinely runs — then `applyConfirmed`'s single
        // still-current read, by which point the participant has been
        // replaced.
        let store = makeStore(
            ContinuityScriptedAuthority([authorityA, authorityA, authorityA, authorityB]),
            operationStorage: storage
        )

        _ = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertFalse(
            ClaimFlowURLProtocol.capturedPaths.isEmpty,
            "the reconciliation must actually have run for this case to mean anything"
        )
        XCTAssertNil(store.createdRequestContinuity)
        XCTAssertTrue(store.requests.isEmpty)
    }

    /// A participant verified, replaced, removed, or discarded while the
    /// presentation is still running retires it: the card belongs to the
    /// authority that created it, and no other participant may be shown it.
    func testParticipantChangeRetiresALiveContinuity() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: createResponse(id: "new-3")))
        // A participant that is stably A for the whole create, and becomes B
        // afterwards — the ordinary shape of a verification, Change Email, or
        // Remove Email landing after the request was posted. Driven by value
        // rather than by a read count, so this case cannot silently start
        // testing something else if the store's internal read pattern changes.
        let authority = MutableAuthority(authorityA)
        let store = makeStore(authority)

        try await store.createRequest(payload())
        XCTAssertNotNil(store.createdRequestContinuity)

        authority.value = authorityB
        // Exactly what `ContentView` calls when participant identity changes.
        store.refreshPendingCreateState()

        XCTAssertNil(store.createdRequestContinuity)
    }

    // MARK: - Retirement, supersession, and cancellation

    /// Retirement is addressed to one exact presentation identity. A late
    /// callback from a superseded presentation — a cancelled Success task, a
    /// view that disappeared — can never retire a continuity confirmed after
    /// it.
    func testRetirementIsScopedToTheExactPresentationIdentity() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: createResponse(id: "new-4")))
        let store = makeStore(ContinuityScriptedAuthority([authorityA]))

        try await store.createRequest(payload())
        let continuity = try XCTUnwrap(store.createdRequestContinuity)

        store.retireCreationContinuity(id: UUID())
        XCTAssertEqual(store.createdRequestContinuity?.id, continuity.id)

        store.retireCreationContinuity(id: continuity.id)
        XCTAssertNil(store.createdRequestContinuity)

        // Idempotent: retiring again changes nothing.
        store.retireCreationContinuity(id: continuity.id)
        XCTAssertNil(store.createdRequestContinuity)
    }

    /// Cancellation before the normal timed cleanup — the presentation going
    /// away mid-dwell — cannot leave continuity state behind for a later
    /// create to inherit, and the next create publishes a genuinely new
    /// presentation rather than reviving the old one.
    func testCancelledPresentationLeavesNothingReusableForALaterCreate() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: createResponse(id: "first")))
        let store = makeStore(ContinuityScriptedAuthority([authorityA]))

        try await store.createRequest(payload())
        let first = try XCTUnwrap(store.createdRequestContinuity)

        // The overlay's own disappearance path, before its dwell completed.
        store.retireCreationContinuity(id: first.id)
        XCTAssertNil(store.createdRequestContinuity)

        ClaimFlowURLProtocol.enqueue(.response(data: createResponse(id: "second")))
        try await store.createRequest(payload())

        let second = try XCTUnwrap(store.createdRequestContinuity)
        XCTAssertEqual(second.request.id, "second")
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertNotEqual(second.operationId, first.operationId)
    }

    /// A later create supersedes an earlier presentation even when it never
    /// reaches CREATED itself: the earlier request's card must not survive as
    /// the apparent outcome of this attempt.
    func testALaterFailingCreateStillRetiresThePriorContinuity() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: createResponse(id: "first")))
        let store = makeStore(ContinuityScriptedAuthority([authorityA]))

        try await store.createRequest(payload())
        XCTAssertNotNil(store.createdRequestContinuity)

        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        do {
            try await store.createRequest(payload())
            XCTFail("transport loss after submission must be ambiguous")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected: write-uncertain, not created.
        }

        XCTAssertNil(
            store.createdRequestContinuity,
            "an ambiguous later create must not present the previous request's card"
        )
    }

    /// A reconciliation pass that resolves to authoritative NO-CREATE retires
    /// any earlier presentation too — the requester is being told nothing was
    /// posted, so no `Request posted` card may remain live behind it.
    func testTerminalNoCreateReconciliationRetiresThePriorContinuity() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        ClaimFlowURLProtocol.enqueue(.response(data: createResponse(id: "first")))
        let store = makeStore(ContinuityScriptedAuthority([authorityA]), operationStorage: storage)

        try await store.createRequest(payload())
        XCTAssertNotNil(store.createdRequestContinuity)

        storage.save(pendingRecord(operationId: "terminal-1"))
        // The exact replay of a readable payload answered by terminal
        // NO-CREATE authority for that exact operation (Path A).
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 409,
            data: Data(#"{"error":{"code":"OPERATION_NOT_CREATED","message":"backend detail"}}"#.utf8)
        ))

        _ = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertEqual(
            store.createRecoveryPresentation,
            .notCreatedRecoverable,
            "this case only means something if the pass really reached terminal NO-CREATE"
        )
        XCTAssertNil(store.createdRequestContinuity)
    }

    // MARK: - Fixtures

    private func makeStore(
        _ authority: ContinuityScriptedAuthority,
        operationStorage: PendingRequestOperationStorage = InMemoryPendingRequestOperationStorage()
    ) -> RequestStore {
        RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { authority.next() },
            participantAuthorityRejected: {},
            operationStorage: operationStorage
        )
    }

    private func makeStore(
        _ authority: MutableAuthority,
        operationStorage: PendingRequestOperationStorage = InMemoryPendingRequestOperationStorage()
    ) -> RequestStore {
        RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { authority.value },
            participantAuthorityRejected: {},
            operationStorage: operationStorage
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

    private func pendingRecord(operationId: String) -> PendingRequestOperationRecord {
        PendingRequestOperationRecord(
            operationId: operationId,
            participantIdentifier: "64c0000000000000000000a1",
            operationAuthority: RequestOperationAuthorityIdentity(
                origin: RequestService.operationAuthorityOrigin(
                    for: URL(string: "https://commonplate.test")!
                ),
                ledger: RequestFetchingURLProtocol.defaultOperationLedger
            ),
            payload: payload()
        )
    }

    private func payload() -> CreateRequestPayload {
        CreateRequestPayload(
            vendor: "Crave NYU",
            timing: .asap,
            windowStart: nil,
            menuPath: .mealExchange,
            mealSwipes: 2,
            mealItems: ["Rice bowl", "Side salad"],
            orderDetails: nil,
            estimatedDiningDollarsCents: nil
        )
    }

    private func createResponse(id: String) -> Data {
        // The create response shape carries no `isOwnRequest`; ownership is
        // resolved by the store under the authority that created it.
        Data(#"""
        {
          "request": {
            "id": "\#(id)",
            "vendor": "Crave NYU",
            "food": "Rice bowl",
            "pickupWindowText": "ASAP",
            "mealSwipes": 2,
            "menuPath": "meal-exchange",
            "mealItems": ["Meal 1"],
            "orderDetails": null,
            "estimatedDiningDollarsCents": null,
            "windowStart": null,
            "windowEnd": null,
            "status": "open",
            "createdAt": "2026-07-20T18:30:00.000Z",
            "expiresAt": "2026-07-20T23:30:00.000Z"
          }
        }
        """#.utf8)
    }
}
