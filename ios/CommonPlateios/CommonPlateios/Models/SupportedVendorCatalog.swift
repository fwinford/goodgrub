//
//  SupportedVendorCatalog.swift
//  CommonPlateios
//
// `Resources/SupportedVendors.json` is a symlink to the repo-root
// `shared/vendors.json` that the backend also reads (see
// `src/supportedVendors.ts`), so this is the same physical catalog, not a
// second copy kept in sync by hand.
import Foundation

enum SupportedVendorCatalog {
    /// Decode failure here means the bundled catalog is missing or malformed,
    /// which is a build-time packaging defect, not a runtime condition the UI
    /// can recover from — so this crashes immediately rather than silently
    /// presenting an empty or partial picker.
    static let diningSpots: [DiningSpot] = {
        guard let url = Bundle.main.url(forResource: "SupportedVendors", withExtension: "json") else {
            fatalError("SupportedVendors.json is missing from the app bundle.")
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([DiningSpot].self, from: data)
        } catch {
            fatalError("SupportedVendors.json failed to decode: \(error)")
        }
    }()
}
