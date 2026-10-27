import XCTest
@testable import CommonPlateios

/// V1.0 excludes requester Screenshot Assistance through the injected
/// `RequesterScreenshotAssistanceAvailability` (W5-IOS1). These checks add the
/// W4-N1 flow-start guards and confirm the helper's required
/// order-confirmation screenshot is a different feature that stays.
@MainActor
final class ScreenshotAssistanceV1AvailabilityTests: XCTestCase {
    /// Every flow start is gated, so even a stale `On` preference or an
    /// internal caller cannot open the picker or the disclosure.
    func testEveryEntryAndFlowStartIsGated() throws {
        let gate = "screenshotProposalStore.isAssistanceAvailable"
        let request = try appSource("Views/RequestFoodView.swift")
        XCTAssertTrue(request.contains("if \(gate) {\n                                screenshotAssistanceRow"))
        for function in ["private func beginScreenshotAssistanceFlow() {", "private func beginTurnOnScreenshotAssistanceFlow() {"] {
            let body = try XCTUnwrap(request.range(of: function)).upperBound
            XCTAssertTrue(request[body...].prefix(120).contains(gate), function)
        }
        XCTAssertTrue(request.contains("canTryOtherScreenshots: \(gate)"))

        let edit = try appSource("Views/EditRequestView.swift")
        XCTAssertTrue(edit.contains("if \(gate) {\n                        EditScreenshotAssistanceRow("))
        let editFlow = try XCTUnwrap(edit.range(of: "private func beginScreenshotAssistanceFlow() {")).upperBound
        XCTAssertTrue(edit[editFlow...].prefix(120).contains(gate))
        XCTAssertTrue(edit.contains("canTryOtherScreenshots: \(gate)"))
    }

    func testNavigationOffersNoScreenshotAssistanceRoute() throws {
        let routes = try appSource("Navigation/AppRoute.swift")
        XCTAssertFalse(routes.localizedCaseInsensitiveContains("screenshot"))
    }

    /// The H1a evidence screenshot is not Screenshot Assistance: it stays
    /// required and visible on the Helping screen.
    func testHelperOrderConfirmationScreenshotIsUntouched() throws {
        let helping = try appSource("Views/FulfillRequestView.swift")
        XCTAssertFalse(helping.contains("isAssistanceAvailable"))
        for marker in [
            "fulfillment-screenshot-choose",
            "fulfillment-screenshot-attached",
            "fulfillment-screenshot-change",
            "fulfillment-screenshot-info",
            "Text(Self.requiredLabel)",
        ] {
            XCTAssertTrue(helping.contains(marker), marker)
        }
        XCTAssertEqual(FulfillRequestView.requiredLabel, "Required")
    }

    private func appSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
