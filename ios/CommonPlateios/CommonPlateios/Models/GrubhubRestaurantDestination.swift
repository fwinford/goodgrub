import Foundation

enum GrubhubRestaurantDestination {
    enum Restaurant: String, CaseIterable {
        case crave = "Crave NYU"
        case dunkin = "Dunkin' at U-Hall"
        case jasper = "Jasper Kane Cafe"
        case peets = "Peet's Coffee at Kimmel"
        case cafe370 = "Cafe 370"
        case flavorLab = "Flavor Lab by NYU Eats"
        case cafe181 = "Cafe 181"
        case upsteinVedge = "Upstein - Vedge Craft & Smoothie Lab"
        case upsteinMain = "Upstein - Shareables, Cluckstein, Slidestein & Taqueria"
        case trueBurger = "True Burger at UHall"
    }

    private struct Menus {
        let mealExchange: String
        let diningDollars: String
    }

    private static let menus: [Restaurant: Menus] = [
        .crave: Menus(
            mealExchange: "https://www.grubhub.com/restaurant/crave-nyu--meal-exchange-181-mercer-st--6th-floor-new-york/-10311827?utm_source=grubhub_iosapp&utm_medium=content_owned&utm_campaign=menushare&utm_content=share-link",
            diningDollars: "https://www.grubhub.com/restaurant/crave-nyu-181-mercer-st--6th-floor-new-york/-10311819?utm_source=grubhub_iosapp&utm_medium=content_owned&utm_campaign=menushare&utm_content=share-link"
        ),
        .dunkin: Menus(
            mealExchange: "https://www.grubhub.com/restaurant/dunkin--at-u-hall--meal-exchange-110-e-14th-new-york/-3427990?utm_source=grubhub_iosapp&utm_medium=content_owned&utm_campaign=menushare&utm_content=share-link",
            diningDollars: "https://www.grubhub.com/restaurant/dunkin--at-u-hall-110-e-14th-new-york/-3427981?utm_source=grubhub_iosapp&utm_medium=content_owned&utm_campaign=menushare&utm_content=share-link"
        ),
        .jasper: Menus(
            mealExchange: "https://www.grubhub.com/restaurant/jasper-kane-cafe-meal-exchange--grill--sushi--deli-6-metrotech-center-brooklyn-brooklyn/-3441895?utm_source=grubhub_iosapp&utm_medium=content_owned&utm_campaign=menushare&utm_content=share-link",
            diningDollars: "https://www.grubhub.com/restaurant/jasper-kane-cafe--shareables--grill--sushi--deli-6-metrotech-center-brooklyn/-3441887?utm_source=grubhub_iosapp&utm_medium=content_owned&utm_campaign=menushare&utm_content=share-link"
        ),
        .peets: Menus(
            mealExchange: "https://www.grubhub.com/restaurant/peet-s-coffee-at-kimmel--meal-exchange-60-washington-square-park-south-new-york/-3428132?utm_source=grubhub_iosapp&utm_medium=content_owned&utm_campaign=menushare&utm_content=share-link",
            diningDollars: "https://www.grubhub.com/restaurant/peet-s-coffee-at-kimmel-60-washington-square-park-south-new-york/-3428126?utm_source=grubhub_iosapp&utm_medium=content_owned&utm_campaign=menushare&utm_content=share-link"
        ),
        .cafe370: Menus(
            mealExchange: "https://www.grubhub.com/restaurant/cafe-370--meal-exchange-370-jay-st-brooklyn/-5898153?utm_source=grubhub_iosapp&utm_medium=content_owned&utm_campaign=menushare&utm_content=share-link",
            diningDollars: "https://www.grubhub.com/restaurant/cafe-370-370-jay-st-brooklyn/-5895181?utm_source=grubhub_iosapp&utm_medium=content_owned&utm_campaign=menushare&utm_content=share-link"
        ),
        .flavorLab: Menus(
            mealExchange: "https://www.grubhub.com/restaurant/flavor-lab-by-nyu-eats--meal-exchange-6-metrotech-center-brooklyn/-15162584?utm_source=grubhub_iosapp&utm_medium=content_owned&utm_campaign=menushare&utm_content=share-link",
            diningDollars: "https://www.grubhub.com/restaurant/flavor-lab-by-nyu-eats-6-metrotech-center-brooklyn/-15157279?utm_source=grubhub_iosapp&utm_medium=content_owned&utm_campaign=menushare&utm_content=share-link"
        ),
        .cafe181: Menus(
            mealExchange: "https://www.grubhub.com/restaurant/cafe-181--meal-exchange-181-mercer-st--2nd-floor-new-york/-10311837?utm_source=grubhub_iosapp&utm_medium=content_owned&utm_campaign=menushare&utm_content=share-link",
            diningDollars: "https://www.grubhub.com/restaurant/cafe-181-181-mercer-st--2nd-floor-new-york/-10311835?utm_source=grubhub_iosapp&utm_medium=content_owned&utm_campaign=menushare&utm_content=share-link"
        ),
        .upsteinVedge: Menus(
            mealExchange: "https://www.grubhub.com/restaurant/upstein-meal-exchange--vedge-craft--smoothie-lab-5-11-university-place-new-york/-19515571?utm_source=grubhub_iosapp&utm_medium=content_owned&utm_campaign=menushare&utm_content=share-link",
            diningDollars: "https://www.grubhub.com/restaurant/upstein--vedge-craft--smoothie-lab-5-11-university-place-new-york/-19515197?utm_source=grubhub_iosapp&utm_medium=content_owned&utm_campaign=menushare&utm_content=share-link"
        ),
        .upsteinMain: Menus(
            mealExchange: "https://www.grubhub.com/restaurant/upstein-meal-exchange--cluckstein--slidestein--taqueria--sushi-5-11-university-place-new-york/-4483130?utm_source=grubhub_iosapp&utm_medium=content_owned&utm_campaign=menushare&utm_content=share-link",
            diningDollars: "https://www.grubhub.com/restaurant/upstein--shareables--cluckstein--slidestein--taqueria--sushi-5-11-university-place-new-york/-4483124?utm_source=grubhub_iosapp&utm_medium=content_owned&utm_campaign=menushare&utm_content=share-link"
        ),
        .trueBurger: Menus(
            mealExchange: "https://www.grubhub.com/restaurant/true-burger-at-uhall--meal-exchange-110-e--14th-inside-of-u-hall-new-york/-3427957?utm_source=grubhub_iosapp&utm_medium=content_owned&utm_campaign=menushare&utm_content=share-link",
            diningDollars: "https://www.grubhub.com/restaurant/true-burger-at-uhall-110-e--14th-inside-of-u-hall-new-york/-3427945?utm_source=grubhub_iosapp&utm_medium=content_owned&utm_campaign=menushare&utm_content=share-link"
        )
    ]

    static func url(restaurantID: DiningSpot.ID, menuPath: RequestMenuPath) -> URL? {
        guard SupportedVendorCatalog.diningSpots.contains(where: { $0.id == restaurantID }),
              let restaurant = Restaurant(rawValue: restaurantID),
              let destinations = menus[restaurant] else { return nil }
        let raw = menuPath == .mealExchange ? destinations.mealExchange : destinations.diningDollars
        return validatedURL(raw)
    }

    /// Faith (N1 walkthrough): with no restaurant-specific listing, Open in
    /// Grubhub still opens Grubhub itself rather than disappearing.
    static let fallback = URL(string: "https://www.grubhub.com/")!

    /// The restaurant listing when one is mapped, otherwise Grubhub itself.
    static func destination(restaurantID: DiningSpot.ID, menuPath: RequestMenuPath) -> URL {
        url(restaurantID: restaurantID, menuPath: menuPath) ?? fallback
    }

    static func validatedURL(_ raw: String) -> URL? {
        guard let parts = URLComponents(string: raw),
              parts.scheme == "https", parts.host == "www.grubhub.com",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.fragment == nil, parts.path.hasPrefix("/restaurant/"),
              parts.path.split(separator: "/").count >= 3,
              let query = parts.queryItems,
              query.count == 4,
              Set(query.map(\.name)) == Set(["utm_source", "utm_medium", "utm_campaign", "utm_content"]),
              query.allSatisfy({ !($0.value?.isEmpty ?? true) })
        else { return nil }
        return parts.url
    }
}
