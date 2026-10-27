import Foundation
import SwiftUI
import XCTest
@testable import CommonPlateios

/// W4-MSG1 CP6: requester Report/Block from reservation start (accepted
/// MSG1 / U1.2 / U1.3), alert ownership while a chat is open, and dormancy.
/// Simulator-hosted with scripted HTTP; the backend stays the authority.
@MainActor
final class RequestReservedRequesterActionsTests: XCTestCase {
    private func serve(phase: String) {
        OwnerHostedURLProtocol.detailStatus = 200
        OwnerHostedURLProtocol.detailBody = Data("""
        {"request": {
          "id": "h1", "vendor": "Palladium", "food": "Rice bowl",
          "pickupWindowText": "ASAP", "mealSwipes": 1, "menuPath": "meal-exchange",
          "mealItems": [], "orderDetails": null, "estimatedDiningDollarsCents": null,
          "windowStart": null, "windowEnd": null,
          "createdAt": "2026-07-20T18:30:00.000Z", "expiresAt": "2099-07-20T23:30:00.000Z",
          "timing": "asap", "phase": "\(phase)", "contentRevision": 1,
          "canEdit": false, "canWithdraw": false,
          "latestScheduledStart": "2099-07-21T03:30:00.000Z"
        }}
        """.utf8)
    }

    private func owner(_ phase: OwnerRequestPhase) -> OwnerRequest {
        OwnerRequest(
            request: FoodRequest(
                id: "h1",
                diningSpot: DiningSpot(name: "Palladium", address: nil),
                foodDescription: "Rice bowl", pickupWindowText: "ASAP", mealSwipes: 1,
                windowStart: nil, windowEnd: nil,
                createdAt: Date(timeIntervalSince1970: 1_784_000_000),
                expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
                status: phase == .reserved ? .claimed : .open,
                ownership: .own
            ),
            phase: phase, contentRevision: 1, canEdit: false, canWithdraw: false,
            latestScheduledStart: Date(timeIntervalSince1970: 4_000_000_000)
        )
    }

    private func host(_ phase: OwnerRequestPhase) throws -> OwnerRequestHost {
        serve(phase: "\(phase)")
        let snapshot = owner(phase)
        let host = try OwnerRequestHost { store, path in
            AnyView(OwnerRequestDetailView(store: store, owner: snapshot, path: path))
        }
        host.settle()
        return host
    }

    func testReservedRequesterOffersTheSafetyMenuFromReservationStart() throws {
        let host = try host(.reserved)
        XCTAssertTrue(host.exists("request-detail-safety-menu"))
    }

    func testAvailableAndScheduledRequestsOfferNoSafetyMenu() throws {
        for phase in [OwnerRequestPhase.available, .scheduled] {
            XCTAssertFalse(try host(phase).exists("request-detail-safety-menu"), "\(phase)")
        }
    }

    func testReservedReportPredicateNeedsReservationAndVerifiedIdentity() {
        XCTAssertTrue(ParticipantReportAvailability.reservedRequesterOffersReport(isReserved: true, hasVerifiedIdentity: true))
        XCTAssertFalse(ParticipantReportAvailability.reservedRequesterOffersReport(isReserved: false, hasVerifiedIdentity: true))
        XCTAssertFalse(ParticipantReportAvailability.reservedRequesterOffersReport(isReserved: true, hasVerifiedIdentity: false))
    }

    func testReservedRequesterVerifierOffersChatReportAndBlockOnlyForAKnownStage() async throws {
        let store = RequestStore(
            service: RequestService(client: APIClient(
                configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
                session: {
                    let c = URLSessionConfiguration.ephemeral
                    c.protocolClasses = [OwnerHostedURLProtocol.self]
                    return URLSession(configuration: c)
                }()
            )),
            installationCredentialProvider: { "c" },
            participantAuthorityProvider: { canonicalParticipantAuthorityFixture },
            participantAuthorityRejected: {}
        )
        let verifier = StoreConversationEntryVerifier(store: store)
        XCTAssertEqual(verifier.availableActions(requestID: "h1", role: .requester), .none, "unknown stage is fail-closed")

        serve(phase: "reserved")
        let reserved = await verifier.verify(requestID: "h1", role: .requester)
        XCTAssertEqual(reserved, .eligible)
        XCTAssertEqual(
            verifier.availableActions(requestID: "h1", role: .requester),
            ConversationActionAvailability(report: true, block: .viewedRequest)
        )

        serve(phase: "available")
        let released = await verifier.verify(requestID: "h1", role: .requester)
        XCTAssertEqual(released, .ineligible)
        XCTAssertEqual(verifier.availableActions(requestID: "h1", role: .requester), .none)
    }

    // MARK: Alert ownership

    func testConversationOnTopSuppressesUnderlyingBlockFailureAndPromptOwnership() throws {
        XCTAssertFalse(AppRoute.hasOpenConversation(in: []))
        XCTAssertFalse(AppRoute.hasOpenConversation(in: [.settings]))
        XCTAssertTrue(AppRoute.hasOpenConversation(in: [.settings, .requestConversation(requestID: "a", role: .helper)]))

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
        for file in ["Views/FulfillRequestView.swift", "Views/HelperWaitingDetailView.swift",
                     "Views/PlacedOrderDetailView.swift", "Views/OwnerRequestDetailView.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains("isSuppressed: AppRoute.hasOpenConversation(in: path)"), file)
        }
        let menus = try String(contentsOf: root.appendingPathComponent("Views/ParticipantBlockViews.swift"), encoding: .utf8)
        XCTAssertEqual(menus.components(separatedBy: "participantBlockFailureAlert(store: store, isSuppressed: isSuppressed)").count - 1, 2)
        let chat = try String(contentsOf: root.appendingPathComponent("Messaging/RequestConversationHostView.swift"), encoding: .utf8)
        XCTAssertTrue(chat.contains(".participantBlockFailureAlert(store: store)"))
        XCTAssertFalse(chat.contains("consumeBlockAfterReport"), "the chat never consumes the shared Block-after-Report flag")
    }
}
