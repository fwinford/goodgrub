//
//  RequestOwnershipTests.swift
//  CommonPlateiosTests
//
// Focused W4-H2 coverage for the participant-scoped request-list ownership
// projection: `isOwnRequest` decodes from the backend's `GET /api/requests`
// response, through `RequestService.fetchActiveRequests`, into `FoodRequest`
// — an authoritative backend signal only, never a locally derived
// heuristic. Reuses `ClaimFlowURLProtocol`, matching this target's existing
// `RequestService`-level fixture pattern.
import Foundation
import XCTest
@testable import CommonPlateios

final class RequestOwnershipTests: XCTestCase {
    override func tearDown() {
        ClaimFlowURLProtocol.reset()
        super.tearDown()
    }

    func testIsOwnRequestDecodesTrueWhenPresent() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a", isOwnRequest: true),
            requestObject(id: "b", isOwnRequest: nil),
        ])))

        let requests = try await makeService().fetchActiveRequests(participantAuthority: "auth")

        let own = try XCTUnwrap(requests.first { $0.id == "a" })
        let other = try XCTUnwrap(requests.first { $0.id == "b" })
        XCTAssertTrue(own.isOwnRequest)
        XCTAssertFalse(other.isOwnRequest)
    }

    func testIsOwnRequestDefaultsFalseWhenFieldIsAbsent() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a", isOwnRequest: nil)
        ])))

        let requests = try await makeService().fetchActiveRequests(participantAuthority: "64c0000000000000000000a1.1.credential")

        XCTAssertEqual(requests.first?.isOwnRequest, false)
    }

    /// Membership/order stay backend-authoritative regardless of ownership —
    /// H2 does not filter or reorder the board client-side.
    func testOwnershipNeverAffectsMembershipOrOrder() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse([
            requestObject(id: "a", isOwnRequest: true),
            requestObject(id: "b", isOwnRequest: nil),
            requestObject(id: "c", isOwnRequest: nil),
        ])))

        let requests = try await makeService().fetchActiveRequests(participantAuthority: "auth")

        XCTAssertEqual(requests.map(\.id), ["a", "b", "c"])
    }

    // MARK: - RequestDetailView source-gating proof (no UI-test target)

    /// W4-H2: the owner-facing detail screen must never expose or execute
    /// Reserve/Help, ahead of and independent of the existing W3-H2
    /// stale-participation eligibility switch.
    func testRequestDetailGatesReserveOnAuthoritativeOwnershipBeforeStaleParticipationSwitch() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestDetailView.swift")

        let opensClaimedFlow = try XCTUnwrap(source.range(of: "if Self.opensClaimedFlow"))
        let ownGate = try XCTUnwrap(
            source.range(of: "} else if currentOwnership == .own {", range: opensClaimedFlow.upperBound..<source.endIndex)
        )
        // W4-H2 fail-closed: unresolved ownership is gated *before* the
        // participation switch too, so a request with no current-authority
        // ownership evidence never reaches the Reserve-exposing branch.
        // Both gates read `currentOwnership` — the authority-bound value —
        // never the materialized navigation value's own `request.ownership`.
        let unresolvedGate = try XCTUnwrap(
            source.range(of: "} else if currentOwnership == .unresolved {", range: ownGate.upperBound..<source.endIndex)
        )
        let staleSwitch = try XCTUnwrap(
            source.range(of: "switch staleParticipationEligibility {", range: unresolvedGate.upperBound..<source.endIndex)
        )
        XCTAssertLessThan(ownGate.lowerBound, unresolvedGate.lowerBound)
        XCTAssertLessThan(unresolvedGate.lowerBound, staleSwitch.lowerBound)
        XCTAssertTrue(source.contains("own-request-notice"))
        XCTAssertFalse(source.contains("installationCredential") && source.contains("isOwnRequest ="))
    }

    // MARK: - Fixtures

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

    private func listResponse(_ requestObjects: [String]) -> Data {
        Data(#"{"requests":[\#(requestObjects.joined(separator: ","))]}"#.utf8)
    }

    private func requestObject(
        id: String,
        vendor: String = "Crave NYU",
        food: String = "Rice bowl",
        pickupWindowText: String = "ASAP",
        mealSwipes: Int = 2,
        status: String = "open",
        createdAt: String = "2026-07-20T18:30:00.000Z",
        expiresAt: String = "2026-07-20T23:30:00.000Z",
        isOwnRequest: Bool?
    ) -> String {
        let isOwnRequestField = isOwnRequest.map { ",\n  \"isOwnRequest\": \($0)" } ?? ""
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
          "windowStart": null,
          "windowEnd": null,
          "status": "\(status)",
          "createdAt": "\(createdAt)",
          "expiresAt": "\(expiresAt)"\(isOwnRequestField)
        }
        """
    }

    private func fileSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CommonPlateiosTests
            .deletingLastPathComponent() // CommonPlateios
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repository root
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
