//
//  PlacedOrderScreenshotFixtures.swift
//  CommonPlateiosTests
//
// W4-H1a test support: a fixed, valid screenshot fixture, and the clearly named
// test-only `fulfillWithFixtureScreenshot` helper below.
import UIKit
@testable import CommonPlateios

extension PlacedOrderScreenshot {
    /// A tiny but real JPEG, so byte-for-byte comparisons are meaningful.
    /// `seed` makes distinguishable images for "this exact image, not another".
    static func fixture(seed: UInt8 = 1) -> PlacedOrderScreenshot {
        let side: CGFloat = 8
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let data = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
            .jpegData(withCompressionQuality: 0.9) { context in
                UIColor(
                    red: CGFloat(seed) / 255,
                    green: CGFloat(255 - seed) / 255,
                    blue: 0.5,
                    alpha: 1
                ).setFill()
                context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            }
        return PlacedOrderScreenshot(mimeType: "image/jpeg", imageData: data)!
    }
}

extension RequestStore {
    /// Test-only convenience for the many store tests that are about claim,
    /// ambiguity, success, or Message behavior and not about WHICH image is sent.
    ///
    /// It goes through the real production path — the same
    /// `selectPlacedOrderScreenshot` the Helping page calls, then the one
    /// production `fulfill` — so the fixture is exercised as genuinely selected
    /// evidence. It lives only in the test target and adds no capability to
    /// production: `RequestStore.fulfill` has no screenshot-less form and throws
    /// `placedOrderScreenshotRequired` without a selection. Tests about the
    /// screenshot itself (`PlacedOrderEvidenceFlowTests`) call select + fulfill
    /// explicitly and do not use this.
    func fulfillWithFixtureScreenshot(
        requestID: String,
        orderNumber: String,
        eta: String,
        contactMessage: String?,
        now: Date = Date()
    ) async throws {
        selectPlacedOrderScreenshot(.fixture(), requestID: requestID)
        try await fulfill(
            requestID: requestID,
            orderNumber: orderNumber,
            eta: eta,
            contactMessage: contactMessage,
            now: now
        )
    }
}
