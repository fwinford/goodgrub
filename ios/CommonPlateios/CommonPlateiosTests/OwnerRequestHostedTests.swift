//
//  OwnerRequestHostedTests.swift
//  CommonPlateiosTests
//
// W4-R5 hosted rendering proof for the requester-owned screens: the real
// production `OwnerRequestDetailView`, `EditRequestView` and `HomeNoticeBanner`
// mounted in a real `UIWindow` (simulator safe area, stubbed transport) and
// read back through the accessibility tree, in light, dark and the largest
// accessibility Dynamic Type size.
//
// Scope honesty: this is the simulator's rendering of the production views. It
// is not VoiceOver proof, not physical-device proof, and not a pixel
// comparison with Figma. Contrast and motion are observations Faith makes on a
// device (`docs/testing.md`).
import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

/// Serves one owner detail document (and nothing else) so the real detail view
/// can reach its `loaded` state.
final class OwnerHostedURLProtocol: URLProtocol {
    nonisolated(unsafe) static var detailBody = Data()
    nonisolated(unsafe) static var detailStatus = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "https://commonplate.test")!
        let isOwnerDetail = url.path.hasPrefix("/api/participant/request/")
        let isLedger = url.path == RequestFetchingURLProtocol.operationLedgerPath
        let response = HTTPURLResponse(
            url: url,
            statusCode: isOwnerDetail ? Self.detailStatus : 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body: Data
        if isOwnerDetail {
            body = Self.detailBody
        } else if isLedger {
            body = RequestFetchingURLProtocol.operationLedgerResponse().data
        } else {
            body = Data("{}".utf8)
        }
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class OwnerRequestHost {
    let window: UIWindow
    let controller: UIHostingController<AnyView>
    let store: RequestStore

    init(
        style: UIUserInterfaceStyle = .light,
        dynamicTypeSize: DynamicTypeSize = .large,
        build: (RequestStore, Binding<[AppRoute]>) -> AnyView
    ) throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OwnerHostedURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
        let hostedStore = RequestStore(
            service: RequestService(client: client),
            installationCredentialProvider: { "hosted-installation-credential" },
            participantAuthorityProvider: { canonicalParticipantAuthorityFixture },
            participantAuthorityRejected: {}
        )
        store = hostedStore
        var path: [AppRoute] = []
        let binding = Binding<[AppRoute]>(get: { path }, set: { path = $0 })
        let root = AnyView(
            NavigationStack { build(hostedStore, binding) }
                .environment(\.dynamicTypeSize, dynamicTypeSize)
        )
        Self.enableAccessibilityTree()
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = style
        controller = UIHostingController(rootView: root)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        settle()
    }

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

    func settle(_ seconds: TimeInterval = 1.2) {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.layoutIfNeeded()
        } while Date() < end
    }

    private func string(_ object: NSObject, _ key: String) -> String? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key) as? String
    }

    private func collect(_ root: NSObject, into result: inout [String: NSObject], depth: Int = 0) {
        guard depth < 60 else { return }
        if !root.accessibilityFrame.isEmpty,
           let identifier = string(root, "accessibilityIdentifier"), !identifier.isEmpty,
           result[identifier] == nil {
            result[identifier] = root
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

    func nodes() -> [String: NSObject] {
        var result: [String: NSObject] = [:]
        collect(controller.view, into: &result)
        var presented = controller.presentedViewController
        while let current = presented {
            if let view = current.view { collect(view, into: &result) }
            presented = current.presentedViewController
        }
        return result
    }

    func exists(_ key: String) -> Bool { nodes()[key] != nil }
    func frame(_ key: String) -> CGRect? { nodes()[key]?.accessibilityFrame }

    func isDisabled(_ key: String) -> Bool? {
        nodes()[key].map { $0.accessibilityTraits.contains(.notEnabled) }
    }

    func label(_ key: String) -> String? {
        nodes()[key].flatMap { string($0, "accessibilityLabel") }
    }
}

@MainActor
final class OwnerRequestHostedTests: XCTestCase {
    private let ownerJSON = """
    {"request": {
      "id": "h1", "vendor": "Jasper Kane Cafe", "food": "Chicken bowl; Turkey sandwich",
      "pickupWindowText": "ASAP", "mealSwipes": 2, "menuPath": "meal-exchange",
      "mealItems": [{"name": "Chicken bowl", "details": "Brown rice, black beans, and salsa"},
                    {"name": "Turkey sandwich", "details": "No mayo"}],
      "orderDetails": null, "estimatedDiningDollarsCents": null,
      "windowStart": null, "windowEnd": null,
      "createdAt": "2026-07-20T18:30:00.000Z", "expiresAt": "2099-07-20T23:30:00.000Z",
      "timing": "asap", "phase": "%PHASE%", "contentRevision": 3,
      "canEdit": %EDIT%, "canWithdraw": %EDIT%,
      "latestScheduledStart": "2099-07-21T03:30:00.000Z"
    }}
    """

    override func setUp() {
        super.setUp()
        OwnerHostedURLProtocol.detailStatus = 200
    }

    private func serve(phase: String, editable: Bool) {
        let body = phase == "scheduled"
            ? ownerJSON
                .replacingOccurrences(of: #""windowStart": null"#, with: #""windowStart": "2099-07-20T22:00:00.000Z""#)
                .replacingOccurrences(of: #""timing": "asap""#, with: #""timing": "scheduled""#)
            : ownerJSON
        OwnerHostedURLProtocol.detailBody = Data(
            body
                .replacingOccurrences(of: "%PHASE%", with: phase)
                .replacingOccurrences(of: "%EDIT%", with: editable ? "true" : "false")
                .utf8
        )
    }

    private func snapshot(phase: OwnerRequestPhase = .available, editable: Bool = true) -> OwnerRequest {
        OwnerRequest(
            request: FoodRequest(
                id: "h1",
                diningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
                foodDescription: "Chicken bowl; Turkey sandwich",
                pickupWindowText: "ASAP",
                mealSwipes: 2,
                resource: RequestResource(
                    menuPath: .mealExchange,
                    mealItems: [
                        MealItem(name: "Chicken bowl", details: "Brown rice, black beans, and salsa"),
                        MealItem(name: "Turkey sandwich", details: "No mayo"),
                    ],
                    orderDetails: nil,
                    estimatedDiningDollarsCents: nil
                ),
                windowStart: nil,
                windowEnd: nil,
                createdAt: Date(timeIntervalSince1970: 1_784_000_000),
                expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
                status: phase == .reserved ? .claimed : .open,
                ownership: .own
            ),
            phase: phase,
            contentRevision: 3,
            canEdit: editable,
            canWithdraw: editable,
            latestScheduledStart: Date(timeIntervalSince1970: 4_000_000_000)
        )
    }

    private func detailHost(
        phase: OwnerRequestPhase = .available,
        editable: Bool = true,
        style: UIUserInterfaceStyle = .light,
        type: DynamicTypeSize = .large
    ) throws -> OwnerRequestHost {
        serve(phase: "\(phase)", editable: editable)
        let owner = snapshot(phase: phase, editable: editable)
        return try OwnerRequestHost(style: style, dynamicTypeSize: type) { store, path in
            AnyView(OwnerRequestDetailView(store: store, owner: owner, path: path))
        }
    }

    private var screenWidth: CGFloat { UIScreen.main.bounds.width }

    // MARK: Available

    func testAvailableDetailShowsTheApprovedStructureAndOffersBothActions() throws {
        let host = try detailHost()

        for key in [
            "owner-request-status", "owner-request-details",
            "owner-request-withdraw", "owner-request-edit",
        ] {
            XCTAssertTrue(host.exists(key), key)
        }
        // One `Your request` heading only: the navigation title (Faith, R3 recheck).
        XCTAssertFalse(host.exists("owner-request-title"))
        XCTAssertEqual(host.isDisabled("owner-request-edit"), false)
        XCTAssertFalse(host.exists("owner-request-edit-disabled-note"))
        XCTAssertFalse(host.exists("owner-request-unverified"))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(host.frame("owner-request-withdraw")).height, 44)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(host.frame("owner-request-edit")).height, 44)
    }

    func testAllOwnerPhasesHaveOneStatusAndNoRedundantTimingRows() throws {
        for phase in [OwnerRequestPhase.available, .scheduled, .reserved] {
            let host = try detailHost(phase: phase, editable: phase != .reserved)
            let status = try XCTUnwrap(host.label("owner-request-status"))
                .replacingOccurrences(of: "\u{202F}", with: " ")
            switch phase {
            case .available: XCTAssertEqual(status, "Available to helpers until 7:30 PM")
            case .scheduled: XCTAssertEqual(status, "Scheduled for 6:00 PM")
            case .reserved: XCTAssertEqual(status, "Being helped")
            }
            let labels = accessibleLabels(in: host.controller.view)
            for removed in ["Requested: ASAP", "Starts at", "Available until", "Timing", "Later"] {
                XCTAssertFalse(labels.contains { $0.contains(removed) }, "\(phase): \(removed)")
            }
            XCTAssertTrue(labels.contains { $0.contains("Chicken bowl") })
            XCTAssertTrue(labels.contains { $0.contains("Brown rice, black beans, and salsa") })
            XCTAssertTrue(labels.contains { $0.contains("Turkey sandwich") })
            XCTAssertEqual(labels.filter { $0 == host.label("owner-request-status") }.count, 1)
            XCTAssertLessThan(
                try XCTUnwrap(host.frame("owner-request-status")).minY,
                try XCTUnwrap(host.frame("owner-request-details")).minY
            )
        }
    }

    private func accessibleLabels(in root: NSObject) -> [String] {
        var seen = Set<ObjectIdentifier>()
        var labels: [String] = []
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let label = object.accessibilityLabel { labels.append(label) }
            if let view = object as? UIView { view.subviews.forEach(visit) }
            for child in object.accessibilityElements ?? [] {
                if let child = child as? NSObject { visit(child) }
            }
            let count = object.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject { visit(child) }
                }
            }
        }
        visit(root)
        return labels
    }

    // MARK: Being helped

    func testBeingHelpedOffersNoWithdrawAndExplainsWhyEditIsOff() throws {
        let host = try detailHost(phase: .reserved, editable: false)

        XCTAssertFalse(host.exists("owner-request-withdraw"))
        XCTAssertTrue(host.exists("owner-request-edit-disabled-note"))
        XCTAssertEqual(host.isDisabled("owner-request-edit"), true)
        XCTAssertEqual(host.label("owner-request-status"), "Being helped")
        // R5 builds no chat entry: MSG1 owns it.
        XCTAssertFalse(host.nodes().keys.contains { $0.localizedCaseInsensitiveContains("chat") })
    }

    // MARK: Unverified

    func testAnUnverifiableReadWithholdsEveryActionAndSaysSo() throws {
        OwnerHostedURLProtocol.detailBody = Data("not json".utf8)
        let owner = snapshot()
        let host = try OwnerRequestHost { store, path in
            AnyView(OwnerRequestDetailView(store: store, owner: owner, path: path))
        }

        XCTAssertTrue(host.exists("owner-request-unverified"))
        XCTAssertEqual(host.isDisabled("owner-request-edit"), true, "no action is offered as current")
        XCTAssertFalse(host.exists("owner-request-withdraw"))
    }

    // MARK: Expired

    func testAVerifiedExpiryShowsTheApprovedOutcomeWithItsTwoExits() throws {
        OwnerHostedURLProtocol.detailStatus = 410
        OwnerHostedURLProtocol.detailBody = Data(
            #"{"error":{"code":"REQUEST_EXPIRED","message":"x","fields":null}}"#.utf8
        )
        let owner = snapshot()
        let host = try OwnerRequestHost { store, path in
            AnyView(OwnerRequestDetailView(store: store, owner: owner, path: path))
        }

        let keys = host.nodes().keys.sorted()
        XCTAssertTrue(host.exists("owner-request-expired"), "\(keys)")
        XCTAssertTrue(host.exists("owner-request-expired-close"), "\(keys)")
        XCTAssertTrue(host.exists("owner-request-expired-request-meal"), "\(keys)")
        XCTAssertFalse(host.exists("owner-request-edit"))
    }

    // MARK: Dark mode and largest Dynamic Type

    func testDarkAppearanceAndAccessibilityTypeKeepEverythingReachableAndInsideTheScreen() throws {
        for (style, type) in [
            (UIUserInterfaceStyle.dark, DynamicTypeSize.large),
            (.light, .accessibility5),
            (.dark, .accessibility5),
        ] {
            let host = try detailHost(style: style, type: type)
            for key in ["owner-request-details", "owner-request-edit"] {
                let frame = try XCTUnwrap(host.frame(key), "\(key) @ \(style.rawValue)/\(type)")
                XCTAssertGreaterThanOrEqual(frame.minX, -1, key)
                XCTAssertLessThanOrEqual(frame.maxX, screenWidth + 1, "\(key) must not overflow horizontally")
            }
            XCTAssertEqual(host.isDisabled("owner-request-edit"), false)
        }
    }

    // MARK: Edit

    func testEditShowsTheSavedRequestAndSaveIsOffUntilSomethingChanges() throws {
        let owner = snapshot()
        let host = try OwnerRequestHost { store, path in
            AnyView(EditScreenshotFixtures.editView(store: store, owner: owner, path: path))
        }

        for key in [
            "edit-request-dining-spot-picker", "edit-request-menu-path-meal-exchange",
            "edit-request-meal-swipes", "edit-request-meal-collapsed-0", "edit-request-meal-collapsed-1",
            "edit-request-timing-asap", "edit-request-timing-later", "edit-request-save",
            "edit-request-back",
        ] {
            XCTAssertTrue(host.exists(key), key)
        }
        XCTAssertEqual(host.isDisabled("edit-request-save"), true, "no change, no save")
        XCTAssertFalse(host.exists("edit-request-outcome"))
        XCTAssertFalse(host.exists("edit-request-start-picker"), "ASAP selected, so no picker")
    }

    func testEditInDarkAndLargestTypeStaysUsable() throws {
        let owner = snapshot()
        for (style, type) in [
            (UIUserInterfaceStyle.dark, DynamicTypeSize.large),
            (.dark, .accessibility5),
        ] {
            let host = try OwnerRequestHost(style: style, dynamicTypeSize: type) { store, path in
                AnyView(EditScreenshotFixtures.editView(store: store, owner: owner, path: path))
            }
            let save = try XCTUnwrap(host.frame("edit-request-save"))
            XCTAssertGreaterThanOrEqual(save.height, 44)
            XCTAssertLessThanOrEqual(save.maxX, screenWidth + 1)
        }
    }

    func testAnUnconfirmedEditLocksTheFormAndShowsTheApprovedMessage() async throws {
        let owner = snapshot()
        let host = try OwnerRequestHost { store, path in
            AnyView(EditScreenshotFixtures.editView(store: store, owner: owner, path: path))
        }
        // A real unknown outcome through the real store: the ledger answers, the
        // edit POST's body cannot be decoded.
        let payload = EditRequestPayload(
            vendor: "Jasper Kane Cafe", menuPath: .mealExchange, mealSwipes: 2,
            mealItems: [MealItem(name: "Edited"), MealItem(name: "Turkey sandwich")],
            orderDetails: nil, estimatedDiningDollarsCents: nil,
            timing: .unchanged, windowStart: nil, expectedContentRevision: 3
        )
        _ = try? await host.store.editRequest(requestID: "h1", payload: payload)
        host.settle()

        XCTAssertEqual(host.store.unresolvedUpdate?.kind, .edit)
        XCTAssertTrue(host.exists("edit-request-outcome"))
        XCTAssertTrue(
            host.label("edit-request-outcome")?.contains(
                EditRequestPresentation.unconfirmedEditMessage
            ) == true,
            "the approved unknown-outcome sentence, never a success or failure"
        )
        // Save stays available: it replays the same identity.
        XCTAssertEqual(host.isDisabled("edit-request-save"), false)
    }

    // MARK: Home banner

    func testTheHomeBannerDismissTargetIsAtLeast44Points() throws {
        let host = try OwnerRequestHost(dynamicTypeSize: .accessibility3) { _, _ in
            AnyView(
                HomeNoticeBanner(
                    icon: .check,
                    title: "Request withdrawn",
                    identifier: "banner",
                    onDismiss: {}
                )
                .padding()
            )
        }
        let dismiss = try XCTUnwrap(host.frame("banner-dismiss"))
        XCTAssertGreaterThanOrEqual(dismiss.width, 44)
        XCTAssertGreaterThanOrEqual(dismiss.height, 44)
        XCTAssertEqual(host.label("banner-dismiss"), "Dismiss")
    }

    // MARK: Manual-review snapshots (opt-in; never part of acceptance counts)

    /// Writes PNGs of the hosted screens for a human to compare with Figma, only
    /// when `R5_SNAPSHOT_DIR` is set (pass it to `xcodebuild` as
    /// `TEST_RUNNER_R5_SNAPSHOT_DIR`). It asserts nothing, so it can never turn a
    /// rendering observation into a pass.
    func testWriteReviewSnapshotsWhenRequested() throws {
        try writeReviewSnapshots(styles: [.light])
    }

    func testWriteDarkReviewSnapshotsWhenRequested() throws {
        try writeReviewSnapshots(styles: [.dark])
    }

    private func writeReviewSnapshots(styles: [UIUserInterfaceStyle]) throws {
        guard let directory = ProcessInfo.processInfo.environment["R5_SNAPSHOT_DIR"],
              !directory.isEmpty else {
            throw XCTSkip("R5_SNAPSHOT_DIR is not set")
        }
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        func write(_ host: OwnerRequestHost, _ name: String) {
            host.settle(1.5)
            let renderer = UIGraphicsImageRenderer(bounds: host.window.bounds)
            let image = renderer.image { _ in
                host.window.drawHierarchy(in: host.window.bounds, afterScreenUpdates: true)
            }
            try? image.pngData()?.write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))
        }
        for style in styles {
            let tag = style == .dark ? "dark" : "light"
            write(try detailHost(style: style), "detail-available-\(tag)")
            write(try detailHost(phase: .reserved, editable: false, style: style), "detail-reserved-\(tag)")
            let owner = snapshot()
            write(
                try OwnerRequestHost(style: style) { store, path in
                    AnyView(EditScreenshotFixtures.editView(store: store, owner: owner, path: path))
                },
                "edit-\(tag)"
            )
            write(
                try OwnerRequestHost(style: style) { _, _ in
                    AnyView(
                        VStack(spacing: 12) {
                            HomeNoticeBanner(icon: .check, title: "Request withdrawn", identifier: "b1", onDismiss: {})
                            HomeNoticeBanner(
                                icon: .clock, title: "Your Jasper Kane Cafe request expired",
                                detail: "2 meal swipes", identifier: "b2", onDismiss: {}
                            )
                            HomeNoticeBanner(
                                icon: .none, title: "Couldn’t open this request",
                                detail: "Please try again.", identifier: "b3", onDismiss: {}
                            )
                            RequestCardView(
                                request: owner.request, kind: .own, showsOwnershipEyebrow: false,
                                ownerPhase: .available
                            )
                            RequestCardView(
                                request: snapshot(phase: .reserved, editable: false).request,
                                kind: .own, showsOwnershipEyebrow: false, ownerPhase: .reserved
                            )
                            Spacer()
                        }
                        .padding()
                        .background(CommonPlateStyle.Color.baseCanvas)
                    )
                },
                "home-bits-\(tag)"
            )
        }
    }

    // MARK: Adaptive tokens (no fixed light colors on the shared card)

    func testTheSharedRequestCardTokensAdaptToDarkAppearance() {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        for color in [
            CommonPlateStyle.Color.requestCardSurface,
            CommonPlateStyle.Color.requestCardBorder,
            CommonPlateStyle.Color.helpingCardSurface,
            CommonPlateStyle.Color.helpingCardBorder,
        ] {
            let ui = UIColor(color)
            XCTAssertNotEqual(
                ui.resolvedColor(with: light), ui.resolvedColor(with: dark),
                "a card token must not be a fixed light color"
            )
        }
        // Light values are exactly the approved light tokens.
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(CommonPlateStyle.Color.requestCardSurface).resolvedColor(with: light)
            .getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(Int((r * 255).rounded()), 245)
        XCTAssertEqual(Int((g * 255).rounded()), 239)
        XCTAssertEqual(Int((b * 255).rounded()), 232)
    }

    func testTheNewScreensUseNoFixedLightRGBLiterals() throws {
        for file in [
            "Views/OwnerRequestDetailView.swift", "Views/EditRequestView.swift",
            "Views/HomeNoticeBanner.swift", "Views/EditRequestPresentation.swift",
        ] {
            let source = try String(
                contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("CommonPlateios")
                    .appendingPathComponent(file),
                encoding: .utf8
            )
            // Every literal color is inside a trait-resolved `UIColor { traits in`.
            let literals = source.components(separatedBy: "Color(red:").count - 1
                + source.components(separatedBy: "UIColor(red:").count - 1
            let adaptive = source.components(separatedBy: "UIColor { traits in").count - 1
            XCTAssertEqual(literals > 0, adaptive > 0, file)
        }
    }
}
