//
//  ScreenshotConformanceVectorTests.swift
//  CommonPlateiosTests
//
// W4-S3 drift guard, iOS side. `shared/screenshot-conformance-vectors.json` is
// the same synthetic vector file `src/screenshotConformanceVectors.test.ts`
// asserts against the backend implementation. The on-device eligibility,
// corroboration, vendor-grounding, Dining Dollars, and provider-output rules
// must produce exactly the backend's expected result for every vector, so the
// accepted fail-closed rules cannot silently diverge between Swift and
// TypeScript. The vectors contain no real screenshot or OCR content.
import Foundation
import XCTest
@testable import CommonPlateios

final class ScreenshotConformanceVectorTests: XCTestCase {
    private struct Vectors {
        let version: Int
        let totalGeometry: [[String: Any]]
        let eligibility: [[String: Any]]
        let mealSwipeCorroboration: [[String: Any]]
        let menuPath: [[String: Any]]
        let providerOutput: [[String: Any]]
    }

    private func loadVectors() throws -> Vectors {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CommonPlateiosTests
            .deletingLastPathComponent() // CommonPlateios
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repository root
        let url = root.appendingPathComponent("shared/screenshot-conformance-vectors.json")
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        return Vectors(
            version: try XCTUnwrap(object["version"] as? Int),
            totalGeometry: try XCTUnwrap(object["totalGeometry"] as? [[String: Any]]),
            eligibility: try XCTUnwrap(object["eligibility"] as? [[String: Any]]),
            mealSwipeCorroboration: try XCTUnwrap(object["mealSwipeCorroboration"] as? [[String: Any]]),
            menuPath: try XCTUnwrap(object["menuPath"] as? [[String: Any]]),
            providerOutput: try XCTUnwrap(object["providerOutput"] as? [[String: Any]])
        )
    }

    func testVectorFileIsTheKnownVersionAndIsNotHollowedOut() throws {
        let vectors = try loadVectors()
        XCTAssertEqual(vectors.version, 1)
        XCTAssertGreaterThanOrEqual(vectors.totalGeometry.count, 6)
        XCTAssertGreaterThanOrEqual(vectors.eligibility.count, 41)
        XCTAssertGreaterThanOrEqual(vectors.mealSwipeCorroboration.count, 22)
        XCTAssertGreaterThanOrEqual(vectors.menuPath.count, 50)
        XCTAssertGreaterThanOrEqual(vectors.providerOutput.count, 113)
        for group in [vectors.totalGeometry, vectors.eligibility, vectors.mealSwipeCorroboration, vectors.menuPath, vectors.providerOutput] {
            let ids = group.compactMap { $0["id"] as? String }
            XCTAssertEqual(ids.count, Set(ids).count, "vector ids must be unique")
        }
    }

    func testTotalGeometryVectors() throws {
        for vector in try loadVectors().totalGeometry {
            let id = try XCTUnwrap(vector["id"] as? String)
            let texts = try XCTUnwrap(vector["evidenceTexts"] as? [String])
            let rawGeometry = try XCTUnwrap(vector["geometryEvidence"] as? [Any])
            let geometry = try JSONDecoder().decode(
                [ScreenshotTotalGeometryEvidence?].self,
                from: JSONSerialization.data(withJSONObject: rawGeometry)
            )
            let expected = try XCTUnwrap(vector["expected"] as? [String: Any])
            XCTAssertEqual(
                RequesterOrderDeterministicEvidence.currentOrderTotalCents(
                    imageEvidenceTexts: texts,
                    imageTotalGeometryEvidence: geometry
                ),
                expected["totalCents"] as? Int,
                "Total geometry: \(id)"
            )
            let resolution = RequesterOrderDeterministicEvidence.resolveMenuPath(
                imageEvidenceTexts: texts,
                imageTotalGeometryEvidence: geometry
            )
            XCTAssertEqual(
                resolution.menuPath,
                Self.domainPath(expected["menuPath"] as? String),
                "Total geometry path: \(id)"
            )
            XCTAssertEqual(resolution.conflict, expected["conflict"] as? Bool, "Total geometry conflict: \(id)")
        }
    }

    func testEligibilityVectors() throws {
        for vector in try loadVectors().eligibility {
            let id = try XCTUnwrap(vector["id"] as? String)
            let text = try XCTUnwrap(vector["evidenceText"] as? String)
            let expected = try XCTUnwrap(vector["expected"] as? [String: Any])
            let result = RequesterOrderDeterministicEvidence.evaluateEligibility(text)
            XCTAssertEqual(result.eligible, expected["eligible"] as? Bool, "eligibility: \(id)")
            XCTAssertEqual(result.category?.rawValue, expected["category"] as? String, "category: \(id)")
        }
    }

    func testMealSwipeCorroborationVectors() throws {
        for vector in try loadVectors().mealSwipeCorroboration {
            let id = try XCTUnwrap(vector["id"] as? String)
            let text = try XCTUnwrap(vector["evidenceText"] as? String)
            let expected = vector["expected"] as? Int // JSON null -> nil
            XCTAssertEqual(RequesterOrderDeterministicEvidence.corroboratedMealSwipeCount(text), expected, "swipes: \(id)")
        }
    }

    /// W4-R4.1: the deterministic menu-path rule, per-screenshot, including
    /// conflicts. Wire strings map to the domain path; `null` is no proposal.
    func testMenuPathVectors() throws {
        for vector in try loadVectors().menuPath {
            let id = try XCTUnwrap(vector["id"] as? String)
            let texts = try XCTUnwrap(vector["evidenceTexts"] as? [String])
            let expected = try XCTUnwrap(vector["expected"] as? [String: Any])
            let result = RequesterOrderDeterministicEvidence.resolveMenuPath(imageEvidenceTexts: texts)
            XCTAssertEqual(result.menuPath, Self.domainPath(expected["menuPath"] as? String), "menu path: \(id)")
            XCTAssertEqual(result.conflict, expected["conflict"] as? Bool, "conflict: \(id)")
        }
    }

    private static func domainPath(_ wire: String?) -> RequestMenuPath? {
        switch wire {
        case "meal-exchange": return .mealExchange
        case "dining-dollars": return .diningDollars
        default: return nil
        }
    }

    func testProviderOutputVectors() throws {
        let catalog = SupportedVendorCatalog.diningSpots
        for vector in try loadVectors().providerOutput {
            let id = try XCTUnwrap(vector["id"] as? String)
            let evidence = try XCTUnwrap(vector["evidenceText"] as? String)
            let count = try XCTUnwrap(vector["evidenceImageCount"] as? Int)
            let expected = try XCTUnwrap(vector["expected"] as? [String: Any])
            let imageTexts = vector["evidenceTexts"] as? [String]
            if let imageTexts {
                XCTAssertEqual(evidence, imageTexts.joined(separator: "\n"), "combined evidence text: \(id)")
            }

            let result = RequesterOrderOutputValidator.validate(
                raw: vector["raw"],
                evidenceText: evidence,
                evidenceImageCount: count,
                imageEvidenceTexts: imageTexts,
                // The shared vectors describe the backend's behavior, where the
                // OCR-derived Dining Dollars rule is available. The OCR→local
                // restriction is Swift-only policy, proven separately below.
                allowsDiningDollarsEstimate: true
            )

            if (expected["ok"] as? Bool) == true {
                let proposal = try XCTUnwrap(expected["proposal"] as? [String: Any])
                XCTAssertEqual(result, .valid(try swiftProposal(from: proposal, catalog: catalog, id: id)), "provider output: \(id)")
            } else {
                let reason = try XCTUnwrap(expected["reason"] as? String)
                let expectedFailure: RequesterOrderOutputValidator.Failure =
                    reason == "forbidden_fields" ? .forbiddenFields : .schemaInvalid
                XCTAssertEqual(result, .invalid(expectedFailure), "provider output: \(id)")
            }
        }
    }

    private func swiftProposal(
        from proposal: [String: Any],
        catalog: [DiningSpot],
        id: String
    ) throws -> ScreenshotProposal {
        var result = ScreenshotProposal()
        result.menuPath = Self.domainPath(proposal["menuPath"] as? String)
        if let spot = proposal["selectedDiningSpot"] as? [String: Any] {
            let name = try XCTUnwrap(spot["name"] as? String)
            let catalogSpot = try XCTUnwrap(catalog.first { $0.name == name }, "vendor \(name) in \(id)")
            XCTAssertEqual(catalogSpot.address, spot["address"] as? String, "vendor address parity: \(id)")
            result.selectedDiningSpot = catalogSpot
        }
        if let items = proposal["mealItems"] as? [[String: Any]] {
            result.mealItems = items.map {
                MealItem(name: $0["name"] as! String, details: $0["details"] as? String)
            }
        }
        result.mealSwipes = proposal["mealSwipes"] as? Int
        result.estimatedDiningDollarsCents = proposal["estimatedDiningDollarsCents"] as? Int
        result.diningDollarsOrderTotalCents = proposal["diningDollarsOrderTotalCents"] as? Int
        return result
    }

    // MARK: - Swift-only authority rules (not in the backend vectors)

    /// OCR→local-text must not populate Dining Dollars: its proposal and the
    /// corroborating Vision evidence are the same text, so they are not
    /// independent — even when every backend condition for the estimate holds.
    func testOCRLocalTextModeNeverProposesDiningDollarsEvenWhenEvidenceWouldSupportIt() {
        let raw: [String: Any] = [
            "visibleVenueText": NSNull(),
            "foodItems": [["name": "Bowl", "quantity": NSNull(), "modifiers": [String]()]],
            "mealSwipes": 3,
        ]
        let evidence = "Your pickup order\n3M + $2.00"

        let withAuthority = RequesterOrderOutputValidator.validate(
            raw: raw, evidenceText: evidence, evidenceImageCount: 1, allowsDiningDollarsEstimate: true
        )
        guard case .valid(let allowed) = withAuthority else { return XCTFail("expected a valid proposal") }
        XCTAssertEqual(allowed.estimatedDiningDollarsCents, 200)

        let withoutAuthority = RequesterOrderOutputValidator.validate(
            raw: raw,
            evidenceText: evidence,
            evidenceImageCount: 1,
            allowsDiningDollarsEstimate: RequesterOrderPolicy.permitsDiningDollarsEstimate(for: .ocrFlattenedText)
        )
        guard case .valid(let restricted) = withoutAuthority else { return XCTFail("expected a valid proposal") }
        XCTAssertNil(restricted.estimatedDiningDollarsCents)
        // Only the money authority is withheld; swipes and items still propose.
        XCTAssertEqual(restricted.mealSwipes, 3)
        XCTAssertEqual(restricted.mealItems, [MealItem(name: "Bowl")])
    }

    /// The Dining Dollars authority rule is Requester policy, stated once per
    /// evidence strategy in `RequesterOrderPolicy` — the shared runtime only
    /// states the workflow-neutral independence fact it is derived from.
    func testDiningDollarsAuthorityRuleIsRequesterPolicyStatedOncePerStrategy() {
        XCTAssertFalse(RequesterOrderPolicy.permitsDiningDollarsEstimate(for: .ocrFlattenedText))
        XCTAssertFalse(RequesterOrderPolicy.permitsDiningDollarsEstimate(for: .ocrLayoutAware))
        // A direct-image mode may gain the authority only after its own
        // qualification and only with independent Vision corroboration; the
        // corroboration itself is still the deterministic OCR rule the
        // validator applies.
        XCTAssertTrue(RequesterOrderPolicy.permitsDiningDollarsEstimate(for: .directImageMultimodal))
        for mode in ScreenshotInputMode.allCases {
            XCTAssertEqual(
                RequesterOrderPolicy.permitsDiningDollarsEstimate(for: mode),
                !mode.consumesRuntimeOCREvidence,
                "Requester derives the rule from the neutral independence fact for \(mode)"
            )
        }
    }

    /// Strictness only ever differs from the backend in the fail-closed
    /// direction: an unsafe integer no provider emits is refused.
    func testUnsafeIntegersFailClosed() {
        let raw: [String: Any] = [
            "visibleVenueText": NSNull(),
            "foodItems": [["name": "Bowl", "quantity": 1e300, "modifiers": [String]()]],
            "mealSwipes": NSNull(),
        ]
        XCTAssertEqual(
            RequesterOrderOutputValidator.validate(
                raw: raw, evidenceText: "x", evidenceImageCount: 1, allowsDiningDollarsEstimate: false
            ),
            .invalid(.schemaInvalid)
        )
    }
}
