//
//  HomeExactCreatedRequestAvailabilityTests.swift
//  CommonPlateiosTests
//
// W4-D2 2026-09-17 exact-created-request Home continuity contract sync:
// after authoritative CREATED, the exact ownership-resolved created request
// already trusted in `RequestStore.createdRequestContinuity` MAY render in
// `Your request(s)` even while the broader Home board is still
// `.loading`/`.unavailable` — scoped only to that one authoritative request,
// never a general Home cache. This file exercises the production
// `HomeExchangeView.ownRequests(displayedBoardState:createdRequestContinuity:)`
// seam directly, the same pure boundary `ownRequestsSection` reads from.
import Foundation
import XCTest
@testable import CommonPlateios

final class HomeExactCreatedRequestAvailabilityTests: XCTestCase {
    private func request(id: String, ownership: RequestOwnership = .own, createdAt: Date = .init()) -> FoodRequest {
        FoodRequest(
            id: id,
            diningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            foodDescription: "Rice bowl",
            pickupWindowText: "ASAP",
            mealSwipes: 2,
            windowStart: nil,
            windowEnd: nil,
            createdAt: createdAt,
            expiresAt: Date().addingTimeInterval(3600),
            status: .open,
            ownership: ownership
        )
    }

    private func continuity(for request: FoodRequest) -> RequestCreationContinuity {
        RequestCreationContinuity(
            operationId: "op-\(request.id)",
            participantAuthority: "authority-1",
            request: request
        )
    }

    // MARK: - (1)/(2) Loading and Unavailable render the exact created request

    func testLoadingWithLiveContinuityRendersTheExactCreatedRequest() {
        let exact = request(id: "exact-created")
        let owned = HomeExchangeView.ownRequests(
            displayedBoardState: .loading,
            createdRequestContinuity: continuity(for: exact)
        )
        XCTAssertEqual(owned.map(\.id), ["exact-created"])
    }

    func testUnavailableWithLiveContinuityRendersTheExactCreatedRequest() {
        let exact = request(id: "exact-created")
        let owned = HomeExchangeView.ownRequests(
            displayedBoardState: .unavailable,
            createdRequestContinuity: continuity(for: exact)
        )
        XCTAssertEqual(owned.map(\.id), ["exact-created"])
    }

    // MARK: - (3)/(4) No invented card without live continuity

    func testLoadingWithNoContinuityInventsNoRequesterCard() {
        XCTAssertEqual(
            HomeExchangeView.ownRequests(displayedBoardState: .loading, createdRequestContinuity: nil),
            []
        )
    }

    func testUnavailableWithNoContinuityInventsNoRequesterCard() {
        XCTAssertEqual(
            HomeExchangeView.ownRequests(displayedBoardState: .unavailable, createdRequestContinuity: nil),
            []
        )
    }

    // MARK: - (5) Exact-request scoping only

    func testOnlyTheExactContinuityRequestIsExposedDuringLoadingOrUnavailable() {
        // The pure boundary takes no broader board/helper/discovery list at
        // all while `.loading`/`.unavailable` — there is structurally
        // nothing else it could expose besides the live continuity's own
        // `request`.
        let exact = request(id: "exact-created")
        for state: HomeExchangeView.BoardState in [.loading, .unavailable] {
            let owned = HomeExchangeView.ownRequests(
                displayedBoardState: state,
                createdRequestContinuity: continuity(for: exact)
            )
            XCTAssertEqual(owned.count, 1)
            XCTAssertEqual(owned.first?.id, "exact-created")
        }
    }

    // MARK: - Empty is authoritative and excluded from the exception

    func testEmptyBoardDoesNotRenderTheContinuityExceptionEvenWithLiveContinuity() {
        let exact = request(id: "exact-created")
        XCTAssertEqual(
            HomeExchangeView.ownRequests(displayedBoardState: .empty, createdRequestContinuity: continuity(for: exact)),
            []
        )
    }

    // MARK: - (7) Populated state is unaffected by the exception

    func testPopulatedStateIgnoresContinuityAndUsesTheAuthoritativePartition() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let owned1 = request(id: "owned-1", createdAt: base)
        let owned2 = request(id: "owned-2", createdAt: base.addingTimeInterval(60))
        let other = request(id: "other-1", ownership: .notOwn, createdAt: base)
        // A stale/different continuity must never leak into a populated
        // board's authoritative partition.
        let staleContinuity = continuity(for: request(id: "stale-unrelated", createdAt: base.addingTimeInterval(120)))

        let owned = HomeExchangeView.ownRequests(
            displayedBoardState: .populated([owned1, other, owned2]),
            createdRequestContinuity: staleContinuity
        )
        XCTAssertEqual(owned.map(\.id), ["owned-2", "owned-1"])
    }

    // MARK: - (8) Reconciliation: no duplicate once the board resolves

    func testTheExactCreatedRequestDoesNotDuplicateOnceTheBoardResolvesToPopulated() {
        let exact = request(id: "exact-created")
        let duringLoading = HomeExchangeView.ownRequests(
            displayedBoardState: .loading,
            createdRequestContinuity: continuity(for: exact)
        )
        XCTAssertEqual(duringLoading.map(\.id), ["exact-created"])

        // The same continuity is still live (not yet retired) when the
        // authoritative fetch resolves and now includes that same request.
        let afterResolve = HomeExchangeView.ownRequests(
            displayedBoardState: .populated([exact]),
            createdRequestContinuity: continuity(for: exact)
        )
        XCTAssertEqual(afterResolve.map(\.id), ["exact-created"])
        XCTAssertEqual(afterResolve.count, 1)
    }

    // MARK: - (9) Retired/absent continuity cannot populate the exception

    func testRetiredContinuityCannotPopulateTheException() {
        // Retirement is modeled by the continuity becoming nil, exactly as
        // `RequestStore.retireCreationContinuity(id:)` and
        // `retireCreationContinuityIfAuthorityChanged()` do.
        for state: HomeExchangeView.BoardState in [.loading, .unavailable] {
            XCTAssertEqual(
                HomeExchangeView.ownRequests(displayedBoardState: state, createdRequestContinuity: nil),
                []
            )
        }
    }

    // MARK: - (11) No global-state lie

    func testTheExceptionNeverReportsTheBoardAsPopulated() throws {
        // Structural guarantee: the seam's own signature only ever returns
        // `[FoodRequest]`, never a `BoardState`, so it cannot itself mutate
        // or claim `displayedBoardState` is `.populated`. Confirmed by
        // source inspection that `ownRequestsSection`'s board-state read is
        // untouched by this exception.
        let source = try String(
            contentsOf: repositoryFile("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("case .loading, .unavailable:"))
        XCTAssertFalse(source.contains("displayedBoardState = .populated"))
    }

    private func repositoryFile(_ relativePath: String) -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CommonPlateiosTests
            .deletingLastPathComponent() // CommonPlateios
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repository root
        let url = root.appendingPathComponent(relativePath)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "expected \(relativePath) at \(url.path)"
        )
        return url
    }
}
