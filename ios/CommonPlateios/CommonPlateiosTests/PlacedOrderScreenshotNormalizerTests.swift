//
//  PlacedOrderScreenshotNormalizerTests.swift
//  CommonPlateiosTests
//
// W4-H1a: local normalization of the helper's required placed-order screenshot.
// Every case runs the real ImageIO / UIKit encode path on generated images, so
// these are executed proofs of the contract bounds, not source inspection:
// longest edge <= 2000 px and never upscaled; JPEG at 0.7 with exactly one
// fallback at 0.5; the 1,500,000-byte cap enforced with a definitive refusal
// (never a silent truncation); HEIC and other source formats normalized to
// JPEG; a source that cannot be decoded refused.
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import CommonPlateios

final class PlacedOrderScreenshotNormalizerTests: XCTestCase {

    // MARK: - Constants are the contract values

    func testContractConstants() {
        XCTAssertEqual(PlacedOrderScreenshot.maximumByteCount, 1_500_000)
        XCTAssertEqual(PlacedOrderScreenshotNormalizer.maximumLongestEdge, 2000)
        XCTAssertEqual(PlacedOrderScreenshotNormalizer.primaryQuality, 0.7)
        XCTAssertEqual(PlacedOrderScreenshotNormalizer.fallbackQuality, 0.5)
        XCTAssertEqual(PlacedOrderScreenshot.supportedMIMETypes, ["image/jpeg", "image/png"])
    }

    // MARK: - Resize bound

    func testALargeImageIsScaledDownToTheLongestEdgeBoundKeepingAspectRatio() throws {
        let source = try pngData(width: 3000, height: 1500)

        let result = try XCTUnwrap(PlacedOrderScreenshotNormalizer.normalize(source))

        XCTAssertEqual(result.mimeType, "image/jpeg")
        let size = try pixelSize(of: result.imageData)
        XCTAssertEqual(max(size.width, size.height), 2000)
        XCTAssertEqual(size.width, 2000)
        XCTAssertEqual(size.height, 1000)
        XCTAssertLessThanOrEqual(result.imageData.count, PlacedOrderScreenshot.maximumByteCount)
    }

    func testATallImageIsBoundedOnItsHeight() throws {
        let result = try XCTUnwrap(PlacedOrderScreenshotNormalizer.normalize(
            try pngData(width: 1200, height: 3200)
        ))
        let size = try pixelSize(of: result.imageData)
        XCTAssertEqual(size.height, 2000)
        XCTAssertEqual(size.width, 750)
    }

    func testASmallImageIsNeverUpscaled() throws {
        let result = try XCTUnwrap(PlacedOrderScreenshotNormalizer.normalize(
            try pngData(width: 400, height: 300)
        ))
        let size = try pixelSize(of: result.imageData)
        XCTAssertEqual(size.width, 400)
        XCTAssertEqual(size.height, 300)
    }

    func testAnImageExactlyAtTheEdgeBoundIsKeptAsIs() throws {
        let result = try XCTUnwrap(PlacedOrderScreenshotNormalizer.normalize(
            try pngData(width: 2000, height: 900)
        ))
        let size = try pixelSize(of: result.imageData)
        XCTAssertEqual(size.width, 2000)
        XCTAssertEqual(size.height, 900)
    }

    func testEXIFOrientationIsAppliedSoTheStoredImageIsUpright() throws {
        // 600x200 pixels tagged "rotated 90°": displayed upright it is 200x600.
        let source = try jpegData(width: 600, height: 200, orientation: 6)

        let result = try XCTUnwrap(PlacedOrderScreenshotNormalizer.normalize(source))

        let size = try pixelSize(of: result.imageData)
        XCTAssertEqual(size.width, 200)
        XCTAssertEqual(size.height, 600)
    }

    // MARK: - Source formats

    func testAPNGSourceBecomesJPEG() throws {
        let result = try XCTUnwrap(PlacedOrderScreenshotNormalizer.normalize(
            try pngData(width: 640, height: 480)
        ))
        XCTAssertEqual(result.mimeType, "image/jpeg")
        XCTAssertEqual(Array(result.imageData.prefix(2)), [0xFF, 0xD8])
        XCTAssertEqual(Array(result.imageData.suffix(2)), [0xFF, 0xD9])
    }

    func testAnImageWithTransparencyIsFlattenedToAValidJPEG() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let transparent = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300), format: format)
            .pngData { context in
                UIColor.red.withAlphaComponent(0.3).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 150, height: 300))
            }

        let result = try XCTUnwrap(PlacedOrderScreenshotNormalizer.normalize(transparent))

        XCTAssertEqual(result.mimeType, "image/jpeg")
        XCTAssertEqual(try pixelSize(of: result.imageData).width, 300)
    }

    func testAHEICSourceIsDecodedAndNormalizedToJPEG() throws {
        let source = try heicData(width: 1500, height: 1000)

        let result = try XCTUnwrap(PlacedOrderScreenshotNormalizer.normalize(source))

        XCTAssertEqual(result.mimeType, "image/jpeg")
        XCTAssertEqual(Array(result.imageData.prefix(2)), [0xFF, 0xD8])
        let size = try pixelSize(of: result.imageData)
        XCTAssertEqual(size.width, 1500)
        XCTAssertEqual(size.height, 1000)
    }

    // MARK: - Fail closed

    func testBytesThatAreNotAnImageAreRefused() {
        XCTAssertNil(PlacedOrderScreenshotNormalizer.normalize(Data()))
        XCTAssertNil(PlacedOrderScreenshotNormalizer.normalize(Data("not an image".utf8)))
        XCTAssertNil(PlacedOrderScreenshotNormalizer.normalize(Data((0..<4096).map { UInt8($0 % 251) })))
    }

    func testATruncatedFileIsNeverSentAsTheEvidence() throws {
        // Whatever a partial file decodes to, a result must be a COMPLETE,
        // within-cap JPEG or nothing at all — never the raw truncated bytes.
        let whole = try pngData(width: 800, height: 800)
        let truncated = whole.prefix(whole.count / 3)
        if let result = PlacedOrderScreenshotNormalizer.normalize(Data(truncated)) {
            XCTAssertEqual(Array(result.imageData.suffix(2)), [0xFF, 0xD9])
            XCTAssertLessThanOrEqual(result.imageData.count, PlacedOrderScreenshot.maximumByteCount)
            XCTAssertNotEqual(result.imageData, Data(truncated))
        }
    }

    // MARK: - Quality ladder and size cap

    func testOneFallbackQualityThenRefusalAtTheCap() throws {
        // High-entropy pixels so JPEG size is strongly quality-dependent.
        let source = try noisyPNGData(side: 700)
        let atPrimary = try XCTUnwrap(PlacedOrderScreenshotNormalizer.normalize(
            source, maximumByteCount: Int.max
        ))

        // A cap one byte under the 0.7 result forces exactly the 0.5 fallback.
        let fallback = try XCTUnwrap(PlacedOrderScreenshotNormalizer.normalize(
            source, maximumByteCount: atPrimary.imageData.count - 1
        ))
        XCTAssertLessThan(fallback.imageData.count, atPrimary.imageData.count)
        XCTAssertLessThanOrEqual(fallback.imageData.count, atPrimary.imageData.count - 1)
        XCTAssertNotEqual(fallback.imageData, atPrimary.imageData)

        // A cap exactly at the 0.7 result keeps the primary encode.
        let atCap = try XCTUnwrap(PlacedOrderScreenshotNormalizer.normalize(
            source, maximumByteCount: atPrimary.imageData.count
        ))
        XCTAssertEqual(atCap.imageData, atPrimary.imageData)

        // A cap even the fallback cannot meet is a definitive refusal — the
        // image is never silently truncated or re-encoded a third time.
        XCTAssertNil(PlacedOrderScreenshotNormalizer.normalize(
            source, maximumByteCount: fallback.imageData.count - 1
        ))
    }

    func testTheProductionCapIsTheContractCap() throws {
        let result = try XCTUnwrap(PlacedOrderScreenshotNormalizer.normalize(
            try pngData(width: 2600, height: 1800)
        ))
        XCTAssertLessThanOrEqual(result.imageData.count, 1_500_000)
        let size = try pixelSize(of: result.imageData)
        XCTAssertLessThanOrEqual(max(size.width, size.height), 2000)
    }

    // MARK: - The wire value

    func testPlacedOrderScreenshotEnforcesTheWireBounds() {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
        XCTAssertNotNil(PlacedOrderScreenshot(mimeType: "image/jpeg", imageData: bytes))
        XCTAssertNotNil(PlacedOrderScreenshot(mimeType: "image/png", imageData: bytes))
        XCTAssertNil(PlacedOrderScreenshot(mimeType: "image/heic", imageData: bytes))
        XCTAssertNil(PlacedOrderScreenshot(mimeType: "image/gif", imageData: bytes))
        XCTAssertNil(PlacedOrderScreenshot(mimeType: "IMAGE/JPEG", imageData: bytes))
        XCTAssertNil(PlacedOrderScreenshot(mimeType: "image/jpeg", imageData: Data()))
        XCTAssertNotNil(PlacedOrderScreenshot(
            mimeType: "image/jpeg", imageData: Data(count: 1_500_000)
        ))
        XCTAssertNil(PlacedOrderScreenshot(
            mimeType: "image/jpeg", imageData: Data(count: 1_500_001)
        ))
    }

    func testTheWirePayloadIsTheMIMETypeAndStandardBase64OfTheExactBytes() throws {
        let screenshot = PlacedOrderScreenshot.fixture(seed: 42)

        let payload = PlacedOrderScreenshotPayload(screenshot)

        XCTAssertEqual(payload.mimeType, "image/jpeg")
        XCTAssertEqual(Data(base64Encoded: payload.imageBase64), screenshot.imageData)
        XCTAssertFalse(payload.imageBase64.contains("\n"))
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(payload)
        ) as? [String: Any]
        XCTAssertEqual(Set(try XCTUnwrap(json).keys), ["mimeType", "imageBase64"])
    }

    func testTheScreenshotNeverDescribesItsBytes() {
        let screenshot = PlacedOrderScreenshot.fixture(seed: 7)
        let base64 = screenshot.imageBase64
        XCTAssertTrue(String(describing: screenshot).contains("bytes"))
        for text in [
            "\(screenshot)", String(describing: screenshot), String(reflecting: screenshot),
            "\(Mirror(reflecting: screenshot).children.map { "\($0.value)" })"
        ] {
            XCTAssertFalse(text.contains(base64))
        }
        var dumped = ""
        dump(screenshot, to: &dumped)
        XCTAssertFalse(dumped.contains(base64))
    }

    // MARK: - Image builders

    private func pixelSize(of data: Data) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        return (
            try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int),
            try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        )
    }

    private func canvas(width: Int, height: Int, noisy: Bool = false) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
            .image { context in
                UIColor(red: 0.95, green: 0.55, blue: 0.1, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                UIColor.white.setFill()
                context.fill(CGRect(x: width / 8, y: height / 8, width: width / 2, height: height / 4))
                if noisy {
                    var generator = SeededGenerator(seed: 0x5EED)
                    for _ in 0..<(width * height / 24) {
                        UIColor(
                            red: .random(in: 0...1, using: &generator),
                            green: .random(in: 0...1, using: &generator),
                            blue: .random(in: 0...1, using: &generator),
                            alpha: 1
                        ).setFill()
                        context.fill(CGRect(
                            x: Int.random(in: 0..<width, using: &generator),
                            y: Int.random(in: 0..<height, using: &generator),
                            width: 3,
                            height: 3
                        ))
                    }
                }
            }
    }

    private func pngData(width: Int, height: Int) throws -> Data {
        try XCTUnwrap(canvas(width: width, height: height).pngData())
    }

    private func noisyPNGData(side: Int) throws -> Data {
        try XCTUnwrap(canvas(width: side, height: side, noisy: true).pngData())
    }

    private func jpegData(width: Int, height: Int, orientation: Int) throws -> Data {
        let image = try XCTUnwrap(canvas(width: width, height: height).cgImage)
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: orientation
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func heicData(width: Int, height: Int) throws -> Data {
        let image = try XCTUnwrap(canvas(width: width, height: height).cgImage)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.heic.identifier as CFString, 1, nil
        ) else {
            throw XCTSkip("This runtime cannot encode HEIC, so the HEIC source case cannot be generated.")
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.8
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("This runtime cannot encode HEIC, so the HEIC source case cannot be generated.")
        }
        return data as Data
    }
}

/// Deterministic pseudo-randomness, so the noisy fixture (and therefore the
/// quality-ladder sizes) are identical on every run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
