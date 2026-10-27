import Foundation
import XCTest
@testable import CommonPlateios

#if DEBUG
/// W4-QA1: the Debug-only local backend override. It must select only approved
/// local development targets, leave the existing default untouched when absent,
/// and refuse (never replace) anything it cannot accept.
final class APIConfigurationDebugOverrideTests: XCTestCase {
    private let key = APIConfiguration.debugOverrideEnvironmentKey

    private func resolve(_ value: String?) throws -> APIConfiguration {
        try APIConfiguration.resolvedForDebugLaunch(
            environment: value.map { [key: $0] } ?? [:]
        )
    }

    // MARK: - Default is unchanged

    func testAbsentOverrideKeepsTheExistingLocalDefault() throws {
        XCTAssertEqual(try resolve(nil).baseURL, APIConfiguration.localSimulator.baseURL)
        XCTAssertEqual(APIConfiguration.localSimulator.baseURL.absoluteString, "http://127.0.0.1:3000")
    }

    func testUnrelatedEnvironmentVariablesDoNotSelectABackend() throws {
        let configuration = try APIConfiguration.resolvedForDebugLaunch(
            environment: ["API_BASE_URL": "http://10.0.0.5:9", "BASE_URL": "http://127.0.0.1:1"]
        )
        XCTAssertEqual(configuration.baseURL, APIConfiguration.localSimulator.baseURL)
    }

    // MARK: - Approved explicit targets

    func testApprovedLocalTargetsAreHonoredWithoutSourceEdits() throws {
        let cases: [(String, String)] = [
            ("http://127.0.0.1:3001", "http://127.0.0.1:3001"),
            ("http://localhost:3001", "http://localhost:3001"),
            ("http://[::1]:3001", "http://[::1]:3001"),
            ("http://127.0.0.1", "http://127.0.0.1"),
            ("HTTP://LOCALHOST:3001/", "http://localhost:3001"),
            ("http://192.168.1.20:3000", "http://192.168.1.20:3000"),
            ("http://10.0.0.5:3000", "http://10.0.0.5:3000"),
            ("http://172.16.4.2:3000", "http://172.16.4.2:3000"),
            ("http://172.31.255.254:3000", "http://172.31.255.254:3000"),
            ("http://faiths-mac.local:3001", "http://faiths-mac.local:3001"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(try resolve(input).baseURL.absoluteString, expected, input)
        }
    }

    func testAnApprovedOverrideReplacesTheDefaultPort() throws {
        XCTAssertNotEqual(try resolve("http://127.0.0.1:3001").baseURL, APIConfiguration.localSimulator.baseURL)
    }

    // MARK: - Refusals never fall back

    func testPublicOrRoutableTargetsAreRefused() {
        for value in [
            "http://api.commonplate.example",
            "http://example.com:3000",
            "http://8.8.8.8:3000",
            "http://172.15.0.1:3000",
            "http://172.32.0.1:3000",
            "http://192.169.0.1:3000",
            "http://11.0.0.1:3000",
            "http://169.254.1.1:3000",
            "http://0.0.0.0:3000",
            "http://[2001:db8::1]:3000",
            "http://localhost.evil.com",
            "http://127.0.0.1.evil.com",
            "http://evil.local.example.com",
            "http://.local",
        ] {
            XCTAssertThrowsError(try resolve(value), value) { error in
                XCTAssertEqual(error as? APIConfigurationOverrideError, .nonLocalHost, value)
            }
        }
    }

    func testAmbiguousIPv4SpellingsAreRefusedRatherThanInterpreted() {
        for value in ["http://127.1:3000", "http://0177.0.0.1:3000", "http://2130706433:3000", "http://10.0.0:3000", "http://010.0.0.1"] {
            XCTAssertThrowsError(try resolve(value), value)
        }
    }

    func testMalformedUnsupportedOrDecoratedValuesAreRefused() {
        let cases: [(String, APIConfigurationOverrideError)] = [
            ("", .empty),
            ("not a url", .malformed),
            (" http://127.0.0.1:3001", .malformed),
            ("http://127.0.0.1:3001 ", .malformed),
            ("127.0.0.1:3001", .malformed),
            ("https://127.0.0.1:3001", .unsupportedScheme),
            ("ftp://127.0.0.1:3001", .unsupportedScheme),
            ("http://user:secret@127.0.0.1:3001", .credentialsNotAllowed),
            ("http://127.0.0.1:3001/api", .unexpectedComponents),
            ("http://127.0.0.1:3001?x=1", .unexpectedComponents),
            ("http://127.0.0.1:3001#frag", .unexpectedComponents),
        ]
        for (value, expected) in cases {
            XCTAssertThrowsError(try resolve(value), value) { error in
                XCTAssertEqual(error as? APIConfigurationOverrideError, expected, value)
            }
        }
    }

    func testAnOutOfRangePortIsRefused() {
        for value in ["http://127.0.0.1:0", "http://127.0.0.1:70000"] {
            XCTAssertThrowsError(try resolve(value), value)
        }
    }

    func testRefusalTextNeverEchoesTheSuppliedValue() {
        XCTAssertThrowsError(try resolve("http://user:hunter2@127.0.0.1:3001")) { error in
            XCTAssertFalse("\(error)".contains("hunter2"))
            XCTAssertFalse("\(error)".contains("127.0.0.1"))
        }
    }

    // MARK: - Existing seams are untouched

    func testExplicitBaseURLInitializerStillWorksForTests() {
        let url = URL(string: "https://commonplate.test")!
        XCTAssertEqual(APIConfiguration(baseURL: url).baseURL, url)
    }

    func testTheLaunchEntryPointKeepsTheDefaultWhenNothingIsSet() {
        // The process environment of an ordinary test run carries no override.
        XCTAssertNil(ProcessInfo.processInfo.environment[key])
        XCTAssertEqual(APIConfiguration.forLaunch().baseURL, APIConfiguration.localSimulator.baseURL)
    }
}
#endif
