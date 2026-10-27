import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class ScreenshotVenueClassifierTests: XCTestCase {
    func testVersionedSyntheticVenueVectorsMatchTheSwiftClassifier() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: root.appendingPathComponent("shared/screenshot-venue-vectors.json"))
            ) as? [String: Any]
        )
        XCTAssertEqual(object["version"] as? Int, 1)
        let vectors = try XCTUnwrap(object["vectors"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(vectors.count, 20)
        for vector in vectors {
            let id = try XCTUnwrap(vector["id"] as? String)
            let texts = try XCTUnwrap(vector["evidenceTexts"] as? [String])
            let expected = try XCTUnwrap(vector["expected"] as? [String: Any])
            let classification = RequesterVenueClassifier.classify(
                imageEvidenceTexts: texts,
                vendors: SupportedVendorCatalog.diningSpots
            )
            let actual = classification.disposition
            XCTAssertEqual(kind(actual), expected["kind"] as? String, id)
            XCTAssertEqual(classification.hasV1Observation, expected["hasV1Observation"] as? Bool, id)
            if let vendor = expected["vendor"] as? String, case .supported(let spot) = actual {
                XCTAssertEqual(spot.name, vendor, id)
            }
            if let key = expected["key"] as? String, case .unsupported(let actualKey) = actual {
                XCTAssertEqual(actualKey, key, id)
            }
        }
    }

    func testNearMissOnlyDowngradesAndNeverReturnsSupportedAuthority() {
        let result = RequesterVenueClassifier.classify(
            imageEvidenceTexts: ["Dunkin'at U-Hall - Meal Exchange"],
            vendors: SupportedVendorCatalog.diningSpots
        )
        XCTAssertEqual(result.disposition, .unresolved)
        XCTAssertTrue(result.hasV1Observation)
    }

    private func kind(_ disposition: RequesterVenueDisposition) -> String {
        switch disposition {
        case .supported: return "supported"
        case .unresolved: return "unresolved"
        case .unsupported: return "unsupported"
        case .conflicting: return "conflicting"
        }
    }
}
