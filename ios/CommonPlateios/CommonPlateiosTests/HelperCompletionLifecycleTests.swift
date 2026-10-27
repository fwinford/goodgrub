//
//  HelperCompletionLifecycleTests.swift
//  CommonPlateiosTests
//
// Focused W4-H1 store-driven coverage: authoritative fulfillment state — never
// success presentation — decides whether a helper is still occupied, and the
// Open Grubhub handoff is gated by that same truth without mutating it.
//
// Confirmed placement completes the active helper relationship immediately, so
// no acknowledgement, dismissal, dwell, animation, cooldown, or client flag may
// gate the next claim. Everything short of authoritatively-confirmed success —
// an ordinary failure, an unresolved/ambiguous fulfillment, an in-flight
// submission — keeps the reservation authoritative and keeps a conflicting
// claim refused, exactly as before.
//
// Kept in its own file per the repository's focused-test-file rule rather than
// extended onto `ClaimFlowTests`.
import Foundation
import XCTest
@testable import CommonPlateios

/// Its own transport double, matching the one-file-one-double convention.
final class HelperCompletionURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let data: Data
        let failure: URLError.Code?
        let gate: RequestFetchingGate?

        static func response(
            statusCode: Int = 200,
            data: Data,
            gate: RequestFetchingGate? = nil
        ) -> Stub {
            Stub(statusCode: statusCode, data: data, failure: nil, gate: gate)
        }

        static func failure(_ code: URLError.Code) -> Stub {
            Stub(statusCode: 0, data: Data(), failure: code, gate: nil)
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var stubs: [Stub] = []
    private nonisolated(unsafe) static var paths: [String] = []

    static func enqueue(_ stub: Stub) {
        lock.lock()
        stubs.append(stub)
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        stubs.removeAll()
        paths.removeAll()
        lock.unlock()
    }

    static var capturedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    private static func dequeue() -> Stub? {
        lock.lock()
        defer { lock.unlock() }
        return stubs.isEmpty ? nil : stubs.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.paths.append(request.url?.path ?? "")
        Self.lock.unlock()

        guard let stub = Self.dequeue() else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        if let gate = stub.gate {
            gate.wait { [weak self] in self?.deliver(stub) }
            return
        }
        deliver(stub)
    }

    private func deliver(_ stub: Stub) {
        if let failure = stub.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: stub.statusCode,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class HelperCompletionLifecycleTests: XCTestCase {
    private let requestA = "meal-a"
    private let requestB = "meal-b"

    override func tearDown() {
        HelperCompletionURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Confirmed success completes the helper relationship

    /// The slice's headline behavior: place → confirmed → immediately eligible
    /// for another request, with the completion presentation still on screen.
    func testConfirmedFulfillmentImmediatelyReleasesHelperEligibility() async throws {
        let store = makeStore()
        try await claim(store, requestID: requestA)
        try await fulfill(store, requestID: requestA, notificationStatus: "sent")

        // Backend-confirmed placement ended the reservation locally too.
        XCTAssertNil(store.activeClaim)
        XCTAssertNotNil(store.fulfillmentConfirmation)

        // No dismissal, no dwell, no delay: the next claim is attempted now.
        let before = HelperCompletionURLProtocol.capturedPaths
        HelperCompletionURLProtocol.enqueue(.response(data: claimResponse(requestID: requestB)))
        try await store.claim(requestID: requestB)

        XCTAssertEqual(
            HelperCompletionURLProtocol.capturedPaths,
            before + ["/api/request/\(requestB)/claim"]
        )
        XCTAssertEqual(store.activeClaim?.requestID, requestB)
        XCTAssertNil(store.claimError(for: requestB))
    }

    /// Dismissal order must be irrelevant. Dismissing before, after, or never
    /// produces the same eligibility, so no ordering can be load-bearing.
    func testDismissalOrderNeverChangesEligibility() async throws {
        for dismissFirst in [true, false] {
            let store = makeStore()
            try await claim(store, requestID: requestA)
            try await fulfill(store, requestID: requestA, notificationStatus: "failed")
            let confirmation = try XCTUnwrap(store.fulfillmentConfirmation)

            if dismissFirst {
                store.dismissFulfillmentConfirmation(id: confirmation.id)
                XCTAssertNil(store.fulfillmentConfirmation)
            }

            HelperCompletionURLProtocol.enqueue(
                .response(data: claimResponse(requestID: requestB))
            )
            try await store.claim(requestID: requestB)
            XCTAssertEqual(store.activeClaim?.requestID, requestB, "dismissFirst=\(dismissFirst)")

            if !dismissFirst {
                store.dismissFulfillmentConfirmation(id: confirmation.id)
                XCTAssertEqual(
                    store.activeClaim?.requestID,
                    requestB,
                    "a late dismissal must not disturb the new reservation"
                )
            }
            HelperCompletionURLProtocol.reset()
        }
    }

    /// Dismissal is presentation only in the other direction too: it never
    /// touches request-scoped fulfillment truth for the completed request, so
    /// it can never reopen a second submission — and therefore never suggest a
    /// second external order.
    func testDismissalNeverReopensSubmissionForTheCompletedRequest() async throws {
        let store = makeStore()
        try await claim(store, requestID: requestA)
        try await fulfill(store, requestID: requestA, notificationStatus: "sent")
        let confirmation = try XCTUnwrap(store.fulfillmentConfirmation)

        XCTAssertFalse(store.canSubmitFulfillment(requestID: requestA))
        store.dismissFulfillmentConfirmation(id: confirmation.id)
        XCTAssertFalse(
            store.canSubmitFulfillment(requestID: requestA),
            "the claim is gone; retiring the success presentation cannot reopen submission"
        )

        let before = HelperCompletionURLProtocol.capturedPaths
        do {
            try await store.fulfillWithFixtureScreenshot(
                requestID: requestA,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
            XCTFail("A completed request must not accept a second submission")
        } catch RequestServiceError.noActiveClaim {
            // Expected: no reservation, so nothing to submit against.
        }
        XCTAssertEqual(HelperCompletionURLProtocol.capturedPaths, before, "no POST was sent")
    }

    // MARK: - Anything short of confirmed success still blocks

    /// An unresolved/ambiguous fulfillment is not confirmed success: the
    /// reservation stays authoritative and a conflicting claim stays refused,
    /// with no second external order implied anywhere.
    func testUnresolvedFulfillmentStillBlocksAConflictingClaim() async throws {
        let store = makeStore()
        try await claim(store, requestID: requestA)

        // Transport failure, then the one permitted read-only status check
        // finding the request still `claimed` — the canonical ambiguity.
        HelperCompletionURLProtocol.enqueue(.failure(.networkConnectionLost))
        HelperCompletionURLProtocol.enqueue(
            .response(data: detailResponse(requestID: requestA, status: "claimed"))
        )
        do {
            try await store.fulfillWithFixtureScreenshot(
                requestID: requestA,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
            XCTFail("An unresolved fulfillment must not confirm placement")
        } catch RequestServiceError.ambiguousFulfillmentOutcome {
            // Expected.
        }

        XCTAssertNotNil(store.fulfillmentAmbiguity)
        XCTAssertNil(store.fulfillmentConfirmation, "nothing may fabricate success")
        XCTAssertEqual(store.activeClaim?.requestID, requestA)

        let before = HelperCompletionURLProtocol.capturedPaths
        do {
            try await store.claim(requestID: requestB)
            XCTFail("An unresolved fulfillment must keep the helper occupied")
        } catch RequestServiceError.existingActiveClaim {
            // Expected, before any POST.
        }
        XCTAssertEqual(HelperCompletionURLProtocol.capturedPaths, before)
        XCTAssertEqual(store.activeClaim?.requestID, requestA)
    }

    /// Leaving the unresolved screen is navigation only. It must not free the
    /// helper merely because the UI disappeared.
    func testLeavingAnUnresolvedFulfillmentScreenDoesNotFreeTheHelper() async throws {
        let store = makeStore()
        try await claim(store, requestID: requestA)
        HelperCompletionURLProtocol.enqueue(.failure(.networkConnectionLost))
        HelperCompletionURLProtocol.enqueue(
            .response(data: detailResponse(requestID: requestA, status: "claimed"))
        )
        try? await store.fulfillWithFixtureScreenshot(
            requestID: requestA,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )
        let ambiguity = try XCTUnwrap(store.fulfillmentAmbiguity)

        var navigations = 0
        FulfillRequestView.returnHome(from: store) { navigations += 1 }

        XCTAssertEqual(navigations, 1)
        XCTAssertEqual(store.fulfillmentAmbiguity?.id, ambiguity.id)
        XCTAssertEqual(store.activeClaim?.requestID, requestA)
        do {
            try await store.claim(requestID: requestB)
            XCTFail("Walking away is not completion")
        } catch RequestServiceError.existingActiveClaim {
            // Expected.
        }
    }

    /// An ordinary definitive fulfillment failure is not success either.
    func testAFailedFulfillmentKeepsTheReservationAndBlocksAnotherClaim() async throws {
        let store = makeStore()
        try await claim(store, requestID: requestA)
        HelperCompletionURLProtocol.enqueue(.response(
            statusCode: 503,
            data: errorResponse(code: "TRANSACTIONS_UNAVAILABLE", message: "Unavailable.")
        ))
        do {
            try await store.fulfillWithFixtureScreenshot(
                requestID: requestA,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
            XCTFail("A failed fulfillment must not confirm placement")
        } catch {
            // Expected.
        }

        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertEqual(store.activeClaim?.requestID, requestA)
        do {
            try await store.claim(requestID: requestB)
            XCTFail("A held reservation must still refuse another claim")
        } catch RequestServiceError.existingActiveClaim {
            // Expected.
        }
    }

    // MARK: - Presentation is not authority, structurally

    /// A guard against reintroducing the removed gate under another name: the
    /// completion presentation exists, and claiming succeeds anyway, with no
    /// refusal recorded on any surface.
    func testCompletionPresentationExistsWithoutWithholdingAnyClaimAffordance() async throws {
        let store = makeStore()
        try await claim(store, requestID: requestA)
        // The variant carrying the strongest safety copy: even this one
        // withholds nothing.
        try await fulfill(store, requestID: requestA, notificationStatus: "failed")

        let confirmation = try XCTUnwrap(store.fulfillmentConfirmation)
        // Public projection only — no claimant-private value rides along.
        XCTAssertEqual(confirmation.vendor, "Crave NYU")
        XCTAssertEqual(confirmation.foodDescription, "Rice bowl")
        XCTAssertEqual(confirmation.kind, .notificationFailed)
        XCTAssertFalse(confirmation.vendor.contains("Taylor"))
        XCTAssertFalse(confirmation.foodDescription.contains("claim-token"))

        // The detail screen offers the claim action with nothing recorded: a
        // live confirmation produces no refusal for any other request.
        XCTAssertNil(store.claimError(for: requestB))
        XCTAssertTrue(RequestDetailView.showsClaimAction(for: nil))

        HelperCompletionURLProtocol.enqueue(.response(data: claimResponse(requestID: requestB)))
        try await store.claim(requestID: requestB)
        XCTAssertEqual(store.activeClaim?.requestID, requestB)
    }

    /// The completion presentation is not durable domain state: a fresh store
    /// (a relaunched process) starts with none, and only a live backend-
    /// confirmed placement in *this* process ever produces one.
    func testCompletionPresentationIsProcessLocalAndStartsAbsent() {
        let store = makeStore()
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertNil(store.confirmedFulfillmentOutcome)
        XCTAssertNil(store.activeClaim)
    }

    // MARK: - Reservation controls

    /// `+ Add 5 minutes` in flight stays the (disabled) extension control — it
    /// never flashes `Can't extend` — and resolves to `5 minutes added`, with
    /// no second extension offered.
    func testExtensionInFlightNeverReadsCantExtendAndResolvesToAdded() async throws {
        let store = makeStore()
        try await claim(store, requestID: requestA)
        let original = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(FulfillRequestView.extensionControlState(for: original), .available)

        let gate = RequestFetchingGate()
        HelperCompletionURLProtocol.enqueue(.response(
            data: Data("""
            {
              "claim": {
                "claimExpiresAt": "\(iso8601(original.claimExpiresAt.addingTimeInterval(5 * 60)))",
                "claimExtendedAt": "\(iso8601(Date()))"
              }
            }
            """.utf8),
            gate: gate
        ))
        let extending = Task { await store.extendActiveClaim() }
        await waitUntil { gate.isWaiting }

        let inFlight = try XCTUnwrap(store.activeClaim)
        XCTAssertTrue(store.isExtendingClaim)
        XCTAssertFalse(store.canExtendActiveClaim, "the in-flight control is disabled")
        XCTAssertEqual(
            FulfillRequestView.extensionControlState(for: inFlight, isExtending: store.isExtendingClaim),
            .available
        )
        XCTAssertTrue(FulfillRequestView.showsExtensionSlot(
            for: original, isExtending: false, isShowingAddedConfirmation: false
        ), "before extension the pair is side by side")
        XCTAssertTrue(FulfillRequestView.showsExtensionSlot(
            for: inFlight, isExtending: store.isExtendingClaim, isShowingAddedConfirmation: false
        ), "in flight is never treated as confirmed")

        gate.open()
        await extending.value
        let extended = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(
            FulfillRequestView.extensionControlState(for: extended, isExtending: store.isExtendingClaim),
            .added
        )
        XCTAssertTrue(FulfillRequestView.showsExtensionSlot(
            for: extended, isExtending: store.isExtendingClaim, isShowingAddedConfirmation: true
        ), "a confirmed extension briefly reads `5 minutes added`")
        XCTAssertFalse(FulfillRequestView.showsExtensionSlot(
            for: extended, isExtending: store.isExtendingClaim, isShowingAddedConfirmation: false
        ), "then the control leaves and Stop helping takes the full width")
        XCTAssertGreaterThan(FulfillRequestView.extensionAddedConfirmationDuration, .zero)
        XCTAssertLessThanOrEqual(FulfillRequestView.extensionAddedConfirmationDuration, .seconds(4))
        XCTAssertFalse(store.canExtendActiveClaim, "never a second extension")
    }

    // MARK: - Open Grubhub handoff

    /// Opening Grubhub is an external handoff only. Whether the system opens
    /// it or refuses, no request is sent and no reservation, fulfillment, or
    /// confirmation state changes — and the gate still allows a retry.
    func testOpenGrubhubHandoffMutatesNoLifecycleState() async throws {
        let store = makeStore()
        try await claim(store, requestID: requestA)
        let claimBefore = try XCTUnwrap(store.activeClaim)
        let pathsBefore = HelperCompletionURLProtocol.capturedPaths
        XCTAssertTrue(openGrubhubAvailable(store, requestID: requestA))

        for systemAccepts in [false, true] {
            let destination = try XCTUnwrap(GrubhubRestaurantDestination.url(
                restaurantID: "Crave NYU", menuPath: .mealExchange
            ))
            var openedURLs: [URL] = []
            var reported: Bool?
            GrubhubHandoff.open(
                destination: destination,
                using: { url, completion in
                    openedURLs.append(url)
                    completion(systemAccepts)
                },
                completion: { didOpen in reported = didOpen }
            )

            XCTAssertEqual(
                openedURLs,
                [destination]
            )
            XCTAssertEqual(reported, systemAccepts)
            XCTAssertEqual(HelperCompletionURLProtocol.capturedPaths, pathsBefore)
            let claimAfter = try XCTUnwrap(store.activeClaim)
            XCTAssertEqual(claimAfter.requestID, claimBefore.requestID)
            XCTAssertEqual(claimAfter.claimExpiresAt, claimBefore.claimExpiresAt)
            XCTAssertEqual(claimAfter.isExtensionAvailable, claimBefore.isExtensionAvailable)
            XCTAssertFalse(store.isFulfilling)
            XCTAssertNil(store.fulfillmentAmbiguity)
            XCTAssertNil(store.fulfillmentConfirmation)
            XCTAssertTrue(store.canSubmitFulfillment(requestID: requestA))
            XCTAssertTrue(
                openGrubhubAvailable(store, requestID: requestA),
                "a failed open may be retried while the gate allows it"
            )
        }
        XCTAssertEqual(
            FulfillRequestView.grubhubOpenFailureNotice,
            "Couldn't open Grubhub. Open the Grubhub app to place the order."
        )
    }

    /// Open Grubhub is withheld while Finish helping is in flight and after
    /// authoritative confirmation, so no path offers a second external order.
    func testOpenGrubhubIsWithheldDuringSubmissionAndAfterConfirmation() async throws {
        let store = makeStore()
        try await claim(store, requestID: requestA)
        let gate = RequestFetchingGate()
        HelperCompletionURLProtocol.enqueue(.response(
            data: fulfillmentResponse(requestID: requestA, notificationStatus: "sent"),
            gate: gate
        ))

        let submission = Task {
            try await store.fulfillWithFixtureScreenshot(
                requestID: requestA,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
        }
        await waitUntil { gate.isWaiting }

        // Submitting is not success, and it is not an ordering opportunity.
        XCTAssertTrue(store.isFulfilling)
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertEqual(store.activeClaim?.requestID, requestA)
        XCTAssertFalse(openGrubhubAvailable(store, requestID: requestA))
        XCTAssertTrue(FulfillRequestView.showsSubmittingState(
            isFulfilling: store.isFulfilling,
            hasMatchingAmbiguity: false
        ))

        gate.open()
        try await submission.value

        XCTAssertNotNil(store.fulfillmentConfirmation)
        XCTAssertNil(store.activeClaim)
        XCTAssertFalse(openGrubhubAvailable(store, requestID: requestA))
    }

    /// Ambiguity and its one-time recovery never re-offer Open Grubhub, before
    /// or after the single status check, and not after the recovery is spent.
    func testOpenGrubhubIsWithheldThroughoutFulfillmentAmbiguityAndRecovery() async throws {
        let store = makeStore()
        try await claim(store, requestID: requestA)
        let statusGate = RequestFetchingGate()
        HelperCompletionURLProtocol.enqueue(.failure(.networkConnectionLost))
        HelperCompletionURLProtocol.enqueue(.response(
            data: detailResponse(requestID: requestA, status: "claimed"),
            gate: statusGate
        ))

        let submission = Task {
            try? await store.fulfillWithFixtureScreenshot(
                requestID: requestA,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: nil
            )
        }
        await waitUntil { statusGate.isWaiting }
        XCTAssertEqual(store.fulfillmentAmbiguity?.isCheckingStatus, true)
        XCTAssertFalse(openGrubhubAvailable(store, requestID: requestA))

        statusGate.open()
        await submission.value
        let ambiguity = try XCTUnwrap(store.fulfillmentAmbiguity)
        XCTAssertTrue(ambiguity.isRecoveryAvailable)
        XCTAssertEqual(store.activeClaim?.requestID, requestA)
        XCTAssertFalse(openGrubhubAvailable(store, requestID: requestA))

        // The single CommonPlate-only resend, answered ambiguously again, then
        // the one status read still finding the request claimed.
        HelperCompletionURLProtocol.enqueue(.response(
            statusCode: 500,
            data: errorResponse(code: "INTERNAL_FAILURE", message: "Unknown result")
        ))
        HelperCompletionURLProtocol.enqueue(
            .response(data: detailResponse(requestID: requestA, status: "claimed"))
        )
        try? await store.resubmitAmbiguousFulfillment(
            ambiguityID: ambiguity.id,
            requestID: requestA
        )
        XCTAssertEqual(store.fulfillmentAmbiguity?.isRecoveryAvailable, false)
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertFalse(openGrubhubAvailable(store, requestID: requestA))
        XCTAssertEqual(
            HelperCompletionURLProtocol.capturedPaths.filter { $0.hasSuffix("/fulfill") }.count,
            2,
            "one original POST and at most one exact resend"
        )
    }

    /// Relaunch after an already-confirmed placement reconciles to ordinary
    /// helper-available state: no reservation, no success presentation to
    /// replay, and no Open Grubhub for that request.
    func testPlacedRelaunchExposesNoOpenGrubhubAndNoSuccessPresentation() async throws {
        let store = makeStore()
        HelperCompletionURLProtocol.enqueue(.response(data: placedContinuationResponse(
            requestID: requestA
        )))

        let outcome = try await store.continueActiveReservationIfNeeded()

        guard case .none = outcome else {
            return XCTFail("a settled placement is not reservation authority")
        }
        XCTAssertNil(store.activeClaim)
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertFalse(openGrubhubAvailable(store, requestID: requestA))
        XCTAssertFalse(store.canSubmitFulfillment(requestID: requestA))
    }

    // MARK: - Helpers

    private func openGrubhubAvailable(_ store: RequestStore, requestID: String) -> Bool {
        FulfillRequestView.isOpenGrubhubAvailable(
            requestID: requestID,
            activeClaimRequestID: store.activeClaim?.requestID,
            isFulfilling: store.isFulfilling,
            hasFulfillmentAmbiguity: store.fulfillmentAmbiguity != nil,
            confirmationRequestID: store.fulfillmentConfirmation?.requestID
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "timed out waiting for condition")
    }

    private func placedContinuationResponse(requestID: String) -> Data {
        Data("""
        {
          "reservation": null,
          "placement": {
            "request": \(requestObject(requestID: requestID, status: "placed")),
            "orderNumber": "70154321",
            "etaText": "15 minutes",
            "notification": { "status": "sent" }
          }
        }
        """.utf8)
    }

    private func makeStore() -> RequestStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HelperCompletionURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return RequestStore(
            service: RequestService(client: client),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { "64c0000000000000000000a1.1.credential" },
            participantAuthorityRejected: {}
        )
    }

    private func claim(_ store: RequestStore, requestID: String) async throws {
        HelperCompletionURLProtocol.enqueue(.response(data: claimResponse(requestID: requestID)))
        try await store.claim(requestID: requestID)
        XCTAssertEqual(store.activeClaim?.requestID, requestID)
    }

    private func fulfill(
        _ store: RequestStore,
        requestID: String,
        notificationStatus: String
    ) async throws {
        HelperCompletionURLProtocol.enqueue(.response(data: fulfillmentResponse(
            requestID: requestID,
            notificationStatus: notificationStatus
        )))
        try await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func requestObject(requestID: String, status: String) -> String {
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
          "createdAt": "2026-08-10T15:00:00.000Z",
          "expiresAt": "\(iso8601(Date().addingTimeInterval(5 * 60 * 60)))"
        }
        """
    }

    private func claimResponse(requestID: String) -> Data {
        Data("""
        {
          "request": \(requestObject(requestID: requestID, status: "claimed")),
          "claim": {
            "pickupName": "Taylor",
            "claimToken": "claim-token-\(requestID)",
            "claimExpiresAt": "\(iso8601(Date().addingTimeInterval(15 * 60)))"
          }
        }
        """.utf8)
    }

    private func fulfillmentResponse(requestID: String, notificationStatus: String) -> Data {
        Data("""
        {
          "request": \(requestObject(requestID: requestID, status: "placed")),
          "notification": { "status": "\(notificationStatus)" }
        }
        """.utf8)
    }

    private func detailResponse(requestID: String, status: String) -> Data {
        Data("""
        { "request": \(requestObject(requestID: requestID, status: status)) }
        """.utf8)
    }

    private func errorResponse(code: String, message: String) -> Data {
        Data("""
        { "error": { "code": "\(code)", "message": "\(message)" } }
        """.utf8)
    }
}
