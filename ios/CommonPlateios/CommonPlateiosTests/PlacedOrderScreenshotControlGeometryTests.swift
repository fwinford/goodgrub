//
//  PlacedOrderScreenshotControlGeometryTests.swift
//  CommonPlateiosTests
//
//  W4-R3 walkthrough regression: attaching an order screenshot must not change
//  the helper control's height or width (the empty chooser and the attached
//  row are one fixed-geometry field). Final appearance is judged on device.
import PhotosUI
import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

@MainActor
final class PlacedOrderScreenshotControlGeometryTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() {
        windows.forEach { $0.isHidden = true }
        windows = []
        super.tearDown()
    }

    private final class Probe { var size: CGSize = .zero }

    private struct Harness: View {
        let isAttached: Bool
        let probe: Probe
        @State private var selection: PhotosPickerItem?

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                PlacedOrderScreenshotControl(
                    isAttached: isAttached,
                    isEnabled: true,
                    selection: $selection
                )
                .background(GeometryReader { proxy in
                    Color.clear.onAppear { probe.size = proxy.size }
                })
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
        }
    }

    private func measure(attached: Bool, width: CGFloat = 390) -> CGSize {
        let probe = Probe()
        let host = UIHostingController(rootView: Harness(isAttached: attached, probe: probe))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 800))
        window.rootViewController = host
        window.isHidden = false
        windows.append(window)
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        return probe.size
    }

    func testAttachingScreenshotDoesNotChangeControlHeight() {
        let empty = measure(attached: false)
        let attached = measure(attached: true)

        XCTAssertEqual(empty.height, PlacedOrderScreenshotControl.height, accuracy: 0.5)
        XCTAssertEqual(attached.height, empty.height, accuracy: 0.5)
    }

    func testEmptyAndAttachedControlsFillTheSameWidth() {
        let empty = measure(attached: false)
        let attached = measure(attached: true)

        XCTAssertEqual(attached.width, empty.width, accuracy: 0.5)
    }
}
