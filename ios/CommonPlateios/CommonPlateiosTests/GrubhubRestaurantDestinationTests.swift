import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class GrubhubRestaurantDestinationTests: XCTestCase {
    func testEveryMappedCanonicalRestaurantHasDistinctContextSpecificPublicDestinations() throws {
        let catalogIDs = Set(SupportedVendorCatalog.diningSpots.map(\.id))
        var destinations = Set<URL>()
        for restaurant in GrubhubRestaurantDestination.Restaurant.allCases {
            XCTAssertTrue(catalogIDs.contains(restaurant.rawValue))
            let exchange = try XCTUnwrap(GrubhubRestaurantDestination.url(
                restaurantID: restaurant.rawValue, menuPath: .mealExchange
            ))
            let dollars = try XCTUnwrap(GrubhubRestaurantDestination.url(
                restaurantID: restaurant.rawValue, menuPath: .diningDollars
            ))
            XCTAssertNotEqual(exchange, dollars)
            XCTAssertTrue(exchange.path.contains("meal-exchange"))
            XCTAssertFalse(dollars.path.contains("meal-exchange"))
            for destination in [exchange, dollars] {
                XCTAssertTrue(destinations.insert(destination).inserted)
                let parts = try XCTUnwrap(URLComponents(url: destination, resolvingAgainstBaseURL: false))
                XCTAssertEqual(parts.scheme, "https")
                XCTAssertEqual(parts.host, "www.grubhub.com")
                XCTAssertEqual(
                    parts.queryItems,
                    [
                        URLQueryItem(name: "utm_source", value: "grubhub_iosapp"),
                        URLQueryItem(name: "utm_medium", value: "content_owned"),
                        URLQueryItem(name: "utm_campaign", value: "menushare"),
                        URLQueryItem(name: "utm_content", value: "share-link")
                    ],
                    "static provider share metadata only; no GoodGrub identity or request parameters"
                )
            }
        }
        XCTAssertEqual(destinations.count, 20)
    }

    func testUpsteinConceptsUseTheirOwnListingsForBothContexts() throws {
        for (context, mainID, vedgeID) in [
            (RequestMenuPath.mealExchange, "-4483130", "-19515571"),
            (.diningDollars, "-4483124", "-19515197")
        ] {
            let main = try XCTUnwrap(GrubhubRestaurantDestination.url(
                restaurantID: GrubhubRestaurantDestination.Restaurant.upsteinMain.rawValue,
                menuPath: context
            ))
            let vedge = try XCTUnwrap(GrubhubRestaurantDestination.url(
                restaurantID: GrubhubRestaurantDestination.Restaurant.upsteinVedge.rawValue,
                menuPath: context
            ))
            XCTAssertEqual(main.lastPathComponent, mainID)
            XCTAssertEqual(vedge.lastPathComponent, vedgeID)
        }
    }

    func testUnknownMissingAndUnsupportedCatalogIdentitiesHaveNoFallback() {
        for id in ["", "Palladium", "Upstein", "crave nyu", "Crave NYU ", "Starbucks"] {
            for context in [RequestMenuPath.mealExchange, .diningDollars] {
                XCTAssertNil(GrubhubRestaurantDestination.url(restaurantID: id, menuPath: context))
            }
        }
        // Starbucks Dining Dollars is product-approved but not representable
        // in the canonical catalog yet; this test does not authorize adding it.
        XCTAssertFalse(SupportedVendorCatalog.diningSpots.contains { $0.id == "Starbucks" })
    }

    func testUnmappedRestaurantsOpenGrubhubItselfAndMappedOnesTheirListing() throws {
        for context in [RequestMenuPath.mealExchange, .diningDollars] {
            XCTAssertEqual(
                GrubhubRestaurantDestination.destination(restaurantID: "Palladium", menuPath: context),
                URL(string: "https://www.grubhub.com/")
            )
            let mapped = try XCTUnwrap(GrubhubRestaurantDestination.url(restaurantID: "Crave NYU", menuPath: context))
            XCTAssertEqual(
                GrubhubRestaurantDestination.destination(restaurantID: "Crave NYU", menuPath: context),
                mapped
            )
        }
    }

    func testInvalidDestinationsAreRejectedAndNeverOpened() throws {
        let valid = try XCTUnwrap(GrubhubRestaurantDestination.url(
            restaurantID: "Crave NYU", menuPath: .mealExchange
        )).absoluteString
        let invalid = [
            "not a URL", "grubhub://", "https://www.grubhub.com",
            valid.replacingOccurrences(of: "https:", with: "http:"),
            valid.replacingOccurrences(of: "www.grubhub.com", with: "www.grubhub.com.evil.test"),
            valid.replacingOccurrences(of: "www.grubhub.com", with: "user:secret@www.grubhub.com"),
            valid + "&requestId=private",
            valid + "#private"
        ]
        for raw in invalid {
            XCTAssertNil(GrubhubRestaurantDestination.validatedURL(raw), raw)
            if let url = URL(string: raw) {
                var didComplete = false
                GrubhubHandoff.open(
                    destination: url,
                    using: { _, _ in XCTFail("must not open invalid destination") },
                    completion: { opened in
                        XCTAssertFalse(opened)
                        didComplete = true
                    }
                )
                XCTAssertTrue(didComplete)
            }
        }
    }
}
