//
//  RequestCardMealSwipeVisibilityTests.swift
//  CommonPlateiosTests
//
//  W3-C1, carried forward by W4-R5's retirement of Active Requests: the
//  request card a helper sees on Home must show a request's existing
//  Request-owned `mealSwipes` value before the helper opens Request Detail.
//  (The retired Active Requests row used to carry this proof.)
//

import XCTest
@testable import CommonPlateios

final class RequestCardMealSwipeVisibilityTests: XCTestCase {
    func testTheCardPresentsTheRequestOwnedMealSwipeQuantity() throws {
        XCTAssertEqual(RequestCardView.mealSwipesText(1), "1 meal swipe")
        XCTAssertEqual(RequestCardView.mealSwipesText(2), "2 meal swipes")

        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("CommonPlateios/Views/RequestCardView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("mealSwipesText(request.mealSwipes)"))
        XCTAssertTrue(
            source.contains("Self.mealSwipesOrDollarsText(for: request)"),
            "RequestCardView no longer shows the request's meal-swipe quantity"
        )
    }

    func testADiningDollarsRequestShowsItsAmountInsteadOfZeroSwipes() {
        func request(_ resource: RequestResource, swipes: Int) -> FoodRequest {
            FoodRequest(
                id: "r", diningSpot: DiningSpot(name: "Peet's Coffee at Kimmel", address: nil),
                foodDescription: "x", pickupWindowText: "ASAP", mealSwipes: swipes,
                resource: resource, windowStart: nil, windowEnd: nil,
                createdAt: Date(), expiresAt: Date(), status: .open
            )
        }
        let dollars = RequestResource(
            menuPath: .diningDollars, mealItems: [], orderDetails: "x",
            estimatedDiningDollarsCents: 200
        )
        XCTAssertEqual(RequestCardView.quantityText(for: request(dollars, swipes: 0)), "$2.00 Dining Dollars")
        let exchange = RequestResource(
            menuPath: .mealExchange, mealItems: [], orderDetails: nil,
            estimatedDiningDollarsCents: 200
        )
        XCTAssertEqual(RequestCardView.quantityText(for: request(exchange, swipes: 2)), "2 meal swipes + $2.00 Dining Dollars")
    }

    func testCardBodyDropsTheDiningDollarsSuffixOnlyWhenTheHeaderShowsTheAmount() {
        func request(_ resource: RequestResource, food: String) -> FoodRequest {
            FoodRequest(
                id: "r", diningSpot: DiningSpot(name: "Peet's Coffee at Kimmel", address: nil),
                foodDescription: food, pickupWindowText: "ASAP", mealSwipes: 0,
                resource: resource, windowStart: nil, windowEnd: nil,
                createdAt: Date(), expiresAt: Date(), status: .open
            )
        }
        let dollars = RequestResource(
            menuPath: .diningDollars, mealItems: [], orderDetails: "Latte",
            estimatedDiningDollarsCents: 200
        )
        XCTAssertEqual(
            RequestCardView.bodyText(for: request(dollars, food: "Latte ($2.00 Dining Dollars)")),
            "Latte"
        )
        XCTAssertEqual(RequestCardView.bodyText(for: request(dollars, food: "Latte")), "Latte")
        let exchange = RequestResource(
            menuPath: .mealExchange, mealItems: [], orderDetails: nil,
            estimatedDiningDollarsCents: 200
        )
        XCTAssertEqual(
            RequestCardView.bodyText(for: request(exchange, food: "Wings + $2.00 Dining Dollars")),
            "Wings"
        )
        XCTAssertEqual(
            RequestCardView.bodyText(for: request(exchange, food: "Wings ($2.00 Dining Dollars)")),
            "Wings ($2.00 Dining Dollars)"
        )
    }

    func testATopUpIsABareAmountOnTheCardTitleSecondLine() {
        func request(_ resource: RequestResource) -> FoodRequest {
            FoodRequest(
                id: "r", diningSpot: DiningSpot(name: "Dunkin' at U-Hall", address: nil),
                foodDescription: "x", pickupWindowText: "ASAP", mealSwipes: 2,
                resource: resource, windowStart: nil, windowEnd: nil,
                createdAt: Date(), expiresAt: Date(), status: .open
            )
        }
        let exchange = RequestResource(
            menuPath: .mealExchange, mealItems: [], orderDetails: nil,
            estimatedDiningDollarsCents: 1500
        )
        XCTAssertEqual(RequestCardView.mealSwipesOrDollarsText(for: request(exchange)), "2 meal swipes")
        XCTAssertEqual(RequestCardView.cardTopUpText(for: request(exchange)), "+\u{00A0}$15.00")
        let none = RequestResource(
            menuPath: .mealExchange, mealItems: [], orderDetails: nil,
            estimatedDiningDollarsCents: nil
        )
        XCTAssertNil(RequestCardView.cardTopUpText(for: request(none)))
    }
}
