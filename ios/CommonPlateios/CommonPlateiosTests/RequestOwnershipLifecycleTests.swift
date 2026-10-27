//
//  RequestOwnershipLifecycleTests.swift
//  CommonPlateiosTests
//
// Focused W4-H2 coverage for the participant-authority *lifecycle* around
// caller-relative request ownership — the boundary `RequestOwnershipTests`
// (wire decoding) does not reach.
//
// Caller-relative ownership is only ever true relative to one exact
// participant authority. These cases prove that a result produced under one
// authority can never become ownership truth for another, that ownership with
// no current-authority evidence behind it fails closed instead of reading as
// an actionable "not own", and that a request this app just created under a
// still-current authenticated authority is recognised as the caller's own
// immediately.
//
// Behavioural throughout: every case drives the real
// `RequestStore`/`RequestService` path over a stubbed transport, rather than
// asserting on source text.
import Foundation
import XCTest
@testable import CommonPlateios

/// A participant-authority provider whose value changes *between* the point a
/// store operation captures it and the point that operation re-checks it —
/// which is exactly what a successful verification, Change Email, or Remove
/// Email does while a request is in flight.
private final class ScriptedAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String?]
    private var index = 0

    init(_ values: [String?]) {
        self.values = values
    }

    /// Returns each scripted value in turn, then repeats the last one — so a
    /// single change stays changed for every later read.
    func next() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let value = values[min(index, values.count - 1)]
        index += 1
        return value
    }
}

@MainActor
final class RequestOwnershipLifecycleTests: XCTestCase {
    private let authorityA = "64c0000000000000000000a1.1.credential"
    private let authorityB = "64c0000000000000000000b2.1.credential"

    override func tearDown() {
        ClaimFlowURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - List authority races

    /// W4-R5: there is no anonymous fetch any more. A fetch that starts with
    /// no authority sends nothing, so no anonymous result can ever land after a
    /// later verification and establish ownership for the verified participant.
    func testFetchStartedWithoutAuthoritySendsNothingAndEstablishesNoOwnership() async {
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a", isOwnRequest: nil)
        ])))
        let store = makeStore(ScriptedAuthority([nil, authorityB]))

        await store.fetchRequests()

        XCTAssertTrue(ClaimFlowURLProtocol.capturedPaths.isEmpty)
        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertFalse(store.hasSuccessfullyFetchedRequests)
    }

    /// Participant A fetch starts → Change Email to B succeeds → A's response
    /// lands carrying `isOwnRequest: true`. W4-R5 `R5-IR-1`: that board was
    /// served to, and filtered for, A, so none of it — data or ownership — is
    /// installed for B. (W4-H2 installed it fail-closed as `.unresolved`.)
    func testParticipantAListResultLandingAfterChangeEmailDoesNotBecomeBOwnership() async {
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a", isOwnRequest: true)
        ])))
        let store = makeStore(ScriptedAuthority([authorityA, authorityB]))

        let outcome = await store.fetchRequests()

        XCTAssertEqual(outcome, .didNotSucceed)
        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertFalse(store.hasSuccessfullyFetchedRequests)
    }

    /// The mirror case: A saw a request as *not* own. That must not become
    /// permission for B to help, because B may well be its owner — and, under
    /// `R5-IR-1`, A's board is not installed for B at all.
    func testParticipantANotOwnResultLandingAfterChangeEmailDoesNotAuthorizeB() async {
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a", isOwnRequest: nil)
        ])))
        let store = makeStore(ScriptedAuthority([authorityA, authorityB]))

        await store.fetchRequests()

        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertFalse(store.requests.contains { $0.allowsHelperAction })
    }

    /// A stable authority is the ordinary case and must still resolve fully —
    /// the fence above must not degrade every normal fetch to `.unresolved`.
    func testStableAuthorityResolvesOwnershipNormally() async {
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a", isOwnRequest: true),
            requestObject(id: "b", isOwnRequest: false),
        ])))
        let store = makeStore(ScriptedAuthority([authorityA]))

        await store.fetchRequests()

        XCTAssertEqual(store.requests.first { $0.id == "a" }?.ownership, .own)
        XCTAssertEqual(store.requests.first { $0.id == "b" }?.ownership, .notOwn)
        XCTAssertTrue(store.requests.first { $0.id == "b" }?.allowsHelperAction ?? false)
    }

    /// The cached-collection window: A's collection is already resolved, then
    /// B becomes current through a successful Change Email.
    ///
    /// W4-R5 `R5-IR-1` supersedes W4-H2 here (this test used to assert that
    /// "public request data is preserved" with ownership `.unresolved`): A's
    /// board was served to, and filtered for, A, so it is retired as soon as B
    /// is current. When B's own reload cannot complete, Home is in its initial
    /// load condition, which is Exchange Unavailable — never Empty Exchange and
    /// never A's board presented as B's.
    func testCachedCollectionIsNotHelperActionableImmediatelyAfterAuthorityChange() async {
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a", isOwnRequest: true),
            requestObject(id: "b", isOwnRequest: nil),
        ])))
        // Reads 1-2 resolve the first fetch under A; read 3 onwards is B,
        // i.e. Change Email succeeded after that collection was established.
        let store = makeStore(ScriptedAuthority([authorityA, authorityA, authorityB]))
        await store.fetchRequests()
        XCTAssertEqual(store.requests.first { $0.id == "a" }?.ownership, .own)

        // B is current now, and B's reconciling reload cannot complete.
        ClaimFlowURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.reconcileOwnershipForCurrentAuthority()

        XCTAssertTrue(store.requests.isEmpty, "A's board must not be retained for B")
        XCTAssertFalse(store.requests.contains { $0.allowsHelperAction })
        XCTAssertFalse(store.hasSuccessfullyFetchedRequests)
        XCTAssertNotNil(store.initialFetchError)
        XCTAssertEqual(HomeExchangeView.boardState(store: store), .unavailable)
    }

    /// Once B's own read resolves, B-relative ownership applies normally.
    func testReconciliationEstablishesOwnershipForTheNewParticipant() async {
        let store = makeStore(ScriptedAuthority([authorityB]))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a", isOwnRequest: false),
            requestObject(id: "b", isOwnRequest: true),
        ])))

        await store.reconcileOwnershipForCurrentAuthority()

        XCTAssertEqual(store.requests.first { $0.id == "a" }?.ownership, .notOwn)
        XCTAssertEqual(store.requests.first { $0.id == "b" }?.ownership, .own)
    }

    // MARK: - Post-create ingestion (W4-D2 Success→Home continuity)

    /// W4-D2 Success→Home continuity supersedes the former (W4-R2
    /// 2026-09-05 sync item 5) "no R2-authored Home insertion" contract for
    /// the still-current-authority case only: the Success→Home continuity
    /// sequence needs the requester-owned Home card to exist, correctly
    /// slotted, the instant Home is revealed — it cannot depend on H4's own
    /// authoritative fetch completing first. A fresh create under the still-
    /// current authority now inserts immediately, ownership-resolved
    /// `.own`; H4's own authoritative fetch still reconciles the same entry
    /// in place afterward.
    func testCreatedRequestInsertsOwnershipResolvedForTheStillCurrentAuthority() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: createResponse(id: "new-1")))
        let store = makeStore(ScriptedAuthority([authorityA]))

        try await store.createRequest(payload())

        XCTAssertEqual(store.requests.map(\.id), ["new-1"])
        XCTAssertEqual(store.requests.first?.ownership, .own)
        XCTAssertEqual(store.createdRequestContinuity?.request.id, "new-1")
    }

    /// The same non-insertion property holds regardless of whether the
    /// authority changed mid-flight — nothing is exposed either way, so there
    /// is no longer a window where an authority-changed create could leak as
    /// fabricated ownership truth.
    func testCreatedRequestDoesNotInsertRegardlessOfAuthorityChangeMidFlight() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: createResponse(id: "new-2")))
        // `createRequest`'s own leading `refreshPendingCreateState()` reads
        // the authority once before this function's own capture does, so the
        // script needs three values, not two, to actually model "captures A,
        // changed to B by confirmation time": the first satisfies that
        // leading read (also A — nothing about D1 state is under test here),
        // the second is this call's own captured `participantAuthority`, and
        // the third is the still-current authority `applyConfirmed` reads at
        // confirmation — genuinely different from the second.
        let store = makeStore(ScriptedAuthority([authorityA, authorityA, authorityB]))

        try await store.createRequest(payload())

        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertNil(store.createdRequestContinuity)
    }

    // MARK: - D1 create reconciliation (W4-D2 Success→Home continuity)

    /// The identical still-current-authority insertion property for a
    /// recovered D1 create: `Check again`'s reconciled CREATED outcome
    /// enters the same Success→Home continuity screen as a fresh create, so
    /// it needs the same immediate, ownership-resolved Home presence.
    func testReconciledCreateInsertsOwnershipResolvedForTheStillCurrentAuthority() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        storage.save(pendingRecord(operationId: "recover-own"))
        ClaimFlowURLProtocol.enqueue(.response(data: createResponse(id: "recovered-1")))
        let store = makeStore(ScriptedAuthority([authorityA]), operationStorage: storage)

        let reconciled = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertTrue(reconciled)
        XCTAssertEqual(store.requests.map(\.id), ["recovered-1"])
        XCTAssertEqual(store.requests.first?.ownership, .own)
        XCTAssertEqual(store.createdRequestContinuity?.request.id, "recovered-1")
    }

    /// Same non-insertion property when the authority changed while
    /// reconciliation was in flight.
    func testReconciledCreateDoesNotInsertRegardlessOfAuthorityChangeMidFlight() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        storage.save(pendingRecord(operationId: "recover-changed"))
        ClaimFlowURLProtocol.enqueue(.response(data: createResponse(id: "recovered-2")))
        let store = makeStore(
            ScriptedAuthority([authorityA, authorityB]),
            operationStorage: storage
        )

        _ = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertTrue(store.requests.isEmpty)
    }

    // MARK: - Notification-driven detail

    /// The production notification path resolves through the real detail
    /// route, which now derives caller-relative ownership.
    func testNotificationDetailResolvesOwnershipForCurrentAuthority() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(id: "d1", isOwnRequest: true)))
        let store = makeStore(ScriptedAuthority([authorityA]))

        let resolution = try await store.resolveHelperNotificationRequest(id: "d1")

        guard case .available(let request) = resolution else {
            return XCTFail("expected an available resolution, got \(resolution)")
        }
        XCTAssertEqual(request.ownership, .own)
        XCTAssertFalse(request.allowsHelperAction)
    }

    /// A participant change during the detail read makes the returned
    /// ownership a conclusion about someone else.
    func testNotificationDetailOwnershipIsUnresolvedWhenAuthorityChangesMidFlight() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(id: "d2", isOwnRequest: nil)))
        let store = makeStore(ScriptedAuthority([authorityA, authorityB]))

        let resolution = try await store.resolveHelperNotificationRequest(id: "d2")

        guard case .available(let request) = resolution else {
            return XCTFail("expected an available resolution, got \(resolution)")
        }
        XCTAssertEqual(request.ownership, .unresolved)
        XCTAssertFalse(request.allowsHelperAction)
    }

    /// The detail route genuinely answers "not yours" for a non-owner, so a
    /// resolved detail read may expose helper behaviour subject to the other
    /// eligibility gates.
    func testNotificationDetailForNonOwnerResolvesNotOwn() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(id: "d3", isOwnRequest: false)))
        let store = makeStore(ScriptedAuthority([authorityA]))

        let resolution = try await store.resolveHelperNotificationRequest(id: "d3")

        guard case .available(let request) = resolution else {
            return XCTFail("expected an available resolution, got \(resolution)")
        }
        XCTAssertEqual(request.ownership, .notOwn)
        XCTAssertTrue(request.allowsHelperAction)
    }

    // MARK: - Response shapes that derive no ownership at all

    /// A claim response embeds a request, but that shape never carries
    /// caller-relative ownership. Absent metadata there must map to
    /// `.unresolved`, not to an actionable `.notOwn`.
    func testClaimEmbeddedRequestOwnershipIsUnresolved() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(id: "c1")))
        let service = makeService()

        let outcome = try await service.claimRequest(
            id: "c1",
            participantAuthority: authorityA
        )

        XCTAssertEqual(outcome.request.ownership, .unresolved)
    }

    // MARK: - Privacy

    /// No request-identity material may reach the domain model from any of
    /// these paths — the wire carries only the caller-relative boolean.
    func testOwnershipCarriesNoParticipantIdentityMaterial() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a", isOwnRequest: true)
        ])))
        let store = makeStore(ScriptedAuthority([authorityA]))

        await store.fetchRequests()

        let mirror = Mirror(reflecting: try XCTUnwrap(store.requests.first))
        let fields = mirror.children.compactMap(\.label)
        XCTAssertFalse(fields.contains("requesterParticipantId"))
        XCTAssertFalse(fields.contains("participantId"))
        XCTAssertFalse(fields.contains("email"))
        XCTAssertEqual(store.requests.first?.ownership, .own)
    }

    // MARK: - Fixtures

    private func makeStore(
        _ authority: ScriptedAuthority,
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

    /// The durable D1 record, bound to participant A's identifier — the same
    /// principal `authorityA` resolves to.
    private func pendingRecord(operationId: String) -> PendingRequestOperationRecord {
        PendingRequestOperationRecord(
            operationId: operationId,
            participantIdentifier: "64c0000000000000000000a1",
            operationAuthority: RequestOperationAuthorityIdentity(
                origin: RequestService.operationAuthorityOrigin(for: URL(string: "https://commonplate.test")!),
                ledger: RequestFetchingURLProtocol.defaultOperationLedger
            ),
            payload: CreateRequestPayload(
                vendor: "Crave NYU",
                timing: .asap,
                windowStart: nil,
                menuPath: .mealExchange,
                mealSwipes: 2,
                mealItems: ["Rice bowl", "Side salad"],
                orderDetails: nil,
                estimatedDiningDollarsCents: nil
            )
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

    private func payload() -> CreateRequestPayload {
        CreateRequestPayload(
            vendor: "Crave NYU",
            timing: .asap,
            windowStart: nil,
            menuPath: .mealExchange,
            mealSwipes: 2,
            mealItems: ["Rice bowl"],
            orderDetails: nil,
            estimatedDiningDollarsCents: nil
        )
    }

    private func listResponse(_ objects: [String]) -> Data {
        Data(#"{"requests":[\#(objects.joined(separator: ","))]}"#.utf8)
    }

    private func detailResponse(id: String, isOwnRequest: Bool?) -> Data {
        Data(#"{"request":\#(requestObject(id: id, isOwnRequest: isOwnRequest))}"#.utf8)
    }

    private func createResponse(id: String) -> Data {
        // The create response shape carries no `isOwnRequest`.
        Data(#"{"request":\#(requestObject(id: id, isOwnRequest: nil))}"#.utf8)
    }

    private func claimResponse(id: String) -> Data {
        Data(#"""
        {
          "request": \#(requestObject(id: id, isOwnRequest: nil, status: "claimed")),
          "claim": {
            "pickupName": "Alex",
            "claimToken": "token-\#(id)",
            "claimExpiresAt": "2026-07-20T19:30:00.000Z"
          }
        }
        """#.utf8)
    }

    private func requestObject(
        id: String,
        isOwnRequest: Bool?,
        status: String = "open"
    ) -> String {
        let ownField = isOwnRequest.map { ",\n  \"isOwnRequest\": \($0)" } ?? ""
        return """
        {
          "id": "\(id)",
          "vendor": "Crave NYU",
          "food": "Rice bowl",
          "pickupWindowText": "ASAP",
          "mealSwipes": 2,
          "menuPath": "meal-exchange",
          "mealItems": ["Meal 1", "Meal 2"],
          "orderDetails": null,
          "estimatedDiningDollarsCents": null,
          "windowStart": null,
          "windowEnd": null,
          "status": "\(status)",
          "createdAt": "2026-07-20T18:30:00.000Z",
          "expiresAt": "2026-07-20T23:30:00.000Z"\(ownField)
        }
        """
    }
}
