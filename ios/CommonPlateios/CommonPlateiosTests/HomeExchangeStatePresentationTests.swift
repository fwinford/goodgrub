//
//  HomeExchangeStatePresentationTests.swift
//  CommonPlateiosTests
//
// W4-H2 focused coverage for the Exchange Unavailable recovery-cue delta and
// the Empty Exchange conditional Request Alerts promotion (HQ decisions 1
// and 2). Copy/predicate assertions exercise `HomeExchangeView`'s testable
// static surface directly; source-text assertions pin the Reduce Motion
// handling and canonical component reuse this target has no UI-test
// infrastructure to exercise interactively — following this file's existing
// `fileSource` precedent (see `OnboardingPresentationTests.swift`).
import Foundation
import XCTest
@testable import CommonPlateios

final class HomeExchangeStatePresentationTests: XCTestCase {
    // MARK: - Exchange Unavailable recovery cue

    func testUnavailableTitleIsTheApprovedTwoLineCue() {
        XCTAssertEqual(HomeExchangeView.unavailableTitle, "Helping is\ntemporarily unavailable")
    }

    func testRefreshCueTextIsExact() {
        XCTAssertEqual(HomeExchangeView.refreshCueText, "Pull down to refresh")
    }

    func testUnavailablePresentationHasNoTryAgainOrOldExplanatoryCopy() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        XCTAssertFalse(source.contains("unavailableBody"))
        XCTAssertFalse(source.contains("couldn’t load the exchange"))
        XCTAssertTrue(source.contains("PullRefreshCue()"))
    }

    /// CP2: only the unavailable cue's arrow makes two finite, small motions.
    /// Text remains static, Reduce Motion resets without animation, and native
    /// `.refreshable` remains the sole reload path.
    func testUnavailableRefreshCueAnimatesOnlyItsArrowTwiceAndStops() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        guard let cueRange = source.range(of: "private struct PullRefreshCue: View {"),
              let cueEnd = source.range(of: "/// Carries one refresh's own", range: cueRange.upperBound..<source.endIndex)
        else {
            return XCTFail("expected PullRefreshCue to be defined")
        }
        let cueBody = source[cueRange.lowerBound..<cueEnd.lowerBound]
        XCTAssertFalse(cueBody.contains("fetchRequests()"))
        XCTAssertEqual(cueBody.components(separatedBy: "Image(systemName:").count - 1, 1, "expected exactly one arrow in the cue")
        XCTAssertEqual(cueBody.components(separatedBy: ".offset(y: arrowOffset)").count - 1, 1)
        XCTAssertTrue(cueBody.contains(".task(id: reduceMotion)"))
        XCTAssertTrue(cueBody.contains("guard !reduceMotion else { return }"))
        XCTAssertTrue(cueBody.contains("transaction.disablesAnimations = true"))
        XCTAssertTrue(cueBody.contains("for _ in 0..<HomeExchangeView.unavailableArrowPulseCount"))
        XCTAssertTrue(cueBody.contains("arrowOffset = HomeExchangeView.unavailableArrowTravel"))
        XCTAssertTrue(cueBody.contains("arrowOffset = 0"))
        XCTAssertTrue(cueBody.contains(".easeInOut(duration: HomeExchangeView.unavailableArrowPulseDuration)"))
        XCTAssertFalse(cueBody.contains("repeatForever"))
        XCTAssertFalse(cueBody.contains("while true"))
        XCTAssertEqual(HomeExchangeView.unavailableArrowPulseCount, 2)
        XCTAssertEqual(HomeExchangeView.unavailableArrowTravel, 4)
        XCTAssertEqual(HomeExchangeView.refreshCueText, "Pull down to refresh")
        XCTAssertFalse(source.contains("PullRefreshPhase"))
        XCTAssertFalse(source.contains("case releaseThreshold"))
        XCTAssertFalse(source.contains("releaseToRefreshText"))
        XCTAssertFalse(source.contains("DragGesture"))
        XCTAssertFalse(source.contains("scrollCoordinateSpace"))
        XCTAssertFalse(source.contains("pullOffset"))
        XCTAssertFalse(source.contains("pullDisplacement"))
        XCTAssertFalse(source.contains("HomeExchangePullOffsetKey"))
    }

    /// W4-H3: healthy refresh has no authored arrow, banner, or `Refreshing…`
    /// copy — the native indicator is the only loading affordance.
    func testNoAuthoredRefreshBannerOrRefreshingCopyExists() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        XCTAssertFalse(source.contains("refreshFeedbackBanner"))
        XCTAssertFalse(source.contains("Refreshing…"))
        XCTAssertFalse(source.contains("refreshingText"))
    }

    /// W4-H3: success acknowledgment is gated on the refresh operation's own
    /// truthful outcome, never on how Home happens to look afterwards. The
    /// H2 recovery-only gate (`wasUnavailable`) and the Unavailable-presentation
    /// hold that deferred the refreshed hierarchy are gone.
    func testSuccessAcknowledgmentIsGatedOnTheRefreshOperationsOwnOutcome() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        XCTAssertTrue(source.contains("guard fetchOutcome == .succeeded else { return false }"))
        XCTAssertTrue(source.contains("case .empty, .populated: return true"))
        XCTAssertTrue(source.contains("case .loading, .unavailable: return false"))
        XCTAssertTrue(source.contains("guard didResolveInTime else { return false }"))
        XCTAssertFalse(source.contains("store.hasSuccessfullyFetchedRequests && store.refreshError == nil"))
        XCTAssertFalse(source.contains("wasUnavailable"))
        XCTAssertFalse(source.contains("unavailableRefreshHold"))
        XCTAssertFalse(source.contains("isShowingRecoverySuccess"))
        XCTAssertFalse(source.contains("shouldShowRecoverySuccess"))
        XCTAssertFalse(source.contains("RecoverySuccessMark"))
    }

    /// Simulator FIX: physical pull-to-refresh could not be initiated at all
    /// on short-content states (Unavailable/Empty, and in practice most
    /// Populated/Low Activity boards) because `.frame(minHeight:
    /// geometry.size.height)` makes the ScrollView's content exactly fill
    /// the viewport, and UIKit only allows the rubber-banding drag
    /// `.refreshable` depends on when content overflows the frame.
    /// `.scrollBounceBehavior(.always, ...)` restores physical pullability
    /// regardless of content length without introducing any custom gesture,
    /// threshold, or second refresh trigger.
    func testExchangeScrollViewAlwaysAllowsVerticalBounceRegardlessOfContentLength() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        XCTAssertTrue(source.contains(".scrollBounceBehavior(.always, axes: .vertical)"))
        // The bounce modifier must sit between the ScrollView and
        // `.refreshable` (i.e. before it in the same modifier chain) rather
        // than on some unrelated view.
        guard let bounceRange = source.range(of: ".scrollBounceBehavior(.always, axes: .vertical)"),
              let refreshableRange = source.range(of: ".refreshable {", range: bounceRange.upperBound..<source.endIndex) else {
            return XCTFail("expected .scrollBounceBehavior to immediately precede .refreshable on the same scroll view")
        }
        XCTAssertLessThan(bounceRange.upperBound, refreshableRange.lowerBound)
    }

    func testUnavailableRefreshReusesTheExistingAuthoritativeReloadPath() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        // Exactly one `.refreshable` on the shared scroll view backs every
        // Home state, including Unavailable; no second reload/cache/source
        // of truth is introduced for this delta.
        let refreshableOccurrences = source.components(separatedBy: ".refreshable {").count - 1
        XCTAssertEqual(refreshableOccurrences, 1)
        XCTAssertTrue(source.contains("await store.fetchRequests()"))
    }

    // MARK: - Empty Exchange conditional Request Alerts promotion

    func testStablePushOnHidesTheSupportingPromptAndRequestAlertsAction() {
        XCTAssertFalse(HomeExchangeView.showsRequestAlertsPromotion(pushState: .on))
    }

    func testEveryNonOnPushStateShowsTheSupportingPromptAndRequestAlertsAction() {
        let nonOnStates: [PushPreferenceState] = [
            .off,
            .settingUp,
            .denied,
            .failed,
            .ambiguous(desiredEnabled: true),
            .ambiguous(desiredEnabled: false)
        ]

        for state in nonOnStates {
            XCTAssertTrue(
                HomeExchangeView.showsRequestAlertsPromotion(pushState: state),
                "expected \(state) to keep the Request Alerts promotion visible"
            )
        }
    }

    func testEmptyExchangeConditionReadsPushSubscriptionStoreStateDirectly() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        XCTAssertTrue(source.contains("showsRequestAlertsPromotion(pushState: pushSubscriptionStore.state)"))
        XCTAssertTrue(source.contains("pushState != .on"))
        // No Apple/iOS permission or Email-state substitute for the Push
        // authority, and no second Home-local boolean/source of truth.
        XCTAssertFalse(source.contains("isPushEnabled"))
        XCTAssertFalse(source.contains("UNAuthorizationStatus"))
        XCTAssertFalse(source.contains("alertSubscriptionStore.state"))
    }

    func testEmptyExchangeNeverShowsTheUnavailableRefreshCue() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        guard let emptyStateRange = source.range(of: "private func emptyState(minHeight: CGFloat)"),
              let unavailableStateRange = source.range(of: "private var unavailableState: some View {") else {
            return XCTFail("expected both emptyState and unavailableState to be present")
        }
        let emptyStateBody = source[emptyStateRange.upperBound..<unavailableStateRange.lowerBound]

        // Search for the call, not the bare identifier: `unavailableState`'s
        // own doc comment mentions `PullToRefreshCue` by name, and that
        // comment sits inside this same slice (immediately above the
        // `unavailableState` declaration the slice ends at).
        XCTAssertFalse(emptyStateBody.contains("PullToRefreshCue()"))
        XCTAssertFalse(emptyStateBody.contains(HomeExchangeView.refreshCueText))
    }

    func testEmptyStateCompositionReservesRemainingSpaceAboveThePersistentAction() throws {
        let available = HomeExchangeView.emptyStateMinimumHeight(
            viewportHeight: 844,
            headerBandHeight: 60,
            boardSectionTop: 400
        )
        XCTAssertEqual(
            available,
            844 - 60 - 400 - HomeExchangeView.emptyStateFooterClearance,
            accuracy: 0.001
        )
        XCTAssertEqual(
            HomeExchangeView.emptyStateMinimumHeight(
                viewportHeight: 500,
                headerBandHeight: 60,
                boardSectionTop: 500
            ),
            0
        )
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")
        let emptyState = try XCTUnwrap(source.range(of: "private func emptyState(minHeight: CGFloat)"))
        let padding = try XCTUnwrap(source.range(
            of: ".padding(.vertical, CommonPlateStyle.Spacing.xl)",
            range: emptyState.upperBound..<source.endIndex
        ))
        let minimumFrame = try XCTUnwrap(source.range(of: ".frame(minHeight: minHeight, alignment: .center)", range: padding.upperBound..<source.endIndex))
        XCTAssertLessThan(padding.lowerBound, minimumFrame.lowerBound)
        XCTAssertTrue(source.contains("boardSectionTop: boardSectionTopInContent"))
        XCTAssertTrue(source.contains("private var requestMealButtonContent: some View"))
    }

    // MARK: - Shared Empty/Unavailable visual grammar

    func testEmptyAndUnavailableShareTheStateContentWidthAndTitleTypography() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        XCTAssertEqual(
            source.components(separatedBy: "CommonPlateStyle.Metrics.stateContentWidth").count - 1,
            6,
            "expected the shared content-width token on the title group, title, supporting text, Push controls, and confirmation"
        )
        XCTAssertEqual(
            source.components(separatedBy: ".font(.headline.weight(.bold))").count - 1,
            2,
            "expected the shared 17pt-bold state-title grammar on both empty and unavailable titles"
        )
    }

    func testStateContentWidthTokenMatchesApprovedFigma() {
        XCTAssertEqual(CommonPlateStyle.Metrics.stateContentWidth, 322)
    }

    func testHomeUsesDirectSharedPushControlWithoutPresentingAnOverlay() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")
        XCTAssertTrue(source.contains("PushNotificationSection("))
        XCTAssertTrue(source.contains("store: pushSubscriptionStore,"))
        XCTAssertTrue(source.contains("isHomePromotion: true,"))
        XCTAssertFalse(source.contains("RequestAlertsOverlayView("))
        XCTAssertFalse(source.contains("isPresentingRequestAlerts"))
    }

    // MARK: - Close / Disclosure fidelity

    func testRequestAlertsOverlayUsesTheCanonicalCloseControl() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestAlertsOverlayView.swift")

        XCTAssertTrue(source.contains("CommonPlateCloseControl(action: dismiss)"))
        XCTAssertFalse(source.contains("Image(systemName: \"xmark\")"))
    }

    func testSettingsRowsUseTheCanonicalDisclosureIndicator() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift")

        XCTAssertTrue(source.contains("CommonPlateDisclosureIndicator()"))
        XCTAssertFalse(source.contains("Image(systemName: \"chevron.right\")"))
    }

    func testCommonPlateCloseControlIsA44By44InteractionTarget() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Design/CommonPlateCloseControl.swift")

        XCTAssertTrue(source.contains(".frame(width: 44, height: 44)"))
        XCTAssertTrue(source.contains("Image(systemName: \"xmark\")"))
    }

    func testCommonPlateDisclosureIndicatorIsA44By44AlignmentFrame() throws {
        let source = try fileSource(
            "ios/CommonPlateios/CommonPlateios/Design/CommonPlateDisclosureIndicator.swift"
        )

        XCTAssertTrue(source.contains(".frame(width: 44, height: 44)"))
        XCTAssertTrue(source.contains("Image(systemName: \"chevron.right\")"))
    }

    func testHomeHelpingCardHasNoDisclosureChevron() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/RequestCardView.swift")

        XCTAssertFalse(source.contains("Image(systemName: \"chevron.right\")"))
        XCTAssertFalse(source.contains("CommonPlateDisclosureIndicator"))
        let links = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HelperContinuationsListView.swift")
        XCTAssertTrue(links.contains("HelperContinuationCardButtonStyle()"))
        XCTAssertTrue(links.contains(".opacity(configuration.isPressed ? 0.84 : 1)"))
        XCTAssertTrue(links.contains("@Environment(\\.accessibilityReduceMotion)"))
    }

    // MARK: - Request a Meal typography

    /// The Request a Meal label must not set its own `.font()`: any inner
    /// modifier on the Text would win over `commonPlateMajorPrimaryAction`'s
    /// `.title3.weight(.semibold)` (~20pt) major-action style and silently
    /// shrink the CTA back to `.body` (~17pt).
    func testRequestAMealLabelDefersItsFontToTheMajorPrimaryActionStyle() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        guard let buttonRange = source.range(of: "Text(\"＋  Request a Meal\")") else {
            return XCTFail("expected the Request a Meal label to be present")
        }
        let afterLabel = source[buttonRange.upperBound...].prefix(80)
        XCTAssertFalse(afterLabel.contains(".font("))
        XCTAssertTrue(source.contains(".commonPlateMajorPrimaryAction()"))
    }

    // MARK: - Loading state stability / retry-preserves-Unavailable fix

    /// `Needs help` must never disappear from Home, including during the
    /// very first load — the bug Faith observed in the simulator was the
    /// bare loading spinner replacing the whole board hierarchy.
    /// HQ decision 3 restructuring: `boardHeadingRow` now renders once,
    /// outside the inner refreshable `ScrollView`, and `boardHeading` derives
    /// the exact text for every board state (including `.loading`) from one
    /// shared switch — so `Needs help` is structurally guaranteed present,
    /// rather than relying on each state branch to repeat its own heading.
    func testLoadingStateKeepsTheSameBoardHeadingAsEveryOtherState() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        XCTAssertEqual(
            source.components(separatedBy: "accessibilityIdentifier(\"home-board-heading\")").count - 1,
            1,
            "expected exactly one shared board heading identifier, rendered outside the refreshable region"
        )
        XCTAssertTrue(source.contains("private var boardHeadingRow: some View {"))
        XCTAssertTrue(source.contains("case .loading:\n            return Self.loadingHeading"))
    }

    /// The pure `boardState` derivation must consult
    /// `hasFailedInitialFetchAtLeastOnce`, not just `isFetching`, so a
    /// pull-to-refresh retry from an already-resolved Exchange Unavailable
    /// stays on that presentation instead of regressing to bare Loading.
    func testBoardStateRetryDerivationReadsFailureHistoryNotJustFetchingFlag() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        XCTAssertTrue(source.contains("hasFailedInitialFetchAtLeastOnce: Bool"))
        XCTAssertTrue(source.contains("if hasFailedInitialFetchAtLeastOnce {\n                return .unavailable\n            }"))
    }

    // MARK: - Settings Request Alerts compact entry (HQ decision 4)

    /// HQ decision 4 supersedes the prior "inline...for later management"
    /// reading: Settings must not embed any of `AlertSignupView`'s form —
    /// full or compact — by default. Faith's simulator finding was that
    /// Settings still felt like the legacy signup screen even collapsed to
    /// one row. `AlertSignupView` itself must therefore carry no
    /// Settings-specific compact-embed mode at all.
    func testAlertSignupViewCarriesNoCompactEmbedMode() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/AlertSignupView.swift")

        XCTAssertFalse(source.contains("isCompactEmbed"))
        XCTAssertFalse(source.contains("compactEntryRow"))
        XCTAssertFalse(source.contains("isCompactEntryExpanded"))
        XCTAssertFalse(source.contains("compactEntrySetUpTitle"))
    }

    /// Final H2 visual alignment FIX: Settings presents Email/Push as the
    /// approved Figma `Control / Toggle` rows — no embedded `AlertSignupView`
    /// in any mode, and no "Set up"/"Manage" row button — and turning either
    /// toggle toward On opens the already-approved focused
    /// `RequestAlertsOverlayView`, exactly as Empty Exchange's own quick
    /// entry already does, rather than expanding a second copy of setup UI
    /// inline or creating a new permanent navigation destination.
    func testSettingsRequestAlertsUsesInlinePushInsteadOfTheHomeOverlay() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift")

        XCTAssertFalse(source.contains("AlertSignupView("))
        XCTAssertTrue(source.contains("@State private var isPresentingRequestAlerts = false"))
        XCTAssertTrue(source.contains("isPresentingRequestAlerts = true"))
        XCTAssertFalse(source.contains("RequestAlertsOverlayView("))
        XCTAssertTrue(source.contains("PushNotificationSection(store: pushSubscriptionStore)"))
        // Faith-selected V1 Settings presents only the Push toggle.
        XCTAssertFalse(source.contains("settings-email-alerts-toggle"))
        let pushSource = try fileSource("ios/CommonPlateios/CommonPlateios/Views/PushNotificationSection.swift")
        XCTAssertTrue(pushSource.contains("settings-push-alerts-toggle"))
        // Superseded compact-row wording (HQ decision 4's own intermediate
        // step): no row button, and no "Set up"/"Manage" action label.
        XCTAssertFalse(source.contains("settings-request-alerts\""))
        XCTAssertFalse(source.contains("requestAlertsCompactActionTitle"))

        // No new/permanent navigation destination: the overlay is presented
        // directly over Settings (a local `@State` boolean + `ZStack`), not
        // routed through `AppRoute` or `NavigationLink`.
        let requestAlerts = try declarationSource(
            startMarker: "private var requestAlertsSection: some View {",
            endMarker: "// MARK: - About & Help",
            in: "ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift"
        )
        XCTAssertFalse(requestAlerts.contains("NavigationLink"))
        XCTAssertFalse(requestAlerts.contains("AppRoute"))
    }

    /// The approved Figma `Control / Toggle` is binary truth only: the Email
    /// row must read exclusively from the W4-N0 authoritative
    /// `emailAlertStateStore.state`, never from `AlertSubscriptionStore`
    /// signup-presentation-history state, and the Push row must read
    /// exclusively from the existing accepted `pushSubscriptionStore.state`.
    func testRequestAlertsTogglesReadOnlyAuthoritativeStateNotPresentationHistory() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift")

        XCTAssertEqual(SettingsView.isEmailToggleOn(.active), true)
        XCTAssertEqual(SettingsView.isEmailToggleOn(.inactive), false)
        XCTAssertEqual(SettingsView.isEmailToggleOn(.unknown), false)
        XCTAssertEqual(SettingsView.isPushToggleOn(.on), true)
        XCTAssertEqual(SettingsView.isPushToggleOn(.off), false)
        XCTAssertTrue(source.contains("PushNotificationSection(store: pushSubscriptionStore)"))
        let pushSource = try fileSource("ios/CommonPlateios/CommonPlateios/Views/PushNotificationSection.swift")
        XCTAssertTrue(pushSource.contains("get: { store.state == .on }"))
        // Mentioned only in doc comments explaining what the toggle must
        // *not* read from; never actually referenced as code.
        XCTAssertFalse(source.contains("get: { alertSubscriptionStore.phase"))
        XCTAssertFalse(source.contains("== alertSubscriptionStore.phase"))
    }

    private func declarationSource(
        startMarker: String,
        endMarker: String,
        in relativePath: String
    ) throws -> String {
        let source = try fileSource(relativePath)
        let start = try XCTUnwrap(source.range(of: startMarker))
        let end = try XCTUnwrap(source.range(of: endMarker, range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }

    // MARK: - Base canvas warmth

    /// The "still feels incredibly white" simulator finding: `baseCanvas`
    /// claimed to be a "warm-neutral system foundation" but was wired to
    /// plain `.systemBackground`. It must now use the dedicated asset
    /// carrying the approved Figma page-background token
    /// (`var(--h2-color-background)`, `#fbf9f6`), and must stay distinct
    /// from `warmSurface`'s own bounded-block asset.
    func testBaseCanvasUsesTheWarmPageBackgroundAssetNotSystemBackground() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Design/CommonPlateStyle.swift")

        XCTAssertTrue(source.contains("static let baseCanvas = SwiftUI.Color(\"CommonPlateBaseCanvas\")"))
        XCTAssertFalse(source.contains("static let baseCanvas = SwiftUI.Color(uiColor: .systemBackground)"))
    }

    func testBaseCanvasAssetMatchesTheApprovedFigmaPageBackgroundHex() throws {
        // #fbf9f6 -> (0.984, 0.976, 0.965), the same rounding convention
        // `CommonPlateWarmSurface.colorset` already uses.
        let source = try fileSource(
            "ios/CommonPlateios/CommonPlateios/Assets.xcassets/CommonPlateBaseCanvas.colorset/Contents.json"
        )

        XCTAssertTrue(source.contains("\"red\" : \"0.984\""))
        XCTAssertTrue(source.contains("\"green\" : \"0.976\""))
        XCTAssertTrue(source.contains("\"blue\" : \"0.965\""))
    }

    /// HQ decision 4: no tinted card, and no embedded form of any kind —
    /// the row itself uses the same flat/native treatment as Identity and
    /// About & Help.
    func testSettingsRequestAlertsRowUsesNoTintedCardOrEmbeddedForm() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/SettingsView.swift")

        XCTAssertFalse(source.contains("settingsRowSurface"))
        XCTAssertFalse(source.contains("title: \"Email\""))
        XCTAssertFalse(source.contains("AlertSignupView("))
    }

    private func fileSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
