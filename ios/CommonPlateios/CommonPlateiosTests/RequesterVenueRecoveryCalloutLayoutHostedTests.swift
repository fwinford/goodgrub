//
//  RequesterVenueRecoveryCalloutLayoutHostedTests.swift
//  CommonPlateiosTests
//
//  Hosted layout proof for the R4.2 venue recovery callout's actions against
//  the approved Figma `1110:7268`: full-width actions stacked in order at every
//  text size, 46 pt tall at ordinary sizes, with complete wrapped labels and at
//  least 44 pt tall targets at accessibility sizes.
import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

@MainActor
final class RequesterVenueRecoveryCalloutLayoutHostedTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() {
        windows.forEach { $0.isHidden = true }
        windows = []
        super.tearDown()
    }

    // MARK: - Fixtures

    private var longestNames: (screenshot: DiningSpot, manual: DiningSpot) {
        let byLength = SupportedVendorCatalog.diningSpots.sorted { $0.name.count > $1.name.count }
        return (byLength[0], byLength[1])
    }

    private func makeRecovery(_ kind: ScreenshotVenueRecoveryKind) -> ScreenshotVenueRecovery {
        let client = APIClient(configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!))
        let store = ScreenshotProposalStore(
            availability: .enabledForTesting(),
            service: ScreenshotProposalService(availability: .enabledForTesting(), client: client),
            preferences: InMemoryScreenshotProposalPreferencesStorage()
        )
        var draft = RequestFoodFormDraft()
        let token = store.beginSelection(clearing: &draft, manualEdits: ScreenshotFieldManualEditState())
        return ScreenshotVenueRecovery(
            token: token,
            outcome: ScreenshotProposalOutcome(eligible: true, proposal: ScreenshotProposal()),
            kind: kind,
            wasGenuineRerun: false
        )
    }

    private final class Taps {
        var confirm = 0
        var dismiss = 0
        var tryOther = 0
    }

    private struct Hosted {
        let window: UIWindow
        let taps: Taps
    }

    private func host(
        _ kind: ScreenshotVenueRecoveryKind,
        size: DynamicTypeSize,
        isAutofillEnabled: Bool = true
    ) throws -> Hosted {
        let taps = Taps()
        let callout = RequesterVenueRecoveryCallout(
            recovery: makeRecovery(kind),
            isAutofillEnabled: isAutofillEnabled,
            canTryOtherScreenshots: true,
            onConfirm: { taps.confirm += 1 },
            onDismiss: { taps.dismiss += 1 },
            onTryOtherScreenshots: { taps.tryOther += 1 },
            locationPicker: { Text("Choose dining location") }
        )
        let root = ScrollView {
            callout.padding(.horizontal, CommonPlateStyle.Spacing.l)
        }
        .environment(\.dynamicTypeSize, size)

        Self.enableAccessibilityTree()
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        windows.append(window)
        settle(window)
        return Hosted(window: window, taps: taps)
    }

    private static func enableAccessibilityTree() {
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let symbol = dlsym(handle, "_AXSSetAutomationEnabled") else { return }
        typealias SetAutomationEnabled = @convention(c) (Bool) -> Void
        unsafeBitCast(symbol, to: SetAutomationEnabled.self)(true)
    }

    private func settle(_ window: UIWindow, _ seconds: TimeInterval = 0.6) {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.layoutIfNeeded()
        } while Date() < end
    }

    /// Identified accessibility elements with a non-empty frame, keyed by
    /// identifier, read through the same tree VoiceOver and XCUITest see.
    private func nodes(in window: UIWindow) -> [String: NSObject] {
        var result: [String: NSObject] = [:]
        func identifier(_ object: NSObject) -> String? {
            guard object.responds(to: NSSelectorFromString("accessibilityIdentifier")) else { return nil }
            return object.value(forKey: "accessibilityIdentifier") as? String
        }
        func walk(_ node: NSObject, _ depth: Int) {
            guard depth < 60 else { return }
            if !node.accessibilityFrame.isEmpty, let id = identifier(node), !id.isEmpty, result[id] == nil {
                result[id] = node
            }
            if node.isAccessibilityElement, !node.accessibilityFrame.isEmpty,
               let label = node.accessibilityLabel, !label.isEmpty, result["label:\(label)"] == nil {
                result["label:\(label)"] = node
            }
            if let view = node as? UIView { view.subviews.forEach { walk($0, depth + 1) } }
            if let elements = node.accessibilityElements {
                for case let element as NSObject in elements { walk(element, depth + 1) }
            } else {
                let count = node.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for index in 0..<count {
                        if let element = node.accessibilityElement(at: index) as? NSObject { walk(element, depth + 1) }
                    }
                }
            }
        }
        walk(window, 0)
        return result
    }

    /// SwiftUI exposes a button's visible title as its accessibility label; the
    /// in-process tree does not surface the button's identifier, so lookups
    /// are by label (which is also what VoiceOver reads).
    private func button(_ label: String, in window: UIWindow) throws -> NSObject {
        let found = nodes(in: window)
        return try XCTUnwrap(found["label:\(label)"], "missing \(label); saw \(found.keys.sorted())")
    }

    // MARK: - Large accessibility sizes keep the stacked actions complete

    func testDifferentRestaurantsActionsStackWithFullWidthAtLargestAccessibilitySize() throws {
        let hosted = try host(.conflicting, size: .accessibility5)
        let primary = try button("Try other screenshots", in: hosted.window).accessibilityFrame
        let secondary = try button("Continue manually", in: hosted.window).accessibilityFrame
        assertStacked(primary: primary, secondary: secondary, in: hosted.window)
    }

    func testLongestManualMismatchNamesStackWithCompleteLabelsAtLargestAccessibilitySize() throws {
        let names = longestNames
        let hosted = try host(.manualMismatch(screenshot: names.screenshot, manual: names.manual), size: .accessibility5)
        let primaryNode = try button("Use \(names.screenshot.name) & autofill", in: hosted.window)
        let secondaryNode = try button("Keep \(names.manual.name) & enter manually", in: hosted.window)

        assertStacked(primary: primaryNode.accessibilityFrame, secondary: secondaryNode.accessibilityFrame, in: hosted.window)
        // The complete, unabbreviated labels are what VoiceOver reads.
        XCTAssertEqual(primaryNode.accessibilityLabel, "Use \(names.screenshot.name) & autofill")
        XCTAssertEqual(secondaryNode.accessibilityLabel, "Keep \(names.manual.name) & enter manually")
        // Even the longest venue name must not produce a button taller than the screen.
        let screenHeight = hosted.window.bounds.height
        XCTAssertLessThan(primaryNode.accessibilityFrame.height, screenHeight)
        XCTAssertLessThan(secondaryNode.accessibilityFrame.height, screenHeight)
    }

    func testUnresolvedActionsStackAtAccessibilitySizeAndKeepDisabledState() throws {
        let hosted = try host(.unresolved, size: .accessibility3, isAutofillEnabled: false)
        let autofill = try button("Autofill order details", in: hosted.window)
        let manual = try button("Continue manually", in: hosted.window)

        assertStacked(primary: autofill.accessibilityFrame, secondary: manual.accessibilityFrame, in: hosted.window)
        XCTAssertTrue(autofill.accessibilityTraits.contains(.notEnabled))
        XCTAssertFalse(manual.accessibilityTraits.contains(.notEnabled))
        XCTAssertTrue(autofill.accessibilityTraits.contains(.button))
        XCTAssertTrue(manual.accessibilityTraits.contains(.button))
    }

    func testStackedActionsStillPerformTheirOwnActions() throws {
        let hosted = try host(.conflicting, size: .accessibility5)
        XCTAssertTrue(try button("Try other screenshots", in: hosted.window).accessibilityActivate())
        settle(hosted.window, 0.2)
        XCTAssertEqual(hosted.taps.tryOther, 1)
        XCTAssertEqual(hosted.taps.dismiss, 0)

        XCTAssertTrue(try button("Continue manually", in: hosted.window).accessibilityActivate())
        settle(hosted.window, 0.2)
        XCTAssertEqual(hosted.taps.dismiss, 1)
        XCTAssertEqual(hosted.taps.tryOther, 1)
        XCTAssertEqual(hosted.taps.confirm, 0)
    }

    // MARK: - Ordinary sizes match the approved Figma stack

    func testOrdinarySizeStacksFullWidthFigmaActionsInOrder() throws {
        for size in [DynamicTypeSize.large, .xxxLarge] {
            for kind in [ScreenshotVenueRecoveryKind.unsupported, .conflicting] {
                let hosted = try host(kind, size: size)
                let primary = try button("Try other screenshots", in: hosted.window).accessibilityFrame
                let secondary = try button("Continue manually", in: hosted.window).accessibilityFrame

                assertStacked(primary: primary, secondary: secondary, in: hosted.window)
                XCTAssertEqual(secondary.minY - primary.maxY, 8, accuracy: 1, "\(size): 8 pt between the actions")
            }
        }
    }

    func testDefaultSizeActionsAreSingleLineFigmaHeight() throws {
        let hosted = try host(.unsupported, size: .large)
        let primary = try button("Try other screenshots", in: hosted.window).accessibilityFrame
        let secondary = try button("Continue manually", in: hosted.window).accessibilityFrame

        XCTAssertEqual(primary.height, 46, accuracy: 1, "approved 46 pt action height, one line")
        XCTAssertEqual(secondary.height, 46, accuracy: 1)
        XCTAssertEqual(primary.width, secondary.width, accuracy: 1)
    }

    func testUnresolvedAndMismatchActionsStackAtDefaultSize() throws {
        let unresolved = try host(.unresolved, size: .large, isAutofillEnabled: false)
        assertStacked(
            primary: try button("Autofill order details", in: unresolved.window).accessibilityFrame,
            secondary: try button("Continue manually", in: unresolved.window).accessibilityFrame,
            in: unresolved.window
        )

        let spots = SupportedVendorCatalog.diningSpots
        let mismatch = try host(.manualMismatch(screenshot: spots[0], manual: spots[1]), size: .large)
        assertStacked(
            primary: try button("Use \(spots[0].name) & autofill", in: mismatch.window).accessibilityFrame,
            secondary: try button("Keep \(spots[1].name) & enter manually", in: mismatch.window).accessibilityFrame,
            in: mismatch.window
        )
    }

    // MARK: - Assertions

    private func assertStacked(
        primary: CGRect,
        secondary: CGRect,
        in window: UIWindow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(primary.maxY, secondary.minY, "primary above secondary", file: file, line: line)
        XCTAssertGreaterThanOrEqual(primary.height, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(secondary.height, 44, file: file, line: line)
        XCTAssertEqual(primary.width, secondary.width, accuracy: 1, "equal useful widths", file: file, line: line)
        // The card spans the window minus the host's side padding; the buttons
        // use nearly all of it rather than half.
        XCTAssertGreaterThan(primary.width, window.bounds.width * 0.7, file: file, line: line)
    }
}
