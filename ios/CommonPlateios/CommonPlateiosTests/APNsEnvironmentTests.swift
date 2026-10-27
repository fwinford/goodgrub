//
//  APNsEnvironmentTests.swift
//  CommonPlateiosTests
//
// Focused coverage for Week 3 Day 6 Slice 6A.2 build-configuration → APNs
// environment derivation.
import XCTest
@testable import CommonPlateios

final class APNsEnvironmentTests: XCTestCase {
    /// `CommonPlateiosTests` always builds under the Debug configuration, so
    /// this pins the Debug → `.development` half of the mapping directly
    /// against the real `#if DEBUG` branch — not a double standing in for
    /// it.
    ///
    /// The Release → `.production` half cannot be exercised by an automated
    /// test the same way, because a test target never runs under Release.
    /// It is guaranteed instead by `project.pbxproj`:
    /// `SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)"` is set
    /// only on the Debug `XCBuildConfiguration` (`DCF2C90E...`), not on
    /// Release (`DCF2C90F...`). Confirm that setting by inspection if this
    /// mapping is ever suspected of drifting, not by trying to force a
    /// Release-configuration unit test run.
    func testDebugConfigurationSynchronizesAsDevelopment() {
        XCTAssertEqual(APNsEnvironment.current, .development)
    }

    func testRawValuesMatchTheBackendsAcceptedEnvironmentStrings() {
        XCTAssertEqual(APNsEnvironment.development.rawValue, "development")
        XCTAssertEqual(APNsEnvironment.production.rawValue, "production")
    }
}
