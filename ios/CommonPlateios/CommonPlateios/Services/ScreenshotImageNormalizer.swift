//
//  ScreenshotImageNormalizer.swift
//  CommonPlateios
//
// W4-S1 local normalization, performed before any screenshot byte leaves
// the device: bounded longest-edge resize plus JPEG compression, matched to
// the backend's own explicit bounded transport limit
// (`MAX_IMAGE_BYTES`/`SCREENSHOT_BODY_LIMIT`, `screenshotProposalRoute.ts`).
// This is size/format normalization only — it asserts nothing about
// eligibility or authenticity.
import UIKit

enum ScreenshotImageNormalizer {
    /// Engineering-owned bounded values. A Grubhub screenshot's readable
    /// content (headings, item lines, prices) survives this resize/quality
    /// comfortably; this is not tuned per fixture.
    static let maxDimension: CGFloat = 1600
    static let jpegCompressionQuality: CGFloat = 0.6

    static func normalize(_ image: UIImage) -> (data: Data, mimeType: String)? {
        let resized = resized(image, maxDimension: maxDimension)
        guard let data = resized.jpegData(compressionQuality: jpegCompressionQuality) else {
            return nil
        }
        return (data, "image/jpeg")
    }

    private static func resized(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longestEdge = max(image.size.width, image.size.height)
        guard longestEdge > maxDimension, longestEdge > 0 else { return image }
        let scale = maxDimension / longestEdge
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
