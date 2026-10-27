//
//  PlacedOrderEvidenceFlowTests.swift
//  CommonPlateiosTests
//
// W4-H1a required placed-order screenshot through the real
// APIClient → RequestService → RequestStore boundary (URLProtocol transport),
// plus the view-level gating, copy, and source-structure facts that cannot be
// observed through the transport:
//
// - the screenshot is on the wire in BOTH authorization shapes, as exact
//   MIME + base64 of the exact normalized bytes;
// - one submission snapshot owns those bytes, and the single permitted
//   CommonPlate-only resend sends the IDENTICAL image — never a re-selected one,
//   and a different image cannot be injected while the ambiguity is unresolved;
// - a definitive backend evidence refusal (and only that) maps back to the
//   screenshot message, leaves the reservation intact, and never becomes an
//   ambiguity or a status check;
// - unrelated failures keep their classifications;
// - a relaunch-restored reservation needs the screenshot added again, while an
//   already-placed reconciliation neither asks for one nor offers Open Grubhub;
// - the screenshot bytes are never persisted, logged, or described.
//
// Rendering of the chooser / attached states is verified separately on the
// Simulator and device; nothing here renders a view.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class PlacedOrderEvidenceFlowTests: XCTestCase {
    private let requestID = "placed-order-evidence-target"
    private let participantAuthority = "64c0000000000000000000a1.1.credential"

    override func tearDown() {
        ClaimFlowURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Wire shape, both authorization shapes

    func testTheTokenShapeSendsTheExactScreenshotAsMIMEAndBase64() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "raw-token")))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse()))
        let screenshot = PlacedOrderScreenshot.fixture(seed: 21)

        store.selectPlacedOrderScreenshot(screenshot, requestID: requestID)
        try await store.fulfill(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )

        let post = try fulfillPosts().first.unwrap()
        XCTAssertEqual(post.bodyObject?["claimToken"] as? String, "raw-token")
        try assertScreenshotOnTheWire(post, equals: screenshot)
        XCTAssertNotNil(store.fulfillmentConfirmation)
    }

    func testTheContinuationShapeSendsTheSameScreenshotWithParticipantAuthority() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: activeReservationResponse()))
        _ = try await store.continueActiveReservationIfNeeded()
        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse()))
        let screenshot = PlacedOrderScreenshot.fixture(seed: 22)

        store.selectPlacedOrderScreenshot(screenshot, requestID: requestID)
        try await store.fulfill(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "ASAP",
            contactMessage: "Meet at the door"
        )

        let post = try fulfillPosts().first.unwrap()
        XCTAssertNil(post.bodyObject?["claimToken"])
        XCTAssertEqual(post.headers[RequestService.participantAuthorityHeader], participantAuthority)
        try assertScreenshotOnTheWire(post, equals: screenshot)
    }

    // MARK: - One snapshot owns the exact bytes; the resend sends the identical image

    func testTheAmbiguousResendCarriesTheIdenticalImageAndNoOtherCanBeInjected() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "raw-token")))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "claimed")))
        let original = PlacedOrderScreenshot.fixture(seed: 31)

        do {
            store.selectPlacedOrderScreenshot(original, requestID: requestID)
            try await store.fulfill(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "30 minutes",
                contactMessage: nil
            )
            XCTFail("the first write must remain ambiguous")
        } catch RequestServiceError.ambiguousFulfillmentOutcome {
            // Expected after the one inconclusive read-only status check.
        }
        let ambiguity = try XCTUnwrap(store.fulfillmentAmbiguity)

        // A different, freshly "re-selected" image cannot be submitted while the
        // ambiguity is unresolved: ambiguity is never turned into reselection.
        do {
            store.selectPlacedOrderScreenshot(.fixture(seed: 99), requestID: requestID)
            try await store.fulfill(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "30 minutes",
                contactMessage: nil
            )
            XCTFail("a second submission during ambiguity must be refused")
        } catch RequestServiceError.unresolvedFulfillment {
            // Expected.
        }
        XCTAssertEqual(try fulfillPosts().count, 1, "no POST was sent for the refused attempt")

        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse()))
        try await store.resubmitAmbiguousFulfillment(ambiguityID: ambiguity.id, requestID: requestID)

        let posts = try fulfillPosts()
        XCTAssertEqual(posts.count, 2)
        for post in posts {
            try assertScreenshotOnTheWire(post, equals: original)
        }
        XCTAssertEqual(
            try canonicalJSON(posts[0].bodyObject),
            try canonicalJSON(posts[1].bodyObject),
            "the resend is byte-for-byte the original request"
        )
        XCTAssertNotNil(store.fulfillmentConfirmation)
    }

    func testTheContinuationShapeResendAlsoCarriesTheIdenticalImage() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: activeReservationResponse()))
        _ = try await store.continueActiveReservationIfNeeded()
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "claimed")))
        let original = PlacedOrderScreenshot.fixture(seed: 32)

        store.selectPlacedOrderScreenshot(original, requestID: requestID)
        try? await store.fulfill(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "ASAP",
            contactMessage: nil
        )
        let ambiguity = try XCTUnwrap(store.fulfillmentAmbiguity)
        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse()))
        try await store.resubmitAmbiguousFulfillment(ambiguityID: ambiguity.id, requestID: requestID)

        let posts = try fulfillPosts()
        XCTAssertEqual(posts.count, 2)
        for post in posts {
            XCTAssertEqual(post.headers[RequestService.participantAuthorityHeader], participantAuthority)
            try assertScreenshotOnTheWire(post, equals: original)
        }
    }

    // MARK: - Definitive backend refusal of the evidence

    func testADefinitiveEvidenceRefusalKeepsTheReservationAndAllowsAnotherScreenshot() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "raw-token")))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 400,
            data: errorResponse(
                code: ClaimErrorCode.invalidPlacedOrderScreenshot,
                message: "The order screenshot is missing or can’t be used."
            )
        ))
        let rejected = PlacedOrderScreenshot.fixture(seed: 41)

        do {
            store.selectPlacedOrderScreenshot(rejected, requestID: requestID)
            try await store.fulfill(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
            XCTFail("a definitive refusal must surface")
        } catch RequestServiceError.serverError(let code, _) {
            XCTAssertEqual(code, "INVALID_PLACED_ORDER_SCREENSHOT")
        }

        // Definitive: no ambiguity, no status check, nothing fabricated.
        XCTAssertNil(store.fulfillmentAmbiguity)
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedPaths.filter { $0 == "/api/request/\(requestID)" }.count,
            0,
            "a pre-mutation refusal triggers no read-only status check"
        )
        // The reservation survives, so the helper can choose another image.
        XCTAssertNotNil(store.activeClaim)
        XCTAssertTrue(store.canSubmitFulfillment(requestID: requestID))
        // It maps to the screenshot message — and to no form-level error.
        XCTAssertTrue(FulfillRequestView.isPlacedOrderScreenshotRefusal(store.fulfillError))
        XCTAssertNil(FulfillmentPresentationError.map(store.fulfillError))

        // A fresh choice then submits that new image, not the refused one.
        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse()))
        let replacement = PlacedOrderScreenshot.fixture(seed: 42)
        store.selectPlacedOrderScreenshot(replacement, requestID: requestID)
        try await store.fulfill(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )
        let posts = try fulfillPosts()
        XCTAssertEqual(posts.count, 2)
        try assertScreenshotOnTheWire(posts[0], equals: rejected)
        try assertScreenshotOnTheWire(posts[1], equals: replacement)
        XCTAssertNotEqual(rejected, replacement)
        XCTAssertNotNil(store.fulfillmentConfirmation)
    }

    func testOnlyTheScreenshotRefusalMapsToTheScreenshotMessage() {
        XCTAssertTrue(FulfillRequestView.isPlacedOrderScreenshotRefusal(
            .serverError(code: ClaimErrorCode.invalidPlacedOrderScreenshot, message: "x")
        ))
        let unrelated: [RequestServiceError?] = [
            nil,
            .serverError(code: "INVALID_FULFILLMENT_PAYLOAD", message: "x"),
            .serverError(code: ClaimErrorCode.internalFailure, message: "x"),
            .serverError(code: ClaimErrorCode.requestNotClaimed, message: "x"),
            .serverError(code: ClaimErrorCode.invalidClaimToken, message: "x"),
            .serverError(code: ClaimErrorCode.claimExpired, message: "x"),
            .serverError(code: ClaimErrorCode.requestAlreadyPlaced, message: "x"),
            .serverError(code: ClaimErrorCode.rateLimited, message: "x"),
            .serverError(code: "TRANSACTIONS_UNAVAILABLE", message: "x"),
            .serverError(code: "PARTICIPANT_VERIFICATION_REQUIRED", message: "x"),
            .ambiguousFulfillmentOutcome(underlying: URLError(.networkConnectionLost)),
            .transport(underlying: URLError(.notConnectedToInternet)),
            .noActiveClaim,
            .claimExpired,
            .unresolvedFulfillment,
            .operationInProgress
        ]
        for error in unrelated {
            XCTAssertFalse(
                FulfillRequestView.isPlacedOrderScreenshotRefusal(error),
                "\(String(describing: error)) must not read as an invalid screenshot"
            )
        }
    }

    func testANetworkLossIsAmbiguityNeverAnInvalidScreenshot() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "raw-token")))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "claimed")))

        store.selectPlacedOrderScreenshot(.fixture(seed: 51), requestID: requestID)
        try? await store.fulfill(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )

        XCTAssertNotNil(store.fulfillmentAmbiguity)
        XCTAssertFalse(FulfillRequestView.isPlacedOrderScreenshotRefusal(store.fulfillError))
        XCTAssertNil(FulfillmentPresentationError.map(store.fulfillError), "ambiguity has its own flow")
    }

    func testAServerFailureKeepsItsOwnClassificationNotTheScreenshotMessage() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "raw-token")))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 429,
            data: errorResponse(code: ClaimErrorCode.rateLimited, message: "Slow down.")
        ))

        store.selectPlacedOrderScreenshot(.fixture(seed: 52), requestID: requestID)
        try? await store.fulfill(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )

        XCTAssertFalse(FulfillRequestView.isPlacedOrderScreenshotRefusal(store.fulfillError))
        XCTAssertEqual(FulfillmentPresentationError.map(store.fulfillError), .rateLimited)
    }

    // MARK: - Success, including the accepted failed-email ending (D-A3)

    func testRequesterEmailFailureIsStillTheAcceptedSuccessWithNoRecoveryAction() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "raw-token")))
        try await store.claim(requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse(notificationStatus: "failed")))

        store.selectPlacedOrderScreenshot(.fixture(seed: 61), requestID: requestID)
        try await store.fulfill(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )

        let confirmation = try XCTUnwrap(store.fulfillmentConfirmation)
        XCTAssertEqual(confirmation.kind, .notificationFailed)
        XCTAssertEqual(HelperSuccessCopy.headline, "Thanks for helping.")
        XCTAssertEqual(
            HelperSuccessCopy.supportingLines(for: confirmation.kind, messageSuppressed: false),
            ["We couldn't email the requester."]
        )
        XCTAssertNil(store.fulfillError)
        XCTAssertNil(store.fulfillmentAmbiguity)
        XCTAssertNil(store.activeClaim)
        // No retry of any kind is on offer: nothing can submit again.
        XCTAssertFalse(store.canSubmitFulfillment(requestID: requestID))
        XCTAssertEqual(try fulfillPosts().count, 1)
    }

    // MARK: - Relaunch

    func testAReservationRestoredAfterRelaunchIsMarkedSoTheScreenshotIsAddedAgain() async throws {
        let inProcess = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "raw-token")))
        try await inProcess.claim(requestID: requestID)
        XCTAssertEqual(inProcess.activeClaim?.wasRestoredByContinuation, false)

        let relaunched = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: activeReservationResponse()))
        _ = try await relaunched.continueActiveReservationIfNeeded()
        XCTAssertEqual(relaunched.activeClaim?.wasRestoredByContinuation, true)
        // The restored reservation is still authoritatively fulfillable, so the
        // only missing piece is the screenshot — which a relaunch never retains.
        XCTAssertTrue(relaunched.canSubmitFulfillment(requestID: requestID))
    }

    func testTheChooserNoticeIsTheContractedCopyAndNeverRedForAMissingScreenshot() {
        // Nothing chosen yet, in-process: incomplete state, NO notice at all.
        XCTAssertNil(PlacedOrderScreenshotNotice.resolve(
            hasAttachedScreenshot: false,
            lastSelectionWasInvalid: false,
            reservationWasRestoredByContinuation: false
        ))
        // Relaunch with no bytes: no reselection notice (removed, Faith R3 recheck).
        XCTAssertNil(PlacedOrderScreenshotNotice.resolve(
            hasAttachedScreenshot: false,
            lastSelectionWasInvalid: false,
            reservationWasRestoredByContinuation: true
        ))
        // A failed attempt outranks the relaunch reminder.
        XCTAssertEqual(
            PlacedOrderScreenshotNotice.resolve(
                hasAttachedScreenshot: false,
                lastSelectionWasInvalid: true,
                reservationWasRestoredByContinuation: true
            ),
            .invalid
        )
        // Once attached, nothing is explained.
        for invalid in [false, true] {
            for restored in [false, true] {
                XCTAssertNil(PlacedOrderScreenshotNotice.resolve(
                    hasAttachedScreenshot: true,
                    lastSelectionWasInvalid: invalid,
                    reservationWasRestoredByContinuation: restored
                ))
            }
        }
        XCTAssertEqual(
            PlacedOrderScreenshotNotice.invalid.message,
            "This image can’t be used. Choose another screenshot to continue."
        )
    }

    func testAnAlreadyPlacedReconciliationAsksForNoScreenshotAndOffersNoExternalOrder() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: placedReservationStateResponse()))

        _ = try await store.continueActiveReservationIfNeeded()

        XCTAssertNil(store.activeClaim, "there is no Helping page, so no chooser and no notice")
        XCTAssertFalse(store.canSubmitFulfillment(requestID: requestID))
        XCTAssertFalse(FulfillRequestView.isOpenGrubhubAvailable(
            requestID: requestID,
            activeClaimRequestID: store.activeClaim?.requestID,
            isFulfilling: false,
            hasFulfillmentAmbiguity: false,
            confirmationRequestID: nil
        ))
        XCTAssertTrue(try fulfillPosts().isEmpty)
    }

    // MARK: - Gating and submission (view-level pure seams)

    func testFinishHelpingIsUnavailableUntilAScreenshotIsSelected() {
        let draft = FulfillmentFormDraft(
            orderNumber: "70154321",
            eta: FulfillmentReadyTime.asap.etaValue,
            readyTime: .asap
        )
        XCTAssertFalse(FulfillRequestView.isSubmissionEnabled(
            draft: draft, hasPlacedOrderScreenshot: false, isOperationallyAvailable: true
        ))
        // A missing screenshot is incomplete, not invalid: there is no field
        // error to show for it.
        XCTAssertTrue(FulfillmentFormValidator.validate(orderNumber: draft.orderNumber).isEmpty)

        XCTAssertTrue(FulfillRequestView.isSubmissionEnabled(
            draft: draft, hasPlacedOrderScreenshot: true, isOperationallyAvailable: true
        ))
        // Every other authoritative gate still applies.
        XCTAssertFalse(FulfillRequestView.isSubmissionEnabled(
            draft: draft, hasPlacedOrderScreenshot: true, isOperationallyAvailable: false
        ))
        var badOrder = draft
        badOrder.orderNumber = "70A"
        XCTAssertFalse(FulfillRequestView.isSubmissionEnabled(
            draft: badOrder, hasPlacedOrderScreenshot: true, isOperationallyAvailable: true
        ))
        var noETA = draft
        noETA.readyTime = nil
        noETA.eta = ""
        XCTAssertFalse(FulfillRequestView.isSubmissionEnabled(
            draft: noETA, hasPlacedOrderScreenshot: true, isOperationallyAvailable: true
        ))
    }

    func testSubmissionNeverReachesTheStoreWithoutASelectedScreenshot() async throws {
        var received = 0
        let draft = FulfillmentFormDraft(
            orderNumber: "70154321",
            eta: "15 minutes",
            readyTime: .fifteenMinutes
        )

        let with = try await FulfillRequestView.orchestrateSubmission(
            draft: draft,
            hasPlacedOrderScreenshot: true,
            presentation: FulfillmentValidationPresentation()
        ) { _ in received += 1 }
        XCTAssertTrue(with.didSubmit)
        XCTAssertEqual(received, 1)

        received = 0
        let without = try await FulfillRequestView.orchestrateSubmission(
            draft: draft,
            hasPlacedOrderScreenshot: false,
            presentation: FulfillmentValidationPresentation()
        ) { _ in received += 1 }
        XCTAssertFalse(without.didSubmit)
        XCTAssertEqual(received, 0, "defense in depth beside the disabled button")
    }

    // MARK: - The store owns the pre-submit selection

    func testSelectionIsHeldByTheStoreForTheActiveReservationOnly() async throws {
        let store = makeStore()
        // No reservation: a selection is ignored — evidence cannot exist for a
        // reservation that is not held.
        store.selectPlacedOrderScreenshot(.fixture(seed: 1), requestID: requestID)
        XCTAssertFalse(store.hasPlacedOrderScreenshot(requestID: requestID))

        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "raw-token")))
        try await store.claim(requestID: requestID)
        XCTAssertFalse(store.hasPlacedOrderScreenshot(requestID: requestID), "a new claim starts empty")

        // A different request is not this reservation.
        store.selectPlacedOrderScreenshot(.fixture(seed: 2), requestID: "someone-else")
        XCTAssertFalse(store.hasPlacedOrderScreenshot(requestID: "someone-else"))
        XCTAssertFalse(store.hasPlacedOrderScreenshot(requestID: requestID))

        store.selectPlacedOrderScreenshot(.fixture(seed: 3), requestID: requestID)
        XCTAssertTrue(store.hasPlacedOrderScreenshot(requestID: requestID))
        store.selectPlacedOrderScreenshot(nil, requestID: requestID)
        XCTAssertFalse(store.hasPlacedOrderScreenshot(requestID: requestID))
    }

    func testFulfillWithoutASelectionIsRefusedBeforeAnyRequestIsSent() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "raw-token")))
        try await store.claim(requestID: requestID)

        do {
            try await store.fulfill(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
            XCTFail("a new fulfillment cannot be issued without a screenshot")
        } catch RequestServiceError.placedOrderScreenshotRequired {
            // Expected.
        }

        XCTAssertTrue(try fulfillPosts().isEmpty)
        XCTAssertNotNil(store.activeClaim)
        XCTAssertNil(store.fulfillError, "nothing was attempted, so there is no backend error to show")
        XCTAssertNil(store.fulfillmentAmbiguity)
    }

    func testChangeReplacesTheSelectionAndTheNextSubmissionSendsTheLatest() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "raw-token")))
        try await store.claim(requestID: requestID)
        store.selectPlacedOrderScreenshot(.fixture(seed: 81), requestID: requestID)
        let replacement = PlacedOrderScreenshot.fixture(seed: 82)
        store.selectPlacedOrderScreenshot(replacement, requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse()))

        try await store.fulfill(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )

        let post = try fulfillPosts().first.unwrap()
        try assertScreenshotOnTheWire(post, equals: replacement)
    }

    func testTheSelectionDoesNotSurviveARelaunchSoTheHelperReselects() async throws {
        let first = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "raw-token")))
        try await first.claim(requestID: requestID)
        first.selectPlacedOrderScreenshot(.fixture(seed: 83), requestID: requestID)
        XCTAssertTrue(first.hasPlacedOrderScreenshot(requestID: requestID))

        // A new process: a fresh store restored from authoritative state.
        let relaunched = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: activeReservationResponse()))
        _ = try await relaunched.continueActiveReservationIfNeeded()

        XCTAssertFalse(relaunched.hasPlacedOrderScreenshot(requestID: requestID))
        do {
            try await relaunched.fulfill(
                requestID: requestID, orderNumber: "70154321", eta: "ASAP", contactMessage: nil
            )
            XCTFail("a relaunched reservation needs the screenshot added again")
        } catch RequestServiceError.placedOrderScreenshotRequired {}
        XCTAssertTrue(try fulfillPosts().isEmpty)
    }

    func testTheSelectionEndsWithAConfirmedPlacementAndCannotReappear() async throws {
        // Confirmed placement.
        let placed = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "raw-token")))
        try await placed.claim(requestID: requestID)
        placed.selectPlacedOrderScreenshot(.fixture(seed: 84), requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse()))
        try await placed.fulfill(
            requestID: requestID, orderNumber: "70154321", eta: "ASAP", contactMessage: nil
        )
        XCTAssertFalse(placed.hasPlacedOrderScreenshot(requestID: requestID))
        // A selection can never reappear after placement.
        placed.selectPlacedOrderScreenshot(.fixture(seed: 85), requestID: requestID)
        XCTAssertFalse(placed.hasPlacedOrderScreenshot(requestID: requestID))
    }

    func testADefinitiveRefusalDiscardsTheRefusedSelectionSoAnotherMustBeChosen() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "raw-token")))
        try await store.claim(requestID: requestID)
        store.selectPlacedOrderScreenshot(.fixture(seed: 87), requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 400,
            data: errorResponse(
                code: ClaimErrorCode.invalidPlacedOrderScreenshot,
                message: "The order screenshot is missing or can’t be used."
            )
        ))

        try? await store.fulfill(
            requestID: requestID, orderNumber: "70154321", eta: "ASAP", contactMessage: nil
        )

        XCTAssertFalse(store.hasPlacedOrderScreenshot(requestID: requestID))
        do {
            try await store.fulfill(
                requestID: requestID, orderNumber: "70154321", eta: "ASAP", contactMessage: nil
            )
            XCTFail("the refused image must not be resent")
        } catch RequestServiceError.placedOrderScreenshotRequired {}
        XCTAssertEqual(try fulfillPosts().count, 1)
    }

    func testALateSelectionNeverMutatesAnIssuedAmbiguousSubmission() async throws {
        let store = makeStore()
        ClaimFlowURLProtocol.enqueue(.response(data: claimResponse(claimToken: "raw-token")))
        try await store.claim(requestID: requestID)
        let original = PlacedOrderScreenshot.fixture(seed: 88)
        store.selectPlacedOrderScreenshot(original, requestID: requestID)
        ClaimFlowURLProtocol.enqueue(.failure(.networkConnectionLost))
        ClaimFlowURLProtocol.enqueue(.response(data: detailResponse(status: "claimed")))
        try? await store.fulfill(
            requestID: requestID, orderNumber: "70154321", eta: "ASAP", contactMessage: nil
        )
        let ambiguity = try XCTUnwrap(store.fulfillmentAmbiguity)

        // A "Change" arriving now (e.g. a slow picker callback) is ignored.
        store.selectPlacedOrderScreenshot(.fixture(seed: 89), requestID: requestID)
        store.selectPlacedOrderScreenshot(nil, requestID: requestID)

        ClaimFlowURLProtocol.enqueue(.response(data: fulfillmentResponse()))
        try await store.resubmitAmbiguousFulfillment(ambiguityID: ambiguity.id, requestID: requestID)
        let posts = try fulfillPosts()
        XCTAssertEqual(posts.count, 2)
        for post in posts { try assertScreenshotOnTheWire(post, equals: original) }
    }

    func testTheContractedCopyIsExact() {
        XCTAssertEqual(FulfillRequestView.orderScreenshotLabel, "Order confirmation")
        XCTAssertEqual(FulfillRequestView.requiredLabel, "Required")
        XCTAssertEqual(FulfillRequestView.messageOptionalLabel, "Optional")
        XCTAssertEqual(FulfillRequestView.chooseScreenshotTitle, "Choose Grubhub screenshot")
        XCTAssertEqual(FulfillRequestView.screenshotAttachedTitle, "Screenshot attached")
        XCTAssertEqual(FulfillRequestView.changeScreenshotTitle, "Change")
        XCTAssertEqual(
            FulfillRequestView.invalidScreenshotNotice,
            "This image can’t be used. Choose another screenshot to continue."
        )
        // No new red "Required" paragraph exists for a missing screenshot.
        XCTAssertNotEqual(FulfillRequestView.invalidScreenshotNotice, FulfillRequestView.requiredLabel)
    }

    // MARK: - Source-structure facts (the view cannot be rendered here)

    func testTheScreenshotFieldIsFirstAndOutsideTheContactRestriction() throws {
        let source = try appSource("Views/FulfillRequestView.swift")
        let fields = try slice(
            of: source,
            from: "private var fulfillmentFields: some View {",
            to: "// MARK: - Order screenshot (W4-H1a)"
        )
        let screenshotIndex = try XCTUnwrap(fields.range(of: "placedOrderScreenshotField"))
        let orderNumberIndex = try XCTUnwrap(fields.range(of: "HelpingFieldLabel(text: Self.orderNumberLabel)"))
        let restrictionIndex = try XCTUnwrap(fields.range(of: "if !store.contactSuppressedRequestIDs.contains(request.id)"))
        XCTAssertLessThan(screenshotIndex.lowerBound, orderNumberIndex.lowerBound, "first item")
        XCTAssertLessThan(
            screenshotIndex.lowerBound, restrictionIndex.lowerBound,
            "the screenshot is required in the restricted (Block-active) state too"
        )
    }

    /// Faith F-P1 (2026-10-16): the helper-facing privacy line is removed with
    /// no replacement; chooser, notice and attached structure are intact.
    func testNoHelperFacingPrivacyDisclosureExistsAndTheFieldStructureIsIntact() throws {
        let source = try appSource("Views/FulfillRequestView.swift")
        XCTAssertFalse(source.contains("The requester can view this after you finish helping"))
        XCTAssertFalse(source.contains("screenshotPrivacyDisclosure"))
        XCTAssertFalse(source.contains("fulfillment-screenshot-disclosure"))
        let field = try slice(
            of: source,
            from: "private var placedOrderScreenshotField: some View {",
            to: "private var screenshotChooser: some View {"
        )
        XCTAssertTrue(field.contains("Self.orderScreenshotLabel"))
        XCTAssertTrue(field.contains("Self.requiredLabel"))
        let branches = field.components(separatedBy: "} else {")
        XCTAssertEqual(branches.count, 2, "attached | unattached; no third initial-state text branch")
        XCTAssertTrue(branches[0].contains("attachedScreenshotRow"))
        XCTAssertTrue(branches[1].contains("screenshotChooser"))
        XCTAssertTrue(branches[1].contains("if let notice = screenshotNotice"))
        XCTAssertTrue(branches[1].contains("fulfillment-screenshot-notice"))
    }

    func testChangingTheScreenshotTouchesNoOtherFieldAndStartsNothingElse() throws {
        let source = try appSource("Views/FulfillRequestView.swift")
        let handling = try slice(
            of: source,
            from: "private func handlePickedScreenshot(_ item: PhotosPickerItem) {",
            to: "/// Whether `error` is the backend's definitive refusal"
        )
        for other in ["orderNumber", "readyTime", "contactMessage", ".eta"] {
            XCTAssertFalse(handling.contains("draft.\(other)"), "choosing a screenshot must not touch \(other)")
        }
        XCTAssertFalse(handling.contains("draft = "))
        XCTAssertFalse(handling.contains("analy"))
        // The only store call is the selection itself.
        XCTAssertEqual(handling.components(separatedBy: "store.").count - 1, 1)
        XCTAssertTrue(handling.contains("store.selectPlacedOrderScreenshot("))
    }

    func testThePreSubmitSelectionIsNoLongerHeldByTheView() throws {
        let view = codeLines(try appSource("Views/FulfillRequestView.swift"))
        let validation = codeLines(try appSource("Views/FulfillmentFormValidation.swift"))
        XCTAssertFalse(view.contains("draft.placedOrderScreenshot"))
        XCTAssertFalse(validation.contains("placedOrderScreenshot"))
        XCTAssertFalse(view.contains("@State private var screenshot:"))
    }

    func testTheEvidenceIsNeverPersistedLoggedOrDescribed() throws {
        for path in ["Services/PlacedOrderScreenshot.swift", "Views/FulfillRequestView.swift"] {
            let source = codeLines(try appSource(path))
            for forbidden in [
                "UserDefaults", "FileManager", ".write(to", "Keychain", "SecItem",
                "print(", "NSLog", "os_log", "Logger(", "debugPrint", "dump(",
                "URLCache", "NSCache", "PHPhotoLibrary", "UIImageWriteToSavedPhotosAlbum"
            ] {
                XCTAssertFalse(source.contains(forbidden), "\(path) must not use \(forbidden)")
            }
        }
        // The store keeps it only as private in-memory state plus the immutable
        // submission snapshot; the bytes are never observable published state.
        let store = codeLines(try appSource("Stores/RequestStore.swift"))
        XCTAssertTrue(store.contains("private var selectedPlacedOrderScreenshot: PlacedOrderScreenshot?"))
        XCTAssertFalse(store.contains("@Published private(set) var selectedPlacedOrderScreenshot"))
        XCTAssertFalse(store.contains("@Published var selectedPlacedOrderScreenshot"))
        XCTAssertFalse(store.contains("@Published private(set) var placedOrderScreenshot"))
    }

    // MARK: - Helpers

    private func assertScreenshotOnTheWire(
        _ post: ClaimFlowURLProtocol.CapturedRequest,
        equals screenshot: PlacedOrderScreenshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fulfillment = try XCTUnwrap(
            post.bodyObject?["fulfillment"] as? [String: Any], file: file, line: line
        )
        let wire = try XCTUnwrap(
            fulfillment["placedOrderScreenshot"] as? [String: Any], file: file, line: line
        )
        XCTAssertEqual(Set(wire.keys), ["mimeType", "imageBase64"], file: file, line: line)
        XCTAssertEqual(wire["mimeType"] as? String, screenshot.mimeType, file: file, line: line)
        let base64 = try XCTUnwrap(wire["imageBase64"] as? String, file: file, line: line)
        XCTAssertEqual(Data(base64Encoded: base64), screenshot.imageData, file: file, line: line)
        XCTAssertNil(fulfillment["screenshot"], file: file, line: line)
        XCTAssertNil(fulfillment["evidenceId"], file: file, line: line)
        XCTAssertNil(fulfillment["url"], file: file, line: line)
    }

    private func fulfillPosts() throws -> [ClaimFlowURLProtocol.CapturedRequest] {
        ClaimFlowURLProtocol.capturedRequests.filter {
            $0.path == "/api/request/\(requestID)/fulfill"
        }
    }

    private func canonicalJSON(_ object: [String: Any]?) throws -> Data {
        try JSONSerialization.data(withJSONObject: XCTUnwrap(object), options: [.sortedKeys])
    }

    private func makeStore() -> RequestStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaimFlowURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
        let authority = participantAuthority
        return RequestStore(
            service: RequestService(client: client),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { authority },
            participantAuthorityRejected: {}
        )
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func requestObject(status: String) -> String {
        """
        {
          "id": "\(requestID)",
          "vendor": "Crave NYU",
          "food": "Rice bowl",
          "pickupWindowText": "ASAP",
          "mealSwipes": 2,
          "menuPath": "meal-exchange",
          "mealItems": [],
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

    private func claimResponse(claimToken: String) -> Data {
        Data("""
        {
          "request": \(requestObject(status: "claimed")),
          "claim": {
            "claimToken": "\(claimToken)",
            "claimExpiresAt": "\(iso8601String(Date().addingTimeInterval(15 * 60)))"
          }
        }
        """.utf8)
    }

    private func activeReservationResponse() -> Data {
        Data("""
        {
          "reservation": {
            "request": \(requestObject(status: "claimed")),
            "claimExpiresAt": "\(iso8601String(Date().addingTimeInterval(15 * 60)))",
            "claimExtendedAt": null
          }
        }
        """.utf8)
    }

    private func placedReservationStateResponse() -> Data {
        Data("""
        {
          "reservation": null,
          "placement": {
            "request": \(requestObject(status: "placed")),
            "orderNumber": "70154321",
            "etaText": "15 minutes",
            "notification": { "status": "sent" }
          }
        }
        """.utf8)
    }

    private func fulfillmentResponse(notificationStatus: String = "sent") -> Data {
        Data("""
        {
          "request": \(requestObject(status: "placed")),
          "notification": { "status": "\(notificationStatus)" }
        }
        """.utf8)
    }

    private func detailResponse(status: String) -> Data {
        Data(#"{"request": \#(requestObject(status: status))}"#.utf8)
    }

    private func errorResponse(code: String, message: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"\#(message)","fields":null}}"#.utf8)
    }

    // Source helpers.

    private func appSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CommonPlateiosTests
            .deletingLastPathComponent() // CommonPlateios
            .appendingPathComponent("CommonPlateios")
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func slice(of source: String, from start: String, to end: String) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start), "missing: \(start)")
        let tail = source[startRange.lowerBound...]
        let endRange = try XCTUnwrap(tail.range(of: end), "missing: \(end)")
        return String(tail[..<endRange.lowerBound])
    }

    private func codeLines(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}

private extension Optional {
    func unwrap(file: StaticString = #filePath, line: UInt = #line) throws -> Wrapped {
        guard let value = self else {
            throw NSError(domain: "PlacedOrderEvidenceFlowTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "unexpected nil at \(file):\(line)"
            ])
        }
        return value
    }
}
