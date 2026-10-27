import Foundation

/// Single source of the product's public name and campus qualifier. User-facing
/// copy interpolates these values so a rename is a one-line change here (plus
/// the display name / support address in configuration), never a sweep across
/// screens. Internal identifiers (asset names, type names, accessibility ids,
/// the backend) are intentionally not derived from it.
enum AppBrand {
    static let name = "GoodGrub"
    static let campus = "NYU"

    /// "GoodGrub at NYU"
    static let nameWithCampus = "\(name) at \(campus)"
    static let nameUppercased = name.uppercased()
    /// "GoodGrub’s"
    static let possessive = "\(name)’s"
}
