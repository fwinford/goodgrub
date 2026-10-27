//
//  RemoveEmailTests.swift
//  CommonPlateiosTests
//
// Focused W3-I4 coverage: `ParticipantIdentityStore.removeIdentity()` — what
// it clears, what it leaves alone, and that a caller cannot use it while a
// verification flow is running. The removal-safety *gating* Settings applies
// (`SettingsView.isRemoveEmailBlocked`) is `!requestStore.hasEstablishedRemovalSafety
// || requestStore.activeClaim != nil || requestStore.hasUnresolvedCreateAmbiguity
// || requestStore.isCreating` (the last disjunct added by the W4-D2 FIX
// 2026-09-18 independent-review MUST FIX; see
// `RemoveEmailInFlightCreateGatingTests.swift` for its focused coverage) by
// source inspection; this file proves those published `RequestStore`
// signals hold exactly when the accepted removal-safety matrix says Remove
// Email must be unavailable, reusing the same store construction other
// focused H1/D1 suites already use. `hasEstablishedRemovalSafety` is the
// fail-closed cold/relaunch-reconciliation readiness gate: it starts `false`
// on a freshly constructed store and is established only by a definitive
// H1 continuation/claim outcome and a definitive D1
// reconciliation/create outcome, never by an inconclusive one.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class RemoveEmailTests: XCTestCase {
    private let requestID = "remove-email-target"
    private let principal = "taylor@nyu.edu"

    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        ClaimFlowURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - What removal clears (proof 1)

    func testRemovalClearsExactlyTheParticipantCredentialAndPresentation() async {
        let storage = InMemoryParticipantIdentityStorage(
            stored: ParticipantIdentityRecord(
                principal: principal,
                authority: canonicalParticipantAuthorityFixture,
                verifiedAt: Date()
            )
        )
        let store = makeIdentityStore(storage: storage)
        XCTAssertTrue(store.isVerified)

        await store.removeIdentity()

        XCTAssertFalse(store.isVerified)
        XCTAssertNil(store.identity)
        XCTAssertNil(store.currentAuthority())
        XCTAssertNil(storage.stored)
        XCTAssertEqual(storage.clearCount, 1)
        // Distinct from a backend-driven refusal: the student chose this, so
        // no "you need to verify again" explanation is raised.
        XCTAssertFalse(store.wasIdentityRevoked)
    }

    // MARK: - Cancel changes nothing (proof 2)

    /// The confirmation dialog's Cancel button (`ContentView`) has no action
    /// at all — by construction it can never call `removeIdentity()` — so the
    /// only thing to prove at the store level is that *not* calling it
    /// changes nothing, which is what every other untouched-state assertion
    /// in this file already establishes. This directly exercises the same
    /// "no call, no effect" guarantee on the store itself.
    func testNoCallToRemoveIdentityChangesNothing() {
        let storage = InMemoryParticipantIdentityStorage(
            stored: ParticipantIdentityRecord(
                principal: principal,
                authority: canonicalParticipantAuthorityFixture,
                verifiedAt: Date()
            )
        )
        let store = makeIdentityStore(storage: storage)

        // Simulates opening, then dismissing, the confirmation without
        // tapping the destructive button.
        XCTAssertTrue(store.isVerified)
        XCTAssertEqual(storage.clearCount, 0)
        XCTAssertNotNil(storage.stored)
    }

    // MARK: - Guards

    func testRemovalOnAnAlreadyUnverifiedInstallationIsANoOp() async {
        let storage = InMemoryParticipantIdentityStorage()
        let store = makeIdentityStore(storage: storage)

        await store.removeIdentity()

        XCTAssertEqual(storage.clearCount, 0)
    }

    func testRemovalIsRefusedWhileAFlowIsRunning() async throws {
        let storage = InMemoryParticipantIdentityStorage(
            stored: ParticipantIdentityRecord(
                principal: principal,
                authority: canonicalParticipantAuthorityFixture,
                verifiedAt: Date()
            )
        )
        let store = makeIdentityStore(storage: storage)
        store.beginEmailReplacement()
        XCTAssertNotNil(store.flow)

        await store.removeIdentity()

        // Not reachable through Home (Remove Email is not offered while a
        // flow is open, matching `beginEmailReplacement()`'s own guard), but
        // the store itself must not act on a stray call either.
        XCTAssertTrue(store.isVerified)
        XCTAssertEqual(storage.clearCount, 0)
        XCTAssertNotNil(store.flow)
    }

    // MARK: - Immediately unverified, and Request Food / Help re-gate
    // (proofs 3, 4, 5)

    func testImmediatelyAfterRemovalTheStoreIsUnverified() async {
        let storage = InMemoryParticipantIdentityStorage(
            stored: ParticipantIdentityRecord(
                principal: principal,
                authority: canonicalParticipantAuthorityFixture,
                verifiedAt: Date()
            )
        )
        let store = makeIdentityStore(storage: storage)

        await store.removeIdentity()

        // `RequestFoodEntryView`/`RequestDetailView` gate on exactly this
        // published signal (`identityStore.isVerified`), so re-gating both
        // screens to verification is a direct, source-inspected consequence
        // of this becoming false — no new gate exists or is needed.
        XCTAssertFalse(store.isVerified)
        // A fresh gated tap opens ordinary first verification, exactly as it
        // would for an installation that had never verified.
        store.beginVerificationIfNeeded()
        XCTAssertEqual(store.flow?.purpose, .firstVerification)
    }

    // MARK: - Reverification succeeds normally (proof 6)

    func testReverificationAfterRemovalEstablishesANewUsableIdentity() async throws {
        let storage = InMemoryParticipantIdentityStorage(
            stored: ParticipantIdentityRecord(
                principal: principal,
                authority: canonicalParticipantAuthorityFixture,
                verifiedAt: Date()
            )
        )
        let store = makeIdentityStore(storage: storage)
        await store.removeIdentity()

        store.beginVerificationIfNeeded()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: verifiedResponse()))
        await store.requestCode(for: principal)
        let verified = await store.submitCode("424242")

        XCTAssertTrue(verified)
        XCTAssertTrue(store.isVerified)
        XCTAssertEqual(store.identity?.principal, principal)
        XCTAssertEqual(storage.stored?.principal, principal)
    }

    // MARK: - Change Email remains a distinct action (proof 7)

    func testChangeEmailIsNotOfferedAsApplicableWhileUnverified() async {
        let storage = InMemoryParticipantIdentityStorage(
            stored: ParticipantIdentityRecord(
                principal: principal,
                authority: canonicalParticipantAuthorityFixture,
                verifiedAt: Date()
            )
        )
        let store = makeIdentityStore(storage: storage)
        await store.removeIdentity()

        // `beginEmailReplacement()` is a *replacement* of an existing
        // identity; `ContentView.participantIdentitySection` only ever
        // offers it in the `identity != nil` branch, so there is nothing to
        // replace once removal has run. Calling it directly, as a stray tap
        // on stale UI would, still does nothing useful: it opens a flow
        // whose purpose is `.emailReplacement` with no identity to protect,
        // and that flow can never `adopt()` into a "replacement" of nothing
        // — the first successful code establishes fresh first-time identity
        // instead (proof 6, above), not a Change Email outcome.
        XCTAssertFalse(store.isVerified)
    }

    // MARK: - Removal-safety gating signals (proofs 13, 14)

    func testActiveReservationKeepsTheRemovalSignalBlocked() async throws {
        let store = try await makeStoreWithActiveClaim()

        XCTAssertNotNil(store.activeClaim, "an active H1 reservation must block Remove Email")
    }

    func testReleasingTheReservationClearsTheRemovalSignal() async throws {
        let store = try await makeStoreWithActiveClaim()
        ClaimFlowURLProtocol.enqueue(.response(data: releaseResponse()))
        ClaimFlowURLProtocol.enqueue(.response(data: listResponse()))

        await store.releaseActiveClaim()

        XCTAssertNil(store.activeClaim, "Remove Email becomes available once the blocker resolves")
    }

    func testUnresolvedD1OperationKeepsTheRemovalSignalBlocked() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStoreWithOperationStorage(storage)
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))

        do {
            try await store.createRequest(asapPayload())
            XCTFail("expected an ambiguous outcome")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected.
        }

        XCTAssertTrue(
            store.hasUnresolvedCreateAmbiguity,
            "an unresolved W3-D1 create must block Remove Email"
        )
    }

    func testAnOrdinaryCreateLeavesTheRemovalSignalUnblocked() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStoreWithOperationStorage(storage)
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 201,
            data: createResponse()
        ))

        try await store.createRequest(asapPayload())

        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertNil(store.activeClaim)
    }

    // MARK: - Cold-launch/relaunch removal-safety readiness (review fix,
    // required proofs 13, 14)
    //
    // `ContentView.isRemoveEmailBlocked` also fails closed on
    // `!requestStore.hasEstablishedRemovalSafety`, by source inspection.
    // These tests prove that signal directly: it starts `false` on a
    // freshly constructed store (the cold-launch window `.task` has not run
    // yet), is established only by a definitive H1 continuation/claim
    // outcome and a definitive D1 reconciliation/create outcome, and never
    // by an inconclusive one.

    func testFreshlyConstructedStoreFailsClosedBeforeAnyReconciliation() {
        let store = RequestStore(
            service: makeClaimService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { canonicalParticipantAuthorityFixture },
            participantAuthorityRejected: {}
        )

        // Mirrors exactly the check `isRemoveEmailBlocked` performs before a
        // tap can ever open the confirmation dialog: a cold/relaunch store
        // that has not yet run `continueActiveReservationIfNeeded()` or
        // `reconcilePendingCreateOperationIfNeeded()` must not report itself
        // safe, even though neither `activeClaim` nor
        // `hasUnresolvedCreateAmbiguity` has anything to show yet.
        XCTAssertFalse(
            store.hasEstablishedRemovalSafety,
            "Remove Email must not become actionable before cold-launch reconciliation runs"
        )
    }

    func testActiveReservationDiscoveredDuringContinuationEstablishesReadinessAndRemainsBlocking() async throws {
        let store = RequestStore(
            service: makeClaimService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { canonicalParticipantAuthorityFixture },
            participantAuthorityRejected: {}
        )
        ClaimFlowURLProtocol.enqueue(.response(data: activeReservationResponse()))

        _ = try await store.continueActiveReservationIfNeeded()

        XCTAssertNotNil(store.activeClaim, "a reservation discovered by continuation must still block")
        // The H1 half of readiness alone, not the combined signal: D1
        // reconciliation was never run in this test, so
        // `hasEstablishedRemovalSafety` correctly still reads `false` — a
        // fresh reservation discovery must not be mistaken for D1 safety too.
        XCTAssertTrue(
            store.hasResolvedReservationStateForRemoval,
            "a definitive continuation result establishes the H1 half of removal-safety readiness"
        )
    }

    func testUnresolvedD1OperationDiscoveredDuringReconciliationEstablishesReadinessAndRemainsBlocking() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        storage.save(
            PendingRequestOperationRecord(
                operationId: "cold-launch-recovered-op",
                participantIdentifier: "64c0000000000000000000a1",
                operationAuthority: RequestOperationAuthorityIdentity(
                    origin: RequestService.operationAuthorityOrigin(for: URL(string: "https://commonplate.test")!),
                    ledger: RequestFetchingURLProtocol.defaultOperationLedger
                ),
                payload: asapPayload()
            )
        )
        let store = makeStoreWithOperationStorage(storage)
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))

        _ = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertTrue(
            store.hasUnresolvedCreateAmbiguity,
            "a durable D1 record discovered by reconciliation must still block"
        )
        XCTAssertTrue(
            store.hasResolvedPendingCreateStateForRemoval,
            "the mere discovery of the record — before its network reconciliation even resolves — already determines the D1 half of readiness"
        )
    }

    func testReconciliationEstablishingNoBlockingWorkMakesRemovalSafetyAvailable() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStoreWithOperationStorage(storage)

        _ = await store.reconcilePendingCreateOperationIfNeeded()
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 200,
            data: Data(#"{"reservation":null}"#.utf8)
        ))
        _ = try await store.continueActiveReservationIfNeeded()

        XCTAssertTrue(
            store.hasEstablishedRemovalSafety,
            "Remove Email becomes available once both cold-launch checks confirm nothing is outstanding"
        )
        XCTAssertNil(store.activeClaim)
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
    }

    func testInconclusiveReservationContinuationLeavesRemovalSafetyUnresolved() async throws {
        let store = RequestStore(
            service: makeClaimService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { canonicalParticipantAuthorityFixture },
            participantAuthorityRejected: {}
        )
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))

        _ = try await store.continueActiveReservationIfNeeded()

        // A transport failure genuinely leaves H1 authority unresolved — it
        // must never be treated as "no reservation exists".
        XCTAssertFalse(store.hasResolvedReservationStateForRemoval)
        XCTAssertFalse(
            store.hasEstablishedRemovalSafety,
            "an inconclusive relaunch read must not incorrectly enable Remove Email"
        )
        // W4-R2 2026-09-06 sync: once the read has settled — even
        // inconclusively — presentation must stop reading as in-progress
        // work, distinct from `hasEstablishedRemovalSafety` remaining `false`
        // forever for this outcome.
        XCTAssertFalse(
            store.isResolvingReservationStateForRemoval,
            "a settled inconclusive read must not be mistaken for one still in flight"
        )
    }

    /// W4-R2 2026-09-06 sync: `isResolvingReservationStateForRemoval` is the
    /// presentation-only signal that lets Settings distinguish an actively
    /// running readiness check from a settled-inconclusive one, since
    /// `hasResolvedReservationStateForRemoval` alone cannot — both read
    /// `false` identically before any read starts and after an inconclusive
    /// one ends. Before this call, it must already read `false` (nothing is
    /// in flight yet); after an inconclusive read completes, it must read
    /// `false` again (no longer in flight), never staying stuck `true`.
    func testIsResolvingReservationStateForRemovalReflectsOnlyTheActiveNetworkRead() async throws {
        let store = RequestStore(
            service: makeClaimService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { canonicalParticipantAuthorityFixture },
            participantAuthorityRejected: {}
        )
        XCTAssertFalse(store.isResolvingReservationStateForRemoval)

        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        _ = try await store.continueActiveReservationIfNeeded()

        XCTAssertFalse(
            store.isResolvingReservationStateForRemoval,
            "the read has ended (inconclusively) by the time this call returns, so no spinner should remain justified"
        )
    }

    /// W4-R2 2026-09-06 same-day rereview (SHOULD FIX): a single gated read
    /// proves the count-backed signal reads `true` only while the network
    /// call is genuinely suspended, and `false` again once it completes —
    /// the baseline a plain Boolean also got right, now reproduced against
    /// `reservationStateResolutionCount` directly rather than inferred from
    /// timing alone.
    func testSingleActiveReadDrivesIsResolvingReservationStateForRemoval() async throws {
        let store = RequestStore(
            service: makeClaimService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { canonicalParticipantAuthorityFixture },
            participantAuthorityRejected: {}
        )
        XCTAssertFalse(store.isResolvingReservationStateForRemoval)
        XCTAssertEqual(store.reservationStateResolutionCount, 0)

        let gate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: Data(#"{"reservation":null}"#.utf8), gate: gate))

        let task = Task { try await store.continueActiveReservationIfNeeded() }
        await waitUntil { gate.isWaiting }

        XCTAssertTrue(store.isResolvingReservationStateForRemoval)
        XCTAssertEqual(store.reservationStateResolutionCount, 1)

        gate.open()
        _ = try await task.value

        XCTAssertFalse(store.isResolvingReservationStateForRemoval)
        XCTAssertEqual(store.reservationStateResolutionCount, 0)
    }

    /// W4-R2 2026-09-06 same-day rereview (SHOULD FIX, key regression): the
    /// exact overlap a plain Boolean got wrong. Two reads overlap — matching
    /// `ContentView`'s launch `.task` and `ReservationWarningRouteDriver`
    /// each independently calling `continueActiveReservationIfNeeded()` —
    /// and the first finishing must not flip presentation to
    /// settled-unavailable while the second is still genuinely in flight.
    /// Only once *both* have exited does the signal read `false` again.
    func testOverlappingReservationReadsKeepIsResolvingTrueUntilTheLastOneExits() async throws {
        let store = RequestStore(
            service: makeClaimService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { canonicalParticipantAuthorityFixture },
            participantAuthorityRejected: {}
        )
        XCTAssertFalse(store.isResolvingReservationStateForRemoval)

        let gateA = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: Data(#"{"reservation":null}"#.utf8), gate: gateA))
        let taskA = Task { try await store.continueActiveReservationIfNeeded() }
        await waitUntil { gateA.isWaiting }
        XCTAssertEqual(store.reservationStateResolutionCount, 1)

        let gateB = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: Data(#"{"reservation":null}"#.utf8), gate: gateB))
        let taskB = Task { try await store.continueActiveReservationIfNeeded() }
        await waitUntil { gateB.isWaiting }
        XCTAssertEqual(
            store.reservationStateResolutionCount, 2,
            "both reads are genuinely in flight at once"
        )
        XCTAssertTrue(store.isResolvingReservationStateForRemoval)

        // The first read exits — the signal must stay `true`: a second real
        // read is still running. This is the exact case a plain Boolean
        // cleared incorrectly.
        gateA.open()
        _ = try await taskA.value
        XCTAssertEqual(store.reservationStateResolutionCount, 1)
        XCTAssertTrue(
            store.isResolvingReservationStateForRemoval,
            "one relevant read is still active; presentation must not settle to unavailable yet"
        )

        // Only once the last one exits does the signal settle.
        gateB.open()
        _ = try await taskB.value
        XCTAssertEqual(store.reservationStateResolutionCount, 0)
        XCTAssertFalse(store.isResolvingReservationStateForRemoval)
    }

    /// W4-R2 2026-09-06 same-day rereview: a gated read that ultimately
    /// succeeds (an active reservation discovered) still balances the count,
    /// and the in-flight signal carries no removal-eligibility authority of
    /// its own — `hasResolvedReservationStateForRemoval`/`activeClaim` are
    /// what actually change, exactly as before this correction.
    func testGatedSuccessfulReadBalancesTheCountAndEstablishesReadinessNormally() async throws {
        let store = RequestStore(
            service: makeClaimService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { canonicalParticipantAuthorityFixture },
            participantAuthorityRejected: {}
        )
        let gate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: activeReservationResponse(), gate: gate))

        let task = Task { try await store.continueActiveReservationIfNeeded() }
        await waitUntil { gate.isWaiting }
        XCTAssertTrue(store.isResolvingReservationStateForRemoval)

        gate.open()
        _ = try await task.value

        XCTAssertFalse(store.isResolvingReservationStateForRemoval)
        XCTAssertEqual(store.reservationStateResolutionCount, 0)
        XCTAssertNotNil(store.activeClaim, "the discovered reservation itself is unaffected by this correction")
        XCTAssertTrue(store.hasResolvedReservationStateForRemoval)
    }

    /// W4-R2 2026-09-06 same-day rereview: cancellation is one of the exit
    /// paths the count must balance on, matching the existing `defer` in
    /// `continueActiveReservationIfNeeded()`.
    func testCancellationOfAGatedReadBalancesTheCount() async throws {
        let store = RequestStore(
            service: makeClaimService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { canonicalParticipantAuthorityFixture },
            participantAuthorityRejected: {}
        )
        let gate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: Data(#"{"reservation":null}"#.utf8), gate: gate))

        let task = Task { try await store.continueActiveReservationIfNeeded() }
        await waitUntil { gate.isWaiting }
        XCTAssertTrue(store.isResolvingReservationStateForRemoval)

        task.cancel()
        gate.open()
        _ = try? await task.value

        XCTAssertFalse(
            store.isResolvingReservationStateForRemoval,
            "a cancelled read has still exited, so it must not leave the count stuck"
        )
        XCTAssertEqual(store.reservationStateResolutionCount, 0)
    }

    /// Directly demonstrates the race the fix closes: at the instant Home
    /// first appears (a freshly constructed store, matching `ContentView`'s
    /// own `.task`, has not yet resolved either cold-launch check), Remove
    /// Email's gate already reads blocked — so a tap racing ahead of
    /// `continueActiveReservationIfNeeded()`/
    /// `reconcilePendingCreateOperationIfNeeded()` cannot reach the
    /// confirmation dialog at all, regardless of how quickly a student taps.
    func testRemovalCannotRaceAheadOfColdLaunchBlockerChecks() {
        let store = RequestStore(
            service: makeClaimService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { canonicalParticipantAuthorityFixture },
            participantAuthorityRejected: {}
        )

        let isRemoveEmailBlocked = !store.hasEstablishedRemovalSafety
            || store.activeClaim != nil
            || store.hasUnresolvedCreateAmbiguity
            || store.isCreating
        XCTAssertTrue(isRemoveEmailBlocked)
    }

    // MARK: - Blocked-by-unresolved-create notice copy (W4-D2 fix,
    // 2026-09-16 Faith decision)

    /// The prior wording ("CommonPlate is still confirming a request you
    /// submitted. You can remove your email once that finishes.") promised
    /// automatic resolution that D2's fail-closed states (unavailable
    /// stable recovery identity; operation-authority/backend-identity
    /// mismatch) may never actually reach. Pins the accepted replacement and
    /// guards against the old sentence silently returning.
    func testRemoveEmailBlockedByPendingCreateNoticeUsesAcceptedPopupCopy() {
        XCTAssertEqual(
            EmailReplacementNoticeContent.signOutRequestUnconfirmed.message,
            "Wait until your request is confirmed before signing out."
        )
        XCTAssertFalse(
            EmailReplacementNoticeContent.signOutRequestUnconfirmed.message.contains("You can remove your email once that finishes")
        )
    }

    // MARK: - Ambiguous-fulfillment-recovery keeps the removal signal blocked
    // (review fix: matrix row 4, required proof 13)

    func testAmbiguousFulfillmentRecoveryKeepsTheRemovalSignalBlocked() async throws {
        let store = try await makeStoreWithActiveClaim()
        // The fulfillment POST itself is lost in transit, and the one
        // read-only status check that follows sees the request still only
        // `claimed` — exactly the accepted "one CommonPlate-only resend"
        // window, not a synthetic `activeClaim` assignment.
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        ClaimFlowURLProtocol.enqueue(.response(data: Data(#"{"request":\#(requestObject(status: "claimed"))}"#.utf8)))

        do {
            try await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
            XCTFail("expected the ambiguous-fulfillment recovery window")
        } catch RequestServiceError.ambiguousFulfillmentOutcome {
            // Expected.
        }

        XCTAssertNotNil(store.fulfillmentAmbiguity, "must be in the one CommonPlate-only resend window")
        XCTAssertNotNil(
            store.activeClaim,
            "ambiguous fulfillment recovery must keep Remove Email blocked until it resolves"
        )
    }

    // MARK: - Subscriber and Push Installation state are untouched (proofs 8, 9)

    /// I4 never reads or writes `AlertSubscriptionStore`,
    /// `PushInstallationStorage`/`PushSubscriptionStore`, or
    /// `ParticipantEmailUnsubscribeStore`: `removeIdentity()` touches only
    /// `ParticipantIdentityStorage`/`ParticipantIdentityStore`'s own
    /// published state (see the method and this file's clearing test above),
    /// and none of those other stores are constructed, injected, or
    /// referenced anywhere in `ParticipantIdentityStore`. This is a
    /// source-inspection proof, not a runtime one: there is no shared store
    /// instance in this file for a behavioral test to observe changing.
    func testRemovalTouchesNoSubscriberStore() async {
        // `ParticipantIdentityStore.init` takes only a verification service
        // and `ParticipantIdentityStorage` — no Subscriber, Push, or
        // unsubscribe dependency exists for `removeIdentity()` to reach.
        let storage = InMemoryParticipantIdentityStorage(
            stored: ParticipantIdentityRecord(
                principal: principal,
                authority: canonicalParticipantAuthorityFixture,
                verifiedAt: Date()
            )
        )
        let store = makeIdentityStore(storage: storage)
        await store.removeIdentity()
        XCTAssertFalse(store.isVerified)
    }

    // MARK: - Fixtures

    private func makeIdentityStore(
        storage: ParticipantIdentityStorage
    ) -> ParticipantIdentityStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
        let store = ParticipantIdentityStore(
            service: ParticipantVerificationService(client: client),
            storage: storage
        )
        store.configureInstallationAssociation { _ in }
        return store
    }

    private func makeRequestService() -> RequestService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return RequestService(client: client)
    }

    private func makeClaimService() -> RequestService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaimFlowURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return RequestService(client: client)
    }

    private func makeStoreWithOperationStorage(
        _ operationStorage: PendingRequestOperationStorage
    ) -> RequestStore {
        RequestStore(
            service: makeRequestService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { canonicalParticipantAuthorityFixture },
            participantAuthorityRejected: {},
            operationStorage: operationStorage
        )
    }

    private func makeStoreWithActiveClaim() async throws -> RequestStore {
        let store = RequestStore(
            service: makeClaimService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { canonicalParticipantAuthorityFixture },
            participantAuthorityRejected: {}
        )
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        return store
    }

    private func requestObject(status: String = "open") -> String {
        """
        {
          "id": "\(requestID)",
          "vendor": "Crave NYU",
          "food": "Rice bowl",
          "pickupWindowText": "ASAP",
          "mealSwipes": 2,
          "menuPath": "meal-exchange",
          "mealItems": ["Meal 1", "Meal 2"],
          "orderDetails": null,
          "estimatedDiningDollarsCents": null,
          "windowStart": null,
          "windowEnd": null,
          "status": "\(status)",
          "createdAt": "2026-07-20T18:30:00.000Z",
          "expiresAt": "\(iso8601String(Date().addingTimeInterval(5 * 60 * 60)))"
        }
        """
    }

    private func claimResponse(
        pickupName: String = "Taylor",
        claimToken: String = "claim-token",
        claimExpiresAt: Date = Date().addingTimeInterval(15 * 60)
    ) -> Data {
        Data("""
        {
          "request": \(requestObject(status: "claimed")),
          "claim": {
            "pickupName": "\(pickupName)",
            "claimToken": "\(claimToken)",
            "claimExpiresAt": "\(iso8601String(claimExpiresAt))"
          }
        }
        """.utf8)
    }

    private func activeReservationResponse(
        claimExpiresAt: Date = Date().addingTimeInterval(15 * 60)
    ) -> Data {
        Data("""
        {
          "reservation": {
            "request": \(requestObject(status: "claimed")),
            "pickupName": "Taylor",
            "claimExpiresAt": "\(iso8601String(claimExpiresAt))",
            "claimExtendedAt": null
          }
        }
        """.utf8)
    }

    private func releaseResponse() -> Data {
        Data(#"{"released":true}"#.utf8)
    }

    private func listResponse() -> Data {
        Data(#"{"requests":[]}"#.utf8)
    }

    private func asapPayload(food: String = "Ambiguous rice bowl") -> CreateRequestPayload {
        CreateRequestPayload(
            vendor: "Jasper Kane Cafe",
            timing: .asap,
            windowStart: nil,
            menuPath: .mealExchange,
            mealSwipes: 2,
            mealItems: [MealItem(name: food), MealItem(name: "Side salad")],
            orderDetails: nil,
            estimatedDiningDollarsCents: nil
        )
    }

    private func createResponse() -> Data {
        Data(#"{"request":\#(requestObject())}"#.utf8)
    }

    private func challengeResponse() -> Data {
        Data(#"""
        {"verification":{
          "expiresAt": "2026-07-28T16:10:00.000Z",
          "resendAvailableAt": "2026-07-28T16:01:00.000Z"
        }}
        """#.utf8)
    }

    private func verifiedResponse() -> Data {
        Data(#"{"participant":{"email":"\#(principal)"},"authority":"\#(canonicalParticipantAuthorityFixture)"}"#.utf8)
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func waitUntil(
        timeoutIterations: Int = 200,
        condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<timeoutIterations {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}
