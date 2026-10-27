import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

/// W4-N1 meal presentation consistency (Faith): `Meal item` primary, optional
/// freeform `Details` secondary, the same rule on every surface.
@MainActor
final class RequestMealPresentationTests: XCTestCase {
    private let tenders = "Signature Breaded Chicken Tenders & Spiral Fries"
    private let tendersDetails = "Apple, BBQ Sauce, Thai Sweet Chili Sauce, Fountain Beverage"
    private let longDetails = """
        Extra crispy please, no salt on the fries. If they are out of BBQ sauce, \
        swap it for honey mustard; if the apple slices are gone, skip them \
        entirely. Fountain beverage should be a Diet Coke with no ice.
        """

    private func request(
        menuPath: RequestMenuPath = .mealExchange,
        meals: [MealItem],
        orderDetails: String? = nil,
        cents: Int? = nil,
        swipes: Int? = nil
    ) -> FoodRequest {
        FoodRequest(
            id: "meal-presentation",
            diningSpot: DiningSpot(name: "Jasper Kane Cafe", address: "BROOKLYN, Rogers Hall"),
            foodDescription: "server summary",
            pickupWindowText: "ASAP",
            mealSwipes: swipes ?? meals.count,
            resource: RequestResource(
                menuPath: menuPath,
                mealItems: meals,
                orderDetails: orderDetails,
                estimatedDiningDollarsCents: cents
            ),
            windowStart: nil,
            windowEnd: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 3_600),
            status: .open
        )
    }

    // MARK: - Shared rule

    func testSingleMealKeepsItsTextExactlyAndLabelsItMealRequest() {
        let entries = RequestMealEntry.entries(for: request(meals: [MealItem(name: tenders, details: tendersDetails)]))
        XCTAssertEqual(entries, [RequestMealEntry(label: "Meal request", name: tenders, details: tendersDetails)])
    }

    func testMultipleMealsAreNumberedAndEmptyDetailsAreOmitted() {
        let entries = RequestMealEntry.entries(for: request(meals: [
            MealItem(name: "Chicken quesadilla"),
            MealItem(name: "Large fries", details: ""),
            MealItem(name: "chicken tenders", details: "  \n"),
            MealItem(name: "Chicken tenders", details: "Crispy, no sauce"),
        ]))
        XCTAssertEqual(entries.map(\.label), ["Meal 1", "Meal 2", "Meal 3", "Meal 4"])
        XCTAssertEqual(entries.map(\.details), [nil, nil, nil, "Crispy, no sauce"])
        XCTAssertEqual(entries[2].name, "chicken tenders", "requester capitalization is preserved")
    }

    func testLongFreeformDetailsAreNeverSplitOrRewritten() {
        let entries = RequestMealEntry.entries(for: request(meals: [MealItem(name: tenders, details: longDetails)]))
        XCTAssertEqual(entries.first?.details, longDetails)
    }

    func testDiningDollarsRequestsHaveNoMealEntries() {
        let dollars = request(menuPath: .diningDollars, meals: [], orderDetails: "Iced latte", cents: 650, swipes: 0)
        XCTAssertTrue(RequestMealEntry.entries(for: dollars).isEmpty)
        XCTAssertTrue(RequestDetailView.mealRows(for: dollars).isEmpty)
    }

    func testPublicDetailRowsUseTheSharedRule() {
        let r = request(meals: [MealItem(name: "Large fries"), MealItem(name: tenders, details: tendersDetails)])
        XCTAssertEqual(
            RequestDetailView.mealRows(for: r).map { RequestMealEntry(label: $0.label, name: $0.name, details: $0.details) },
            RequestMealEntry.entries(for: r)
        )
    }

    // MARK: - Helping ordering context

    func testOrderingContextShowsOnlyTheQuantityForSwipesAndKeepsDiningDollars() {
        XCTAssertEqual(
            FulfillRequestView.orderingContextText(for: request(meals: [MealItem(name: "x")])),
            "1 meal swipe"
        )
        XCTAssertEqual(
            FulfillRequestView.orderingContextText(for: request(meals: Array(repeating: MealItem(name: "x"), count: 4))),
            "4 meal swipes"
        )
        XCTAssertEqual(
            FulfillRequestView.orderingContextText(for: request(meals: [MealItem(name: "x")], cents: 250)),
            "1 meal swipe + $2.50 Dining Dollars"
        )
        XCTAssertEqual(
            FulfillRequestView.orderingContextText(
                for: request(menuPath: .diningDollars, meals: [], orderDetails: "Iced latte", cents: 650, swipes: 0)
            ),
            "Dining Dollars · $6.50"
        )
    }

    // MARK: - Surfaces use the shared view, never "item (details)"

    func testEverySurfaceRendersMealsThroughTheSharedView() throws {
        let surfaces: [(String, String)] = [
            ("Views/RequestCardView.swift", "density: .compact"),
            ("Views/OwnerRequestDetailView.swift", "density: .detail"),
            ("Views/RequestDetailView.swift", "density: .detail"),
            ("Views/FulfillRequestView.swift", "density: .execution"),
        ]
        for (path, marker) in surfaces {
            let source = try appSource(path)
            XCTAssertTrue(source.contains("RequestMealView(") && source.contains(marker), path)
        }
        let owner = try appSource("Views/OwnerRequestDetailView.swift")
        XCTAssertFalse(owner.contains("mealRowTitle"), "no more `Meal 1 · item` one-liners")
        let shared = try appSource("Views/RequestMealPresentation.swift")
        XCTAssertFalse(shared.contains("components(separatedBy"), "details are never parsed")
        XCTAssertFalse(shared.contains("No details"))
    }

    // MARK: - Hosted rendering

    func testExecutionDensityShowsDetailsLabelOnlyWhenThereAreDetails() throws {
        let with = try labels(RequestMealView(
            entry: RequestMealEntry(label: "Meal 1", name: tenders, details: tendersDetails),
            density: .execution
        ))
        let combined = try XCTUnwrap(with.first { $0.contains(tenders) })
        XCTAssertTrue(combined.contains("MEAL 1"))
        XCTAssertTrue(combined.contains("DETAILS"))
        XCTAssertTrue(combined.contains(tendersDetails), "details read with their meal")
        let nameRange = try XCTUnwrap(combined.range(of: tenders))
        let detailsRange = try XCTUnwrap(combined.range(of: tendersDetails))
        XCTAssertLessThan(nameRange.lowerBound, detailsRange.lowerBound)

        let without = try labels(RequestMealView(
            entry: RequestMealEntry(label: "Meal 2", name: "Large fries", details: nil),
            density: .execution
        ))
        XCTAssertFalse(without.joined().contains("DETAILS"))
        XCTAssertFalse(without.joined().localizedCaseInsensitiveContains("No details"))
    }

    func testExecutionDetailsUseAnAccentLineWithoutAFilledContainer() throws {
        let shared = try appSource("Views/RequestMealPresentation.swift")
        let start = try XCTUnwrap(shared.range(of: "case .execution:"))
        let end = try XCTUnwrap(shared.range(of: "private func eyebrow", range: start.upperBound..<shared.endIndex))
        let execution = String(shared[start.upperBound..<end.lowerBound])
        XCTAssertTrue(execution.contains("Capsule()"), "subtle leading accent line")
        XCTAssertTrue(execution.contains(".frame(width: 3)"))
        for retired in [".background(", "RoundedRectangle", "secondarySystemFill"] {
            XCTAssertFalse(execution.contains(retired), retired)
        }
        let placeOrder = try appSource("Views/FulfillRequestView.swift")
        XCTAssertFalse(placeOrder.contains("\"Meal Exchange · "), "no redundant menu prefix")
    }

    func testCompactDensityHasNoLabels() throws {
        let compact = try labels(RequestMealView(
            entry: RequestMealEntry(label: "Meal 1", name: "Chicken tenders", details: "Crispy, no sauce"),
            density: .compact
        )).joined(separator: " ")
        XCTAssertTrue(compact.contains("Chicken tenders"))
        XCTAssertTrue(compact.contains("Crispy, no sauce"))
        XCTAssertFalse(compact.contains("MEAL"))
        XCTAssertFalse(compact.contains("DETAILS"))
        XCTAssertFalse(compact.contains("("))
    }

    func testLongDetailsWrapAtLargestTypeInDarkMode() {
        let entry = RequestMealEntry(label: "Meal 1", name: tenders, details: longDetails)
        let width: CGFloat = 320
        func height(_ density: RequestMealDensity, _ size: DynamicTypeSize) -> CGFloat {
            let host = UIHostingController(rootView: RequestMealView(entry: entry, density: density)
                .dynamicTypeSize(size)
                .environment(\.colorScheme, .dark))
            return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        }
        for density in [RequestMealDensity.detail, .execution] {
            let regular = height(density, .large)
            let largest = height(density, .accessibility5)
            XCTAssertGreaterThan(regular, 120, "long details wrap onto several lines")
            XCTAssertGreaterThan(largest, regular * 2, "Dynamic Type grows instead of truncating")
            let fit = UIHostingController(rootView: RequestMealView(entry: entry, density: density))
                .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            XCTAssertLessThanOrEqual(fit.width, width + 0.5, "no horizontal overflow")
        }
    }

    // MARK: - Helpers

    private func labels<V: View>(_ view: V) throws -> [String] {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view.padding())
        window.makeKeyAndVisible()
        window.rootViewController?.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        defer { window.isHidden = true }
        var result: [String] = []
        func walk(_ node: NSObject) {
            if let label = node.accessibilityLabel, !label.isEmpty { result.append(label) }
            if let elements = node.accessibilityElements as? [NSObject] {
                elements.forEach(walk)
            }
            if let view = node as? UIView {
                view.subviews.forEach(walk)
            }
        }
        walk(window)
        return result
    }

    private func appSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
