//
//  PlacedOrderScreenshot.swift
//  CommonPlateios
//
// W4-H1a: the helper's required placed-order screenshot, prepared on device.
//
// This is transient, in-memory evidence only. It is created from the helper's
// chosen image, held by the Helping page's draft until Finish helping, captured
// ONCE into the store's exact fulfillment submission snapshot, and sent in that
// one POST. Nothing here — and nothing that holds it — persists the bytes to
// UserDefaults, a file, a cache, or a database, and none of it is logged: the
// description below is deliberately redacted so a stray print, string
// interpolation, or failing assertion cannot dump image bytes.
//
// It is not a general-purpose attachment type, it carries no recognition or
// analysis result, and it asserts nothing about authenticity. Screenshot
// Assistance (a later slice) is a separate consumer of the helper's selection;
// selecting this evidence never starts any analysis.
import Foundation
import ImageIO
import UIKit

struct PlacedOrderScreenshot: Equatable {
    /// Wire formats the backend accepts. This client only ever produces JPEG;
    /// PNG is permitted by the contract but is never what normalization emits.
    static let supportedMIMETypes = ["image/jpeg", "image/png"]

    /// Decoded-byte cap, matching the backend route validator and the stored
    /// `byteLength` schema validator exactly. Never widened to make a fixture
    /// fit.
    static let maximumByteCount = 1_500_000

    let mimeType: String
    let imageData: Data

    /// `nil` unless the value could be sent as-is: a supported type and a
    /// non-empty image within the cap.
    init?(mimeType: String, imageData: Data) {
        guard Self.supportedMIMETypes.contains(mimeType),
              !imageData.isEmpty,
              imageData.count <= Self.maximumByteCount else {
            return nil
        }
        self.mimeType = mimeType
        self.imageData = imageData
    }

    /// Standard base64 with no line breaks — the form the backend's strict
    /// decoder accepts.
    var imageBase64: String {
        imageData.base64EncodedString()
    }
}

extension PlacedOrderScreenshot: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "PlacedOrderScreenshot(\(mimeType), \(imageData.count) bytes)" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["mimeType": mimeType, "byteCount": imageData.count])
    }
}

/// Local normalization of the helper's chosen image. Runs entirely on device
/// before any byte leaves it, and fails closed: an image that cannot be decoded,
/// or cannot be encoded within the cap, yields `nil` and nothing is sent.
enum PlacedOrderScreenshotNormalizer {
    /// Longest edge, in pixels. Never upscaled.
    static let maximumLongestEdge = 2000
    /// JPEG quality for the first attempt, then exactly one fallback.
    static let primaryQuality: CGFloat = 0.7
    static let fallbackQuality: CGFloat = 0.5

    /// - Parameters:
    ///   - sourceData: the picker's bytes in whatever format it produced
    ///     (HEIC, JPEG, PNG, ...). Decoding is ImageIO's, so any format the
    ///     system can read is normalized to JPEG.
    ///   - maximumByteCount: the size cap. A parameter only so the refusal
    ///     path can be proved with a small fixture; production always uses
    ///     `PlacedOrderScreenshot.maximumByteCount`.
    static func normalize(
        _ sourceData: Data,
        maximumByteCount: Int = PlacedOrderScreenshot.maximumByteCount
    ) -> PlacedOrderScreenshot? {
        guard !sourceData.isEmpty,
              let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            return nil
        }

        // Bounded by the smaller of the image's own longest edge and the cap,
        // so a small image is never upscaled.
        let targetEdge = min(max(width, height), maximumLongestEdge)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: targetEdge
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              decoded.width > 0, decoded.height > 0 else {
            return nil
        }

        // Flattened onto an opaque 1x canvas so transparency and exotic color
        // models cannot make the JPEG encoder fail or vary.
        let size = CGSize(width: decoded.width, height: decoded.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let flattened = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: decoded).draw(in: CGRect(origin: .zero, size: size))
        }

        for quality in [primaryQuality, fallbackQuality] {
            guard let data = flattened.jpegData(compressionQuality: quality), !data.isEmpty else {
                continue
            }
            if data.count <= maximumByteCount {
                return PlacedOrderScreenshot(mimeType: "image/jpeg", imageData: data)
            }
        }
        return nil
    }
}
