import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

@MainActor
final class N1HelperOrderingHostedTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() {
        windows.forEach { $0.isHidden = true }
        windows = []
        ClaimFlowURLProtocol.reset()
        super.tearDown()
    }

    func testMappedAndUnmappedHelperFlowsRenderExactDetailsAcrossTypeAndAppearance() async throws {
        let longMeal = String(repeating: "Requested meal; keep this exact text. ", count: 12)
        let longDetails = String(repeating: "No onions; sauce on the side. ", count: 16)
        for (vendor, context, meal, details, mapped) in [
            ("Crave NYU", RequestMenuPath.mealExchange, "Rice bowl", Optional<String>.none, true),
            ("Crave NYU", .mealExchange, longMeal, longDetails, true),
            ("Cafe 370", .diningDollars, longMeal, longDetails, true),
            ("Palladium", .mealExchange, "Sandwich", "No mustard", false),
            ("Palladium", .diningDollars, longMeal, Optional<String>.none, false)
        ] {
            for (size, appearance) in [
                (DynamicTypeSize.large, ColorScheme.light),
                (.accessibility3, .dark)
            ] {
                let store = try await claimedStore(vendor: vendor, context: context, meal: meal, details: details)
                let request = try XCTUnwrap(store.activeClaim?.request)
                let root = FulfillRequestView(request: request, store: store, path: .constant([.fulfillment(request)]))
                    .dynamicTypeSize(size)
                    .environment(\.colorScheme, appearance)
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
                let host = UIHostingController(rootView: root)
                window.rootViewController = host
                window.makeKeyAndVisible()
                windows.append(window)
                host.view.frame = window.bounds
                host.view.layoutIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                let elements = accessibilityTree(window)
                let labels = elements.compactMap(\.accessibilityLabel)
                XCTAssertTrue(labels.contains { $0.contains(vendor) })
                let mealElement = try XCTUnwrap(elements.first { $0.accessibilityLabel?.contains(meal) == true })
                XCTAssertGreaterThan(mealElement.accessibilityFrame.height, 0)
                XCTAssertGreaterThanOrEqual(mealElement.accessibilityFrame.minX, -1)
                XCTAssertLessThanOrEqual(mealElement.accessibilityFrame.maxX, window.bounds.width + 1)
                if context == .mealExchange, let details {
                    XCTAssertTrue(labels.contains { $0.contains(details) }, "customizations remain exact")
                }
                let contextLabel = context == .mealExchange ? "1 meal swipe" : "Dining Dollars"
                XCTAssertTrue(labels.contains { $0.contains(contextLabel) })
                XCTAssertFalse(labels.contains { $0.contains("Meal Exchange ·") })
                let action = elements.first { $0.accessibilityLabel == "Open in Grubhub" }
                XCTAssertNotNil(action, "Open in Grubhub is always offered; unmapped places open Grubhub itself")
                if let action {
                    XCTAssertEqual(action.accessibilityHint, FulfillRequestView.openGrubhubAccessibilityHint)
                    XCTAssertTrue(action.accessibilityTraits.contains(.button))
                    XCTAssertGreaterThan(action.accessibilityFrame.height, 0)
                }
                XCTAssertTrue(labels.contains { $0.contains(FulfillRequestView.chooseScreenshotTitle) })
                XCTAssertFalse(labels.contains { $0.contains("After placing the order") }, "no screenshot caption")
                XCTAssertFalse(labels.contains { $0.contains(FulfillRequestView.screenshotInfo) }, "guidance only on demand")
                let info = elements.first { $0.accessibilityLabel == FulfillRequestView.screenshotInfoAccessibilityLabel }
                XCTAssertTrue(info?.accessibilityTraits.contains(.button) == true)
                XCTAssertTrue(labels.contains(FulfillRequestView.diningHallLabel.uppercased())
                    || labels.contains { $0.localizedCaseInsensitiveContains(FulfillRequestView.diningHallLabel) })
                do {
                    let grubhubY = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Open in Grubhub" }).accessibilityFrame.minY
                    XCTAssertLessThan(grubhubY, mealElement.accessibilityFrame.minY, "Open in Grubhub precedes the order details")
                }
                XCTAssertTrue(labels.contains { $0.contains(FulfillRequestView.requiredLabel) })
                XCTAssertTrue(labels.contains { $0.contains(FulfillRequestView.submitTitle) })
                XCTAssertTrue(store.canSubmitFulfillment(requestID: request.id))
                XCTAssertTrue(
                    elements.contains {
                        $0.accessibilityLabel?.contains(FulfillRequestView.submitTitle) == true
                            && $0.accessibilityTraits.contains(.notEnabled)
                    },
                    "incomplete form remains disabled"
                )
                window.isHidden = true
            }
        }
    }

    private func claimedStore(
        vendor: String, context: RequestMenuPath, meal: String, details: String?
    ) async throws -> RequestStore {
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
            participantAuthorityProvider: { nil },
            participantAuthorityRejected: {}
        )
        var item: [String: Any] = ["name": meal]
        if let details { item["details"] = details }
        let request: [String: Any] = [
            "id": "n1-hosted-order", "vendor": vendor, "food": meal,
            "pickupWindowText": "ASAP", "mealSwipes": context == .mealExchange ? 1 : 0,
            "menuPath": context == .mealExchange ? "meal-exchange" : "dining-dollars",
            "mealItems": context == .mealExchange ? [item] : [],
            "orderDetails": context == .diningDollars ? meal : NSNull(),
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
        try await store.claim(requestID: "n1-hosted-order")
        return store
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
