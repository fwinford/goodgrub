import XCTest
@testable import CommonPlateios

/// Faith (W4-N1): tapping `Request Alerts` on empty Home hid the promotion with
/// no feedback. A Home tap that reaches On now confirms in its place.
@MainActor
final class HomeRequestAlertsConfirmationTests: XCTestCase {
    func testOnlyAHomeTapThatReachesOnConfirms() {
        XCTAssertEqual(HomeExchangeView.homeRequestAlertsResult(awaiting: true, state: .on), .confirmOn)
        XCTAssertEqual(HomeExchangeView.homeRequestAlertsResult(awaiting: true, state: .settingUp), .keepWaiting)
        for state in [PushPreferenceState.off, .denied, .failed, .ambiguous(desiredEnabled: true)] {
            XCTAssertEqual(HomeExchangeView.homeRequestAlertsResult(awaiting: true, state: state), .stopAwaiting, "\(state)")
        }
    }

    /// Launch reconciliation (`settingUp` → `on` without a tap) never claims
    /// the student just turned alerts on.
    func testReconciliationWithoutATapNeverConfirms() {
        for state in [PushPreferenceState.on, .settingUp, .off, .denied, .failed] {
            XCTAssertEqual(HomeExchangeView.homeRequestAlertsResult(awaiting: false, state: state), .keepWaiting)
        }
    }

    func testConfirmationCopy() {
        XCTAssertEqual(HomeExchangeView.requestAlertsOnTitle, "Request Alerts are on")
        XCTAssertEqual(HomeExchangeView.requestAlertsConfirmationDuration, .seconds(4))
    }

    func testConfirmationExpiresAndDoesNotReturnAfterLeavingHome() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios/Views/HomeExchangeView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(source.contains("We’ll notify you when someone needs help."))
        XCTAssertTrue(source.contains("Task.sleep(for: Self.requestAlertsConfirmationDuration)"))
        XCTAssertTrue(source.contains("guard !Task.isCancelled else { return }"))
        XCTAssertTrue(source.contains(".onDisappear { showsRequestAlertsOnConfirmation = false }"))
    }

    func testOnlyTheHomePromotionButtonSignalsTheTap() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios/Views/PushNotificationSection.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "onHomeEnableRequested?()").count - 1, 1)
        let tap = try XCTUnwrap(source.range(of: "onHomeEnableRequested?()"))
        let promotion = try XCTUnwrap(source.range(of: "private var homePromotion: some View {"))
        let end = try XCTUnwrap(source.range(of: "private var failureAlertMessage"))
        XCTAssertTrue(promotion.upperBound < tap.lowerBound && tap.upperBound < end.lowerBound)
    }
}
