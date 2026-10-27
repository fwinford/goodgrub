//
//  RequestFoodScreenshotAssistanceExclusionHostedTests.swift
//  CommonPlateiosTests
//
// W5-IOS1: renders the real production `RequestFoodView` and proves the V1.0
// exclusion removes every Screenshot Assistance entry point without a disabled
// or "Coming Soon" placeholder, while ordinary manual Request Food still
// renders. The enabled host is the positive control. Simulator rendering only;
// not physical-device or VoiceOver proof.
import XCTest
@testable import CommonPlateios

@MainActor
final class RequestFoodScreenshotAssistanceExclusionHostedTests: XCTestCase {
    private let assistanceIdentifiers = [
        "request-screenshot-turn-on",
        "request-screenshot-picker",
        "request-screenshot-change",
        "request-screenshot-checked-row",
        "request-screenshot-notice",
        "request-screenshot-help-modal",
        "request-screenshot-assistance-disclosure-modal",
    ]
    private let assistanceLabels = [
        "label:Screenshot Assistance",
        "label:Turn on Screenshot Assistance",
        "label:Coming Soon",
    ]

    func testExcludedRequestFoodShowsNoAssistanceEntryAndKeepsTheManualForm() throws {
        let host = try RequesterFormHost(screenshotAvailability: .shipping)
        let nodes = host.nodes()

        XCTAssertNotNil(nodes["request-menu-path-picker"], "the manual form must still render")
        for identifier in assistanceIdentifiers {
            XCTAssertNil(nodes[identifier], identifier)
        }
        for label in assistanceLabels {
            XCTAssertNil(nodes[label], label)
        }
        XCTAssertFalse(
            nodes.keys.contains { $0.localizedCaseInsensitiveContains("screenshot") },
            "no screenshot-related element may remain: \(nodes.keys.filter { $0.localizedCaseInsensitiveContains("screenshot") })"
        )
    }

    func testEnabledPositiveControlStillShowsTheAssistanceEntry() throws {
        let host = try RequesterFormHost(screenshotAvailability: .enabledForTesting())
        XCTAssertTrue(
            host.exists("request-screenshot-picker") || host.exists("request-screenshot-turn-on"),
            "the preserved implementation must remain reachable when the gate is injected enabled"
        )
    }
}
