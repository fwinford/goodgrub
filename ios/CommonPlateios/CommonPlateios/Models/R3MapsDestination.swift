import Foundation

struct R3MapsDestination: Equatable {
    let query: String

    private static let verifiedAddresses: [String: String] = [
        "Peet's Coffee at Kimmel": "Kimmel Center, 60 Washington Sq S, 2nd Floor",
        "Palladium": "Palladium Hall, 140 E 14th St",
        "Upstein - Vedge Craft & Smoothie Lab": "Weinstein Hall, 5 University Pl #11",
        "Upstein - Shareables, Cluckstein, Slidestein & Taqueria": "Weinstein Hall, 5 University Pl #11",
        "True Burger at UHall": "U-Hall, 110 E. 14th",
        "Cafe 370": "BROOKLYN - 370 Jay St"
    ]

    /// Real street addresses for venues whose shared-catalog text is a building
    /// or floor description. Display and Maps use these; `vendors.json` (the
    /// screenshot-qualification catalog) is untouched. Venues not listed here
    /// and not verified above stay plain text.
    private static let streetAddresses: [String: String] = [
        "Crave NYU": "181 Mercer St",
        "Cafe 181": "181 Mercer St",
        "Jasper Kane Cafe": "327 Jay St",
        "Flavor Lab by NYU Eats": "327 Jay St",
        "Dunkin' at U-Hall": "110 E 14th St"
    ]

    private static let brooklynVenues: Set<String> = [
        "Jasper Kane Cafe", "Flavor Lab by NYU Eats"
    ]

    /// The address to show for a venue: a real street address when one is
    /// known, otherwise the catalog text.
    static func displayAddress(for spot: DiningSpot) -> String? {
        streetAddresses[spot.name] ?? spot.address
    }

    init?(diningSpot: DiningSpot) {
        if let street = Self.streetAddresses[diningSpot.name] {
            let city = Self.brooklynVenues.contains(diningSpot.name) ? "Brooklyn, NY" : "New York, NY"
            query = "\(diningSpot.name), \(street), \(city)"
            return
        }
        guard let address = diningSpot.address,
              Self.verifiedAddresses[diningSpot.name] == address else {
            return nil
        }
        query = "\(diningSpot.name), \(address)"
    }

    var appleMapsURL: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url
    }

    var googleMapsURL: URL? {
        var components = URLComponents()
        components.scheme = "comgooglemaps"
        components.host = ""
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url
    }
}
