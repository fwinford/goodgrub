import XCTest
@testable import CommonPlateios

final class ProductionAPIConfigurationTests: XCTestCase {
    func testExplicitHTTPSOriginIsAccepted() throws {
        let configuration = try APIConfiguration.resolvedForReleaseLaunch(
            info: [APIConfiguration.productionBaseURLInfoKey: "https://api.example.org"]
        )
        XCTAssertEqual(configuration.baseURL.absoluteString, "https://api.example.org")
    }

    func testMissingOrNonStringConfigurationIsUnavailable() {
        for info: [String: Any] in [[:], [APIConfiguration.productionBaseURLInfoKey: 42]] {
            XCTAssertThrowsError(try APIConfiguration.resolvedForReleaseLaunch(info: info)) {
                XCTAssertEqual($0 as? ProductionAPIConfigurationError, .unavailable)
            }
        }
    }

    func testInvalidOrLocalOriginsAreUnavailableWithoutFallback() {
        for raw in [
            "", "$(COMMONPLATE_PRODUCTION_API_BASE_URL)", " https://api.example.org",
            "https://api.example.org\n", "http://api.example.org", "https://localhost",
            "https://127.0.0.1", "https://10.0.0.1", "https://192.168.1.1",
            "https://172.16.0.1", "https://[::1]", "https://[fc00::1]",
            "https://2130706433", "https://0177.0.0.1", "https://127.1",
            "https://backend.local", "https://backend.internal", "https://backend.test",
            "https://api.example.org/", "https://api.example.org/api",
            "https://api.example.org?x=1", "https://api.example.org#fragment",
            "https://user:secret@api.example.org", "https://api.example.org:443",
            "https://api.example.org:", "https:////api.example.org",
            "https://-bad.example.org", "https://api..example.org",
            "https://api.example.org.", "https://api%2eexample.org"
        ] {
            XCTAssertThrowsError(try APIConfiguration.resolvedForReleaseLaunch(
                info: [APIConfiguration.productionBaseURLInfoKey: raw]
            ), raw) {
                XCTAssertEqual($0 as? ProductionAPIConfigurationError, .unavailable)
            }
        }
    }

    func testUnavailableMessageContainsNoConfigurationValue() {
        XCTAssertEqual(
            ProductionAPIConfigurationError.unavailable.message,
            "Configuration unavailable. Please try again after updating the app."
        )
    }

    func testShippingAssistanceIsExcludedIndependentOfBuildConfiguration() {
        XCTAssertFalse(RequesterScreenshotAssistanceAvailability.shipping.isAvailable)
        XCTAssertTrue(RequesterScreenshotAssistanceAvailability.enabledForTesting().isAvailable)
    }
}
