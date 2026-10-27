//
//  RequestDetailStaleParticipationTests.swift
//  CommonPlateiosTests
//
// Focused coverage for the W3-H2 review-response fix to stale detail Reserve
// truth: a request-detail screen reached through stale navigation must not
// present an actionable Reserve affordance for a verified participant who
// already successfully held this exact request. `claimRequest`'s own
// conditional grant (`REQUEST_ALREADY_PARTICIPATED`) remains the
// authoritative backstop; this proves the tri-state
// `RequestStore.StaleParticipationEligibility` production-boundary read
// (`resolveStaleParticipationEligibility`) — including the identity-staleness
// guard against a Change Email completing mid-read — and the source-level
// wiring that gates `RequestDetailView`'s Reserve affordance behind it.
import Foundation
import XCTest
@testable import CommonPlateios

/// Its own transport double, matching the one-file-one-double convention
/// (`ClaimFlowURLProtocol`, `ReservationContinuationURLProtocol`,
/// `PlacementReentryURLProtocol`).
final class StaleParticipationURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let data: Data
        let errorCode: URLError.Code?

        static func response(statusCode: Int = 200, data: Data) -> Stub {
            Stub(statusCode: statusCode, data: data, errorCode: nil)
        }

        static func failure(_ errorCode: URLError.Code) -> Stub {
            Stub(statusCode: 0, data: Data(), errorCode: errorCode)
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var stubs: [Stub] = []
    private nonisolated(unsafe) static var capturedPaths: [String] = []
    private nonisolated(unsafe) static var capturedHeaders: [[String: String]] = []

    static func enqueue(_ stub: Stub) {
        lock.lock()
        stubs.append(stub)
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        stubs.removeAll()
        capturedPaths.removeAll()
        capturedHeaders.removeAll()
        lock.unlock()
    }

    static var requestedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return capturedPaths
    }

    static var lastCapturedHeaders: [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        return capturedHeaders.last
    }

    private static func dequeue() -> Stub? {
        lock.lock()
        defer { lock.unlock() }
        guard !stubs.isEmpty else { return nil }
        return stubs.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.capturedPaths.append(request.url?.path ?? "")
        Self.capturedHeaders.append(request.allHTTPHeaderFields ?? [:])
        Self.lock.unlock()

        guard let stub = Self.dequeue() else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        if let errorCode = stub.errorCode {
            client?.urlProtocol(self, didFailWithError: URLError(errorCode))
            return
        }

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: stub.statusCode,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class RequestDetailStaleParticipationTests: XCTestCase {
    enum TestHelperError: Error {
        case markerNotFound
    }

    override func tearDown() {
        StaleParticipationURLProtocol.reset()
        super.tearDown()
    }

    private func makeService() -> RequestService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StaleParticipationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return RequestService(client: client)
    }

    private func makeStore(
        service: RequestService,
        participantAuthority: String? = "64c0000000000000000000a1.1.credential"
    ) -> RequestStore {
        RequestStore(
            service: service,
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { participantAuthority },
            participantAuthorityRejected: {}
        )
    }

    /// A store whose `participantAuthorityProvider` returns a different
    /// value on each successive call — models the authoritative identity
    /// changing (e.g. a Change Email completing) between
    /// `resolveStaleParticipationEligibility`'s pre-read capture and its
    /// post-read comparison, which are its only two calls to the provider.
    private func makeStoreWithShiftingAuthority(
        service: RequestService,
        authorities: [String]
    ) -> RequestStore {
        var callCount = 0
        return RequestStore(
            service: service,
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: {
                defer { callCount = min(callCount + 1, authorities.count - 1) }
                return authorities[callCount]
            },
            participantAuthorityRejected: {}
        )
    }

    private func detailResponse(alreadyParticipated: Bool?) -> Data {
        let field = alreadyParticipated.map { $0 ? "true" : "false" }
        let alreadyParticipatedLine = field.map { ",\"alreadyParticipated\":\($0)" } ?? ""
        return Data("""
        {
          "request": {
            "id": "stale-detail-target",
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
            "status": "open",
            "createdAt": "2026-08-10T15:00:00.000Z",
            "expiresAt": "2026-08-10T20:00:00.000Z"
          }\(alreadyParticipatedLine)
        }
        """.utf8)
    }

    // MARK: - RequestService.fetchAlreadyParticipated

    func testFetchAlreadyParticipatedDecodesTrueAndSendsTheParticipantHeader() async throws {
        let service = makeService()
        StaleParticipationURLProtocol.enqueue(.response(data: detailResponse(alreadyParticipated: true)))

        let result = try await service.fetchAlreadyParticipated(
            id: "stale-detail-target",
            participantAuthority: "64c0000000000000000000a1.1.credential"
        )

        XCTAssertTrue(result)
        XCTAssertEqual(StaleParticipationURLProtocol.requestedPaths, ["/api/request/stale-detail-target"])
        XCTAssertNotNil(StaleParticipationURLProtocol.lastCapturedHeaders?["x-commonplate-participant"])
    }

    func testFetchAlreadyParticipatedTreatsAnAbsentFieldAsFalse() async throws {
        let service = makeService()
        StaleParticipationURLProtocol.enqueue(.response(data: detailResponse(alreadyParticipated: nil)))

        let result = try await service.fetchAlreadyParticipated(
            id: "stale-detail-target",
            participantAuthority: "64c0000000000000000000a1.1.credential"
        )

        XCTAssertFalse(result)
    }

    // MARK: - RequestStore.resolveStaleParticipationEligibility

    func testResolvesEligibleFromBackendTruthWhenNeverParticipated() async throws {
        let service = makeService()
        StaleParticipationURLProtocol.enqueue(.response(data: detailResponse(alreadyParticipated: false)))
        let store = makeStore(service: service)

        let result = await store.resolveStaleParticipationEligibility(for: "stale-detail-target")

        XCTAssertEqual(result, .eligible)
    }

    func testResolvesAlreadyParticipatedFromBackendTruth() async throws {
        let service = makeService()
        StaleParticipationURLProtocol.enqueue(.response(data: detailResponse(alreadyParticipated: true)))
        let store = makeStore(service: service)

        let result = await store.resolveStaleParticipationEligibility(for: "stale-detail-target")

        XCTAssertEqual(result, .alreadyParticipated)
    }

    /// Browsing stays open to anyone (W3-I1): with no participant identity
    /// presented at all, there is no participation history to ask about, so
    /// this resolves immediately to `.eligible` without any network call —
    /// the same permissive answer this screen gave before W3-H2 existed.
    func testResolvesEligibleWithoutAnyReadWhenNoParticipantIdentityIsPresented() async throws {
        let service = makeService()
        let store = makeStore(service: service, participantAuthority: nil)

        let result = await store.resolveStaleParticipationEligibility(for: "stale-detail-target")

        XCTAssertEqual(result, .eligible)
        XCTAssertTrue(StaleParticipationURLProtocol.requestedPaths.isEmpty)
    }

    /// A failed read must never be treated as authoritative permission to
    /// Reserve — it stays `.unresolved`, not `.eligible`. `claimRequest`'s
    /// own conditional grant remains the real backstop regardless.
    func testResolvesUnresolvedRatherThanEligibleWhenTheReadFails() async throws {
        let service = makeService()
        StaleParticipationURLProtocol.enqueue(.failure(.notConnectedToInternet))
        let store = makeStore(service: service)

        let result = await store.resolveStaleParticipationEligibility(for: "stale-detail-target")

        XCTAssertEqual(result, .unresolved)
    }

    /// The identity-staleness guard: the authority in effect when the read
    /// started differs from the authority in effect when it completed (a
    /// Change Email finished mid-read). The result belongs to a principal
    /// that is no longer authoritative and must be discarded as
    /// `.unresolved`, never silently applied to the replacement identity.
    func testDiscardsAResultResolvedForAnAuthorityThatChangedWhileTheReadWasInFlight() async throws {
        let service = makeService()
        StaleParticipationURLProtocol.enqueue(.response(data: detailResponse(alreadyParticipated: false)))
        let store = makeStoreWithShiftingAuthority(
            service: service,
            authorities: ["authority-before-change-email", "authority-after-change-email"]
        )

        let result = await store.resolveStaleParticipationEligibility(for: "stale-detail-target")

        XCTAssertEqual(result, .unresolved)
    }

    /// The unchanged-identity path must still resolve normally — the guard
    /// above must not make every read `.unresolved`.
    func testAppliesTheResultWhenTheAuthorityIsUnchangedAcrossTheRead() async throws {
        let service = makeService()
        StaleParticipationURLProtocol.enqueue(.response(data: detailResponse(alreadyParticipated: true)))
        let store = makeStoreWithShiftingAuthority(
            service: service,
            authorities: ["stable-authority", "stable-authority"]
        )

        let result = await store.resolveStaleParticipationEligibility(for: "stale-detail-target")

        XCTAssertEqual(result, .alreadyParticipated)
    }

    // MARK: - Source-level wiring

    /// `RequestDetailView` has no automated UI-test target, so the actual
    /// on-screen suppression of the Reserve affordance cannot be driven and
    /// observed by this target — only the underlying store/service read
    /// above can be. This proves the view is structurally wired to that
    /// read and to gate its claim section on the result, ahead of the
    /// ordinary claim-action affordance, matching the source-inspection
    /// pattern already used elsewhere in this target (e.g.
    /// `testRequestDetailViewRoutesBothFulfillmentEntryPointsThroughTheActiveClaimsOwnRequest`
    /// in `ClaimFlowTests.swift`).
    func testRequestDetailViewGatesTheClaimSectionOnStaleParticipationTruth() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestDetailView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("@State private var resolvedStaleParticipation: ResolvedStaleParticipation?"),
            "the raw resolved result must start nil — never actionable before any read completes"
        )
        XCTAssertTrue(
            source.contains("case .eligible:\n                        claimSection"),
            "the claim section may render only for the confirmed .eligible case"
        )
        XCTAssertFalse(
            source.contains("case .unresolved:\n                        claimSection"),
            "the claim section must never render for .unresolved — a pending or failed read is not permission"
        )
        XCTAssertTrue(
            source.contains(
                "let result = await store.resolveStaleParticipationEligibility(for: request.id)"
            ),
            "eligibility must be populated from the store's authoritative tri-state backend read"
        )
        XCTAssertTrue(
            source.contains("guard !Task.isCancelled, key == staleParticipationKey else { return }"),
            "a superseded read (task id changed, cancelled, or a newer key already in effect) must never write a stale result"
        )
        XCTAssertTrue(
            source.contains(".task(id: staleParticipationKey) {"),
            "the read must re-resolve whenever the request or the authoritative participant identity changes"
        )
    }

    /// `staleParticipationEligibility` — the only property the body's
    /// `switch` reads — must delegate to `Self.renderedEligibility`, the
    /// pure key-gated function exercised directly below, rather than
    /// returning a stored value unconditionally.
    func testRenderedEligibilityPropertyDelegatesToTheKeyGatedPureFunction() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestDetailView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains(
                "Self.renderedEligibility(resolved: resolvedStaleParticipation, currentKey: staleParticipationKey)"
            ),
            "the rendered property must be gated by the pure, independently testable key-comparison function"
        )
        XCTAssertTrue(
            source.contains("identity: identityStore.identity"),
            "the current key must be derived from the live, currently authoritative identity, not a captured one"
        )
    }

    // MARK: - RequestDetailView.renderedEligibility (the identity-key gate itself)

    private func identity(_ principal: String) -> ParticipantIdentityPresentation {
        ParticipantIdentityPresentation(principal: principal, masked: "***", verifiedAt: Date())
    }

    /// The exact scenario the review flagged: A resolves eligible, identity
    /// changes to B, and — before B's own read has had any chance to
    /// complete — rendering must already read as `.unresolved`, never as A's
    /// stale `.eligible`. This is what makes the fix synchronous rather than
    /// racing an async cancellation.
    func testEligibleForPrincipalABecomesUnresolvedTheInstantIdentityChangesToBBeforeBResolves() {
        let keyA = StaleParticipationTaskKey(requestID: "shared-request", identity: identity("a@nyu.edu"))
        let keyB = StaleParticipationTaskKey(requestID: "shared-request", identity: identity("b@nyu.edu"))
        let resolvedForA = ResolvedStaleParticipation(key: keyA, eligibility: .eligible)

        let renderedBeforeBResolves = RequestDetailView.renderedEligibility(
            resolved: resolvedForA,
            currentKey: keyB
        )

        XCTAssertEqual(renderedBeforeBResolves, .unresolved)
    }

    /// A stale A response that arrives (and, hypothetically, were written)
    /// after the switch to B must not change B's rendered state either —
    /// modeled directly at the permissive end of the range (an
    /// already-participated result for A must not leak as B's truth, but
    /// crucially neither may an eligible one).
    func testAStaleResultResolvedForAcannotChangeBsRenderedStateEvenIfWritten() {
        let keyA = StaleParticipationTaskKey(requestID: "shared-request", identity: identity("a@nyu.edu"))
        let keyB = StaleParticipationTaskKey(requestID: "shared-request", identity: identity("b@nyu.edu"))
        let staleResultForA = ResolvedStaleParticipation(key: keyA, eligibility: .alreadyParticipated)

        let renderedForB = RequestDetailView.renderedEligibility(
            resolved: staleResultForA,
            currentKey: keyB
        )

        XCTAssertEqual(renderedForB, .unresolved)
    }

    func testAnUnchangedKeyEligibleResultApplies() {
        let key = StaleParticipationTaskKey(requestID: "shared-request", identity: identity("a@nyu.edu"))
        let resolved = ResolvedStaleParticipation(key: key, eligibility: .eligible)

        let rendered = RequestDetailView.renderedEligibility(resolved: resolved, currentKey: key)

        XCTAssertEqual(rendered, .eligible)
    }

    func testAnUnchangedKeyAlreadyParticipatedResultApplies() {
        let key = StaleParticipationTaskKey(requestID: "shared-request", identity: identity("a@nyu.edu"))
        let resolved = ResolvedStaleParticipation(key: key, eligibility: .alreadyParticipated)

        let rendered = RequestDetailView.renderedEligibility(resolved: resolved, currentKey: key)

        XCTAssertEqual(rendered, .alreadyParticipated)
    }

    /// A failed read resolves to `.unresolved` at the store layer
    /// (`resolveStaleParticipationEligibility`); this proves that value
    /// stays non-actionable through the rendering gate too, for the same
    /// unchanged key.
    func testAFailedReadStaysNonActionableThroughTheRenderingGate() {
        let key = StaleParticipationTaskKey(requestID: "shared-request", identity: identity("a@nyu.edu"))
        let resolved = ResolvedStaleParticipation(key: key, eligibility: .unresolved)

        let rendered = RequestDetailView.renderedEligibility(resolved: resolved, currentKey: key)

        XCTAssertEqual(rendered, .unresolved)
    }

    /// No read has ever completed for the current key at all.
    func testNoResolvedResultYetIsNonActionable() {
        let key = StaleParticipationTaskKey(requestID: "shared-request", identity: identity("a@nyu.edu"))

        let rendered = RequestDetailView.renderedEligibility(resolved: nil, currentKey: key)

        XCTAssertEqual(rendered, .unresolved)
    }

    /// A change in `requestID` alone (same identity, different request —
    /// e.g. navigating from one detail screen to another that happens to
    /// reuse a view instance) must also invalidate a prior result, not only
    /// an identity change.
    func testADifferentRequestIDAloneAlsoInvalidatesAPriorResult() {
        let identityA = identity("a@nyu.edu")
        let keyForRequestOne = StaleParticipationTaskKey(requestID: "request-one", identity: identityA)
        let keyForRequestTwo = StaleParticipationTaskKey(requestID: "request-two", identity: identityA)
        let resolvedForRequestOne = ResolvedStaleParticipation(key: keyForRequestOne, eligibility: .eligible)

        let rendered = RequestDetailView.renderedEligibility(
            resolved: resolvedForRequestOne,
            currentKey: keyForRequestTwo
        )

        XCTAssertEqual(rendered, .unresolved)
    }

    // MARK: - RequestDetailView.canStartClaim (the action boundary itself)

    /// Current-key `.eligible` truth: the action boundary must permit the
    /// existing claim flow to continue.
    func testCanStartClaimWhenCurrentKeyEligibilityIsConfirmed() {
        let key = StaleParticipationTaskKey(requestID: "shared-request", identity: identity("a@nyu.edu"))
        let resolved = ResolvedStaleParticipation(key: key, eligibility: .eligible)

        XCTAssertTrue(RequestDetailView.canStartClaim(resolved: resolved, currentKey: key))
    }

    /// The exact scenario the review flagged: A resolved eligible and a
    /// button materialized for A. Identity changes to B before any B
    /// eligibility result arrives — the stored result still says A/`.eligible`
    /// — and invoking the action boundary with B's current key (which is
    /// what `startClaim()` derives fresh at the moment of the tap, not a
    /// value captured when the button was drawn) must refuse to proceed.
    func testAnAlreadyMaterializedActionForPrincipalACannotStartAClaimAfterIdentityChangesToBBeforeBResolves() {
        let keyA = StaleParticipationTaskKey(requestID: "shared-request", identity: identity("a@nyu.edu"))
        let keyB = StaleParticipationTaskKey(requestID: "shared-request", identity: identity("b@nyu.edu"))
        let resolvedForA = ResolvedStaleParticipation(key: keyA, eligibility: .eligible)

        let canStartForB = RequestDetailView.canStartClaim(resolved: resolvedForA, currentKey: keyB)

        XCTAssertFalse(canStartForB)
    }

    func testCannotStartClaimWhileUnresolved() {
        let key = StaleParticipationTaskKey(requestID: "shared-request", identity: identity("a@nyu.edu"))

        XCTAssertFalse(RequestDetailView.canStartClaim(resolved: nil, currentKey: key))
    }

    func testCannotStartClaimWhenAlreadyParticipated() {
        let key = StaleParticipationTaskKey(requestID: "shared-request", identity: identity("a@nyu.edu"))
        let resolved = ResolvedStaleParticipation(key: key, eligibility: .alreadyParticipated)

        XCTAssertFalse(RequestDetailView.canStartClaim(resolved: resolved, currentKey: key))
    }

    /// A stale/mismatched-key `.eligible` result (e.g. a different request,
    /// same identity — navigating between two detail screens that happen to
    /// reuse a view instance) must not authorize starting a claim either.
    func testCannotStartClaimWithAStaleMismatchedKeyEligibleResult() {
        let identityA = identity("a@nyu.edu")
        let keyForRequestOne = StaleParticipationTaskKey(requestID: "request-one", identity: identityA)
        let keyForRequestTwo = StaleParticipationTaskKey(requestID: "request-two", identity: identityA)
        let resolvedForRequestOne = ResolvedStaleParticipation(key: keyForRequestOne, eligibility: .eligible)

        let canStart = RequestDetailView.canStartClaim(
            resolved: resolvedForRequestOne,
            currentKey: keyForRequestTwo
        )

        XCTAssertFalse(canStart)
    }

    /// `startClaim()` itself must consult the action boundary before doing
    /// anything else — not merely trust the button having been drawn. No UI
    /// test target exists to drive an actual tap, so this pins the call site
    /// via source inspection, matching this file's other source-wiring
    /// proof; the boundary function's own behavior above is what is proved
    /// at the production-decision level, not by source text.
    func testStartClaimConsultsTheActionBoundaryBeforeAnyVerificationOrClaimWork() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestDetailView.swift"
            ),
            encoding: .utf8
        )

        let function = try sourceSliceBetweenMarkers(
            of: source,
            from: "private func startClaim() {",
            to: "\n    private func performClaim() {"
        )
        XCTAssertTrue(
            function.contains(
                "guard Self.canStartClaim(resolved: resolvedStaleParticipation, currentKey: staleParticipationKey) else {"
            ),
            "the action boundary must be the first thing startClaim() checks"
        )
        // The guard's own early `return` must precede both the verification
        // entry point and the direct claim call, so neither can run past it.
        let boundaryRange = try XCTUnwrap(
            function.range(of: "guard Self.canStartClaim")
        )
        let verificationRange = try XCTUnwrap(
            function.range(of: "verificationCoordinator.beginClaim")
        )
        let performClaimRange = try XCTUnwrap(
            function.range(of: "performClaim()")
        )
        XCTAssertLessThan(boundaryRange.lowerBound, verificationRange.lowerBound)
        XCTAssertLessThan(boundaryRange.lowerBound, performClaimRange.lowerBound)
    }

    private func sourceSliceBetweenMarkers(of source: String, from startMarker: String, to endMarker: String) throws -> String {
        guard let startRange = source.range(of: startMarker) else {
            XCTFail("Expected marker not found: \(startMarker)")
            throw TestHelperError.markerNotFound
        }
        guard let endRange = source.range(of: endMarker, range: startRange.upperBound..<source.endIndex) else {
            XCTFail("Expected marker not found after start: \(endMarker)")
            throw TestHelperError.markerNotFound
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private func repositoryFile(_ relativePath: String) throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.pathComponents.count > 1 {
            let candidate = directory.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        XCTFail("Expected repository file not found: \(relativePath)")
        throw TestHelperError.markerNotFound
    }
}
