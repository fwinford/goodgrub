//
//  HomeExchangeRefreshDeadlineTests.swift
//  CommonPlateiosTests
//
// W4-H2-FIX (manual refresh timeout + final cue transition): focused
// source-text coverage for HQ decision 8 (the 5-second manual-refresh
// deadline), the stale/cancel safety it relies on, and the pull-arrow →
// refresh-symbol transition/text-ghosting correction. This target has no UI
// test infrastructure to drive `.refreshable` interactively, so — following
// `HomeExchangeStatePresentationTests`'s existing precedent — these
// assertions pin the production source directly.
import Foundation
import XCTest
@testable import CommonPlateios

final class HomeExchangeRefreshDeadlineTests: XCTestCase {
    // MARK: - Manual refresh deadline (HQ decision 8)

    func testManualRefreshDeadlineIsFiveSeconds() {
        XCTAssertEqual(HomeExchangeView.manualRefreshDeadline, .seconds(5))
    }

    /// The initial-load deadline (HQ decision 5) and the manual-refresh
    /// deadline (HQ decision 8) are two distinct bounded presentation
    /// lifetimes; they must not collapse into a single shared flag/authority.
    func testInitialLoadAndManualRefreshDeadlinesAreDistinct() {
        XCTAssertEqual(HomeExchangeView.initialLoadDeadline, .seconds(5))
        XCTAssertEqual(HomeExchangeView.manualRefreshDeadline, .seconds(5))
    }

    func testPerformAuthoredRefreshRacesTheFetchAgainstTheManualDeadline() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        XCTAssertTrue(source.contains(
            "let didResolveInTime = await Self.awaitWithDeadline(deadline) {"
        ))
        // The race's deadline defaults to the one 5-second manual deadline,
        // and the view's refresh closure passes no other value.
        XCTAssertTrue(source.contains("deadline: Duration = manualRefreshDeadline"))
        XCTAssertTrue(source.contains("await Self.resolveRefresh(store: store)"))
        // The deadline outcome feeds the success predicate, whose first
        // guard rejects any unresolved (timed-out) refresh.
        XCTAssertTrue(source.contains("didResolveInTime: didResolveInTime,"))
        XCTAssertTrue(source.contains("guard didResolveInTime else { return false }"))
    }

    /// Cancellation/stale-result correctness relies entirely on
    /// `RequestStore`'s own existing `fetchGeneration`/`collectionRevision`
    /// fence — this delta introduces no second request-list truth owner and
    /// no independent reload/timeout authority in the store.
    func testAwaitWithDeadlineCancelsTheLoserAndInvokesNoSecondReloadAuthority() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        // W4-H4 physical-device FIX: now `internal` rather than `private`, so
        // `HomeRefreshCallerCancellationTests` can exercise the real race
        // instead of only pinning its source. The loser-cancellation
        // guarantee this test exists for is unchanged.
        XCTAssertTrue(source.contains("static func awaitWithDeadline("))
        XCTAssertTrue(source.contains("withTaskGroup(of: Bool.self)"))
        XCTAssertTrue(source.contains("group.cancelAll()"))

        // Exactly two call sites invoke the one authoritative reload directly
        // — the initial-appearance `.task` and the refresh closure the
        // deadline race wraps — and no independent reload/truth authority is
        // added beyond that same existing path.
        let reloadOccurrences = source.components(separatedBy: "await store.fetchRequests()").count - 1
        XCTAssertEqual(reloadOccurrences, 2)

        // The participant-identity-change re-key reaches that same reload
        // through `RequestStore.reconcileOwnershipForCurrentAuthority()`,
        // which invalidates the previous authority's caller-relative
        // ownership and then delegates to `fetchRequests()` itself. It is a
        // third *entry point* to the one existing reload, not a second
        // request-list truth owner.
        let reconcileOccurrences = source
            .components(separatedBy: "await store.reconcileOwnershipForCurrentAuthority()").count - 1
        XCTAssertEqual(reconcileOccurrences, 1)
    }

    /// A refresh that times out ends the refresh interaction without a
    /// success acknowledgment: the acknowledgment is reachable only through
    /// `shouldAcknowledgeRefreshSuccess`, whose `didResolveInTime` guard
    /// rejects an unresolved refresh before anything else is evaluated, and
    /// the fetch outcome is read only when the race reports the fetch itself
    /// finished first.
    func testTimeoutNeverReachesTheSuccessAcknowledgment() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        guard let resolveRange = source.range(of: "static func resolveRefresh("),
              let outcomeReadRange = source.range(
                of: "if didResolveInTime {\n            fetchOutcome = await outcomeRecorder.outcome",
                range: resolveRange.upperBound..<source.endIndex
              ),
              let predicateCallRange = source.range(
                of: "return shouldAcknowledgeRefreshSuccess(",
                range: resolveRange.upperBound..<source.endIndex
              ),
              let guardRange = source.range(
                of: "guard didResolveInTime else { return false }",
                range: predicateCallRange.upperBound..<source.endIndex
              )
        else {
            return XCTFail("expected resolveRefresh to read the outcome only after the deadline race and then apply the success predicate")
        }

        XCTAssertLessThan(outcomeReadRange.upperBound, predicateCallRange.lowerBound)
        XCTAssertLessThan(predicateCallRange.upperBound, guardRange.lowerBound, "predicate body follows resolveRefresh")
        XCTAssertTrue(source[predicateCallRange.lowerBound..<guardRange.lowerBound].contains("didResolveInTime: didResolveInTime"))

        // The authored settle (and with it the acknowledgment) is begun only
        // behind that result.
        guard let performRange = source.range(of: "private func performAuthoredRefresh() async {"),
              let gateRange = source.range(of: "if acknowledgesSuccess {", range: performRange.upperBound..<source.endIndex),
              let presentRange = source.range(of: "beginRefreshSettle()", range: gateRange.upperBound..<source.endIndex)
        else {
            return XCTFail("expected beginRefreshSettle() to be gated on acknowledgesSuccess")
        }
        XCTAssertLessThan(gateRange.upperBound, presentRange.lowerBound)
        XCTAssertEqual(
            source.components(separatedBy: "beginRefreshSettle()").count - 1,
            2,
            "expected exactly one declaration and one gated call site"
        )
    }

    // MARK: - Authored spinner removed (W4-H3)

    /// W4-H3: the native system indicator is the only loading affordance, so
    /// the authored arrow-to-spinner morph and its delayed spin start no
    /// longer exist.
    func testAuthoredSpinnerAndSymbolMorphAreGone() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        XCTAssertFalse(source.contains("symbolMorphDuration"))
        XCTAssertFalse(source.contains("spinGeneration"))
        XCTAssertFalse(source.contains("arrow.triangle.2.circlepath"))
    }

    // MARK: - Text ghosting

    /// Faith's screenshot showed `Refreshing`/`Pull down to refresh` reading
    /// simultaneously. `.contentTransition(.opacity)` on the cue's `Text`
    /// crossfades the old and new strings on top of each other while the
    /// symbol carries the authored motion instead; the fix is a clean,
    /// non-animated text swap.
    func testRefreshCueTextHasNoCrossfadeContentTransition() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        guard let cueRange = source.range(of: "private struct PullRefreshCue: View {") else {
            return XCTFail("expected PullRefreshCue to be defined")
        }
        let cueBody = source[cueRange.lowerBound...]
        XCTAssertFalse(cueBody.contains(".contentTransition(.opacity)"))
    }

    // MARK: - Success mark is opacity-only (W4-H3)

    /// The selected micro-check is opacity-only: no symbol bounce/effect, no
    /// scale, no offset animation, and no haptic — under every motion
    /// preference, since Reduce Motion authorizes no separate variant.
    func testSuccessMarkIsOpacityOnlyWithNoBounceScaleOrHaptic() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        XCTAssertFalse(source.contains(".symbolEffect"))
        XCTAssertFalse(source.contains("scaleEffect"))
        XCTAssertFalse(source.contains("UIImpactFeedbackGenerator"))
        XCTAssertFalse(source.contains("UINotificationFeedbackGenerator"))
        XCTAssertFalse(source.contains("sensoryFeedback"))
        guard let markRange = source.range(of: "private var refreshSuccessMark: some View {"),
              let markEnd = source.range(of: "static let refreshSuccessMarkSide", range: markRange.upperBound..<source.endIndex)
        else {
            return XCTFail("expected refreshSuccessMark")
        }
        let mark = source[markRange.lowerBound..<markEnd.lowerBound]
        XCTAssertTrue(mark.contains(".opacity(isShowingRefreshSuccess ? 1 : 0)"))
        XCTAssertFalse(mark.contains("reduceMotion"))
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
