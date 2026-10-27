//
//  RequestIdentityReplacementTests.swift
//  CommonPlateiosTests
//
// Focused W4-R5 `R5-IR-1` / `R5-IR-2` coverage.
//
// `R5-IR-1`: the request board is bound to the participant it was served to.
// While a Change Email is pending, cancelled or failed the current participant
// does not change, so nothing is invalidated. Once a *different* participant
// is current the previous participant's board is retired at once, a read that
// was issued for them can no longer install anything, and the replacement's
// own load either installs their board or ends in Exchange Unavailable — never
// a fabricated Empty Exchange. A same-participant refresh failure keeps W4-H2's
// stale-healthy board.
//
// `R5-IR-2`: Change Email replaces the credential this installation holds. The
// client never treats the old credential as revoked, and private
// participant-bound recovery state is not consumed by the board's invalidation.
//
// Behavioural throughout: the real `RequestStore`, `RequestService` and
// `ParticipantIdentityStore` run over stubbed transports.
import Foundation
import XCTest
@testable import CommonPlateios

/// A participant-authority provider whose value is set explicitly, so a test
/// decides exactly when "Change Email succeeded" happens relative to a read.
private final class SettableAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(_ value: String?) {
        self.value = value
    }

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: String?) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

@MainActor
final class RequestIdentityReplacementTests: XCTestCase {
    private let authorityA = canonicalParticipantAuthorityFixture
    private let authorityB = replacementParticipantAuthorityFixture

    override func tearDown() {
        ClaimFlowURLProtocol.reset()
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - R5-IR-1 req 1: pending / cancelled / failed Change Email

    func testPendingChangeEmailLeavesTheOriginalBoardAndIdentityIntact() async throws {
        let (identity, store) = try await makeEstablishedBoard()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))

        identity.beginEmailReplacement()
        await identity.requestCode(for: "replacement@stern.nyu.edu")

        XCTAssertFalse(store.invalidateRequestDataIfIdentityReplaced())
        XCTAssertEqual(identity.currentAuthority(), authorityA)
        XCTAssertEqual(store.requests.map(\.id), ["a1", "a2"])
        XCTAssertEqual(store.requests.first?.ownership, .own)
        XCTAssertTrue(store.hasSuccessfullyFetchedRequests)
    }

    func testFailedChangeEmailCodeLeavesTheOriginalBoardIntact() async throws {
        let (identity, store) = try await makeEstablishedBoard()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 400, data: errorResponse(code: "VERIFICATION_CODE_INVALID"))
        )

        identity.beginEmailReplacement()
        await identity.requestCode(for: "replacement@stern.nyu.edu")
        let verified = await identity.submitCode("999999")

        XCTAssertFalse(verified)
        XCTAssertFalse(store.invalidateRequestDataIfIdentityReplaced())
        XCTAssertEqual(store.requests.map(\.id), ["a1", "a2"])
        XCTAssertEqual(HomeExchangeView.boardState(store: store), .populated(store.requests))
    }

    func testCancelledChangeEmailLeavesTheOriginalBoardIntact() async throws {
        let (identity, store) = try await makeEstablishedBoard()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))

        identity.beginEmailReplacement()
        await identity.requestCode(for: "replacement@stern.nyu.edu")
        identity.cancelVerification()

        XCTAssertFalse(store.invalidateRequestDataIfIdentityReplaced())
        // A reconcile after cancellation is an ordinary same-identity reload.
        ClaimFlowURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.reconcileOwnershipForCurrentAuthority()
        XCTAssertEqual(store.requests.map(\.id), ["a1", "a2"], "same identity: stale-healthy")
    }

    // MARK: - R5-IR-1 req 2, 4, 5: successful replacement

    func testSuccessfulReplacementRetiresTheOldBoardImmediately() async throws {
        let (identity, store) = try await makeEstablishedBoard()
        try await completeChangeEmail(identity, to: "replacement@stern.nyu.edu", authority: authorityB)
        XCTAssertEqual(identity.currentAuthority(), authorityB)

        // Same turn, before any reload has been scheduled or answered.
        XCTAssertTrue(store.invalidateRequestDataIfIdentityReplaced())

        XCTAssertTrue(store.requests.isEmpty, "no old-principal card survives")
        XCTAssertFalse(store.hasSuccessfullyFetchedRequests)
        XCTAssertFalse(store.isFetching)
        XCTAssertNil(store.initialFetchError)
        XCTAssertNil(store.refreshError)
        // Not Unavailable and not Empty: the replacement's board is simply not
        // established yet.
        XCTAssertEqual(HomeExchangeView.boardState(store: store), .loading)
        // Retiring is idempotent.
        XCTAssertFalse(store.invalidateRequestDataIfIdentityReplaced())
    }

    func testReplacementLoadInstallsOnlyTheNewPrincipalsBoard() async throws {
        let (identity, store) = try await makeEstablishedBoard()
        try await completeChangeEmail(identity, to: "replacement@stern.nyu.edu", authority: authorityB)
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "b1", isOwnRequest: true),
            requestObject(id: "a1", isOwnRequest: false),
        ])))

        await store.reconcileOwnershipForCurrentAuthority()

        XCTAssertEqual(store.requests.map(\.id), ["b1", "a1"])
        XCTAssertEqual(store.requests.first { $0.id == "b1" }?.ownership, .own)
        // A request both principals can see is now relative to B, not A.
        XCTAssertEqual(store.requests.first { $0.id == "a1" }?.ownership, .notOwn)
        XCTAssertEqual(ClaimFlowURLProtocol.capturedRequests.last?.headers["x-commonplate-participant"], authorityB)
    }

    func testReplacementLoadFailureIsUnavailableNeverEmpty() async throws {
        let (identity, store) = try await makeEstablishedBoard()
        try await completeChangeEmail(identity, to: "replacement@stern.nyu.edu", authority: authorityB)
        ClaimFlowURLProtocol.enqueue(.failure(.timedOut))

        await store.reconcileOwnershipForCurrentAuthority()

        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertEqual(HomeExchangeView.boardState(store: store), .unavailable)
        XCTAssertNotEqual(HomeExchangeView.boardState(store: store), .empty)
    }

    func testReplacementLoadServerErrorIsUnavailableNeverEmpty() async throws {
        let (identity, store) = try await makeEstablishedBoard()
        try await completeChangeEmail(identity, to: "replacement@stern.nyu.edu", authority: authorityB)
        ClaimFlowURLProtocol.enqueue(.response(statusCode: 503, data: Data(
            #"{"error":{"code":"PARTICIPANT_VERIFICATION_UNAVAILABLE","message":"x","fields":null}}"#.utf8
        )))

        await store.fetchRequests()

        XCTAssertEqual(HomeExchangeView.boardState(store: store), .unavailable)
    }

    func testAnAuthoritativeEmptyReplacementBoardIsEmptyNotUnavailable() async throws {
        let (identity, store) = try await makeEstablishedBoard()
        try await completeChangeEmail(identity, to: "replacement@stern.nyu.edu", authority: authorityB)
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([])))

        await store.reconcileOwnershipForCurrentAuthority()

        XCTAssertEqual(HomeExchangeView.boardState(store: store), .empty)
    }

    func testAnEntryPointThatSkipsTheSynchronousHookStillRetiresTheOldBoard() async throws {
        let (identity, store) = try await makeEstablishedBoard()
        try await completeChangeEmail(identity, to: "replacement@stern.nyu.edu", authority: authorityB)
        ClaimFlowURLProtocol.enqueue(.failure(.notConnectedToInternet))

        // A plain refresh (no reconcile call, no invalidation call) must not
        // become a stale-healthy refresh of someone else's board.
        await store.fetchRequests()

        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertEqual(HomeExchangeView.boardState(store: store), .unavailable)
    }

    // MARK: - R5-IR-1 req 3: old responses completing after replacement

    func testAnInitialListIssuedForThePreviousPrincipalInstallsNothingAfterReplacement() async {
        let authority = SettableAuthority(authorityA)
        let store = makeStore(authority)
        let gate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            data: listResponse([requestObject(id: "a1", isOwnRequest: true)]),
            gate: gate
        ))

        let inFlight = Task { await store.fetchRequests() }
        await waitUntil { gate.isWaiting }
        authority.set(authorityB)
        gate.open()
        let outcome = await inFlight.value

        XCTAssertEqual(outcome, .didNotSucceed)
        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertFalse(store.hasSuccessfullyFetchedRequests)
        XCTAssertFalse(store.isFetching)
    }

    func testARefreshIssuedForThePreviousPrincipalInstallsNothingAfterReplacement() async {
        let authority = SettableAuthority(authorityA)
        let store = makeStore(authority)
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a1", isOwnRequest: true)
        ])))
        await store.fetchRequests()
        XCTAssertEqual(store.requests.map(\.id), ["a1"])

        let gate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            data: listResponse([requestObject(id: "a-late", isOwnRequest: true)]),
            gate: gate
        ))
        let refresh = Task { await store.fetchRequests() }
        await waitUntil { gate.isWaiting }
        XCTAssertTrue(store.isRefreshingRequests)

        authority.set(authorityB)
        XCTAssertTrue(store.invalidateRequestDataIfIdentityReplaced())
        gate.open()
        let outcome = await refresh.value

        XCTAssertEqual(outcome, .didNotSucceed)
        XCTAssertTrue(store.requests.isEmpty, "the late A list must not land for B")
        XCTAssertFalse(store.isRefreshingRequests)
        XCTAssertFalse(store.hasSuccessfullyFetchedRequests)
    }

    func testAnOldListLandingAfterTheReplacementsOwnLoadDoesNotOverwriteIt() async {
        let authority = SettableAuthority(authorityA)
        let store = makeStore(authority)
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a1", isOwnRequest: true)
        ])))
        await store.fetchRequests()

        let gate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            data: listResponse([requestObject(id: "a-late", isOwnRequest: true)]),
            gate: gate
        ))
        let oldRefresh = Task { await store.fetchRequests() }
        await waitUntil { gate.isWaiting }

        authority.set(authorityB)
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "b1", isOwnRequest: true)
        ])))
        await store.reconcileOwnershipForCurrentAuthority()
        XCTAssertEqual(store.requests.map(\.id), ["b1"])

        gate.open()
        _ = await oldRefresh.value

        XCTAssertEqual(store.requests.map(\.id), ["b1"])
        XCTAssertEqual(store.requests.first?.ownership, .own)
    }

    func testAFailureForThePreviousPrincipalSaysNothingAboutTheNewBoard() async {
        let authority = SettableAuthority(authorityA)
        let store = makeStore(authority)
        let gate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.failure(.notConnectedToInternet, gate: gate))

        let inFlight = Task { await store.fetchRequests() }
        await waitUntil { gate.isWaiting }
        authority.set(authorityB)
        gate.open()
        _ = await inFlight.value

        XCTAssertNil(store.initialFetchError)
        XCTAssertFalse(store.hasFailedInitialFetchAtLeastOnce)
    }

    func testAnOldDetailReadResolvesToUnresolvedOwnershipForTheNewPrincipal() async {
        let authority = SettableAuthority(authorityA)
        let store = makeStore(authority)
        let gate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            data: Data(#"{"request":\#(requestObject(id: "a1", isOwnRequest: true))}"#.utf8),
            gate: gate
        ))

        let resolution = Task { await store.resolveOwnership(requestID: "a1") }
        await waitUntil { gate.isWaiting }
        authority.set(authorityB)
        gate.open()

        let ownership = await resolution.value
        XCTAssertEqual(ownership, .unresolved)
    }

    // MARK: - R5-IR-1 req 6: same identity

    func testSameIdentityRefreshFailureKeepsTheStaleHealthyBoard() async {
        let authority = SettableAuthority(authorityA)
        let store = makeStore(authority)
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a1", isOwnRequest: true)
        ])))
        await store.fetchRequests()
        ClaimFlowURLProtocol.enqueue(.failure(.notConnectedToInternet))

        await store.fetchRequests()

        XCTAssertEqual(store.requests.map(\.id), ["a1"])
        XCTAssertTrue(store.hasSuccessfullyFetchedRequests)
        XCTAssertNotNil(store.refreshError)
        XCTAssertNil(store.initialFetchError)
        XCTAssertEqual(HomeExchangeView.boardState(store: store), .populated(store.requests))
    }

    func testReverifyingTheSamePrincipalIsNotAnIdentityReplacement() async throws {
        let (identity, store) = try await makeEstablishedBoard()
        // Change Email to the very same address: the backend issues the same
        // deterministic credential, so the client sees the same principal.
        try await completeChangeEmail(identity, to: "taylor@nyu.edu", authority: authorityA)

        XCTAssertFalse(store.invalidateRequestDataIfIdentityReplaced())
        ClaimFlowURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.reconcileOwnershipForCurrentAuthority()

        XCTAssertEqual(store.requests.map(\.id), ["a1", "a2"], "same principal: stale-healthy")
        XCTAssertEqual(store.requests.first?.ownership, .own)
    }

    // MARK: - D-R5-2: identity retirement is privacy-first

    func testRetiringTheIdentityRemovesItsBoardAtOnceAndNeverPresentsItAgain() async throws {
        let (identity, store) = try await makeEstablishedBoard()
        identity.discardRejectedIdentity()

        XCTAssertTrue(store.invalidateRequestDataIfIdentityReplaced(), "retirement retires the board")
        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertFalse(store.hasSuccessfullyFetchedRequests)

        // The reload that follows can only be Exchange Unavailable: nothing is
        // sent without an identity and nothing stale is shown in its place.
        await store.reconcileOwnershipForCurrentAuthority()
        XCTAssertTrue(store.requests.isEmpty)
        guard case .participantAuthorityRequired? = store.initialFetchError else {
            return XCTFail("expected Exchange Unavailable, got \(String(describing: store.initialFetchError))")
        }
        XCTAssertFalse(store.hasSuccessfullyFetchedRequests, "never a fabricated Empty Exchange")
    }

    func testRetirementAlsoRemovesTheOwnerListAndEveryNoticeAboutIt() async throws {
        let authority = SettableAuthority(authorityA)
        let store = makeStore(authority)
        ClaimFlowURLProtocol.enqueue(.response(data: ownerListResponse(["a-own"])))
        await store.fetchOwnerRequests()
        XCTAssertEqual(store.ownerRequests.map(\.id), ["a-own"])
        store.reportOwnRequestWithdrawn(requestID: "elsewhere")
        XCTAssertNotNil(store.requesterNotice)

        authority.set(nil)
        XCTAssertTrue(store.invalidateRequestDataIfIdentityReplaced())

        XCTAssertTrue(store.ownerRequests.isEmpty)
        XCTAssertFalse(store.hasLoadedOwnerRequests)
        XCTAssertNil(store.requesterNotice, "a retired identity's notice names its request")
    }

    func testAnotherParticipantVerifyingAfterRetirementNeverSeesTheRetiredBoardOrOwnerList() async throws {
        let authority = SettableAuthority(authorityA)
        let store = makeStore(authority)
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([requestObject(id: "a1", isOwnRequest: true)])))
        await store.fetchRequests()
        ClaimFlowURLProtocol.enqueue(.response(data: ownerListResponse(["a-own"])))
        await store.fetchOwnerRequests()
        authority.set(nil)
        XCTAssertTrue(store.invalidateRequestDataIfIdentityReplaced())
        authority.set(authorityB)

        XCTAssertFalse(store.invalidateRequestDataIfIdentityReplaced(), "already retired; nothing left to show")
        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertTrue(store.ownerRequests.isEmpty)
    }

    func testRetirementLeavesDurableUpdateRecordsAndTheirParticipantBindingUntouched() async throws {
        let authority = SettableAuthority(authorityA)
        let storage = InMemoryPendingRequestUpdateStorage()
        let store = makeStore(authority, updateStorage: storage)
        ClaimFlowURLProtocol.enqueue(.failure(.timedOut))
        _ = try? await store.withdrawRequest(requestID: "a-own")
        let record = try XCTUnwrap(store.unresolvedUpdate)
        ClaimFlowURLProtocol.enqueue(.response(data: ownerListResponse(["a-own"])))
        await store.fetchOwnerRequests()

        authority.set(nil)
        XCTAssertTrue(store.invalidateRequestDataIfIdentityReplaced())

        XCTAssertEqual(storage.load().records, [record], "recovery records survive, still A's")
        XCTAssertNil(store.unresolvedUpdate, "but nobody is current to see or replay it")
        authority.set(authorityA)
        store.refreshUnresolvedUpdate()
        XCTAssertEqual(store.unresolvedUpdate, record)
    }

    // MARK: - R5-IR-1: A -> retired -> B still retires A's board

    func testVerifyingADifferentPrincipalAfterRetirementRetiresTheRetiredPrincipalsBoard() async throws {
        let authority = SettableAuthority(authorityA)
        let store = makeStore(authority)
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a1", isOwnRequest: true)
        ])))
        await store.fetchRequests()
        authority.set(nil)
        XCTAssertTrue(store.invalidateRequestDataIfIdentityReplaced(), "D-R5-2: retired at retirement")
        authority.set(authorityB)

        XCTAssertFalse(store.invalidateRequestDataIfIdentityReplaced())
        XCTAssertTrue(store.requests.isEmpty)
    }

    // MARK: - R5-IR-1 req 2: navigation snapshots

    func testReplacementDropsRequestCarryingRoutesAndKeepsTheRest() {
        let request = makeFoodRequest(id: "a1")
        let path: [AppRoute] = [
            .requestDetail(request),
            .ownRequests([request]),
            .fulfillment(request),
            .settings,
            .privacySafety,
        ]

        XCTAssertEqual(
            AppRoute.afterIdentityReplacement(from: path),
            [.fulfillment(request), .settings, .privacySafety],
            "held-reservation continuation keeps its own principal binding"
        )
        XCTAssertEqual(AppRoute.afterIdentityReplacement(from: []), [])
        XCTAssertEqual(AppRoute.afterIdentityReplacement(from: [.settings]), [.settings])
    }

    func testContentViewWiresNavigationRetirementToADirectReplacementOnly() throws {
        let source = try Self.productionSource("ContentView.swift")
        XCTAssertTrue(source.contains("requestStore.invalidateRequestDataIfIdentityReplaced()"))
        XCTAssertTrue(source.contains("if let previous, let current, previous.principal != current.principal"))
        XCTAssertTrue(source.contains("path = AppRoute.afterIdentityReplacement(from: path)"))
        XCTAssertTrue(source.contains("} else if previous != nil, current == nil {"), "D-R5-2: retirement strips the stack too")

        let home = try Self.productionSource("Views/HomeExchangeView.swift")
        XCTAssertTrue(home.contains("store.invalidateRequestDataIfIdentityReplaced()"))
        XCTAssertTrue(home.contains("Task { await store.reconcileOwnershipForCurrentAuthority() }"))
    }

    // MARK: - R5-IR-2: Change Email replaces the held credential only

    func testChangeEmailReplacesTheHeldCredentialAndPresentsNothingForTheOldOne() async throws {
        let (identity, _) = try await makeEstablishedBoard()
        try await completeChangeEmail(identity, to: "replacement@stern.nyu.edu", authority: authorityB)

        // The installation holds exactly one credential and it is the new one.
        XCTAssertEqual(identity.currentAuthority(), authorityB)
        XCTAssertNotEqual(identity.currentAuthority(), authorityA)
    }

    func testALateInvalidRefusalForTheOldCredentialDoesNotDiscardTheReplacementIdentity() async {
        let authority = SettableAuthority(authorityA)
        var rejectionCount = 0
        let store = RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { authority.get() },
            participantAuthorityRejected: { rejectionCount += 1 }
        )
        let gate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 401,
            data: Data(#"{"error":{"code":"PARTICIPANT_AUTHORITY_INVALID","message":"x","fields":null}}"#.utf8),
            gate: gate
        ))

        let inFlight = Task { await store.fetchRequests() }
        await waitUntil { gate.isWaiting }
        authority.set(authorityB)
        gate.open()
        _ = await inFlight.value

        // The refusal was about the credential that was presented, which is no
        // longer the one this installation holds: the replacement stands.
        XCTAssertEqual(rejectionCount, 0)
        XCTAssertNil(store.initialFetchError)
    }

    func testADefinitiveRefusalForTheCurrentCredentialStillDiscardsTheIdentity() async {
        let authority = SettableAuthority(authorityA)
        var rejectionCount = 0
        let store = RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { authority.get() },
            participantAuthorityRejected: { rejectionCount += 1 }
        )
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 401,
            data: Data(#"{"error":{"code":"PARTICIPANT_AUTHORITY_INVALID","message":"x","fields":null}}"#.utf8)
        ))

        await store.fetchRequests()

        XCTAssertEqual(rejectionCount, 1)
    }

    // MARK: - Boundary 8: participant-bound recovery state is not consumed

    func testBoardRetirementLeavesPendingCreateOperationsAndTheirBindingUntouched() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        storage.save(pendingRecord(operationId: "op-for-a", participantIdentifier: "64c0000000000000000000a1"))
        let authority = SettableAuthority(authorityA)
        let store = makeStore(authority, operationStorage: storage)
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a1", isOwnRequest: true)
        ])))
        await store.fetchRequests()

        authority.set(authorityB)
        XCTAssertTrue(store.invalidateRequestDataIfIdentityReplaced())
        ClaimFlowURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.reconcileOwnershipForCurrentAuthority()

        // A's durable operation is still there, still A's, and was not
        // reconciled, replayed or adopted for B.
        let restored = storage.restoreAll()
        XCTAssertEqual(restored.count, 1)
        XCTAssertTrue(
            ClaimFlowURLProtocol.capturedPaths.allSatisfy { $0 == "/api/requests" },
            "no create operation was replayed: \(ClaimFlowURLProtocol.capturedPaths)"
        )
    }

    func testBoardRetirementLeavesAnActiveReservationContinuationUntouched() async throws {
        let authority = SettableAuthority(authorityA)
        let store = makeStore(authority)
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(id: "held-1")))
        try await store.claim(requestID: "held-1")
        let claimBefore = try XCTUnwrap(store.activeClaim)

        authority.set(authorityB)
        store.invalidateRequestDataIfIdentityReplaced()
        ClaimFlowURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.reconcileOwnershipForCurrentAuthority()

        XCTAssertEqual(store.activeClaim?.requestID, claimBefore.requestID)
    }

    // MARK: - Fixtures

    /// A verified A with a loaded two-request board, over a real identity store
    /// so Change Email is the real flow.
    private func makeEstablishedBoard() async throws -> (ParticipantIdentityStore, RequestStore) {
        let storage = InMemoryParticipantIdentityStorage(
            stored: ParticipantIdentityRecord(
                principal: "taylor@nyu.edu",
                authority: authorityA,
                verifiedAt: Date()
            )
        )
        let identity = ParticipantIdentityStore(
            service: ParticipantVerificationService(client: makeClient(RequestFetchingURLProtocol.self)),
            storage: storage
        )
        identity.configureInstallationAssociation { _ in }
        let store = RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { identity.currentAuthority() },
            participantAuthorityRejected: { identity.discardRejectedIdentity() }
        )
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a1", isOwnRequest: true),
            requestObject(id: "a2", isOwnRequest: false),
        ])))
        await store.fetchRequests()
        XCTAssertEqual(store.requests.map(\.id), ["a1", "a2"])
        return (identity, store)
    }

    private func completeChangeEmail(
        _ identity: ParticipantIdentityStore,
        to email: String,
        authority: String
    ) async throws {
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 200,
            data: Data(#"{"participant":{"email":"\#(email)"},"authority":"\#(authority)"}"#.utf8)
        ))
        identity.beginEmailReplacement()
        await identity.requestCode(for: email)
        let verified = await identity.submitCode("424242")
        XCTAssertTrue(verified)
    }

    private func makeStore(
        _ authority: SettableAuthority,
        operationStorage: PendingRequestOperationStorage = InMemoryPendingRequestOperationStorage(),
        updateStorage: PendingRequestUpdateStorage = InMemoryPendingRequestUpdateStorage()
    ) -> RequestStore {
        RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { authority.get() },
            participantAuthorityRejected: {},
            operationStorage: operationStorage,
            updateStorage: updateStorage
        )
    }

    private func ownerListResponse(_ ids: [String]) -> Data {
        let objects = ids.map { id in
            """
            {
              "id": "\(id)", "vendor": "Crave NYU", "food": "Rice bowl",
              "pickupWindowText": "ASAP", "mealSwipes": 1, "menuPath": "meal-exchange",
              "mealItems": [{"name": "Rice bowl"}], "orderDetails": null,
              "estimatedDiningDollarsCents": null, "windowStart": null, "windowEnd": null,
              "createdAt": "2026-07-20T18:30:00.000Z", "expiresAt": "2099-07-20T23:30:00.000Z",
              "timing": "asap", "phase": "available", "contentRevision": 1,
              "canEdit": true, "canWithdraw": true,
              "latestScheduledStart": "2026-07-21T03:30:00.000Z"
            }
            """
        }
        return Data(#"{"requests":[\#(objects.joined(separator: ","))]}"#.utf8)
    }

    private func makeService() -> RequestService {
        RequestService(client: makeClient(ClaimFlowURLProtocol.self))
    }

    private func makeClient(_ protocolClass: AnyClass) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        return APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
    }

    private func pendingRecord(
        operationId: String,
        participantIdentifier: String
    ) -> PendingRequestOperationRecord {
        PendingRequestOperationRecord(
            operationId: operationId,
            participantIdentifier: participantIdentifier,
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

    private func makeFoodRequest(id: String) -> FoodRequest {
        FoodRequest(
            id: id,
            diningSpot: DiningSpot(name: "Crave NYU", address: nil),
            foodDescription: "Rice bowl",
            pickupWindowText: "ASAP",
            mealSwipes: 2,
            windowStart: nil,
            windowEnd: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 3_600),
            status: .open
        )
    }

    private func waitUntil(
        timeoutIterations: Int = 200,
        condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<timeoutIterations {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }

    private static func productionSource(_ relativePath: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        url.appendPathComponent("CommonPlateios")
        url.appendPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func challengeResponse() -> Data {
        Data(#"""
        {"verification":{
          "expiresAt": "2026-07-28T16:10:00.000Z",
          "resendAvailableAt": "2026-07-28T16:01:00.000Z"
        }}
        """#.utf8)
    }

    private func errorResponse(code: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"detail","fields":null}}"#.utf8)
    }

    private func listResponse(_ objects: [String]) -> Data {
        Data(#"{"requests":[\#(objects.joined(separator: ","))]}"#.utf8)
    }

    private func claimResponse(id: String) -> Data {
        let expires = ISO8601DateFormatter.fractional.string(from: Date().addingTimeInterval(15 * 60))
        let requestExpires = ISO8601DateFormatter.fractional.string(from: Date().addingTimeInterval(5 * 3600))
        return Data("""
        {
          "request": \(requestObject(id: id, isOwnRequest: nil, status: "claimed", expiresAt: requestExpires)),
          "claim": {
            "pickupName": "Taylor",
            "claimToken": "token-\(id)",
            "claimExpiresAt": "\(expires)"
          }
        }
        """.utf8)
    }

    private func requestObject(
        id: String,
        isOwnRequest: Bool?,
        status: String = "open",
        expiresAt: String = "2099-07-20T23:30:00.000Z"
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
          "expiresAt": "\(expiresAt)"\(ownField)
        }
        """
    }
}

private extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
