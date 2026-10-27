//
//  RequestOwnershipReconciliationTests.swift
//  CommonPlateiosTests
//
// W4-H2-FIX review triage (finding 4): caller-relative `FoodRequest.
// isOwnRequest` truth must be resolved for the exact current participant
// context, not silently frozen at whatever it was under a prior context.
// Two concrete gaps confirmed against current source before this fix:
//
// 1. `RequestService.fetchRequest(id:)` — the helper new-request
//    notification-tap-routing path — never sent participant authority at
//    all, so `dto.isOwnRequest` always decoded `nil` and mapped to `false`
//    regardless of who the tapped request actually belongs to.
// 2. `HomeExchangeView`'s shared board never refreshed `store.requests` (and
//    therefore never re-resolved `isOwnRequest`) when the authoritative
//    participant identity changed (verification completing, Change Email,
//    Remove Email), so ownership metadata resolved for a superseded
//    participant could remain visible after a newer one became current.
//
// Reuses `RequestFetchingURLProtocol` (internal, not private, in
// `RequestFetchingTests.swift`) for the service-level proof, and a
// source-text assertion for the SwiftUI re-key (this target has no UI-test
// infrastructure to drive `.onChange` interactively, matching this file's
// existing `fileSource` precedent elsewhere in this target).
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class RequestOwnershipReconciliationTests: XCTestCase {
    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - fetchRequest(id:participantAuthority:)

    func testFetchRequestSendsParticipantHeaderWhenAuthorityIsProvided() async throws {
        RequestFetchingURLProtocol.enqueue(.response(data: detailResponse(
            requestObject(id: "meal-a")
        )))

        _ = try await makeService().fetchRequest(
            id: "meal-a",
            participantAuthority: "the-current-participant-authority"
        )

        let headers = try XCTUnwrap(RequestFetchingURLProtocol.lastCapturedHeaders)
        XCTAssertEqual(headers["x-commonplate-participant"], "the-current-participant-authority")
    }

    /// W4-R5: an unverified caller sends nothing at all — the service
    /// boundary refuses the read rather than issuing it anonymously.
    func testFetchRequestSendsNothingWhenAuthorityIsEmpty() async {
        do {
            _ = try await makeService().fetchRequest(id: "meal-a", participantAuthority: "")
            XCTFail("expected the service boundary to refuse")
        } catch RequestServiceError.participantAuthorityRequired {
            XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// `isOwnRequest` decodes and maps through `fetchRequest` exactly as it
    /// already does for `fetchActiveRequests` — the notification-tap path
    /// gains correct ownership truth, not a separately reimplemented mapping.
    func testFetchRequestMapsAffirmativeOwnershipSignal() async throws {
        RequestFetchingURLProtocol.enqueue(.response(data: detailResponse(
            requestObject(id: "meal-a", isOwnRequest: true)
        )))

        let request = try await makeService().fetchRequest(
            id: "meal-a",
            participantAuthority: "the-current-participant-authority"
        )

        XCTAssertTrue(request.isOwnRequest)
    }

    // MARK: - resolveHelperNotificationRequest passes current authority through

    func testResolveHelperNotificationRequestPassesTheCurrentParticipantAuthority() async throws {
        let store = RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { "the-current-participant-authority" },
            participantAuthorityRejected: {}
        )
        RequestFetchingURLProtocol.enqueue(.response(data: detailResponse(
            requestObject(id: "meal-a", isOwnRequest: true)
        )))

        let resolution = try await store.resolveHelperNotificationRequest(id: "meal-a")

        let headers = try XCTUnwrap(RequestFetchingURLProtocol.lastCapturedHeaders)
        XCTAssertEqual(headers["x-commonplate-participant"], "the-current-participant-authority")
        guard case .available(let request) = resolution else {
            return XCTFail("expected the tapped request to resolve as available")
        }
        XCTAssertTrue(
            request.isOwnRequest,
            "a helper notification tap on the tapper's own request must still surface affirmative ownership"
        )
    }

    // MARK: - Home re-resolves ownership when identity changes

    /// Source-text proof (no UI-test harness to drive `.onChange`
    /// interactively): Home reconciles ownership whenever
    /// `identityStore.identity` changes, so a participant switch cannot leave
    /// caller-relative ownership bound to whoever was current at the last
    /// fetch. This is the same `.onChange(of: identityStore.identity)` re-key
    /// `RequestDetailView` already uses for its own per-request
    /// stale-participation truth — not a new mechanism.
    ///
    /// It calls `reconcileOwnershipForCurrentAuthority()` rather than
    /// `fetchRequests()` directly: a bare refetch only *repairs* the window
    /// after replacement truth lands, leaving the previous participant's
    /// own/not-own conclusions authoritative until then. Reconciling
    /// invalidates them first, so the window fails closed. The reconcile path
    /// delegates to the same single `fetchRequests()` reload — it is not a
    /// second request-list truth owner; the behavioural proof lives in
    /// `RequestOwnershipLifecycleTests`.
    func testHomeReconcilesOwnershipWhenParticipantIdentityChanges() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        XCTAssertTrue(source.contains(".onChange(of: identityStore.identity) { _, _ in"))
        XCTAssertTrue(
            source.contains("Task { await store.reconcileOwnershipForCurrentAuthority() }")
        )
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

    private func detailResponse(_ requestObject: String) -> Data {
        Data(#"{"request":\#(requestObject)}"#.utf8)
    }

    private func requestObject(id: String, isOwnRequest: Bool? = nil) -> String {
        let isOwnRequestJSON = isOwnRequest.map { $0 ? "true" : "false" } ?? "null"
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
          "expiresAt": "2026-07-20T23:30:00.000Z",
          "isOwnRequest": \(isOwnRequestJSON)
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
