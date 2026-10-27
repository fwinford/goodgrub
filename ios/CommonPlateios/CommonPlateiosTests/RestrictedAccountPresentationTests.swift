import Foundation
import SwiftUI
import XCTest
@testable import CommonPlateios

/// CP5 fix lane: a restricted (suspended) account is shown what it can do, not
/// controls the backend will refuse. The only input is the store's existing
/// affirmative restriction marker; the backend stays authoritative.
@MainActor
final class RestrictedAccountPresentationTests: XCTestCase {
    private let authorityA =
        "64c0000000000000000000c1.1." + String(repeating: "C", count: 42) + "A"
    private let authorityB =
        "64c0000000000000000000c2.1." + String(repeating: "D", count: 42) + "A"

    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    func testRestrictedAccountIsNotOfferedRequestAMealOrANewClaim() {
        XCTAssertFalse(RestrictedAccountPresentation.offersRequestAMeal(isRestricted: true))
        XCTAssertFalse(RestrictedAccountPresentation.offersNewClaim(isRestricted: true))
        XCTAssertTrue(RestrictedAccountPresentation.offersRequestAMeal(isRestricted: false))
        XCTAssertTrue(RestrictedAccountPresentation.offersNewClaim(isRestricted: false))
    }

    func testRestrictedCopyIsNeutralAndNamesNoModerationDetail() {
        let copy = [
            RestrictedAccountPresentation.title,
            RestrictedAccountPresentation.detail,
            RestrictedAccountPresentation.helpingNotice,
        ].joined(separator: " ").lowercased()
        for forbidden in ["report", "violat", "policy", "moderat", "suspend", "reason"] {
            XCTAssertFalse(copy.contains(forbidden), forbidden)
        }
    }

    func testPresentationIsWiredToTheStoresExistingRestrictionMarkerOnly() throws {
        let home = try source("Views/HomeExchangeView.swift")
        XCTAssertTrue(home.contains(
            "RestrictedAccountPresentation.offersRequestAMeal(\n            isRestricted: store.isParticipantRestricted"
        ))
        let owner = try source("Views/OwnerRequestDetailView.swift")
        XCTAssertTrue(owner.contains("offersRequestAMeal(\n                isRestricted: store.isParticipantRestricted"))
        let detail = try source("Views/RequestDetailView.swift")
        XCTAssertTrue(detail.contains(
            "offersNewClaim(isRestricted: store.isParticipantRestricted)"
        ))
        // The existing claim-action rules are unchanged by the restriction.
        XCTAssertFalse(RequestDetailView.showsClaimAction(for: .ambiguous))
        XCTAssertTrue(RequestDetailView.showsClaimAction(for: nil))
    }

    func testRestrictionMarkerIsAffirmativeOnlyAndNotCarriedAcrossAccounts() async throws {
        var authority: String? = authorityA
        let store = RequestStore(
            service: RequestService(client: client()),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { authority },
            participantAuthorityRejected: {}
        )
        RequestFetchingURLProtocol.enqueue(.response(data: Data(#"{"restricted":true}"#.utf8)))
        await store.refreshParticipantRestriction()
        XCTAssertTrue(store.isParticipantRestricted)

        // A different participant whose read fails never inherits the marker.
        authority = authorityB
        RequestFetchingURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.refreshParticipantRestriction()
        XCTAssertFalse(store.isParticipantRestricted)

        // Absent means not established as restricted, never a fabricated state.
        RequestFetchingURLProtocol.enqueue(.response(data: Data("{}".utf8)))
        await store.refreshParticipantRestriction()
        XCTAssertFalse(store.isParticipantRestricted)

        authority = nil
        await store.refreshParticipantRestriction()
        XCTAssertFalse(store.isParticipantRestricted)
    }

    func testSupportContactSitsBelowTheTextRowAndKeepsItsConfiguration() throws {
        let banner = try source("Views/HomeNoticeBanner.swift")
        // The icon and text share a row; the action follows it at the banner's leading edge.
        let detail = try XCTUnwrap(banner.range(of: "Text(RestrictedAccountPresentation.detail)"))
        let action = try XCTUnwrap(banner.range(of: "CommonPlateSupportAction(title: \"Contact support\")"))
        XCTAssertTrue(detail.lowerBound < action.lowerBound)
        let beforeAction = banner[..<action.lowerBound]
        XCTAssertTrue(beforeAction.hasSuffix("            }\n            "))
        XCTAssertTrue(banner.contains("dynamicTypeSize.isAccessibilitySize"))
        XCTAssertTrue(banner.contains(".accessibilityAddTraits(.isHeader)"))
        XCTAssertTrue(banner.contains("home-restriction-contact-support"))

        let support = try source("Views/CommonPlateSupportAction.swift")
        XCTAssertTrue(support.contains("frame(minHeight: 44, alignment: .leading)"))
        XCTAssertTrue(support.contains(".contentShape(Rectangle())"))
        XCTAssertTrue(support.contains(".disabled(!contact.isConfigured)"))
        XCTAssertEqual(CommonPlateSupportContact.infoDictionaryKey, "BrandSupportEmail")
        XCTAssertEqual(
            CommonPlateSupportContact(address: "support@example.com").mailtoURL?.absoluteString,
            "mailto:support@example.com"
        )
    }

    private func client() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        return APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
    }

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
