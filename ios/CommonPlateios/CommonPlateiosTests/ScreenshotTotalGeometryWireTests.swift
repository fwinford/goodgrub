import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class ScreenshotTotalGeometryWireTests: XCTestCase {
    override func tearDown() {
        ScreenshotProposalURLProtocol.reset()
        super.tearDown()
    }

    func testRequesterExternalProviderTransmitsOnlyDerivedGeometryEvidencePerImage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScreenshotProposalURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
        ScreenshotProposalURLProtocol.enqueue(.response(
            data: Data(#"{"eligible":true,"proposal":{}}"#.utf8)
        ))

        let evidence = ScreenshotTotalGeometryEvidence(
            observations: [
                .init(id: 2, classification: .totalLabel, cents: nil, geometryValid: true),
                .init(id: 4, classification: .amount, cents: 1_545, geometryValid: true),
            ],
            relations: [
                .init(
                    totalObservationID: 2,
                    amountObservationID: 4,
                    sameRow: true,
                    rightOf: true
                ),
            ]
        )
        let text = "Your Pickup Order\nContinue to Checkout\nTotal\nOrder actions\n$15.45"
        let image = ScreenshotPreparedImage(
            sourceData: Data([1]), data: Data([2]), mimeType: "image/jpeg"
        )
        let selection = try XCTUnwrap(ScreenshotSelection(images: [image]))
        let input = ScreenshotProviderInput<RequesterOrderWorkflow>(
            selection: selection,
            derived: RequesterOrderEvidence(
                textsByIndex: [0: text],
                totalGeometryByIndex: [0: evidence],
                combinedText: text
            )
        )

        _ = try await RequesterOpenAIExternalProvider(
            service: ScreenshotProposalService(availability: .enabledForTesting(), client: client)
        ).analyze(input, authority: "authority")

        let request = try XCTUnwrap(ScreenshotProposalURLProtocol.capturedRequests.last)
        let body = try XCTUnwrap(request.body)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let images = try XCTUnwrap(object["images"] as? [[String: Any]])
        let geometry = try XCTUnwrap(images.first?["localTotalGeometry"] as? [String: Any])
        XCTAssertEqual(images.first?["localEvidenceText"] as? String, text)
        XCTAssertEqual((geometry["observations"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((geometry["relations"] as? [[String: Any]])?.count, 1)

        let encoded = String(decoding: body, as: UTF8.self).lowercased()
        for forbidden in ["boundingbox", "minx", "miny", "maxx", "maxy", "width", "height"] {
            XCTAssertFalse(encoded.contains(forbidden), forbidden)
        }
    }
}
