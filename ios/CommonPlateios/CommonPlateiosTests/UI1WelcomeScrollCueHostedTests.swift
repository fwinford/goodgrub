import SwiftUI
import UIKit
import Vision
import XCTest
@testable import CommonPlateios

@MainActor
final class UI1WelcomeScrollCueHostedTests: XCTestCase {
    func testRenderedChevronStaysBelowStationaryInvitationAcrossItsCycle() async throws {
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            try await checkCue(appearance: appearance)
        }
    }

    private func checkCue(appearance: UIUserInterfaceStyle) async throws {
        let host = try UI1Checkpoint1CorrectionsTests.Host(
            OnboardingWelcomeView(onContinue: {})
                .dynamicTypeSize(.large)
                .preferredColorScheme(appearance == .dark ? .dark : .light)
        )
        defer { host.close() }
        host.window.overrideUserInterfaceStyle = appearance
        var invitationPositions: [CGFloat] = []
        var cuePositions: [CGFloat] = []
        var labelBottom: CGFloat = 0
        for sample in 0...40 {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let image = UIGraphicsImageRenderer(bounds: host.window.bounds, format: format).image { _ in
                host.window.drawHierarchy(in: host.window.bounds, afterScreenUpdates: true)
            }
            let cgImage = try XCTUnwrap(image.cgImage)
            if sample == 0 || sample == 40 {
                let textRequest = VNRecognizeTextRequest()
                textRequest.recognitionLevel = .accurate
                try VNImageRequestHandler(cgImage: cgImage).perform([textRequest])
                let invitation = try XCTUnwrap(textRequest.results?.first {
                    $0.topCandidates(1).first?.string == OnboardingCopy.scrollInvitation
                }, "The production scroll invitation must be visible.")
                labelBottom = (1 - invitation.boundingBox.minY) * CGFloat(cgImage.height)
                invitationPositions.append(labelBottom / image.scale)
            }
            let cueTop = try cueTop(in: cgImage, appearance: appearance)
            cuePositions.append(cueTop / image.scale)
            if cueTop < labelBottom {
                let attachment = XCTAttachment(image: image)
                attachment.name = "welcome-chevron-overlaps-invitation"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTFail("The rendered chevron must remain below See how it works, including during animation.")
                return
            }
            try await Task.sleep(for: .seconds(OnboardingMotion.scrollCueDuration / 20))
        }

        XCTAssertEqual(invitationPositions.count, 2)
        XCTAssertEqual(cuePositions.count, 41)
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(invitationPositions.max()) - XCTUnwrap(invitationPositions.min()),
            1,
            "The invitation text must remain stationary."
        )
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(cuePositions.max()) - XCTUnwrap(cuePositions.min()),
            OnboardingMotion.scrollCueTravel + 1,
            "Only the bounded downward cue displacement may animate."
        )
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(cuePositions.max()) - XCTUnwrap(cuePositions.min()),
            OnboardingMotion.scrollCueTravel / 2,
            "The cue must visibly move rather than stay stationary."
        )
    }

    private func cueTop(in image: CGImage, appearance: UIUserInterfaceStyle) throws -> CGFloat {
        let width = image.width
        let height = image.height
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let color = UIColor(CommonPlateStyle.Color.brandText)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: appearance))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        // Below the hero, the cue is the only brand-colored mark in the
        // center column. Match its interior, not font antialiasing or a bitmap baseline.
        for y in (height / 2)..<height {
            for x in (width / 3)..<(width * 2 / 3) {
                let index = (y * width + x) * 4
                if abs(CGFloat(pixels[index]) / 255 - red) < 0.04,
                   abs(CGFloat(pixels[index + 1]) / 255 - green) < 0.04,
                   abs(CGFloat(pixels[index + 2]) / 255 - blue) < 0.04 {
                    return CGFloat(y)
                }
            }
        }
        XCTFail("The production chevron must be visible.")
        throw NSError(domain: "WelcomeScrollCueCapture", code: 1)
    }
}
