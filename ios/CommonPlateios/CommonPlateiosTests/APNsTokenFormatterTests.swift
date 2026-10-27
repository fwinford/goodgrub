//
//  APNsTokenFormatterTests.swift
//  CommonPlateiosTests
//
// Focused coverage for Week 3 Day 6 Slice 6A.2 device-token normalization.
import XCTest
@testable import CommonPlateios

final class APNsTokenFormatterTests: XCTestCase {
    func testNormalizesToLowercaseHexOneTwoCharacterPairPerByte() throws {
        let token = try APNsTokenFormatter.normalize(Data([0xDE, 0xAD, 0xBE, 0xEF]))
        XCTAssertEqual(token, "deadbeef")
    }

    func testPreservesLeadingZeroBytes() throws {
        let token = try APNsTokenFormatter.normalize(Data([0x00, 0x0A, 0xFF]))
        XCTAssertEqual(token, "000aff")
    }

    func testSupportsAOneByteToken() throws {
        XCTAssertEqual(try APNsTokenFormatter.normalize(Data([0x07])), "07")
    }

    func testSupportsTheCurrentThirtyTwoByteAppleTokenLength() throws {
        let bytes = (0..<32).map { UInt8($0) }
        let token = try APNsTokenFormatter.normalize(Data(bytes))
        XCTAssertEqual(token.count, 64)
        XCTAssertEqual(token, bytes.map { String(format: "%02x", $0) }.joined())
    }

    func testSupportsALongerTokenWithoutAssumingAppsCurrentSize() throws {
        let bytes = [UInt8](repeating: 0xAB, count: 64)
        let token = try APNsTokenFormatter.normalize(Data(bytes))
        XCTAssertEqual(token.count, 128)
    }

    func testRejectsAnEmptyToken() {
        XCTAssertThrowsError(try APNsTokenFormatter.normalize(Data())) { error in
            XCTAssertEqual(error as? APNsTokenFormatterError, .emptyToken)
        }
    }

    func testNeverEmitsSeparatorsOrDataDescriptionText() throws {
        let token = try APNsTokenFormatter.normalize(Data([0x1A, 0x2B, 0x3C]))
        XCTAssertFalse(token.contains(" "))
        XCTAssertFalse(token.contains("<"))
        XCTAssertFalse(token.contains(">"))
        XCTAssertTrue(token.allSatisfy { "0123456789abcdef".contains($0) })
    }
}
