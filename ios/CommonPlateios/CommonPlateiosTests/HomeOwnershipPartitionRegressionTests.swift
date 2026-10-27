//
//  HomeOwnershipPartitionRegressionTests.swift
//  CommonPlateiosTests
//
// W4-H4 review follow-up (ACTIVE / FIX): the existing `ownRequestsPreview`
// coverage in HomeExchangeBoardStateTests exercises an already-partitioned
// `owned` array — it proves the 0/1/2/3+ preview shape but not the upstream
// invariant that every caller-owned request in a mixed authoritative board
// is excluded from `Needs help right now`, including an owned request beyond
// the two-card Home preview. This file exercises the production
// `HomeExchangeView.partitionByOwnership` seam directly — the same function
// `ownRequests` and `populatedBoard(_:)` both derive from — against a mixed
// authoritative list, without duplicating its filtering algorithm.
import Foundation
import XCTest
@testable import CommonPlateios

final class HomeOwnershipPartitionRegressionTests: XCTestCase {
    /// W4-D2: `createdAt` is now the owned zone's sole ordering authority
    /// (newest first), so every request below carries an explicit, distinct
    /// timestamp rather than relying on call-order wall-clock `Date()`
    /// values.
    private func request(id: String, ownership: RequestOwnership, createdAt: Date) -> FoodRequest {
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

    /// Mixed authoritative order: 4 owned requests interleaved with 3
    /// helper-eligible requests owned by other participants, so accidental
    /// reordering within either zone is detectable. Owned requests are
    /// deliberately *not* in creation order in the input array — owned-3 is
    /// the newest and owned-1 the oldest — so a regression back to
    /// "preserve board order" would be caught by the newest-first
    /// assertions below.
    private var mixedAuthoritativeBoard: [FoodRequest] {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        return [
            request(id: "owned-1", ownership: .own, createdAt: base),
            request(id: "other-1", ownership: .notOwn, createdAt: base),
            request(id: "owned-2", ownership: .own, createdAt: base.addingTimeInterval(60)),
            request(id: "other-2", ownership: .notOwn, createdAt: base),
            request(id: "owned-4", ownership: .own, createdAt: base.addingTimeInterval(30)),
            request(id: "other-3", ownership: .notOwn, createdAt: base),
            request(id: "owned-3", ownership: .own, createdAt: base.addingTimeInterval(90)),
        ]
    }

    /// 1. The full authoritative owned partition contains every owned
    /// request, newest-created first (W4-D2) — independent of the input
    /// array's own order.
    func testPartitionOwnedContainsEveryOwnedRequestNewestCreatedFirst() {
        let partition = HomeExchangeView.partitionByOwnership(mixedAuthoritativeBoard)
        XCTAssertEqual(partition.owned.map(\.id), ["owned-3", "owned-2", "owned-4", "owned-1"])
    }

    /// 2. The Home ownership preview contains only the first two (newest
    /// two) when owned count is 3+.
    func testHomePreviewCapsAtTwoWhenFourAreOwned() {
        let partition = HomeExchangeView.partitionByOwnership(mixedAuthoritativeBoard)
        let preview = HomeExchangeView.ownRequestsPreview(partition.owned)
        XCTAssertEqual(preview.cards.map(\.id), ["owned-3", "owned-2"])
        XCTAssertEqual(preview.seeAllCount, 4)
    }

    /// 3. The third and later owned requests remain part of the
    /// authoritative owned set even though hidden from the Home preview.
    func testThirdAndLaterOwnedRequestsRemainInTheAuthoritativeOwnedSetDespiteBeingHiddenFromThePreview() {
        let partition = HomeExchangeView.partitionByOwnership(mixedAuthoritativeBoard)
        let preview = HomeExchangeView.ownRequestsPreview(partition.owned)
        let hiddenFromPreview = Set(partition.owned.map(\.id)).subtracting(preview.cards.map(\.id))

        XCTAssertEqual(hiddenFromPreview, ["owned-4", "owned-1"])
        XCTAssertTrue(partition.owned.map(\.id).contains("owned-4"))
        XCTAssertTrue(partition.owned.map(\.id).contains("owned-1"))
    }

    /// 4. None of the owned requests appear in `Needs help right now`,
    /// including the ones beyond the two-card Home preview.
    func testNoneOfTheOwnedRequestsAppearInNeedsHelpRegardlessOfPreviewVisibility() {
        let partition = HomeExchangeView.partitionByOwnership(mixedAuthoritativeBoard)
        let ownedIDs = Set(partition.owned.map(\.id))
        let needsHelpIDs = Set(partition.needsHelp.map(\.id))

        XCTAssertTrue(ownedIDs.isDisjoint(with: needsHelpIDs))
        for ownedID in ["owned-1", "owned-2", "owned-3", "owned-4"] {
            XCTAssertFalse(needsHelpIDs.contains(ownedID))
        }
    }

    /// 5. Eligible non-owned requests remain in `Needs help` in accepted
    /// (authoritative) order.
    func testEligibleNonOwnedRequestsRemainInNeedsHelpInAuthoritativeOrder() {
        let partition = HomeExchangeView.partitionByOwnership(mixedAuthoritativeBoard)
        XCTAssertEqual(partition.needsHelp.map(\.id), ["other-1", "other-2", "other-3"])
    }

    /// 6. Ownership/filtering authority is unchanged: partitioning is driven
    /// solely by `FoodRequest.isOwnRequest` (`ownership == .own`), never a
    /// local heuristic, and every input request lands in exactly one zone.
    func testPartitionIsExhaustiveAndDrivenOnlyByIsOwnRequest() {
        let partition = HomeExchangeView.partitionByOwnership(mixedAuthoritativeBoard)

        XCTAssertEqual(partition.owned.count + partition.needsHelp.count, mixedAuthoritativeBoard.count)
        XCTAssertTrue(partition.owned.allSatisfy(\.isOwnRequest))
        XCTAssertTrue(partition.needsHelp.allSatisfy { !$0.isOwnRequest })
    }

    /// 7. W4-D2 required proof: ASAP vs Later timing must never reorder the
    /// requester-owned zone — only `createdAt` may. An older ASAP request
    /// stays behind a newer Later one, and vice versa.
    func testASAPVersusLaterTimingDoesNotReorderTheOwnedZone() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let olderASAP = FoodRequest(
            id: "older-asap",
            diningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            foodDescription: "Rice bowl",
            pickupWindowText: "ASAP",
            mealSwipes: 1,
            windowStart: nil,
            windowEnd: nil,
            createdAt: base,
            expiresAt: base.addingTimeInterval(3600),
            status: .open,
            ownership: .own
        )
        let newerLater = FoodRequest(
            id: "newer-later",
            diningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            foodDescription: "Rice bowl",
            pickupWindowText: "6:00 PM",
            mealSwipes: 1,
            windowStart: base.addingTimeInterval(7200),
            windowEnd: base.addingTimeInterval(9000),
            createdAt: base.addingTimeInterval(120),
            expiresAt: base.addingTimeInterval(3600 + 120),
            status: .open,
            ownership: .own
        )

        // Later timing did not make it created first, and ASAP timing does
        // not pull the older request back to the front — only `createdAt`
        // decides.
        let partition = HomeExchangeView.partitionByOwnership([olderASAP, newerLater])
        XCTAssertEqual(partition.owned.map(\.id), ["newer-later", "older-asap"])

        let reversedInput = HomeExchangeView.partitionByOwnership([newerLater, olderASAP])
        XCTAssertEqual(reversedInput.owned.map(\.id), ["newer-later", "older-asap"])
    }

    /// 8/9. W4-D2 required proof: the zero-existing-request and existing-
    /// requester-owned-request landing cases both put the newest request
    /// first, with the correct singular/plural Home heading, and preserve
    /// older requests underneath.
    func testZeroExistingAndExistingOwnedLandingBothPutTheNewestRequestFirst() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        func owned(_ id: String, createdAt: Date) -> FoodRequest {
            FoodRequest(
                id: id,
                diningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
                foodDescription: "Rice bowl",
                pickupWindowText: "ASAP",
                mealSwipes: 1,
                windowStart: nil,
                windowEnd: nil,
                createdAt: createdAt,
                expiresAt: base.addingTimeInterval(3600),
                status: .open,
                ownership: .own
            )
        }

        // Zero-existing: the new request is the only one, under the
        // singular heading.
        let zeroExistingPartition = HomeExchangeView.partitionByOwnership([owned("only-new", createdAt: base)])
        XCTAssertEqual(zeroExistingPartition.owned.map(\.id), ["only-new"])
        XCTAssertEqual(HomeExchangeView.ownRequestsHeading(count: zeroExistingPartition.owned.count), "Your request")

        // Existing-request: the new request lands first, under the plural
        // heading, and the older request is preserved underneath.
        let existingPartition = HomeExchangeView.partitionByOwnership([
            owned("older-existing", createdAt: base),
            owned("brand-new", createdAt: base.addingTimeInterval(60)),
        ])
        XCTAssertEqual(existingPartition.owned.map(\.id), ["brand-new", "older-existing"])
        XCTAssertEqual(HomeExchangeView.ownRequestsHeading(count: existingPartition.owned.count), "Your requests")
    }
}
