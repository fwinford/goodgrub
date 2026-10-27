import CryptoKit
import UIKit
import XCTest

final class AppIconPackagingTests: XCTestCase {
    func testApprovedMasterIsUnchangedAndAllIPhoneIconSlotsHaveOpaqueImages() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios/Assets.xcassets/GoodGrubAppIcon.appiconset")
        let master = try Data(contentsOf: directory.appendingPathComponent("AppIcon-1024.png"))
        XCTAssertEqual(
            SHA256.hash(data: master).map { String(format: "%02x", $0) }.joined(),
            "0880c28a8887cb9c82d12e002fc279384c16e7c0bcc44efdd73415d6a9aeacf9"
        )
        let contents = try JSONDecoder().decode(Catalog.self, from:
            Data(contentsOf: directory.appendingPathComponent("Contents.json")))
        for points in [20, 29, 40, 60] {
            for scale in [2, 3] {
                let slot = try XCTUnwrap(contents.images.first {
                    $0.idiom == "iphone" && $0.size == "\(points)x\(points)" && $0.scale == "\(scale)x"
                })
                let image = try XCTUnwrap(UIImage(contentsOfFile:
                    directory.appendingPathComponent(slot.filename).path)?.cgImage)
                XCTAssertEqual(image.width, points * scale)
                XCTAssertEqual(image.height, points * scale)
                XCTAssertTrue([CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo))
            }
        }
        XCTAssertTrue(contents.images.contains {
            $0.idiom == "universal" && $0.platform == "ios"
                && $0.size == "1024x1024" && $0.filename == "AppIcon-1024.png"
        }, "Device-thinned catalogs must retain the approved runtime master, not only size references.")
    }

    func testInstalledAppRegistersTheGoodGrubPrimaryIcon() throws {
        let icons = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any])
        let primary = try XCTUnwrap(icons["CFBundlePrimaryIcon"] as? [String: Any])
        XCTAssertEqual(primary["CFBundleIconName"] as? String, "GoodGrubAppIcon")
        let files = try XCTUnwrap(primary["CFBundleIconFiles"] as? [String])
        XCTAssertFalse(files.isEmpty)
        for name in files {
            XCTAssertTrue(name.hasPrefix("GoodGrubAppIcon"))
            XCTAssertNotNil(UIImage(named: name, in: .main, compatibleWith: nil))
        }
    }

    private struct Catalog: Decodable {
        let images: [Image]
        struct Image: Decodable {
            let filename: String
            let idiom: String
            let size: String
            let scale: String?
            let platform: String?
        }
    }
}
