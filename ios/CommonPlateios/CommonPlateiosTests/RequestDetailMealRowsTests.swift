import XCTest
@testable import CommonPlateios

/// Request detail (before claiming) lists each meal under its own label, so a
/// helper can see which meal each swipe pays for.
final class RequestDetailMealRowsTests: XCTestCase {
    private func request(
        menuPath: RequestMenuPath,
        meals: [MealItem],
        orderDetails: String? = nil
    ) -> FoodRequest {
        let now = Date()
        return FoodRequest(
            id: "r1",
            diningSpot: DiningSpot(name: "Cafe 370", address: nil),
            foodDescription: "Summary text",
            pickupWindowText: "ASAP",
            mealSwipes: menuPath == .mealExchange ? meals.count : 0,
            resource: RequestResource(
                menuPath: menuPath,
                mealItems: meals,
                orderDetails: orderDetails,
                estimatedDiningDollarsCents: nil
            ),
            windowStart: nil,
            windowEnd: nil,
            createdAt: now,
            expiresAt: now.addingTimeInterval(3 * 3600),
            status: .open,
            ownership: .notOwn
        )
    }

    func testMultipleMealsGetOneNumberedRowEachWithExactTextAndDetails() {
        let rows = RequestDetailView.mealRows(for: request(menuPath: .mealExchange, meals: [
            MealItem(name: "Breakfast sandwich"),
            MealItem(name: "Poke bowl", details: "Extra edamame"),
            MealItem(name: "Large fries", details: "")
        ]))
        XCTAssertEqual(rows, [
            .init(label: "Meal 1", name: "Breakfast sandwich", details: nil),
            .init(label: "Meal 2", name: "Poke bowl", details: "Extra edamame"),
            .init(label: "Meal 3", name: "Large fries", details: nil)
        ])
    }

    func testSingleMealKeepsTheMealRequestLabel() {
        let rows = RequestDetailView.mealRows(for: request(menuPath: .mealExchange, meals: [
            MealItem(name: "Rice bowl", details: "No onions")
        ]))
        XCTAssertEqual(rows, [.init(label: "Meal request", name: "Rice bowl", details: "No onions")])
    }

    func testDiningDollarsAndUnstructuredRequestsFallBackToOrderDetails() throws {
        XCTAssertEqual(RequestDetailView.mealRows(for: request(
            menuPath: .diningDollars, meals: [], orderDetails: "Iced latte"
        )), [])
        XCTAssertEqual(RequestDetailView.mealRows(for: request(menuPath: .mealExchange, meals: [])), [])

        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("CommonPlateios/Views/RequestDetailView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("Text(request.resource.orderDetails ?? request.foodDescription)"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"request-meal-\\(index + 1)\")"))
    }

    func testGoToActiveReservationIsAFullWidthOneLineSecondaryAction() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("CommonPlateios/Views/RequestDetailView.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "Text(Self.goToActiveReservationTitle)"))
        let end = try XCTUnwrap(source.range(of: ".accessibilityIdentifier(\"go-to-active-reservation\")"))
        let span = source[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(span.contains(".commonPlateMajorSecondaryAction()"))
        XCTAssertFalse(span.contains(".commonPlateMajorActionFrame()"), "full column width, like Start helping")
        XCTAssertEqual(RequestDetailView.goToActiveReservationTitle, "Go to your current request")
    }
}
