import XCTest
@testable import CommonPlateios

/// Proves the Picker's data source decodes from the bundled shared catalog
/// (`Resources/SupportedVendors.json`, a symlink to the repo-root
/// `shared/vendors.json` the backend also reads — see
/// `src/supportedVendors.test.ts`), preserving the exact accepted 10 entries
/// rather than a second hand-maintained Swift list.
final class SupportedVendorCatalogTests: XCTestCase {
    func testDecodesExactlyTheAcceptedTenSpotsInOrder() {
        let names = SupportedVendorCatalog.diningSpots.map(\.name)

        XCTAssertEqual(names, [
            "Crave NYU",
            "Dunkin' at U-Hall",
            "Jasper Kane Cafe",
            "Peet's Coffee at Kimmel",
            "Cafe 370",
            "Flavor Lab by NYU Eats",
            "Cafe 181",
            "Upstein - Vedge Craft & Smoothie Lab",
            "Upstein - Shareables, Cluckstein, Slidestein & Taqueria",
            "True Burger at UHall",
        ])
    }

    func testPalladiumIsNotASupportedDiningHall() {
        // Faith (N1): Palladium has no Grubhub listing and is not requestable.
        XCTAssertFalse(SupportedVendorCatalog.diningSpots.contains { $0.name == "Palladium" })
    }

    func testEveryEntryHasAnAddress() {
        for spot in SupportedVendorCatalog.diningSpots {
            XCTAssertFalse((spot.address ?? "").isEmpty, "\(spot.name) is missing its address")
        }
    }
}
