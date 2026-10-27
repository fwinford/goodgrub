//
//  RequesterFormHostedHarness.swift
//  CommonPlateiosTests
//
// W4-R4 test-only hosted rendering/geometry harness. It mounts the real
// production `RequestFoodView` (real stores, stubbed transport) in a real
// `UIWindow` with the simulator's own safe area, then reads where controls
// were actually laid out. Source-text assertions cannot establish rendered
// geometry, scroll offsets, or environment tint (`docs/testing.md`: no UI-test
// target), which is the exact gap the 2026-09-26 physical-device findings fell
// through.
//
// Frames come from the accessibility tree (`accessibilityIdentifier` +
// `accessibilityFrame`), which SwiftUI populates from the same layout it draws.
// Scroll offset comes from the real backing `UIScrollView`.
//
// Scope honesty: this is the simulator's rendering of the production view. It
// is not physical-device proof of motion smoothness, keyboard behavior, or
// device-specific safe areas.
import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

/// Answers every request with `{"paused":false}`, which is all a mounted
/// `RequestFoodView` needs to reach `.form`.
final class RequesterHostedURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "https://commonplate.test")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"paused":false}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class RequesterFormHost {
    let window: UIWindow
    let draftSession: RequestFoodDraftSession
    let controller: UIHostingController<AnyView>

    /// - Parameters:
    ///   - viewportHeight: when set, the form is hosted in a container this
    ///     tall (top-aligned) so a short viewport can be simulated on any
    ///     simulator.
    ///   - dynamicTypeSize: injected into the hosted environment.
    init(
        draft: RequestFoodFormDraft = RequestFoodFormDraft(),
        viewportHeight: CGFloat? = nil,
        dynamicTypeSize: DynamicTypeSize = .large,
        screenshotAvailability: RequesterScreenshotAssistanceAvailability = .enabledForTesting()
    ) throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequesterHostedURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )

        let identityStore = ParticipantIdentityStore(
            service: ParticipantVerificationService(client: client),
            storage: InMemoryParticipantIdentityStorage()
        )
        let coordinator = ParticipantActionVerificationCoordinator(identityStore: identityStore)
        let requestStore = RequestStore(
            service: RequestService(client: client),
            installationCredentialProvider: { "hosted-installation-credential" },
            participantAuthorityProvider: { identityStore.currentAuthority() },
            participantAuthorityRejected: { identityStore.discardRejectedIdentity() }
        )
        let screenshotStore = ScreenshotProposalStore(
            availability: screenshotAvailability,
            service: ScreenshotProposalService(availability: screenshotAvailability, client: client),
            preferences: InMemoryScreenshotProposalPreferencesStorage()
        )
        let session = RequestFoodDraftSession()
        session.draft = draft
        draftSession = session

        let form = RequestFoodView(
            store: requestStore,
            screenshotProposalStore: screenshotStore,
            draftSession: session,
            identityStore: identityStore,
            verificationCoordinator: coordinator,
            path: .constant([]),
            onExit: {},
            isPresentingScreenshotHelp: .constant(false),
            isPresentingScreenshotAssistanceDisclosure: .constant(false),
            isSuppressingBackNavigation: .constant(false)
        )

        let root = AnyView(
            NavigationStack {
                Group {
                    if let viewportHeight {
                        VStack(spacing: 0) {
                            form.frame(height: viewportHeight)
                            Spacer(minLength: 0)
                        }
                    } else {
                        form
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
            }
            .environment(\.dynamicTypeSize, dynamicTypeSize)
        )

        Self.enableAccessibilityTree()
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        window = UIWindow(windowScene: scene)
        controller = UIHostingController(rootView: root)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        settle()
    }

    /// SwiftUI populates its accessibility tree only while accessibility
    /// automation is on, as it is under XCUITest. Turning it on in the test
    /// process lets a unit-test host read the same tree.
    private static func enableAccessibilityTree() {
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let symbol = dlsym(handle, "_AXSSetAutomationEnabled") else { return }
        typealias SetAutomationEnabled = @convention(c) (Bool) -> Void
        unsafeBitCast(symbol, to: SetAutomationEnabled.self)(true)
    }

    deinit {
        let window = self.window
        Task { @MainActor in window.isHidden = true }
    }

    func settle(_ seconds: TimeInterval = 1.0) {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.layoutIfNeeded()
        } while Date() < end
    }

    // MARK: - Accessibility-tree frames (window coordinates)

    /// SwiftUI's private `AccessibilityNode` objects do not statically
    /// conform to `UIAccessibilityIdentification`, but they do answer the
    /// selector, so it is read dynamically.
    private func string(_ object: NSObject, _ key: String) -> String? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key) as? String
    }

    private func collect(_ root: NSObject, into result: inout [String: NSObject], depth: Int = 0) {
        guard depth < 60 else { return }
        if !root.accessibilityFrame.isEmpty {
            if let identifier = string(root, "accessibilityIdentifier"), !identifier.isEmpty,
               result[identifier] == nil {
                result[identifier] = root
            }
            if root.isAccessibilityElement,
               let label = string(root, "accessibilityLabel"), !label.isEmpty,
               result["label:\(label)"] == nil {
                result["label:\(label)"] = root
            }
        }
        if let view = root as? UIView {
            for sub in view.subviews { collect(sub, into: &result, depth: depth + 1) }
        }
        if let elements = root.accessibilityElements {
            for element in elements {
                if let element = element as? NSObject { collect(element, into: &result, depth: depth + 1) }
            }
        } else {
            let count = root.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let element = root.accessibilityElement(at: index) as? NSObject {
                        collect(element, into: &result, depth: depth + 1)
                    }
                }
            }
        }
    }

    /// Every identified or labelled accessibility element, freshly collected.
    /// Keys are the `accessibilityIdentifier`, or `label:<accessibilityLabel>`.
    func nodes() -> [String: NSObject] {
        var result: [String: NSObject] = [:]
        collect(controller.view, into: &result)
        return result
    }

    /// Every accessibility element's label, duplicates included, so a test
    /// can prove a label appears exactly once (or not at all).
    func allLabels() -> [String] {
        var labels: [String] = []
        // The hosting hierarchy exposes the same node through more than one
        // path, and SwiftUI hands out throwaway proxy objects, so identity
        // cannot dedupe; the label plus its rounded frame does.
        var seen = Set<String>()
        func walk(_ node: NSObject, _ depth: Int) {
            guard depth < 60 else { return }
            if node.isAccessibilityElement, !node.accessibilityFrame.isEmpty,
               let label = string(node, "accessibilityLabel"), !label.isEmpty {
                let frame = node.accessibilityFrame
                let signature = "\(label)|\(Int(frame.minX.rounded()))|\(Int(frame.minY.rounded()))|\(Int(frame.width.rounded()))"
                if seen.insert(signature).inserted { labels.append(label) }
            }
            if let view = node as? UIView { view.subviews.forEach { walk($0, depth + 1) } }
            if let elements = node.accessibilityElements {
                for element in elements { if let element = element as? NSObject { walk(element, depth + 1) } }
            } else {
                let count = node.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for index in 0..<count {
                        if let element = node.accessibilityElement(at: index) as? NSObject { walk(element, depth + 1) }
                    }
                }
            }
        }
        walk(controller.view, 0)
        return labels
    }

    /// Every element's frame, in window coordinates (`accessibilityFrame` is
    /// screen-space and the test window is full-screen, so they coincide).
    func frames() -> [String: CGRect] {
        nodes().mapValues { $0.accessibilityFrame }
    }

    func frame(_ key: String) -> CGRect? {
        nodes()[key]?.accessibilityFrame
    }

    func exists(_ key: String) -> Bool {
        nodes()[key] != nil
    }

    /// Activates the real production control behind `key` through the same
    /// accessibility action VoiceOver's double-tap uses.
    @discardableResult
    func activate(_ key: String, settling seconds: TimeInterval = 1.0) -> Bool {
        guard let node = nodes()[key] else { return false }
        let activated = node.accessibilityActivate()
        settle(seconds)
        return activated
    }

    /// The UIKit text control behind `key`. SwiftUI assigns a `UITextField`'s
    /// identifier lazily, so this also matches a text input by the element's
    /// laid-out frame.
    func uiView(withIdentifier identifier: String) -> UIView? {
        func walk(_ view: UIView, where predicate: (UIView) -> Bool) -> UIView? {
            if predicate(view) { return view }
            for sub in view.subviews { if let hit = walk(sub, where: predicate) { return hit } }
            return nil
        }
        if let hit = walk(controller.view, where: { $0.accessibilityIdentifier == identifier }) { return hit }
        guard let target = frame(identifier) else { return nil }
        return walk(controller.view) { view in
            guard view is UITextField || view is UITextView, !view.isHidden else { return false }
            let inWindow = view.convert(view.bounds, to: nil)
            return inWindow.intersects(target)
                && abs(inWindow.midY - target.midY) < 6
        }
    }

    /// Focuses then blurs the `UITextField` behind `identifier`, driving the
    /// real `FocusState` transition that presents a field's validation.
    func focusThenBlur(_ identifier: String) throws {
        let field = try XCTUnwrap(uiView(withIdentifier: identifier), "no UIKit field for \(identifier)")
        XCTAssertTrue(field.becomeFirstResponder(), "field \(identifier) could not take focus")
        settle(0.5)
        field.resignFirstResponder()
        settle(0.7)
    }

    // MARK: - Rendered pixels

    struct Pixels {
        let width: Int
        let height: Int
        let scale: CGFloat
        private let bytes: [UInt8]
        private let bytesPerRow: Int

        fileprivate init(width: Int, height: Int, scale: CGFloat, bytes: [UInt8], bytesPerRow: Int) {
            self.width = width
            self.height = height
            self.scale = scale
            self.bytes = bytes
            self.bytesPerRow = bytesPerRow
        }

        /// RGB at a point in window coordinates.
        func rgb(atX x: CGFloat, y: CGFloat) -> (r: Int, g: Int, b: Int) {
            let px = min(max(Int(x * scale), 0), width - 1)
            let py = min(max(Int(y * scale), 0), height - 1)
            let offset = py * bytesPerRow + px * 4
            return (Int(bytes[offset + 2]), Int(bytes[offset + 1]), Int(bytes[offset]))
        }
    }

    /// The window as actually drawn (BGRA, 2x).
    func pixels() -> Pixels? {
        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let cg = image.cgImage,
              let data = cg.dataProvider?.data,
              let pointer = CFDataGetBytePtr(data) else { return nil }
        let count = CFDataGetLength(data)
        return Pixels(
            width: cg.width,
            height: cg.height,
            scale: image.scale,
            bytes: Array(UnsafeBufferPointer(start: pointer, count: count)),
            bytesPerRow: cg.bytesPerRow
        )
    }

    /// The rightmost drawn (non-background) x inside `rect`, in window
    /// points. The background is sampled just outside the content column at
    /// the same height, so this compares rendered ink, not layout frames.
    func inkRightEdge(in rect: CGRect) -> CGFloat? {
        guard let pixels = pixels() else { return nil }
        let background = pixels.rgb(atX: window.bounds.width - 2, y: rect.midY)
        var right: CGFloat?
        var x = rect.minX
        while x <= rect.maxX {
            var y = rect.minY
            while y <= rect.maxY {
                let color = pixels.rgb(atX: x, y: y)
                let delta = abs(color.r - background.r) + abs(color.g - background.g) + abs(color.b - background.b)
                if delta > 60 { right = x; break }
                y += 0.5
            }
            x += 0.5
        }
        return right
    }

    // MARK: - Scroll view

    /// The form's real backing scroll view (the tallest vertically scrolling
    /// `UIScrollView` in the hosted hierarchy).
    func scrollView() -> UIScrollView? {
        var found: [UIScrollView] = []
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView,
               String(describing: type(of: scroll)).contains("Scroll") {
                found.append(scroll)
            }
            view.subviews.forEach(walk)
        }
        walk(controller.view)
        return found
            .filter { $0.bounds.height > 100 }
            .max { $0.bounds.height < $1.bounds.height }
    }

    /// How far the content has scrolled from its resting top (0 at rest).
    var scrollOffsetY: CGFloat {
        guard let scroll = scrollView() else { return 0 }
        return scroll.contentOffset.y + scroll.adjustedContentInset.top
    }

    /// The farthest the content can scroll from its resting top.
    var maxScrollOffsetY: CGFloat {
        guard let scroll = scrollView() else { return 0 }
        let inset = scroll.adjustedContentInset
        return max(0, scroll.contentSize.height + inset.top + inset.bottom - scroll.bounds.height)
    }

    func scroll(toOffsetY offset: CGFloat) {
        guard let scroll = scrollView() else { return }
        let clamped = min(max(0, offset), maxScrollOffsetY)
        scroll.setContentOffset(
            CGPoint(x: 0, y: clamped - scroll.adjustedContentInset.top),
            animated: false
        )
        settle(0.5)
    }

    func scrollToBottom() {
        scroll(toOffsetY: maxScrollOffsetY)
    }

    /// Bounds of the window inside its safe area.
    var safeFrame: CGRect {
        window.bounds.inset(by: window.safeAreaInsets)
    }
}
