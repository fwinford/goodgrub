import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

/// W4-N1 (Faith): the helper holding a live reservation can contact the
/// requester before placing the order, from directly under Open in Grubhub.
@MainActor
final class HelperReservationContactTests: XCTestCase {
    private var windows: [UIWindow] = []
    private let requestID = "n1-contact-order"
    private let contactPath = "/api/participant/active-reservation/n1-contact-order/contact"

    override func tearDown() {
        windows.forEach { $0.isHidden = true }
        windows = []
        ClaimFlowURLProtocol.reset()
        super.tearDown()
    }

    func testStoreReadsTheRequesterAddressForTheLiveReservationWithParticipantAuthority() async throws {
        let store = try await claimedStore(authority: "participant-authority")
        ClaimFlowURLProtocol.enqueue(.response(data: Data(#"{"contactRequesterEmail":"requester@nyu.edu"}"#.utf8)))

        let email = await store.fetchHelperReservationContact(requestID: requestID)

        XCTAssertEqual(email, "requester@nyu.edu")
        let request = try XCTUnwrap(ClaimFlowURLProtocol.capturedRequests.last)
        XCTAssertEqual(request.path, contactPath)
        XCTAssertEqual(request.method, "GET")
        XCTAssertNil(request.body)
        XCTAssertEqual(request.headers["x-commonplate-participant"], "participant-authority")
    }

    func testAnyRefusalOrMissingAuthorityMeansNoContact() async throws {
        let store = try await claimedStore(authority: "participant-authority")
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 404,
            data: Data(#"{"code":"RESERVATION_CONTACT_NOT_FOUND","message":"Contact isn't available for this request."}"#.utf8)
        ))
        let refused = await store.fetchHelperReservationContact(requestID: requestID)
        XCTAssertNil(refused)

        ClaimFlowURLProtocol.enqueue(.failure(.notConnectedToInternet))
        let offline = await store.fetchHelperReservationContact(requestID: requestID)
        XCTAssertNil(offline)

        let unverified = try await claimedStore(authority: nil)
        let before = ClaimFlowURLProtocol.capturedPaths.count
        let missing = await unverified.fetchHelperReservationContact(requestID: requestID)
        XCTAssertNil(missing)
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths.count, before, "no read without participant authority")
    }

    func testContactRowSitsBelowTheOrderDetails() async throws {
        let store = try await claimedStore(authority: "participant-authority")
        ClaimFlowURLProtocol.enqueue(.response(data: Data(#"{"contactRequesterEmail":"requester@nyu.edu"}"#.utf8)))
        let request = try XCTUnwrap(store.activeClaim?.request)
        let window = host(FulfillRequestView(request: request, store: store, path: .constant([.fulfillment(request)])))

        var contact: NSObject?
        for _ in 0..<40 where contact == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
            window.rootViewController?.view.setNeedsLayout()
            window.rootViewController?.view.layoutIfNeeded()
            contact = accessibilityTree(window).first {
                $0.accessibilityLabel?.contains(FulfillRequestView.contactRequesterTitle) == true
            }
        }
        let elements = accessibilityTree(window)
        let contactFrame = try XCTUnwrap(contact, "contact row renders once authorized").accessibilityFrame
        let grubhub = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Open in Grubhub" })
        let diningHall = try XCTUnwrap(elements.first {
            $0.accessibilityLabel?.localizedCaseInsensitiveContains(FulfillRequestView.diningHallLabel) == true
        })
        let lastMeal = try XCTUnwrap(elements.last {
            $0.accessibilityLabel?.localizedCaseInsensitiveContains("Meal") == true
                && $0.accessibilityLabel?.localizedCaseInsensitiveContains(FulfillRequestView.diningHallLabel) == false
        })
        XCTAssertLessThan(diningHall.accessibilityFrame.minY, grubhub.accessibilityFrame.minY)
        XCTAssertLessThan(grubhub.accessibilityFrame.minY, lastMeal.accessibilityFrame.minY)
        XCTAssertLessThan(lastMeal.accessibilityFrame.minY, contactFrame.minY)
        XCTAssertEqual(contact?.accessibilityLabel, FulfillRequestView.contactRequesterTitle, "no subtitle")
        XCTAssertGreaterThanOrEqual(contactFrame.height, 44)
        XCTAssertTrue(ClaimFlowURLProtocol.capturedPaths.contains(contactPath))
    }

    func testContactRowIsAbsentWhenTheBackendRefuses() async throws {
        let store = try await claimedStore(authority: "participant-authority")
        ClaimFlowURLProtocol.enqueue(.response(statusCode: 404, data: Data(#"{"code":"RESERVATION_CONTACT_NOT_FOUND"}"#.utf8)))
        let request = try XCTUnwrap(store.activeClaim?.request)
        let window = host(FulfillRequestView(request: request, store: store, path: .constant([.fulfillment(request)])))

        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertFalse(accessibilityTree(window).contains {
            $0.accessibilityLabel?.contains(FulfillRequestView.contactRequesterTitle) == true
        })
    }

    func testContactIsWithheldWhileABlockIsActive() throws {
        let view = try repoSource("Views/FulfillRequestView.swift")
        let store = try repoSource("Stores/RequestStore.swift")
        XCTAssertTrue(view.contains("if !isBlockActive, let email = reservationContactEmail"))
        XCTAssertTrue(store.contains("guard !contactSuppressedRequestIDs.contains(requestID),"))
    }

    func testInfoButtonIsRightAlignedAfterRequired() throws {
        let view = try repoSource("Views/FulfillRequestView.swift")
        let spacer = try XCTUnwrap(view.range(of: "Text(Self.requiredLabel)"))
        let info = try XCTUnwrap(view.range(of: "isShowingScreenshotInfo = true"))
        XCTAssertLessThan(spacer.lowerBound, info.lowerBound)
    }

    private func claimedStore(authority: String?) async throws -> RequestStore {
        ClaimFlowURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaimFlowURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
        let store = RequestStore(
            service: RequestService(client: client),
            installationCredentialProvider: { "test-installation" },
            participantAuthorityProvider: { authority },
            participantAuthorityRejected: {}
        )
        let request: [String: Any] = [
            "id": requestID, "vendor": "Crave NYU", "food": "Rice bowl",
            "pickupWindowText": "ASAP", "mealSwipes": 1, "menuPath": "meal-exchange",
            "mealItems": [["name": "Rice bowl"]], "orderDetails": NSNull(),
            "estimatedDiningDollarsCents": NSNull(),
            "windowStart": NSNull(), "windowEnd": NSNull(), "status": "claimed",
            "createdAt": "2026-07-20T18:30:00.000Z",
            "expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        ]
        let data = try JSONSerialization.data(withJSONObject: [
            "request": request,
            "claim": [
                "claimToken": "test-token",
                "claimExpiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(900))
            ]
        ])
        ClaimFlowURLProtocol.enqueue(.response(data: data))
        try await store.claim(requestID: requestID)
        return store
    }

    private func host<V: View>(_ root: V) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIHostingController(rootView: root)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        windows.append(window)
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        return window
    }

    private func repoSource(_ relative: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        url.appendPathComponent("CommonPlateios/\(relative)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func accessibilityTree(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        var result: [NSObject] = []
        func visit(_ element: NSObject) {
            guard seen.insert(ObjectIdentifier(element)).inserted else { return }
            result.append(element)
            for child in element.accessibilityElements ?? [] {
                if let child = child as? NSObject { visit(child) }
            }
            let count = element.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let child = element.accessibilityElement(at: index) as? NSObject { visit(child) }
                }
            }
            if let view = element as? UIView { view.subviews.forEach { visit($0) } }
        }
        visit(root)
        return result
    }
}
