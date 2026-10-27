//
//  OnboardingPresentationTests.swift
//  CommonPlateiosTests
//
// Focused W4-R1 proof that onboarding is a local presentation preference,
// never a participant role or authority record.

import XCTest
@testable import CommonPlateios

@MainActor
final class OnboardingPresentationTests: XCTestCase {
    func testFreshInstallationStartsWithOnboardingIncomplete() {
        let storage = InMemoryOnboardingPresentationStorage()

        XCTAssertFalse(OnboardingPresentationStore(storage: storage).hasCompletedOnboarding)
    }

    func testCompletionPersistsAcrossStoreReconstruction() {
        let storage = InMemoryOnboardingPresentationStorage()
        let firstStore = OnboardingPresentationStore(storage: storage)

        firstStore.completeOnboarding()

        XCTAssertTrue(storage.hasCompletedOnboarding)
        XCTAssertTrue(OnboardingPresentationStore(storage: storage).hasCompletedOnboarding)
    }

    func testCompletionPersistsThroughTheProductionUserDefaultsStorageBoundary() {
        let suiteName = "OnboardingPresentationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storage = UserDefaultsOnboardingPresentationStorage(defaults: defaults)

        OnboardingPresentationStore(storage: storage).completeOnboarding()

        let reconstructedStorage = UserDefaultsOnboardingPresentationStorage(defaults: defaults)
        XCTAssertTrue(OnboardingPresentationStore(storage: reconstructedStorage).hasCompletedOnboarding)
    }

    /// W4-H2 supersedes R1's two-zone static composition with the live
    /// exchange board (E1). This now proves the board-first replacement
    /// structure instead of the retired zone layout.
    func testHomeUsesTheBoardFirstExchangeComposition() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        XCTAssertTrue(source.contains("GeometryReader { geometry in"))
        // W4-H3: content fills the viewport visible beneath the reserved band.
        XCTAssertTrue(source.contains(".frame(minHeight: max(0, geometry.size.height - headerBandHeight), alignment: .top)"))
        XCTAssertTrue(source.contains("continueHelpingSection"))
        XCTAssertTrue(source.contains("boardSection"))
        XCTAssertTrue(source.contains("home-request-a-meal"))
        XCTAssertFalse(source.contains("HomeActionRow"))
        XCTAssertFalse(source.contains("Text(\"More\")"))
        XCTAssertFalse(source.contains("Get alerts for new requests"))
        XCTAssertFalse(source.contains("Find a request"))
    }

    func testCompletionTransitionUsesTheSelectedSoftBrandSettleAndPreservesReduceMotion() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/ContentView.swift")

        XCTAssertTrue(source.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"))
        let storageSource = try fileSource("ios/CommonPlateios/CommonPlateios/Stores/OnboardingPresentationStorage.swift")

        XCTAssertTrue(source.contains("SoftBrandSettlePresentation("))
        XCTAssertTrue(source.contains("onboardingFlowCoordinator.isCompletingOnboarding"))
        XCTAssertTrue(source.contains("OnboardingWelcomeView(onContinue: {})"))
        XCTAssertTrue(source.contains("home(hasArrived)"))
        XCTAssertTrue(source.contains("hasArrived || reduceMotion ? 0 : -7"))
        XCTAssertTrue(source.contains(".easeInOut(duration: 0.31)"))
        XCTAssertTrue(source.contains(".offset(y: hasArrived || reduceMotion ? 0 : 9)"))
        XCTAssertTrue(source.contains("duration: 0.43"))
        XCTAssertTrue(source.contains("duration: 0.47"))
        XCTAssertTrue(source.contains(".offset(y: brandHasSettled || reduceMotion ? 0 : 2)"))
        XCTAssertTrue(source.contains(".easeInOut(duration: 0.17)"))
        XCTAssertTrue(source.contains("transaction.disablesAnimations = true"))
        XCTAssertTrue(source.contains("withTransaction(transaction)"))
        XCTAssertTrue(source.contains("path = []"))
        XCTAssertTrue(storageSource.contains("@Published private(set) var isCompletingOnboarding = false"))
        XCTAssertTrue(storageSource.contains("isCompletingOnboarding = true"))
        XCTAssertFalse(storageSource.contains("Task.yield"))
        XCTAssertFalse(storageSource.contains("sleep("))
    }

    func testFinalR1MotionAndNavigationSeamsStayDistinct() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/ContentView.swift")
        let onboarding = try fileSource("ios/CommonPlateios/CommonPlateios/Views/OnboardingExperienceView.swift")
        let requestEntry = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestFoodEntryView.swift")
        // W4-H2: both entry points relocated from Home to the shared
        // Settings route; the destination-building switch itself
        // (`case .onboardingChooser:` / `case .privacySafety:`) stays in
        // `ContentView` and is unchanged.
        let settings = try fileSource("ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift")

        XCTAssertTrue(source.contains("SoftFlowEnterDestination"))
        XCTAssertTrue(source.contains("case route(AppRoute)"))
        XCTAssertTrue(source.contains("duration: 0.28"))
        // W4-R2 2026-09-05 sync item 8: `SoftFlowEnterDestination` gained a
        // `playsOwnSettle` parameter (defaulting to `true`, so every route
        // besides `.requestFood` keeps this exact offset/gating behavior
        // unchanged) so Request Food's own local Bottom Continuity settle can
        // become the entrance's sole owner without duplicating this shared
        // wrapper's own settle/hit-testing gate.
        XCTAssertTrue(source.contains("offset(y: playsOwnSettle && !hasEntered && !reduceMotion ? 6 : 0)"))
        XCTAssertTrue(source.contains("var playsOwnSettle: Bool = true"))
        XCTAssertTrue(source.contains("playsOwnSettle: route != .requestFood"))
        XCTAssertTrue(source.contains(".allowsHitTesting(playsOwnSettle ? hasEntered : true)"))
        XCTAssertTrue(source.contains("flowPresentation = .route(route)\n            path = AppRoute.appending(route, to: path)"))
        XCTAssertTrue(source.contains("if case .route(let route)? = flowPresentation, newPath.last != route"))
        // W4-R2: Request Food is now pushed through the same typed
        // `AppRoute.requestFood` destination every other route uses —
        // superseding the former Home-owned sheet special-case — and exits
        // through the same `finishPrimaryRoute` truncation every other
        // primary route uses.
        XCTAssertFalse(source.contains("isRequestFoodPresented"))
        XCTAssertFalse(source.contains("requestFoodPresentationPath"))
        XCTAssertTrue(source.contains("case .requestFood:"))
        XCTAssertTrue(source.contains("onExit: { finishPrimaryRoute(.requestFood) }"))
        XCTAssertFalse(requestEntry.contains("Color.clear"))
        // The pushed destination must keep ParticipantVerificationView's own
        // NavigationStack behind the accepted modal boundary. Mounting it
        // directly inside ContentView's typed root stack makes an interactive
        // request-food push fail with AnyNavigationPath comparison mismatch.
        XCTAssertTrue(requestEntry.contains(".sheet(isPresented: isPresentingEntryVerification)"))
        XCTAssertTrue(requestEntry.contains("case .verification:\n                CommonPlateStyle.Color.baseCanvas"))
        // The form destination no longer wraps itself in a second, nested
        // `NavigationStack` now that it is pushed directly on the root one.
        XCTAssertFalse(requestEntry.contains("NavigationStack {"))
        XCTAssertFalse(source.contains("flowDestination(for:"))
        XCTAssertFalse(source.contains("if let flowPresentation {"))
        XCTAssertTrue(settings.contains("NavigationLink(value: AppRoute.howCommonPlateWorks)"))
        XCTAssertTrue(settings.contains("NavigationLink(value: AppRoute.privacySafety)"))
                XCTAssertTrue(onboarding.contains("CommonPlateWarmGhostBackButton"))
        XCTAssertTrue(onboarding.contains("Image(systemName: \"chevron.left\")"))
        XCTAssertTrue(onboarding.contains(".font(.system(size: 17, weight: .semibold))"))
        XCTAssertFalse(onboarding.contains(".font(.body.weight(.semibold))"))
        XCTAssertTrue(onboarding.contains("frame(width: 44, height: 44)"))
    }

    /// W4-R2 restyled these two fields into the approved `Requester / Form
    /// Field` bordered-card control (a `Menu` for meal swipes, matching the
    /// approved component's plain value display with no native
    /// `Picker`/list chrome) — the exact SwiftUI declaration this test
    /// pinned to before that restyle no longer exists. The substantive
    /// guarantee this test guards remains true and is asserted directly: the
    /// bounded meal-swipe range is unchanged, driven by the same
    /// `RequestFoodFormDraft.mealSwipeOptions`, and the accepted field labels
    /// are unchanged. The revised READY contract also removes the permanent
    /// meal-swipes helper sentence with no replacement, and the final R2
    /// contract renames the field label to `Name on order` with no separate
    /// timing-mixed sentence.
    func testRequesterGuidanceUsesTheAcceptedLabelsWithoutChangingThePickerRange() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift")

        XCTAssertTrue(source.contains("mealSwipesControl"))
        XCTAssertTrue(source.contains("static let mealSwipesLabel = \"Number of meal swipes\""))
        XCTAssertFalse(source.contains("Choose how many meal swipes your Grubhub order requires."))
        // W4-R4: pickup name is removed from the requester form entirely,
        // so the label it used no longer exists anywhere in this source.
        XCTAssertFalse(source.contains("pickupNameLabel"))
        XCTAssertFalse(source.contains("Name on order"))
        XCTAssertFalse(source.contains("Enter the name you want the Grubhub order placed under."))
        XCTAssertFalse(source.contains("The student placing the order will use this name and approximate time."))
        XCTAssertTrue(source.contains("RequestFoodFormDraft.mealSwipeOptions"))
    }

    /// W4-O1 F1: the Welcome `Grubhub` badge text must stay legible in dark
    /// appearance (the approved H1 light/dark Grubhub text values) while
    /// remaining text-only with no logo or third-party asset.
    func testGrubhubBadgeTextIsAppearanceAwareAndStaysTextOnly() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/OnboardingExperienceView.swift")
        let badge = try declarationSource(
            startMarker: "private struct GrubhubTextBadge: View {",
            endMarker: "/// One shared top anchor",
            in: source
        )

        XCTAssertTrue(badge.contains("traits.userInterfaceStyle == .dark"))
        XCTAssertTrue(badge.contains("UIColor(red: 1, green: 170 / 255, blue: 90 / 255, alpha: 1)"))
        XCTAssertTrue(badge.contains("UIColor(red: 156 / 255, green: 71 / 255, blue: 0, alpha: 1)"))
        XCTAssertTrue(badge.contains(".foregroundStyle(Self.text)"))
        XCTAssertFalse(badge.contains("Image("))
    }

    private func fileSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func declarationSource(
        startMarker: String,
        endMarker: String,
        in source: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let end = try XCTUnwrap(source.range(of: endMarker, range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }
}

private final class InMemoryOnboardingPresentationStorage: OnboardingPresentationStoring {
    var hasCompletedOnboarding = false
    var helpingDiscoveryRecord: HelpingDiscoveryRecord?
}
