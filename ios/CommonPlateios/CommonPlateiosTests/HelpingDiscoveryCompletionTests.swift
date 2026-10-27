//
//  HelpingDiscoveryCompletionTests.swift
//  CommonPlateiosTests
//
// W4-O1 focused proof: first-eligible-request discovery completes only when
// the student opens an eligible request from a Home `Needs help` card while
// the treatment is active — never from navigation that merely reaches the
// same request detail.

import XCTest
@testable import CommonPlateios

@MainActor
final class HelpingDiscoveryCompletionTests: XCTestCase {
    private final class MemoryStorage: OnboardingPresentationStoring {
        var hasCompletedOnboarding = false
        var helpingDiscoveryRecord: HelpingDiscoveryRecord?
    }

    private func request(_ id: String, _ ownership: RequestOwnership = .notOwn) -> FoodRequest {
        FoodRequest(
            id: id,
            diningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            foodDescription: "Rice bowl",
            pickupWindowText: "ASAP",
            mealSwipes: 1,
            windowStart: nil,
            windowEnd: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: Date().addingTimeInterval(3600),
            status: .open,
            ownership: ownership
        )
    }

    private func eligible(_ requests: [FoodRequest]) -> [FoodRequest] {
        HelpingDiscovery.eligibleRequests(boardState: .populated(requests))
    }

    /// Mirrors ContentView's wiring: the card tap supplies the marker, the
    /// resulting path change asks `shouldComplete`, and a `true` result
    /// persists completion.
    private func openRequest(
        store: OnboardingPresentationStore,
        cardMarker: String?,
        path: [AppRoute],
        board: [FoodRequest]
    ) {
        if HelpingDiscovery.shouldComplete(
            isPending: store.isHelpingDiscoveryPending,
            openedFromHomeCardID: cardMarker,
            newPath: path,
            eligible: eligible(board)
        ) {
            store.completeHelpingDiscovery()
        }
    }

    private func pendingStore() -> (OnboardingPresentationStore, MemoryStorage) {
        let storage = MemoryStorage()
        let store = OnboardingPresentationStore(storage: storage)
        store.completeOnboarding()
        return (store, storage)
    }

    func testOpeningTheHighlightedEligibleHomeCardCompletesDiscovery() {
        let board = [request("a"), request("b")]
        let (store, storage) = pendingStore()
        XCTAssertEqual(
            HelpingDiscovery.selectedRequestID(isPending: true, hasActiveReservation: false, eligible: eligible(board)),
            "a"
        )

        openRequest(store: store, cardMarker: "a", path: [.requestDetail(board[0])], board: board)

        XCTAssertFalse(store.isHelpingDiscoveryPending)
        XCTAssertEqual(storage.helpingDiscoveryRecord, .complete)
    }

    func testOpeningADifferentEligibleHomeCardAlsoCompletesDiscovery() {
        let board = [request("a"), request("b")]
        let (store, storage) = pendingStore()

        openRequest(store: store, cardMarker: "b", path: [.requestDetail(board[1])], board: board)

        XCTAssertFalse(store.isHelpingDiscoveryPending)
        XCTAssertEqual(storage.helpingDiscoveryRecord, .complete)
    }

    func testRequestDetailNavigationWithoutAHomeCardOpenDoesNotComplete() {
        let board = [request("a"), request("b")]
        let (store, storage) = pendingStore()

        // The same eligible request detail reached by a notification or deep
        // link carries no Home-card marker.
        openRequest(store: store, cardMarker: nil, path: [.requestDetail(board[0])], board: board)

        XCTAssertTrue(store.isHelpingDiscoveryPending)
        XCTAssertEqual(storage.helpingDiscoveryRecord, .pending)
    }

    func testOwnOrIneligibleRequestDoesNotComplete() {
        let board = [request("own", .own), request("a")]
        let (store, storage) = pendingStore()

        // Even with a card marker, an own request is not in the eligible set.
        openRequest(store: store, cardMarker: "own", path: [.requestDetail(board[0])], board: board)
        XCTAssertTrue(store.isHelpingDiscoveryPending)

        // A request that has left the board is not eligible either.
        openRequest(store: store, cardMarker: "gone", path: [.requestDetail(request("gone"))], board: board)
        XCTAssertTrue(store.isHelpingDiscoveryPending)
        XCTAssertEqual(storage.helpingDiscoveryRecord, .pending)
    }

    func testUnrelatedNavigationOrMismatchedMarkerDoesNotComplete() {
        let board = [request("a"), request("b")]
        let (store, _) = pendingStore()

        // Settings and other non-detail destinations.
        openRequest(store: store, cardMarker: "a", path: [.settings], board: board)
        openRequest(store: store, cardMarker: nil, path: [.howCommonPlateWorks], board: board)
        // A marker for one card cannot complete via a different detail.
        openRequest(store: store, cardMarker: "a", path: [.requestDetail(board[1])], board: board)
        // Deeper paths are not a direct Home-card open.
        openRequest(store: store, cardMarker: "a", path: [.settings, .requestDetail(board[0])], board: board)

        XCTAssertTrue(store.isHelpingDiscoveryPending)
    }

    func testNotPendingNeverCompletesAndGrandfatheredStaysUntouched() {
        let board = [request("a")]
        XCTAssertFalse(HelpingDiscovery.shouldComplete(
            isPending: false,
            openedFromHomeCardID: "a",
            newPath: [.requestDetail(board[0])],
            eligible: eligible(board)
        ))

        let storage = MemoryStorage()
        storage.hasCompletedOnboarding = true
        let store = OnboardingPresentationStore(storage: storage)
        openRequest(store: store, cardMarker: "a", path: [.requestDetail(board[0])], board: board)
        XCTAssertNil(storage.helpingDiscoveryRecord)
        XCTAssertFalse(store.isHelpingDiscoveryPending)
    }

    func testCompletionPersistsAcrossRelaunchAndNeverRecurs() {
        let board = [request("a")]
        let (store, storage) = pendingStore()
        openRequest(store: store, cardMarker: "a", path: [.requestDetail(board[0])], board: board)

        let relaunched = OnboardingPresentationStore(storage: storage)
        XCTAssertTrue(relaunched.hasCompletedOnboarding)
        XCTAssertFalse(relaunched.isHelpingDiscoveryPending)
        XCTAssertNil(HelpingDiscovery.selectedRequestID(
            isPending: relaunched.isHelpingDiscoveryPending,
            hasActiveReservation: false,
            eligible: eligible(board)
        ))
    }

    // MARK: - Structure

    /// Accessibility-size QA found the decorative cue and fixed-size icon /
    /// number tiles outgrowing their containers; each is capped.
    func testDecorativeCueAndFixedTileGlyphsCapDynamicType() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios/Views")
        let cap = ".dynamicTypeSize(...DynamicTypeSize.xxxLarge)"
        let home = try String(contentsOf: views.appendingPathComponent("HomeExchangeView.swift"), encoding: .utf8)
        let cueRange = try XCTUnwrap(home.range(of: "Text(\"View request\")"))
        XCTAssertTrue(home[cueRange.upperBound...].prefix(400).contains(cap))
        let welcome = try String(contentsOf: views.appendingPathComponent("OnboardingExperienceView.swift"), encoding: .utf8)
        XCTAssertTrue(welcome.contains(cap))
        let reference = try String(contentsOf: views.appendingPathComponent("HowCommonPlateWorksViews.swift"), encoding: .utf8)
        XCTAssertEqual(reference.components(separatedBy: cap).count - 1, 2)
    }

    func testCompletionSourceIsTheHomeCardTapNotGlobalNavigation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
        let home = try String(contentsOf: root.appendingPathComponent("Views/HomeExchangeView.swift"), encoding: .utf8)
        // The card tap reports through a simultaneous gesture on the existing
        // link: no second tap target, no separate `View request` button.
        XCTAssertTrue(home.contains("onOpenEligibleRequestCard"))
        XCTAssertTrue(home.contains("simultaneousGesture(TapGesture()"))
        XCTAssertTrue(home.contains(".allowsHitTesting(false)"))

        let content = try String(contentsOf: root.appendingPathComponent("ContentView.swift"), encoding: .utf8)
        XCTAssertTrue(content.contains("onOpenEligibleRequestCard: { homeCardOpenedRequestID = $0 }"))
        XCTAssertTrue(content.contains("openedFromHomeCardID: cardID"))
        // The marker is consumed (cleared) by every path change.
        XCTAssertTrue(content.contains("homeCardOpenedRequestID = nil"))

        // F2: a VoiceOver activation never runs the touch gesture, so the
        // same card carries a default accessibility action — only while the
        // treatment is active — that records the marker and then pushes the
        // route, and only from Home itself (an empty path).
        XCTAssertTrue(home.contains(".accessibilityAction(.default) { onAccessibilityActivate() }"))
        let activation = try XCTUnwrap(content.range(of: "onActivateEligibleRequestCard: { request in"))
        let body = String(content[activation.upperBound...].prefix(500))
        let guardAt = try XCTUnwrap(body.range(of: "guard path.isEmpty else { return }"))
        let markerAt = try XCTUnwrap(body.range(of: "homeCardOpenedRequestID = request.id"))
        let pushAt = try XCTUnwrap(body.range(of: "path.append(.requestDetail(request))"))
        XCTAssertLessThan(guardAt.lowerBound, markerAt.lowerBound)
        XCTAssertLessThan(markerAt.lowerBound, pushAt.lowerBound)
    }
}
