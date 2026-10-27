//
//  ActiveRequestsParticipantAuthorityTests.swift
//  CommonPlateiosTests
//
// Focused coverage for W3-H2 required-proof item A: the Active Requests path
// (`RequestService.fetchActiveRequests` and `RequestStore.fetchRequests()`)
// must actually send the exact verified participant authority the
// participant-aware `GET /api/requests` marketplace-presentation filter
// depends on — proved at the production wire boundary, not by source
// inspection. Reuses `RequestFetchingURLProtocol` (`RequestFetchingTests.swift`)
// rather than introducing a fourth near-identical transport double.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class ActiveRequestsParticipantAuthorityTests: XCTestCase {
    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
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

    private func makeStore(
        service: RequestService,
        participantAuthority: String?
    ) -> RequestStore {
        RequestStore(
            service: service,
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { participantAuthority },
            participantAuthorityRejected: {}
        )
    }

    private func emptyListResponse() -> Data {
        Data(#"{"requests":[]}"#.utf8)
    }

    // MARK: - RequestService.fetchActiveRequests

    func testFetchActiveRequestsSendsTheExactParticipantHeaderWhenAnAuthorityIsProvided() async throws {
        let service = makeService()
        RequestFetchingURLProtocol.enqueue(.response(data: emptyListResponse()))

        _ = try await service.fetchActiveRequests(
            participantAuthority: "64c0000000000000000000a1.1.credential"
        )

        XCTAssertEqual(
            RequestFetchingURLProtocol.lastCapturedHeaders?["x-commonplate-participant"],
            "64c0000000000000000000a1.1.credential"
        )
    }

    func testFetchActiveRequestsSendsNothingWhenNoAuthorityIsProvided() async {
        let service = makeService()

        do {
            _ = try await service.fetchActiveRequests(participantAuthority: "")
            XCTFail("expected the service boundary to refuse")
        } catch RequestServiceError.participantAuthorityRequired {
            XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - RequestStore.fetchRequests() production wiring

    /// Proves the store's own initial-load path — not just the service
    /// method in isolation — actually forwards the currently authoritative
    /// participant authority all the way to the wire.
    func testStoreFetchRequestsForwardsTheExactVerifiedParticipantAuthorityToTheWire() async {
        let service = makeService()
        RequestFetchingURLProtocol.enqueue(.response(data: emptyListResponse()))
        let store = makeStore(
            service: service,
            participantAuthority: "64c0000000000000000000a1.1.credential"
        )

        await store.fetchRequests()

        XCTAssertEqual(
            RequestFetchingURLProtocol.lastCapturedHeaders?["x-commonplate-participant"],
            "64c0000000000000000000a1.1.credential"
        )
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, ["/api/requests"])
    }

    /// W4-R5: the list is verified-only, so an unverified installation sends
    /// nothing; the failure is the ordinary unavailable presentation and
    /// never an authoritative empty list.
    func testStoreFetchRequestsSendsNothingWhenNoIdentityIsPresented() async {
        let service = makeService()
        let store = makeStore(service: service, participantAuthority: nil)

        let outcome = await store.fetchRequests()

        XCTAssertEqual(outcome, .didNotSucceed)
        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
        XCTAssertNotNil(store.initialFetchError)
        XCTAssertFalse(store.hasSuccessfullyFetchedRequests)
        XCTAssertTrue(store.requests.isEmpty)
    }
}
