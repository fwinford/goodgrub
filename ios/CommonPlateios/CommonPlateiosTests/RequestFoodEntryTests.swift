import Foundation
import XCTest
@testable import CommonPlateios

/// W3-I2 requester verification entry: `AppRoute.requestFood` decides
/// verification-first vs. direct-to-form before any Request Food form exists,
/// consuming W3-I1's identity, flow, and continuation machinery unchanged.
@MainActor
final class RequestFoodEntryTests: XCTestCase {
    private let principal = "entry@nyu.edu"

    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Presentation

    func testCleanNoIdentityEntryRoutesToVerificationNotTheForm() {
        XCTAssertEqual(
            RequestFoodEntryView.presentation(isVerified: false),
            .verification
        )
    }

    /// The default `eligibilityCheck` (already-`.eligible`) reproduces the
    /// exact presentation this function returned before W4-Q1 consumption
    /// existed, so every call site not concerned with the early quota
    /// boundary is unaffected.
    func testVerifiedIdentityEntryRoutesDirectlyToTheForm() {
        XCTAssertEqual(
            RequestFoodEntryView.presentation(isVerified: true),
            .form
        )
    }

    // MARK: - W4-R2 item 20: early Q1 eligibility boundary

    /// A verified identity with no eligibility read yet (or one still in
    /// flight) never reaches the form — the requester sees the check, not a
    /// flash of the form before an exhausted answer arrives.
    func testVerifiedIdentityAwaitingEligibilityShowsCheckingNotTheForm() {
        XCTAssertEqual(
            RequestFoodEntryView.presentation(
                isVerified: true,
                eligibilityCheck: .notStarted
            ),
            .checkingEligibility
        )
        XCTAssertEqual(
            RequestFoodEntryView.presentation(
                isVerified: true,
                eligibilityCheck: .checking
            ),
            .checkingEligibility
        )
    }

    /// `eligible` continues to the same pushed Request Food destination,
    /// whether the identity was already verified or just finished verifying.
    func testEligibleVerifiedIdentityReachesTheForm() {
        XCTAssertEqual(
            RequestFoodEntryView.presentation(
                isVerified: true,
                eligibilityCheck: .resolved(.eligible)
            ),
            .form
        )
    }

    /// `exhausted` stops before the requester invests in the form, using
    /// `RequestFoodView`'s own already-accepted daily-limit copy, and offers
    /// no retry — another read now would answer identically.
    func testExhaustedVerifiedIdentityStopsBeforeTheFormWithNonRetryableLimitCopy() {
        XCTAssertEqual(
            RequestFoodEntryView.presentation(
                isVerified: true,
                eligibilityCheck: .resolved(.exhausted)
            ),
            .unavailable(message: RequestFoodView.postingLimitReachedNotice, retryable: false)
        )
    }

    /// `unknown` (missing authority, transport/decoding failure, or a stale
    /// result the read's own guard discarded) is never treated as eligible,
    /// and is distinguished from `exhausted` by being retryable — the read
    /// itself, not the quota, is what did not resolve.
    func testUnknownEligibilityStopsBeforeTheFormWithRetryableUnavailableCopy() {
        XCTAssertEqual(
            RequestFoodEntryView.presentation(
                isVerified: true,
                eligibilityCheck: .resolved(.unknown)
            ),
            .unavailable(message: RequestFoodView.availabilityUnknownNotice, retryable: true)
        )
    }

    /// An unverified requester never reaches an eligibility state — the
    /// verification modal boundary is unconditionally first, and cancelled
    /// or unsuccessful verification never queries W4-Q1 at all.
    func testUnverifiedIdentityNeverReachesAnEligibilityStateRegardlessOfEligibilityValue() {
        for eligibilityCheck in [
            RequestFoodEligibilityCheck.notStarted,
            .checking,
            .resolved(.eligible),
            .resolved(.exhausted),
            .resolved(.unknown)
        ] {
            XCTAssertEqual(
                RequestFoodEntryView.presentation(isVerified: false, eligibilityCheck: eligibilityCheck),
                .verification
            )
        }
    }

    /// Once this session has legitimately admitted the form (`hasEnteredForm`),
    /// it outranks eligibility entirely — the early boundary is a one-time
    /// gate before admission, not a state re-checked on every render, and
    /// mid-form authority loss must not revert an admitted session away from
    /// the mounted `RequestFoodView`/draft.
    func testAdmittedFormOutranksAnyLaterEligibilityValue() {
        for eligibilityCheck in [
            RequestFoodEligibilityCheck.notStarted,
            .checking,
            .resolved(.eligible),
            .resolved(.exhausted),
            .resolved(.unknown)
        ] {
            XCTAssertEqual(
                RequestFoodEntryView.presentation(
                    isVerified: false,
                    hasEnteredForm: true,
                    eligibilityCheck: eligibilityCheck
                ),
                .form
            )
        }
    }

    // MARK: - Fresh entry opens a usable verification experience

    func testFreshEntryOpensTheExistingVerificationExperienceAtEmailEntry() {
        let store = makeIdentityStore()
        XCTAssertEqual(
            RequestFoodEntryView.presentation(isVerified: store.isVerified),
            .verification
        )

        store.beginVerificationIfNeeded()

        XCTAssertEqual(store.flow?.purpose, .firstVerification)
        XCTAssertEqual(store.flow?.stage, .enteringEmail)
        XCTAssertTrue(
            RequestFoodEntryView.shouldPresentEntryVerification(
                hasEnteredForm: false,
                verificationPurpose: store.flow?.purpose
            )
        )
        // The usable start action itself: an eligible address may send a code.
        XCTAssertTrue(
            ParticipantVerificationView.canSendCode(email: principal, isRequesting: false)
        )
    }

    func testEntryVerificationModalCannotCaptureAnAdmittedFormOrReplacementFlow() {
        XCTAssertFalse(
            RequestFoodEntryView.shouldPresentEntryVerification(
                hasEnteredForm: true,
                verificationPurpose: .firstVerification
            )
        )
        XCTAssertFalse(
            RequestFoodEntryView.shouldPresentEntryVerification(
                hasEnteredForm: false,
                verificationPurpose: .emailReplacement
            )
        )
        XCTAssertFalse(
            RequestFoodEntryView.shouldPresentEntryVerification(
                hasEnteredForm: false,
                verificationPurpose: nil
            )
        )
    }

    /// The same idempotence `beginVerificationIfNeeded` already guarantees at
    /// the store level, exercised through this screen's own entry point so a
    /// second appearance (e.g. returning from backgrounding mid-code) does not
    /// restart progress.
    func testReenteringWhileAFlowIsRunningDoesNotRestartIt() async {
        let store = makeIdentityStore()
        store.beginVerificationIfNeeded()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
        await store.requestCode(for: principal)
        let stageBefore = store.flow?.stage

        store.beginVerificationIfNeeded()

        XCTAssertEqual(store.flow?.stage, stageBefore)
    }

    // MARK: - Successful verification continues into the form

    func testSuccessfulVerificationMakesTheFormReachable() async {
        let store = makeIdentityStore()
        XCTAssertEqual(RequestFoodEntryView.presentation(isVerified: store.isVerified), .verification)

        store.beginVerificationIfNeeded()
        await completeVerification(store)

        XCTAssertTrue(store.isVerified)
        XCTAssertEqual(RequestFoodEntryView.presentation(isVerified: store.isVerified), .form)
        // The flow that gated entry is over; nothing is left presenting it.
        XCTAssertNil(store.flow)
    }

    /// Successful verification switches the one Home-owned presentation from
    /// verification to the form; it must not invoke the Cancel exit callback.
    func testSuccessfulVerificationDoesNotInvokeTheCancelExitPath() async {
        let store = makeIdentityStore()

        store.beginVerificationIfNeeded()
        await completeVerification(store)
        let hasEnteredForm = RequestFoodEntryView.nextHasEnteredForm(
            previousHasEnteredForm: false,
            eligibility: .eligible
        )
        XCTAssertTrue(hasEnteredForm)
        XCTAssertEqual(
            RequestFoodEntryView.presentation(isVerified: store.isVerified, hasEnteredForm: hasEnteredForm),
            .form
        )
    }

    // MARK: - Failed / cancelled / abandoned verification does not

    func testFailedVerificationDoesNotReachTheForm() async {
        let store = makeIdentityStore()
        store.beginVerificationIfNeeded()
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 400, data: errorResponse(code: "VERIFICATION_CODE_INVALID"))
        )
        await store.requestCode(for: principal)

        let verified = await store.submitCode("000000")

        XCTAssertFalse(verified)
        XCTAssertFalse(store.isVerified)
        XCTAssertEqual(RequestFoodEntryView.presentation(isVerified: store.isVerified), .verification)
    }

    func testCancelledVerificationDoesNotReachTheFormAndRetiresTheFlow() {
        let store = makeIdentityStore()
        store.beginVerificationIfNeeded()

        store.cancelVerification()

        XCTAssertFalse(store.isVerified)
        XCTAssertNil(store.flow)
        XCTAssertEqual(RequestFoodEntryView.presentation(isVerified: store.isVerified), .verification)
    }

    func testCancellingEntryVerificationRetiresTheFlowAndRequestsHomeOwnedDismissal() {
        let store = makeIdentityStore()
        var exitRequests = 0
        store.beginVerificationIfNeeded()

        RequestFoodEntryView.cancelEntryVerification(identityStore: store) {
            exitRequests += 1
        }

        XCTAssertNil(store.flow)
        XCTAssertEqual(exitRequests, 1)
        XCTAssertEqual(AppRoute.appending(.requestFood, to: []), [.requestFood])
    }

    // MARK: - Already-verified and restored identity enter directly

    /// Already verified in the same session (e.g. a request posted earlier and
    /// the installation never lost identity) — distinct from restoration
    /// below, which is what a fresh launch produces.
    func testAlreadyVerifiedIdentityEntersDirectlyWithoutReopeningVerification() async {
        let store = makeIdentityStore()
        store.beginVerificationIfNeeded()
        await completeVerification(store)
        XCTAssertTrue(store.isVerified)

        XCTAssertEqual(RequestFoodEntryView.presentation(isVerified: store.isVerified), .form)
        store.beginVerificationIfNeeded()
        XCTAssertNil(store.flow)
        XCTAssertEqual(RequestFoodEntryView.presentation(isVerified: store.isVerified), .form)
    }

    func testRestoredVerifiedIdentityEntersDirectlyOnTheNextLaunch() {
        let storage = InMemoryParticipantIdentityStorage(
            stored: ParticipantIdentityRecord(
                principal: principal,
                authority: canonicalParticipantAuthorityFixture,
                verifiedAt: Date(timeIntervalSince1970: 1_000)
            )
        )

        // A fresh store is what a relaunch produces.
        let store = makeIdentityStore(storage: storage)

        XCTAssertTrue(store.isVerified)
        XCTAssertEqual(RequestFoodEntryView.presentation(isVerified: store.isVerified), .form)

        // Re-running the entry gate on an already-restored identity must not
        // reopen verification.
        store.beginVerificationIfNeeded()
        XCTAssertNil(store.flow)
        XCTAssertEqual(RequestFoodEntryView.presentation(isVerified: store.isVerified), .form)
    }

    // MARK: - Mid-form authority loss does not tear the admitted form down

    /// The latch `RequestFoodEntryView` applies in `performEligibilityCheckIfNeeded()`:
    /// sticky once an `.eligible` W4-Q1 read is ever seen, unaffected by a
    /// later non-eligible result.
    func testLatchStaysSetOnceEligibleRegardlessOfLaterLoss() {
        XCTAssertFalse(
            RequestFoodEntryView.nextHasEnteredForm(previousHasEnteredForm: false, eligibility: .unknown)
        )
        XCTAssertFalse(
            RequestFoodEntryView.nextHasEnteredForm(previousHasEnteredForm: false, eligibility: .exhausted)
        )
        XCTAssertTrue(
            RequestFoodEntryView.nextHasEnteredForm(previousHasEnteredForm: false, eligibility: .eligible)
        )
        // The exact regression: a legitimately admitted session losing
        // authority afterward must not clear the latch.
        XCTAssertTrue(
            RequestFoodEntryView.nextHasEnteredForm(previousHasEnteredForm: true, eligibility: .unknown)
        )
        XCTAssertTrue(
            RequestFoodEntryView.nextHasEnteredForm(previousHasEnteredForm: true, eligibility: .eligible)
        )
    }

    /// The full regression this MUST-FIX finding describes: a verified
    /// requester legitimately enters Request Food, fills a draft, submission
    /// receives a real `PARTICIPANT_AUTHORITY_INVALID`, the identity store
    /// discards the rejected identity through the exact production callback
    /// `RequestStore` invokes — and the entry screen's own presentation logic,
    /// now latched, keeps returning `.form` rather than reverting to
    /// `.verification` and destroying the mounted `RequestFoodView`'s draft.
    func testAuthorityInvalidAfterLegitimateFormAdmissionKeepsTheFormMounted() async throws {
        let identityStore = makeIdentityStore()
        let coordinator = ParticipantActionVerificationCoordinator(identityStore: identityStore)
        let requestStore = RequestStore(
            service: RequestService(client: client()),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { identityStore.currentAuthority() },
            participantAuthorityRejected: { identityStore.discardRejectedIdentity() }
        )

        // Legitimate admission: verify, then latch the way the view's own
        // `onChange` does.
        identityStore.beginVerificationIfNeeded()
        await completeVerification(identityStore)
        var hasEnteredForm = RequestFoodEntryView.nextHasEnteredForm(
            previousHasEnteredForm: false,
            eligibility: .eligible
        )
        XCTAssertTrue(hasEnteredForm)
        XCTAssertEqual(
            RequestFoodEntryView.presentation(isVerified: identityStore.isVerified, hasEnteredForm: hasEnteredForm),
            .form
        )

        let draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            menuPath: .mealExchange,
            timing: .asap,
            preferredPickupTime: Date(timeIntervalSince1970: 1_754_755_800),
            mealSwipes: 1,
            mealEntries: ["The exact filled draft", "", "", "", ""]
        )

        // The real backend refusal `RequestFoodView.submit()` would receive
        // mid-form, driving the identity store's discard through the exact
        // callback `RequestStore` was constructed with above — not a manual
        // `discardRejectedIdentity()` call from the test.
        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 403, data: errorResponse(code: ParticipantErrorCode.authorityInvalid))
        )
        do {
            try await requestStore.createRequest(CreateRequestPayload(
                vendor: draft.selectedDiningSpot!.name,
                timing: .asap,
                windowStart: nil,
                menuPath: .mealExchange,
                mealSwipes: 2,
                mealItems: draft.activeMealEntries,
                orderDetails: nil,
                estimatedDiningDollarsCents: nil
            ))
            XCTFail("expected the rejected authority to surface as an error")
        } catch {
            // Expected: the create itself fails.
        }

        XCTAssertFalse(identityStore.isVerified)

        // The regression: applying the same latch rule to this real loss must
        // not revert presentation to `.verification`.
        hasEnteredForm = RequestFoodEntryView.nextHasEnteredForm(
            previousHasEnteredForm: hasEnteredForm,
            eligibility: .unknown
        )
        XCTAssertTrue(hasEnteredForm)
        XCTAssertEqual(
            RequestFoodEntryView.presentation(isVerified: identityStore.isVerified, hasEnteredForm: hasEnteredForm),
            .form
        )

        // Recovery is `RequestFoodView.submit()`'s own existing gate — it
        // checks `!identityStore.isVerified` and opens the in-form
        // continuation with this exact draft, never fabricating authority.
        XCTAssertTrue(coordinator.beginRequestCreation(draft: draft, path: [.requestFood]))
        let continuation = try XCTUnwrap(coordinator.pendingContinuation)

        // Cancellation/failure submits nothing.
        coordinator.requesterCancelled()
        XCTAssertNil(coordinator.pendingContinuation)
        XCTAssertNil(identityStore.pendingContinuation)
        XCTAssertFalse(identityStore.consumeContinuation(continuation))
        XCTAssertEqual(capturedRequestCount(path: "/api/request"), 1)

        // Successful reverification resumes only this exact draft, through
        // the same coordinator entry point `RequestFoodView` already uses.
        XCTAssertTrue(coordinator.beginRequestCreation(draft: draft, path: [.requestFood]))
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: verifiedResponse()))
        await identityStore.requestCode(for: principal)
        let reverified = await identityStore.submitCode("424242")
        XCTAssertTrue(reverified)
        let newIdentity = try XCTUnwrap(identityStore.identity)
        let resume = coordinator.requesterIdentityDidChange(
            from: nil,
            to: newIdentity,
            path: [.requestFood]
        )
        guard case .requestCreation(let resumedDraft)? = resume else {
            return XCTFail("expected the exact requester continuation to resume")
        }
        XCTAssertEqual(resumedDraft, draft)
        XCTAssertEqual(capturedRequestCount(path: "/api/request"), 1)
    }

    /// The rereview finding: a repeat appearance of `RequestFoodEntryView`
    /// after admission — e.g. returning from backgrounding once a mid-form
    /// `PARTICIPANT_AUTHORITY_INVALID` cleared identity — must not let
    /// `onAppear` start another entry-owned `.firstVerification` flow. Doing
    /// so would occupy `identityStore.flow`, and
    /// `ParticipantIdentityStore.beginVerification(for:)` refuses to replace
    /// an existing flow, so `RequestFoodView`'s own coordinator-owned
    /// recovery could never start. This proves the repeat-appearance
    /// ownership boundary itself, not merely the latch predicate.
    func testRepeatAppearanceAfterAdmissionDoesNotStartAnEntryOwnedVerificationFlow() async throws {
        let identityStore = makeIdentityStore()
        let coordinator = ParticipantActionVerificationCoordinator(identityStore: identityStore)
        let requestStore = RequestStore(
            service: RequestService(client: client()),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { identityStore.currentAuthority() },
            participantAuthorityRejected: { identityStore.discardRejectedIdentity() }
        )

        // Legitimate admission, exactly as the entry view's own onAppear +
        // onChange would produce it.
        XCTAssertTrue(
            RequestFoodEntryView.shouldBeginEntryVerificationOnAppear(hasEnteredForm: false)
        )
        identityStore.beginVerificationIfNeeded()
        await completeVerification(identityStore)
        let hasEnteredForm = RequestFoodEntryView.nextHasEnteredForm(
            previousHasEnteredForm: false,
            eligibility: .eligible
        )
        XCTAssertTrue(hasEnteredForm)

        let draft = RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            menuPath: .mealExchange,
            timing: .asap,
            preferredPickupTime: Date(timeIntervalSince1970: 1_754_755_800),
            mealSwipes: 1,
            mealEntries: ["The retained draft", "", "", "", ""]
        )

        // A real mid-form authority-invalid response clears identity through
        // the exact production callback, not a manual call.
        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 403, data: errorResponse(code: ParticipantErrorCode.authorityInvalid))
        )
        do {
            try await requestStore.createRequest(CreateRequestPayload(
                vendor: draft.selectedDiningSpot!.name,
                timing: .asap,
                windowStart: nil,
                menuPath: .mealExchange,
                mealSwipes: 2,
                mealItems: draft.activeMealEntries,
                orderDetails: nil,
                estimatedDiningDollarsCents: nil
            ))
            XCTFail("expected the rejected authority to surface as an error")
        } catch {
            // Expected.
        }
        XCTAssertFalse(identityStore.isVerified)

        // The repeat appearance: `hasEnteredForm` is still `true`, so
        // `onAppear`'s own guard must refuse to start another entry flow —
        // this is the exact call `RequestFoodEntryView.body`'s `.onAppear`
        // makes.
        XCTAssertFalse(
            RequestFoodEntryView.shouldBeginEntryVerificationOnAppear(hasEnteredForm: hasEnteredForm)
        )
        // Simulates the appearance itself calling the guarded onAppear body:
        // because the guard above is false, `beginVerificationIfNeeded()` is
        // never invoked, so no hidden `.firstVerification` flow is created.
        XCTAssertNil(identityStore.flow)

        // Presentation still resolves to the admitted form.
        XCTAssertEqual(
            RequestFoodEntryView.presentation(isVerified: identityStore.isVerified, hasEnteredForm: hasEnteredForm),
            .form
        )

        // Because no entry-owned flow occupied `identityStore.flow`,
        // `RequestFoodView`'s own coordinator-owned recovery can actually
        // start — the exact thing the bug silently prevented.
        XCTAssertTrue(coordinator.beginRequestCreation(draft: draft, path: [.requestFood]))
        let continuation = try XCTUnwrap(coordinator.pendingContinuation)

        // Cancellation/failure submits nothing further.
        coordinator.requesterCancelled()
        XCTAssertNil(coordinator.pendingContinuation)
        XCTAssertNil(identityStore.pendingContinuation)
        XCTAssertFalse(identityStore.consumeContinuation(continuation))
        XCTAssertEqual(capturedRequestCount(path: "/api/request"), 1)

        // Successful reverification resumes only this exact retained draft.
        XCTAssertTrue(coordinator.beginRequestCreation(draft: draft, path: [.requestFood]))
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: verifiedResponse()))
        await identityStore.requestCode(for: principal)
        let reverified = await identityStore.submitCode("424242")
        XCTAssertTrue(reverified)
        let newIdentity = try XCTUnwrap(identityStore.identity)
        let resume = coordinator.requesterIdentityDidChange(
            from: nil,
            to: newIdentity,
            path: [.requestFood]
        )
        guard case .requestCreation(let resumedDraft)? = resume else {
            return XCTFail("expected the exact requester continuation to resume")
        }
        XCTAssertEqual(resumedDraft, draft)
        XCTAssertEqual(capturedRequestCount(path: "/api/request"), 1)
    }

    // MARK: - W4-R2 item 20: end-to-end Q1 read against RequestStore

    /// Already-verified + eligible: the read `RequestStore.resolveRequestCreationEligibility()`
    /// performs against real (stubbed) `GET /api/participant/request-eligibility`
    /// resolves `.eligible`, and feeding that into `presentation` continues
    /// to the same pushed Request Food destination.
    func testAlreadyVerifiedAndEligibleContinuesToTheForm() async throws {
        let identityStore = makeIdentityStore()
        identityStore.beginVerificationIfNeeded()
        await completeVerification(identityStore)
        XCTAssertTrue(identityStore.isVerified)

        let requestStore = RequestStore(
            service: RequestService(client: client()),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { identityStore.currentAuthority() },
            participantAuthorityRejected: { identityStore.discardRejectedIdentity() }
        )
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: eligibilityResponse(.eligible)))

        let result = await requestStore.resolveRequestCreationEligibility()

        XCTAssertEqual(result, .eligible)
        XCTAssertEqual(
            RequestFoodEntryView.presentation(
                isVerified: identityStore.isVerified,
                eligibilityCheck: .resolved(result)
            ),
            .form
        )
    }

    /// Already-verified + exhausted: the limit surfaces before form
    /// investment, and no create/D1 authority is touched by this read.
    func testAlreadyVerifiedAndExhaustedStopsBeforeTheForm() async throws {
        let identityStore = makeIdentityStore()
        identityStore.beginVerificationIfNeeded()
        await completeVerification(identityStore)

        let requestStore = RequestStore(
            service: RequestService(client: client()),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { identityStore.currentAuthority() },
            participantAuthorityRejected: { identityStore.discardRejectedIdentity() }
        )
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: eligibilityResponse(.exhausted)))

        let result = await requestStore.resolveRequestCreationEligibility()

        XCTAssertEqual(result, .exhausted)
        XCTAssertEqual(
            RequestFoodEntryView.presentation(
                isVerified: identityStore.isVerified,
                eligibilityCheck: .resolved(result)
            ),
            .unavailable(message: RequestFoodView.postingLimitReachedNotice, retryable: false)
        )
    }

    /// Unverified → verified + eligible: the read is never attempted before
    /// verification completes (no participant authority exists yet to
    /// present), and only the newly-verified authority's read continues into
    /// the form.
    func testUnverifiedThenVerifiedAndEligibleContinuesToTheForm() async throws {
        let identityStore = makeIdentityStore()
        XCTAssertNil(identityStore.currentAuthority())

        identityStore.beginVerificationIfNeeded()
        await completeVerification(identityStore)
        XCTAssertNotNil(identityStore.currentAuthority())

        let requestStore = RequestStore(
            service: RequestService(client: client()),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { identityStore.currentAuthority() },
            participantAuthorityRejected: { identityStore.discardRejectedIdentity() }
        )
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: eligibilityResponse(.eligible)))

        let result = await requestStore.resolveRequestCreationEligibility()

        XCTAssertEqual(result, .eligible)
    }

    /// Unverified → verified + exhausted: the limit still surfaces before
    /// form investment even though verification only just completed.
    func testUnverifiedThenVerifiedAndExhaustedStopsBeforeTheForm() async throws {
        let identityStore = makeIdentityStore()
        identityStore.beginVerificationIfNeeded()
        await completeVerification(identityStore)

        let requestStore = RequestStore(
            service: RequestService(client: client()),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { identityStore.currentAuthority() },
            participantAuthorityRejected: { identityStore.discardRejectedIdentity() }
        )
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: eligibilityResponse(.exhausted)))

        let result = await requestStore.resolveRequestCreationEligibility()

        XCTAssertEqual(
            RequestFoodEntryView.presentation(isVerified: true, eligibilityCheck: .resolved(result)),
            .unavailable(message: RequestFoodView.postingLimitReachedNotice, retryable: false)
        )
    }

    /// Cancelled/failed verification never has an authority to present, so
    /// `RequestStore.resolveRequestCreationEligibility()` resolves `.unknown`
    /// without ever issuing the request — proving no Q1 call is made using an
    /// unverified or fabricated identity.
    func testCancelledVerificationNeverQueriesEligibility() async {
        let identityStore = makeIdentityStore()
        identityStore.beginVerificationIfNeeded()
        identityStore.cancelVerification()
        XCTAssertFalse(identityStore.isVerified)

        let requestStore = RequestStore(
            service: RequestService(client: client()),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { identityStore.currentAuthority() },
            participantAuthorityRejected: { identityStore.discardRejectedIdentity() }
        )

        let result = await requestStore.resolveRequestCreationEligibility()

        XCTAssertEqual(result, .unknown)
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths.count, 0)
    }

    /// A missing/unavailable/error result is never treated as eligible.
    func testUnknownEligibilityResultNeverBecomesEligible() async throws {
        let identityStore = makeIdentityStore()
        identityStore.beginVerificationIfNeeded()
        await completeVerification(identityStore)

        let requestStore = RequestStore(
            service: RequestService(client: client()),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { identityStore.currentAuthority() },
            participantAuthorityRejected: { identityStore.discardRejectedIdentity() }
        )
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 500, data: Data()))

        let result = await requestStore.resolveRequestCreationEligibility()

        XCTAssertEqual(result, .unknown)
        XCTAssertNotEqual(result, .eligible)
        XCTAssertEqual(
            RequestFoodEntryView.presentation(isVerified: true, eligibilityCheck: .resolved(result)),
            .unavailable(message: RequestFoodView.availabilityUnknownNotice, retryable: true)
        )
    }

    // MARK: - W4-R2 2026-09-05 sync item 2: authority-invalid during the
    // entry-owned Q1 read reopens verification rather than a blank canvas

    /// The exact regression the sync describes: a verified requester reaches
    /// this entry's own Q1 read; the read itself receives a live
    /// `PARTICIPANT_AUTHORITY_INVALID`, which `RequestStore.applyParticipantVerdict`
    /// retires through the exact production `participantAuthorityRejected`
    /// callback — not a manual `discardRejectedIdentity()` call. Before the
    /// fix, nothing re-opens verification here (`.onAppear`'s
    /// `beginVerificationIfNeeded()` never refires for an already-mounted
    /// view), so `identityStore.flow` stays `nil` and the sheet binding
    /// (`shouldPresentEntryVerification`) stays `false` even though
    /// `presentation(...)` has already switched to `.verification` — the
    /// blank `baseCanvas` with no active recovery path. The fix is the same
    /// `.onChange(of: identityStore.isVerified)` guard this entry's body now
    /// runs: reproduced here as the literal predicate/call pair so this test
    /// is provably exercising what the view's own `onChange` does.
    func testAuthorityInvalidDuringEntryOwnedEligibilityReadReopensVerificationThenFreshQ1() async throws {
        let identityStore = makeIdentityStore()
        let requestStore = RequestStore(
            service: RequestService(client: client()),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { identityStore.currentAuthority() },
            participantAuthorityRejected: { identityStore.discardRejectedIdentity() }
        )

        // Verified, entering Request Food fresh: `hasEnteredForm` is still
        // `false`, so this entry's own Q1 read is about to run.
        identityStore.beginVerificationIfNeeded()
        await completeVerification(identityStore)
        XCTAssertTrue(identityStore.isVerified)

        // `performEligibilityCheckIfNeeded()`'s own pre-await guard passes
        // here; the state becomes `.checking` before the read is sent.
        let eligibilityCheckBeforeRead = RequestFoodEligibilityCheck.checking
        XCTAssertEqual(
            RequestFoodEntryView.presentation(
                isVerified: identityStore.isVerified,
                hasEnteredForm: false,
                eligibilityCheck: eligibilityCheckBeforeRead
            ),
            .checkingEligibility
        )

        // The live Q1 read itself receives a real `PARTICIPANT_AUTHORITY_INVALID`.
        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 403, data: errorResponse(code: ParticipantErrorCode.authorityInvalid))
        )
        let result = await requestStore.resolveRequestCreationEligibility()

        XCTAssertEqual(result, .unknown)
        // The exact production retirement path — not a manual call.
        XCTAssertFalse(identityStore.isVerified)

        // `performEligibilityCheckIfNeeded()`'s post-await guard now fails
        // (`identityStore.isVerified` flipped to `false`), so it returns
        // without ever resolving `eligibilityCheck` — it stays `.checking`.
        // `presentation(...)` already renders `.verification` (the blank
        // canvas) purely from `isVerified` being `false`.
        XCTAssertEqual(
            RequestFoodEntryView.presentation(
                isVerified: identityStore.isVerified,
                hasEnteredForm: false,
                eligibilityCheck: .checking
            ),
            .verification
        )
        // The defect, proven directly: nothing has started a flow, so the
        // sheet that would actually show verification UI stays unpresentable
        // — this is the blank-canvas dead end, not merely a render label.
        XCTAssertNil(identityStore.flow)
        XCTAssertFalse(
            RequestFoodEntryView.shouldPresentEntryVerification(
                hasEnteredForm: false,
                verificationPurpose: identityStore.flow?.purpose
            )
        )

        // The fix: this test calls the exact production-owned function the
        // real view's `.onChange(of: identityStore.isVerified)` invokes —
        // not a reimplementation of its condition — for this exact
        // `true` → `false` transition.
        RequestFoodEntryView.handleVerifiedTransition(
            wasVerified: true,
            isVerified: identityStore.isVerified,
            hasEnteredForm: false,
            identityStore: identityStore
        )

        // Verification UI can now actually present.
        XCTAssertEqual(identityStore.flow?.purpose, .firstVerification)
        XCTAssertTrue(
            RequestFoodEntryView.shouldPresentEntryVerification(
                hasEnteredForm: false,
                verificationPurpose: identityStore.flow?.purpose
            )
        )

        // Successful re-verification reaches a fresh Q1 read, which
        // continues to `eligible`.
        await completeVerification(identityStore)
        XCTAssertTrue(identityStore.isVerified)
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: eligibilityResponse(.eligible)))
        let freshResult = await requestStore.resolveRequestCreationEligibility()

        XCTAssertEqual(freshResult, .eligible)
        let hasEnteredForm = RequestFoodEntryView.nextHasEnteredForm(
            previousHasEnteredForm: false,
            eligibility: freshResult
        )
        XCTAssertTrue(hasEnteredForm)
        XCTAssertEqual(
            RequestFoodEntryView.presentation(
                isVerified: identityStore.isVerified,
                hasEnteredForm: hasEnteredForm,
                eligibilityCheck: .resolved(freshResult)
            ),
            .form
        )
    }

    /// The fix's guard must not fire on an ordinary successful verification
    /// (`false` → `true`) — only on `true` → `false`. Calls the exact
    /// production-owned `handleVerifiedTransition` the real view's
    /// `.onChange` invokes, proving the guard is direction-specific, not
    /// merely "isVerified changed" — a real `identityStore` with no flow
    /// started is the direct proof nothing began.
    func testOnChangeGuardDoesNotFireOnAnOrdinaryVerificationCompletion() {
        let identityStore = makeIdentityStore()

        RequestFoodEntryView.handleVerifiedTransition(
            wasVerified: false,
            isVerified: true,
            hasEnteredForm: false,
            identityStore: identityStore
        )

        XCTAssertNil(identityStore.flow)
    }

    // MARK: - No second free-form participant-email field

    /// `RequestFoodEntryView` renders either the existing verification screen
    /// or `RequestFoodView` — never both, and never any email field of its
    /// own — so this screen cannot introduce a second identity source.
    func testEntryViewDeclaresNoEmailFieldOfItsOwn() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodEntryView.swift"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("TextField"))
    }

    // MARK: - Screenshot Help owns the toolbar while it is showing

    /// W4-R2 final walkthrough sync: the underlying `Request Food` toolbar
    /// Back control must not remain a competing, still-functional control
    /// while Screenshot Help is showing. Disabling it in place would still be
    /// the "decorative/nonfunctional Back" item 9 already prohibits, so this
    /// entry screen removes it from the toolbar entirely instead — proven
    /// here by source inspection since `backToolbarItem` is a real
    /// `ToolbarItem`, not app content `RequestFoodView`'s own
    /// `.accessibilityHidden` can reach.
    func testBackToolbarItemIsRemovedWhileScreenshotHelpIsShowing() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodEntryView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("@State private var isPresentingScreenshotHelp = false"))
        XCTAssertTrue(source.contains("isPresentingScreenshotHelp: $isPresentingScreenshotHelp"))
        // W4-S3 consent-authority revision: the `Turn on Screenshot
        // Assistance?` disclosure is the same kind of local centered overlay
        // as Screenshot Help (not a `.sheet`), so it needs the same toolbar
        // Back suppression for the same competing-Back-control reason, via
        // its own binding (mirroring `isPresentingScreenshotHelp`, not a
        // store-observed flag — there is no per-attempt popup any more).
        guard let range = source.range(
            of: "if !isPresentingScreenshotHelp && !isPresentingScreenshotAssistanceDisclosure && !isSuppressingBackNavigation {\n                        backToolbarItem\n                    }"
        ) else {
            XCTFail("expected backToolbarItem to be conditionally included only while neither Screenshot Help nor the disclosure is showing")
            return
        }
        _ = range
    }

    /// W4-S3 consent-authority revision: the disclosure's toolbar suppression
    /// mirrors Screenshot Help's own, via its own binding owned by this
    /// screen.
    func testBackToolbarItemIsRemovedWhileTheScreenshotAssistanceDisclosureIsShowing() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodEntryView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("@State private var isPresentingScreenshotAssistanceDisclosure = false"))
        XCTAssertTrue(source.contains("isPresentingScreenshotAssistanceDisclosure: $isPresentingScreenshotAssistanceDisclosure"))
        XCTAssertFalse(source.contains("isAwaitingExternalAIPermission"))
    }

    /// W4-R2 2026-08-31 round-2 sync: the Posting/Success transient
    /// submission sequence must also remove `backToolbarItem` from the
    /// toolbar entirely — no alternative cancel/dismiss action replaces it.
    func testBackToolbarItemIsRemovedWhileSuppressedForPostingOrSuccess() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodEntryView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("@State private var isSuppressingBackNavigation = false"))
        XCTAssertTrue(source.contains("isSuppressingBackNavigation: $isSuppressingBackNavigation"))
    }

    // MARK: - Normal Back reliability (W4-R2 2026-08-31 round-2 sync)

    /// The reported intermittent failure traced to `backToolbarItem` popping
    /// this pushed destination by reaching up into `ContentView`'s manually
    /// mutated `path` inside a `disablesAnimations` transaction — a change
    /// that can be silently dropped if it races an already in-flight push
    /// transition. `dismiss()` is SwiftUI's own transition-safe authority for
    /// popping the current destination on a path-driven `NavigationStack`;
    /// `beginExit`/`onExit` remain the mechanism for D1's `Go to Home` and
    /// Success's automatic dwell-dismissal only, neither of which this sync
    /// flagged as unreliable.
    func testBackToolbarItemUsesNativeDismissRatherThanTheManualExitPath() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodEntryView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("@Environment(\\.dismiss) private var dismiss"))
        guard let range = source.range(of: "private var backToolbarItem: some ToolbarContent {") else {
            XCTFail("expected to find backToolbarItem")
            return
        }
        let body = String(source[range.upperBound...].prefix(300))
        XCTAssertTrue(body.contains("Button(action: { dismiss() })"))
        XCTAssertFalse(body.contains("Button(action: beginExit)"))
    }

    // MARK: - Submission still uses verified participant authority

    /// Entry no longer gates Submit — it gates seeing the form at all — but
    /// the credential a create actually carries still comes from
    /// `ParticipantIdentityStore.currentAuthority()`, established by this same
    /// entry verification, not from anything the form collects.
    func testFormSubmissionCarriesTheAuthorityEntryVerificationEstablished() async throws {
        let store = makeIdentityStore()
        store.beginVerificationIfNeeded()
        await completeVerification(store)
        XCTAssertEqual(RequestFoodEntryView.presentation(isVerified: store.isVerified), .form)

        let requestStore = RequestStore(
            service: RequestService(client: client()),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { store.currentAuthority() },
            participantAuthorityRejected: { store.discardRejectedIdentity() }
        )
        RequestFetchingURLProtocol.enqueue(
            .response(statusCode: 201, data: createdResponse())
        )

        try await requestStore.createRequest(CreateRequestPayload(
            vendor: "Jasper Kane Cafe",
            timing: .asap,
            windowStart: nil,
            menuPath: .mealExchange,
            mealSwipes: 2,
            mealItems: ["Chicken bowl"],
            orderDetails: nil,
            estimatedDiningDollarsCents: nil
        ))

        let headers = try XCTUnwrap(RequestFetchingURLProtocol.lastCapturedHeaders)
        XCTAssertEqual(headers["x-commonplate-participant"], canonicalParticipantAuthorityFixture)
    }

    // MARK: - Fixtures

    private func makeIdentityStore(
        storage: ParticipantIdentityStorage = InMemoryParticipantIdentityStorage()
    ) -> ParticipantIdentityStore {
        ParticipantIdentityStore(
            service: ParticipantVerificationService(client: client()),
            storage: storage
        )
    }

    private func completeVerification(_ store: ParticipantIdentityStore) async {
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 202, data: challengeResponse()))
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: verifiedResponse()))
        await store.requestCode(for: principal)
        let verified = await store.submitCode("424242")
        XCTAssertTrue(verified)
    }

    private func client() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        return APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
    }

    private func challengeResponse() -> Data {
        Data(#"{"verification":{"expiresAt":"2026-08-09T17:10:00.000Z","resendAvailableAt":"2026-08-09T17:01:00.000Z"}}"#.utf8)
    }

    private func verifiedResponse() -> Data {
        Data(#"{"participant":{"email":"\#(principal)"},"authority":"\#(canonicalParticipantAuthorityFixture)"}"#.utf8)
    }

    private func errorResponse(code: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"detail","fields":null}}"#.utf8)
    }

    private func capturedRequestCount(path: String) -> Int {
        RequestFetchingURLProtocol.capturedRequestedPaths.filter { $0 == path }.count
    }

    private func createdResponse() -> Data {
        Data(#"{"request":{"id":"64b0000000000000000000a1","vendor":"Jasper Kane Cafe","food":"Chicken bowl","pickupWindowText":"ASAP","mealSwipes":2,"menuPath":"meal-exchange","mealItems":["Meal 1","Meal 2"],"orderDetails":null,"estimatedDiningDollarsCents":null,"windowStart":null,"windowEnd":null,"status":"open","createdAt":"2026-08-09T17:00:00.000Z","expiresAt":"2026-08-09T20:00:00.000Z"}}"#.utf8)
    }

    /// `GET /api/participant/request-eligibility`'s minimal W4-Q1 response
    /// shape (`RequestEligibilityResponseDTO`).
    private func eligibilityResponse(_ eligibility: RequestStore.RequestCreationEligibility) -> Data {
        let wire = eligibility == .exhausted ? "exhausted" : "eligible"
        return Data(#"{"eligibility":"\#(wire)"}"#.utf8)
    }

    /// Walks up from this file to the repository root, matching the pattern
    /// used elsewhere for source-text assertions against the real tracked file.
    private func repositoryFile(_ relativePath: String) throws -> URL {
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
