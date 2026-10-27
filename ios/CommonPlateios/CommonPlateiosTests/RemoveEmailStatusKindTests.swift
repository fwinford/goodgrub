//
//  RemoveEmailStatusKindTests.swift
//  CommonPlateiosTests
//
// Focused W4-F1 coverage for `ContentView.removeEmailBlockedStatusKind(
// hasEstablishedRemovalSafety:isResolvingReservationStateForRemoval:hasActiveClaim:)`
// — the pure mapping the F1 state foundation introduced from Remove Email's
// existing W3-I4 removal-safety signals onto a `CommonPlateStatusKind`. This
// does not re-prove the removal-safety gating itself (`RemoveEmailTests.swift`
// already does that against real `RequestStore` signals); it proves only
// that the new presentation mapping is deterministic and matches the exact
// precedence `removeEmailBlockedNotice` documents: an unestablished readiness
// check outranks an active claim, and the W4-R2 2026-09-06 sync's
// actively-checking-versus-settled-inconclusive distinction is respected
// within that unestablished-readiness state.
import XCTest
@testable import CommonPlateios

final class RemoveEmailStatusKindTests: XCTestCase {
    func testUnestablishedRemovalSafetyWhileActivelyResolvingIsLoadingRegardlessOfActiveClaim() {
        XCTAssertEqual(
            ContentView.removeEmailBlockedStatusKind(
                hasEstablishedRemovalSafety: false,
                isResolvingReservationStateForRemoval: true,
                hasActiveClaim: false
            ),
            .loading
        )
        XCTAssertEqual(
            ContentView.removeEmailBlockedStatusKind(
                hasEstablishedRemovalSafety: false,
                isResolvingReservationStateForRemoval: true,
                hasActiveClaim: true
            ),
            .loading,
            "an unresolved cold/relaunch readiness check must outrank an active claim, matching removeEmailBlockedNotice's precedence"
        )
    }

    func testUnestablishedRemovalSafetyOnceSettledInconclusiveIsUnavailableRegardlessOfActiveClaim() {
        XCTAssertEqual(
            ContentView.removeEmailBlockedStatusKind(
                hasEstablishedRemovalSafety: false,
                isResolvingReservationStateForRemoval: false,
                hasActiveClaim: false
            ),
            .unavailable,
            "once the readiness check has ended without establishing removal safety, presentation must stop reading as in-progress work"
        )
        XCTAssertEqual(
            ContentView.removeEmailBlockedStatusKind(
                hasEstablishedRemovalSafety: false,
                isResolvingReservationStateForRemoval: false,
                hasActiveClaim: true
            ),
            .unavailable
        )
    }

    func testEstablishedSafetyWithActiveClaimIsUnavailable() {
        XCTAssertEqual(
            ContentView.removeEmailBlockedStatusKind(
                hasEstablishedRemovalSafety: true,
                isResolvingReservationStateForRemoval: false,
                hasActiveClaim: true
            ),
            .unavailable
        )
    }

    func testEstablishedSafetyWithNoActiveClaimIsUncertain() {
        // The only remaining reason `isRemoveEmailBlocked` can be true once
        // safety is established and there is no active claim is an
        // unresolved W3-D1 create — a mutation-outcome-uncertain state.
        XCTAssertEqual(
            ContentView.removeEmailBlockedStatusKind(
                hasEstablishedRemovalSafety: true,
                isResolvingReservationStateForRemoval: false,
                hasActiveClaim: false
            ),
            .uncertain
        )
    }
}
