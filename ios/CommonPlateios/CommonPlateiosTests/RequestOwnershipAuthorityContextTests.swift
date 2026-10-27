//
//  RequestOwnershipAuthorityContextTests.swift
//  CommonPlateiosTests
//
// Focused W4-H2 coverage for the ownership *wire mapping* and the claim
// boundary that depends on it.
//
// The wire has three meaningful states — `true`, `false`, and absent — and
// absence means different things depending on something only this client
// knows: whether it presented a participant credential. Mapping absence to a
// flat `false` is what previously let an unusable credential, or a response
// shape that derives no ownership at all, read as an authoritative "not your
// request" and expose helper actions.
//
// Also covers the same-principal reverification hole: an anonymous browser
// legitimately sees a request as `.notOwn`, taps Help, verifies as the very
// participant who owns it, and must not go on to claim their own request.
import Foundation
import XCTest
@testable import CommonPlateios

private final class ScriptedAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String?]
    private var index = 0

    init(_ values: [String?]) { self.values = values }

    func next() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let value = values[min(index, values.count - 1)]
        index += 1
        return value
    }
}

@MainActor
final class RequestOwnershipAuthorityContextTests: XCTestCase {
    private let authorityA = "64c0000000000000000000a1.1.credential"
    private let authorityB = "64c0000000000000000000b2.1.credential"

    override func tearDown() {
        ClaimFlowURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Wire mapping: the four cases

    /// W4-R5: the list is verified-only, so an anonymous service call is
    /// refused at the service boundary — nothing is sent and no ownership is
    /// ever mapped for a caller with no authority.
    func testListWithoutAuthorityIsRefusedBeforeAnythingIsSent() async {
        do {
            _ = try await makeService().fetchActiveRequests(participantAuthority: "")
            XCTFail("expected the service boundary to refuse")
        } catch RequestServiceError.participantAuthorityRequired {
            XCTAssertEqual(ClaimFlowURLProtocol.capturedRequests.count, 0)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// Authenticated + `true` → `.own`.
    func testAuthenticatedWithTrueMapsToOwn() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a", isOwnRequest: true)
        ])))

        let requests = try await makeService()
            .fetchActiveRequests(participantAuthority: authorityA)

        XCTAssertEqual(requests.first?.ownership, .own)
        XCTAssertFalse(requests.first?.allowsHelperAction ?? true)
    }

    /// Authenticated + explicit `false` → `.notOwn`. The server resolved the
    /// caller and answered; that is a usable answer.
    func testAuthenticatedWithFalseMapsToNotOwn() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a", isOwnRequest: false)
        ])))

        let requests = try await makeService()
            .fetchActiveRequests(participantAuthority: authorityA)

        XCTAssertEqual(requests.first?.ownership, .notOwn)
        XCTAssertTrue(requests.first?.allowsHelperAction ?? false)
    }

    /// Authenticated + absent → `.unresolved`. The credential was presented
    /// and the server could not resolve it, so ownership is unknown. This is
    /// the case a flat `?? false` got wrong.
    func testAuthenticatedWithAbsentFieldMapsToUnresolved() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a", isOwnRequest: nil)
        ])))

        let requests = try await makeService()
            .fetchActiveRequests(participantAuthority: authorityA)

        XCTAssertEqual(requests.first?.ownership, .unresolved)
        XCTAssertFalse(requests.first?.allowsHelperAction ?? true)
    }

    /// The same three cases hold on the detail route.
    func testDetailMappingMatchesListMapping() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(id: "d", isOwnRequest: true)))
        let owned = try await makeService().fetchRequest(id: "d", participantAuthority: authorityA)
        XCTAssertEqual(owned.ownership, .own)

        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(id: "d", isOwnRequest: false)))
        let notOwned = try await makeService().fetchRequest(id: "d", participantAuthority: authorityA)
        XCTAssertEqual(notOwned.ownership, .notOwn)

        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(id: "d", isOwnRequest: nil)))
        let unresolved = try await makeService().fetchRequest(id: "d", participantAuthority: authorityA)
        XCTAssertEqual(unresolved.ownership, .unresolved)
    }

    /// W4-R5: the detail read is refused at the service boundary without
    /// authority; nothing is sent.
    func testDetailWithoutAuthorityIsRefusedBeforeAnythingIsSent() async {
        do {
            _ = try await makeService().fetchRequest(id: "d", participantAuthority: "")
            XCTFail("expected the service boundary to refuse")
        } catch RequestServiceError.participantAuthorityRequired {
            XCTAssertEqual(ClaimFlowURLProtocol.capturedRequests.count, 0)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - Materialized detail ownership across an authority transition

    private func key(_ requestID: String, _ identity: ParticipantIdentityPresentation?) -> StaleParticipationTaskKey {
        StaleParticipationTaskKey(requestID: requestID, identity: identity)
    }

    private func identity(_ principal: String) -> ParticipantIdentityPresentation {
        ParticipantIdentityPresentation(
            principal: principal,
            masked: "m***@nyu.edu",
            verifiedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )
    }

    /// While the identity is unchanged, the materialized navigation value's
    /// ownership is honoured — anonymous browsing keeps working.
    func testMaterializedOwnershipIsHonouredWhileIdentityIsUnchanged() {
        let anonymousKey = key("r1", nil)

        XCTAssertEqual(
            RequestDetailView.renderedOwnership(
                resolved: nil,
                materializedKey: anonymousKey,
                materializedOwnership: .notOwn,
                currentKey: anonymousKey
            ),
            .notOwn
        )
        XCTAssertTrue(
            RequestDetailView.canClaimForOwnership(
                resolved: nil,
                materializedKey: anonymousKey,
                materializedOwnership: .notOwn,
                currentKey: anonymousKey
            )
        )
    }

    /// The load-bearing case: an anonymous `.notOwn` must not survive into a
    /// verified authority. This is what stops a same-principal reverification
    /// from claiming the helper's own request.
    func testAnonymousNotOwnDoesNotSurviveVerification() {
        let anonymousKey = key("r1", nil)
        let verifiedKey = key("r1", identity("owner@nyu.edu"))

        XCTAssertEqual(
            RequestDetailView.renderedOwnership(
                resolved: nil,
                materializedKey: anonymousKey,
                materializedOwnership: .notOwn,
                currentKey: verifiedKey
            ),
            .unresolved
        )
        XCTAssertFalse(
            RequestDetailView.canClaimForOwnership(
                resolved: nil,
                materializedKey: anonymousKey,
                materializedOwnership: .notOwn,
                currentKey: verifiedKey
            ),
            "no claim may be sent on an ownership conclusion resolved for a different principal"
        )
    }

    /// Once the newly verified participant's own read returns `.own`, the
    /// claim boundary refuses — the helper is this request's requester.
    func testResolvedOwnRefusesTheClaimBoundary() {
        let verifiedKey = key("r1", identity("owner@nyu.edu"))
        let resolved = ResolvedRequestOwnership(key: verifiedKey, ownership: .own)

        XCTAssertEqual(
            RequestDetailView.renderedOwnership(
                resolved: resolved,
                materializedKey: key("r1", nil),
                materializedOwnership: .notOwn,
                currentKey: verifiedKey
            ),
            .own
        )
        XCTAssertFalse(
            RequestDetailView.canClaimForOwnership(
                resolved: resolved,
                materializedKey: key("r1", nil),
                materializedOwnership: .notOwn,
                currentKey: verifiedKey
            )
        )
    }

    /// A verified non-owner resolves to `.notOwn` and may proceed.
    func testResolvedNotOwnPermitsTheClaimBoundary() {
        let verifiedKey = key("r1", identity("helper@nyu.edu"))
        let resolved = ResolvedRequestOwnership(key: verifiedKey, ownership: .notOwn)

        XCTAssertTrue(
            RequestDetailView.canClaimForOwnership(
                resolved: resolved,
                materializedKey: nil,
                materializedOwnership: .unresolved,
                currentKey: verifiedKey
            )
        )
    }

    /// `.unresolved` is never permission.
    func testUnresolvedRefusesTheClaimBoundary() {
        let verifiedKey = key("r1", identity("helper@nyu.edu"))
        let resolved = ResolvedRequestOwnership(key: verifiedKey, ownership: .unresolved)

        XCTAssertFalse(
            RequestDetailView.canClaimForOwnership(
                resolved: resolved,
                materializedKey: nil,
                materializedOwnership: .unresolved,
                currentKey: verifiedKey
            )
        )
    }

    /// A detail read that began under A and resolves after B became current
    /// cannot authorize B — the stored key no longer matches.
    func testLateAResultCannotAuthorizeB() {
        let aKey = key("r1", identity("a@nyu.edu"))
        let bKey = key("r1", identity("b@nyu.edu"))
        let resolvedForA = ResolvedRequestOwnership(key: aKey, ownership: .notOwn)

        XCTAssertEqual(
            RequestDetailView.renderedOwnership(
                resolved: resolvedForA,
                materializedKey: aKey,
                materializedOwnership: .notOwn,
                currentKey: bKey
            ),
            .unresolved
        )
        XCTAssertFalse(
            RequestDetailView.canClaimForOwnership(
                resolved: resolvedForA,
                materializedKey: aKey,
                materializedOwnership: .notOwn,
                currentKey: bKey
            )
        )
    }

    // MARK: - Store-level ownership re-resolution

    /// The store's re-resolution reads the detail route under the authority
    /// current now.
    func testResolveOwnershipReturnsOwnForTheRequester() async {
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(id: "r1", isOwnRequest: true)))
        let store = makeStore(ScriptedAuthority([authorityA]))

        let ownership = await store.resolveOwnership(requestID: "r1")

        XCTAssertEqual(ownership, .own)
    }

    /// Any failure fails closed rather than guessing.
    func testResolveOwnershipFailsClosedOnTransportFailure() async {
        ClaimFlowURLProtocol.enqueue(.failure(.notConnectedToInternet))
        let store = makeStore(ScriptedAuthority([authorityA]))

        let ownership = await store.resolveOwnership(requestID: "r1")

        XCTAssertEqual(ownership, .unresolved)
    }

    /// A participant change during the read invalidates the answer.
    func testResolveOwnershipFailsClosedWhenAuthorityChangesMidFlight() async {
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(id: "r1", isOwnRequest: false)))
        let store = makeStore(ScriptedAuthority([authorityA, authorityB]))

        let ownership = await store.resolveOwnership(requestID: "r1")

        XCTAssertEqual(ownership, .unresolved)
    }

    // MARK: - Source proof for the continuation wiring (no UI-test target)

    /// The verification continuation must not call `performClaim()` directly
    /// off the identity change — that is the exact defect. It records intent
    /// and lets re-resolution decide.
    func testVerificationContinuationDoesNotClaimDirectly() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestDetailView.swift")

        let coordinatorHandler = try XCTUnwrap(
            source.range(of: "verificationCoordinator.helperIdentityDidChange(")
        )
        let afterHandler = String(source[coordinatorHandler.upperBound...])
        let intentRange = try XCTUnwrap(
            afterHandler.range(of: "isAwaitingPostVerificationClaim = true")
        )
        // Nothing between the identity-change handler and recording the intent
        // may invoke the claim.
        let between = String(afterHandler[..<intentRange.lowerBound])
        XCTAssertFalse(between.contains("performClaim()"))

        // And the claim itself is gated on established not-own.
        XCTAssertTrue(source.contains("guard Self.canClaimForOwnership("))
    }

    // MARK: - Fixtures

    private func makeStore(_ authority: ScriptedAuthority) -> RequestStore {
        RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { authority.next() },
            participantAuthorityRejected: {}
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

    private func listResponse(_ objects: [String]) -> Data {
        Data(#"{"requests":[\#(objects.joined(separator: ","))]}"#.utf8)
    }

    private func detailResponse(id: String, isOwnRequest: Bool?) -> Data {
        Data(#"{"request":\#(requestObject(id: id, isOwnRequest: isOwnRequest))}"#.utf8)
    }

    private func requestObject(id: String, isOwnRequest: Bool?) -> String {
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
          "status": "open",
          "createdAt": "2026-07-20T18:30:00.000Z",
          "expiresAt": "2026-07-20T23:30:00.000Z"\(ownField)
        }
        """
    }

    private func fileSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
