//
//  HelperMessageSuppressionTests.swift
//  CommonPlateiosTests
//
// W4-U1.1 helper Message suppression. When the helper's optional fulfillment
// Message is refused by the backend filter AFTER the real Grubhub order was
// placed, the placement still commits exactly once. That is a SUCCESS:
//
// - the fulfill response carries a private, content-free `messageSuppressed`
//   signal that iOS renders as the approved H1 success state — order-recorded
//   truth first, existing requester-email truth after, no new control, and the
//   unchanged brief-success → automatic-Home-return timing;
// - after an ambiguous response, suppression can be shown only when the
//   participant-scoped placed read authoritatively proves it, and is never
//   fabricated when that read cannot;
// - a relaunch reconstructs no success or suppression UI and exposes no way to
//   place a second external order.
//
// Unit proof of state and wiring, not device evidence of presentation: the
// project has no UI-test target (`docs/testing.md`).
import Foundation
import XCTest
@testable import CommonPlateios

/// Isolated transport stub for this suite, so its queue can never be consumed
/// by another suite.
final class HelperMessageSuppressionURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let data: Data
        let errorCode: URLError.Code?
        var isHeld = false

        static func response(statusCode: Int = 200, data: Data) -> Stub {
            Stub(statusCode: statusCode, data: data, errorCode: nil)
        }

        static func failure(_ code: URLError.Code) -> Stub {
            Stub(statusCode: 0, data: Data(), errorCode: code)
        }

        /// Answers `stub` only when `releaseHeld()` is called, so a test can keep
        /// one request pending while other store state changes around it.
        static func held(_ stub: Stub) -> Stub {
            var held = stub
            held.isHeld = true
            return held
        }
    }

    struct Captured {
        let path: String
        let method: String
        let headers: [String: String]
        let body: Data?

        var bodyObject: [String: Any]? {
            body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var stubs: [Stub] = []
    private nonisolated(unsafe) static var captured: [Captured] = []
    private nonisolated(unsafe) static var heldLoaders: [(loader: HelperMessageSuppressionURLProtocol, stub: Stub)] = []

    static func enqueue(_ stub: Stub) {
        lock.lock(); defer { lock.unlock() }
        stubs.append(stub)
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        stubs.removeAll()
        captured.removeAll()
        heldLoaders.removeAll()
    }

    /// Requests received whose answer is still being held.
    static var heldRequestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return heldLoaders.count
    }

    /// Answers every held request with the stub it was queued with.
    static func releaseHeld() {
        lock.lock()
        let released = heldLoaders
        heldLoaders.removeAll()
        lock.unlock()
        for entry in released {
            entry.loader.deliver(entry.stub)
        }
    }

    static var capturedRequests: [Captured] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    static var capturedPaths: [String] { capturedRequests.map(\.path) }

    private static func dequeue() -> Stub? {
        lock.lock(); defer { lock.unlock() }
        return stubs.isEmpty ? nil : stubs.removeFirst()
    }

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.captured.append(Captured(
            path: request.url?.path ?? "",
            method: request.httpMethod ?? "",
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.readBody(from: request)
        ))
        Self.lock.unlock()

        guard let stub = Self.dequeue() else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        if stub.isHeld {
            Self.lock.lock()
            Self.heldLoaders.append((loader: self, stub: stub))
            Self.lock.unlock()
            return
        }
        deliver(stub)
    }

    private func deliver(_ stub: Stub) {
        if let errorCode = stub.errorCode {
            client?.urlProtocol(self, didFailWithError: URLError(errorCode))
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: stub.statusCode,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        // A cancelled request is no longer waiting for an answer.
        Self.lock.lock()
        Self.heldLoaders.removeAll { $0.loader === self }
        Self.lock.unlock()
    }
}

@MainActor
private final class SuppressionAuthorityBox {
    var value: String?
    init(_ value: String?) { self.value = value }
}

@MainActor
final class HelperMessageSuppressionTests: XCTestCase {
    private let requestID = "meal-a"
    private let helperAuthority = "64c0000000000000000000a1.1.credential"
    private let suppressedBody = "Your message didn’t meet \(AppBrand.name)’s guidelines."

    override func tearDown() {
        HelperMessageSuppressionURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Wire decoding

    func testFulfillResponseDecodesTheSuppressionSignalAndToleratesItsAbsence() throws {
        let suppressed = try decoder().decode(
            FulfillResponseDTO.self,
            from: fulfillmentResponse(notificationStatus: "sent", messageSuppressed: true)
        )
        XCTAssertEqual(suppressed.messageSuppressed, true)
        XCTAssertEqual(suppressed.request.status, .placed)

        // The unchanged success shape a stale backend or a normal placement sends.
        let plain = try decoder().decode(
            FulfillResponseDTO.self,
            from: fulfillmentResponse(notificationStatus: "sent")
        )
        XCTAssertNil(plain.messageSuppressed)
    }

    func testPlacedReadDecodesTheSuppressionSignalAffirmativeOnly() throws {
        let suppressed = try decoder().decode(
            ActiveReservationResponseDTO.self,
            from: placementResponse(requestID: requestID, messageSuppressed: true)
        )
        XCTAssertEqual(suppressed.placement?.messageSuppressed, true)
        XCTAssertNil(suppressed.reservation)

        let plain = try decoder().decode(
            ActiveReservationResponseDTO.self,
            from: placementResponse(requestID: requestID)
        )
        XCTAssertNil(plain.placement?.messageSuppressed)
    }

    // MARK: - Normal fulfillment success

    func testASuppressedPlacementIsASuccessfulConfirmationNeverAnError() async throws {
        let store = makeStore()
        HelperMessageSuppressionURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        HelperMessageSuppressionURLProtocol.enqueue(.response(
            data: fulfillmentResponse(notificationStatus: "sent", messageSuppressed: true)
        ))

        // The client never pre-filters: the helper's Message is sent as typed.
        try await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: "a message the backend will refuse"
        )

        let fulfill = try XCTUnwrap(
            HelperMessageSuppressionURLProtocol.capturedRequests.last(where: { $0.path.hasSuffix("/fulfill") })
        )
        XCTAssertEqual(
            (fulfill.bodyObject?["fulfillment"] as? [String: Any])?["contactMessage"] as? String,
            "a message the backend will refuse"
        )

        // Placement succeeded exactly like any other: claim ended, request
        // removed from the open collection, nothing blocking or failed.
        XCTAssertNil(store.activeClaim)
        XCTAssertNil(store.fulfillError)
        XCTAssertNil(store.fulfillmentAmbiguity)
        XCTAssertTrue(store.requests.isEmpty)
        let confirmation = try XCTUnwrap(store.fulfillmentConfirmation)
        XCTAssertEqual(confirmation.kind, .notificationSent)
        XCTAssertTrue(confirmation.messageSuppressed)
        XCTAssertEqual(store.confirmedFulfillmentOutcome?.messageSuppressed, true)
        XCTAssertEqual(store.helperPlacedContinuation?.request.id, requestID)
        XCTAssertEqual(store.helperPlacedContinuation?.orderNumber, "70154321")
        XCTAssertEqual(store.helperPlacedContinuation?.etaText, "15 minutes")
        // No second order is on offer after confirmed placement.
        XCTAssertFalse(store.canSubmitFulfillment(requestID: requestID))
    }

    func testAPlacementWithoutSuppressionIsUnchanged() async throws {
        let store = makeStore()
        HelperMessageSuppressionURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        HelperMessageSuppressionURLProtocol.enqueue(.response(
            data: fulfillmentResponse(notificationStatus: "failed")
        ))

        try await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: nil
        )

        let confirmation = try XCTUnwrap(store.fulfillmentConfirmation)
        XCTAssertEqual(confirmation.kind, .notificationFailed)
        XCTAssertFalse(confirmation.messageSuppressed)
        XCTAssertEqual(store.confirmedFulfillmentOutcome?.messageSuppressed, false)
    }

    func testRequesterEmailFailureDoesNotHideOrUndoSuppression() async throws {
        let store = makeStore()
        HelperMessageSuppressionURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        HelperMessageSuppressionURLProtocol.enqueue(.response(
            data: fulfillmentResponse(notificationStatus: "failed", messageSuppressed: true)
        ))

        try await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: "blocked"
        )

        let confirmation = try XCTUnwrap(store.fulfillmentConfirmation)
        XCTAssertEqual(confirmation.kind, .notificationFailed)
        XCTAssertTrue(confirmation.messageSuppressed)
        XCTAssertEqual(
            HelperSuccessCopy.supportingLines(
                for: confirmation.kind,
                messageSuppressed: confirmation.messageSuppressed
            ),
            []
        )
    }

    // MARK: - Same-flow ambiguity recovery

    func testAmbiguityRecoveryShowsSuppressionOnlyWhenThePlacedReadAuthoritativelyProvesIt() async throws {
        let store = makeStore()
        HelperMessageSuppressionURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        // The first response is lost; the status read proves placement; the
        // participant-scoped placed read proves suppression.
        HelperMessageSuppressionURLProtocol.enqueue(.failure(.networkConnectionLost))
        HelperMessageSuppressionURLProtocol.enqueue(.response(data: detailResponse(status: "placed")))
        HelperMessageSuppressionURLProtocol.enqueue(.response(
            data: placementResponse(requestID: requestID, messageSuppressed: true)
        ))

        try await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: "blocked"
        )

        XCTAssertNil(store.activeClaim)
        XCTAssertNil(store.fulfillmentAmbiguity)
        let confirmation = try XCTUnwrap(store.fulfillmentConfirmation)
        XCTAssertTrue(confirmation.messageSuppressed)
        // Email outcome was never settled for this path: unchanged truth.
        XCTAssertEqual(confirmation.kind, .emailStatusUnknown)
        XCTAssertEqual(
            HelperMessageSuppressionURLProtocol.capturedPaths,
            ["/api/request/\(requestID)/claim", "/api/request/\(requestID)/fulfill",
             "/api/request/\(requestID)", "/api/participant/active-reservation"]
        )
        // The placed read is the helper's own authority, never a public read.
        let placedRead = try XCTUnwrap(HelperMessageSuppressionURLProtocol.capturedRequests.last)
        XCTAssertEqual(placedRead.headers[RequestService.participantAuthorityHeader], helperAuthority)
        // W4-R5: the status read is verified-only, so it presents the current
        // authority too — but only the participant-scoped read can prove
        // suppression.
        XCTAssertTrue(HelperMessageSuppressionURLProtocol.capturedRequests
            .filter { $0.path == "/api/request/\(requestID)" }
            .allSatisfy { $0.headers[RequestService.participantAuthorityHeader] == helperAuthority })
    }

    func testAmbiguityRecoveryNeverFabricatesSuppressionWhenThePlacedReadCannotEstablishIt() async throws {
        let unestablished: [(String, HelperMessageSuppressionURLProtocol.Stub)] = [
            ("marker absent", .response(data: placementResponse(requestID: requestID))),
            ("marker explicitly false", .response(data: placementResponse(requestID: requestID, messageSuppressedLiteral: "false"))),
            ("a different request's placement", .response(data: placementResponse(requestID: "someone-else", messageSuppressed: true))),
            ("no placement at all", .response(data: Data(#"{"reservation":null,"placement":null}"#.utf8))),
            ("an undecodable body", .response(data: Data(#"{"placement":{"request":{}}}"#.utf8))),
            ("an authority refusal", .response(
                statusCode: 401,
                data: Data(#"{"error":{"code":"PARTICIPANT_AUTHORITY_INVALID","message":"x","fields":null}}"#.utf8)
            )),
            ("a server failure", .response(
                statusCode: 503,
                data: Data(#"{"error":{"code":"PARTICIPANT_VERIFICATION_UNAVAILABLE","message":"x","fields":null}}"#.utf8)
            )),
            ("transport loss", .failure(.notConnectedToInternet)),
        ]
        for (label, stub) in unestablished {
            HelperMessageSuppressionURLProtocol.reset()
            let store = makeStore()
            HelperMessageSuppressionURLProtocol.enqueue(.response(data: claimResponse()))
            try await store.claim(requestID: requestID)
            HelperMessageSuppressionURLProtocol.enqueue(.failure(.networkConnectionLost))
            HelperMessageSuppressionURLProtocol.enqueue(.response(data: detailResponse(status: "placed")))
            HelperMessageSuppressionURLProtocol.enqueue(stub)

            try await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: "blocked"
            )

            // Placement is confirmed regardless; suppression is simply not shown.
            let confirmation = try XCTUnwrap(store.fulfillmentConfirmation, label)
            XCTAssertFalse(confirmation.messageSuppressed, label)
            XCTAssertEqual(confirmation.kind, .emailStatusUnknown, label)
            XCTAssertNil(store.activeClaim, label)
            XCTAssertNil(store.fulfillmentAmbiguity, label)
        }
    }

    /// W4-R5: with no participant authority the status check cannot be made.
    /// That is inconclusive — never proof of placement or of non-placement. The
    /// claim, the ambiguity and its one-use recovery are all preserved, and no
    /// read of any kind is sent.
    func testAmbiguityStatusCheckWithoutAParticipantAuthoritySendsNoReadAndFabricatesNothing() async throws {
        let authority = SuppressionAuthorityBox(helperAuthority)
        let store = makeStore(authority: authority)
        HelperMessageSuppressionURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        // The identity is gone by the time the ambiguity resolves.
        authority.value = nil
        HelperMessageSuppressionURLProtocol.enqueue(.failure(.networkConnectionLost))

        try? await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: "blocked"
        )

        XCTAssertNil(store.fulfillmentConfirmation)
        let ambiguity = try XCTUnwrap(store.fulfillmentAmbiguity)
        XCTAssertFalse(ambiguity.isCheckingStatus)
        XCTAssertTrue(ambiguity.isRecoveryAvailable)
        XCTAssertNotNil(store.activeClaim)
        XCTAssertEqual(
            HelperMessageSuppressionURLProtocol.capturedPaths,
            ["/api/request/\(requestID)/claim", "/api/request/\(requestID)/fulfill"]
        )
    }

    func testAmbiguousRecoveryThatDoesNotProvePlacementReadsNoSuppressionAtAll() async throws {
        let store = makeStore()
        HelperMessageSuppressionURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        HelperMessageSuppressionURLProtocol.enqueue(.failure(.timedOut))
        HelperMessageSuppressionURLProtocol.enqueue(.response(data: detailResponse(status: "claimed")))

        try? await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: "blocked"
        )

        // Still unresolved: no confirmation, no suppression, claim retained.
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertNotNil(store.fulfillmentAmbiguity)
        XCTAssertNotNil(store.activeClaim)
        XCTAssertFalse(HelperMessageSuppressionURLProtocol.capturedPaths.contains("/api/participant/active-reservation"))
    }

    // MARK: - Confirmed placement is never forfeited by suppression enrichment

    /// Starts an ambiguous fulfillment whose public status read proves placement
    /// and whose participant-scoped suppression lookup is then held pending.
    /// Returns once placement is proven and only the enrichment is outstanding.
    private func startFulfillmentWithPendingSuppressionLookup(
        store: RequestStore,
        heldLookup: HelperMessageSuppressionURLProtocol.Stub
    ) async throws -> Task<Void, Never> {
        HelperMessageSuppressionURLProtocol.enqueue(.failure(.networkConnectionLost))
        HelperMessageSuppressionURLProtocol.enqueue(.response(data: detailResponse(status: "placed")))
        HelperMessageSuppressionURLProtocol.enqueue(.held(heldLookup))
        let fulfilling = Task { @MainActor in
            _ = try? await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: "blocked"
            )
        }
        try await waitUntil(
            { HelperMessageSuppressionURLProtocol.heldRequestCount == 1 },
            "the suppression lookup to be pending"
        )
        XCTAssertEqual(
            HelperMessageSuppressionURLProtocol.capturedPaths.last,
            "/api/participant/active-reservation",
            "placement is already proven by the public status read"
        )
        XCTAssertNil(store.fulfillmentConfirmation, "only the enrichment is outstanding")
        return fulfilling
    }

    private func assertPlacementWonWithoutAnExpiryNotice(
        _ store: RequestStore,
        suppressed: Bool,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let confirmation = try XCTUnwrap(store.fulfillmentConfirmation, label, file: file, line: line)
        XCTAssertEqual(confirmation.kind, .emailStatusUnknown, label, file: file, line: line)
        XCTAssertEqual(confirmation.messageSuppressed, suppressed, label, file: file, line: line)
        XCTAssertTrue(store.claimUnavailableNotices.isEmpty, "\(label): no expiry/ambiguity notice", file: file, line: line)
        XCTAssertNil(store.fulfillmentAmbiguity, label, file: file, line: line)
        XCTAssertNil(store.activeClaim, label, file: file, line: line)
        // The helper is never offered a second external order.
        XCTAssertFalse(store.canSubmitFulfillment(requestID: requestID), label, file: file, line: line)
    }

    func testClaimExpiryDuringAPendingSuppressionLookupNeverForfeitsConfirmedPlacement() async throws {
        let store = makeStore()
        HelperMessageSuppressionURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        let deadline = try XCTUnwrap(store.activeClaim?.claimExpiresAt)
        let fulfilling = try await startFulfillmentWithPendingSuppressionLookup(
            store: store,
            heldLookup: .response(data: placementResponse(requestID: requestID, messageSuppressed: true))
        )

        // The claim deadline passes while the lookup is still pending.
        store.revalidateActiveClaimExpiration(now: deadline.addingTimeInterval(1))
        XCTAssertTrue(store.claimUnavailableNotices.isEmpty, "expiry must not announce over proven placement")
        XCTAssertNotNil(store.activeClaim, "the proven placement still owns the claim until it is applied")

        HelperMessageSuppressionURLProtocol.releaseHeld()
        await fulfilling.value

        // Confirmed placement wins and still carries the authoritative suppression.
        try assertPlacementWonWithoutAnExpiryNotice(store, suppressed: true, "expiry then lookup answers")
    }

    func testTheClaimTimerFiringDuringAPendingSuppressionLookupNeverForfeitsConfirmedPlacement() async throws {
        let store = makeStore()
        HelperMessageSuppressionURLProtocol.enqueue(.response(data: claimResponse(expiresIn: 2)))
        try await store.claim(requestID: requestID)
        let deadline = try XCTUnwrap(store.activeClaim?.claimExpiresAt)
        let fulfilling = try await startFulfillmentWithPendingSuppressionLookup(
            store: store,
            heldLookup: .response(data: placementResponse(requestID: requestID, messageSuppressed: true))
        )

        // The real lifecycle timer reaches the deadline while the lookup is pending.
        try await Task.sleep(nanoseconds: UInt64(max(0, deadline.timeIntervalSinceNow + 0.6) * 1_000_000_000))
        XCTAssertTrue(store.claimUnavailableNotices.isEmpty, "the timer must not announce over proven placement")

        HelperMessageSuppressionURLProtocol.releaseHeld()
        await fulfilling.value

        try assertPlacementWonWithoutAnExpiryNotice(store, suppressed: true, "timer then lookup answers")
    }

    func testAFailedSuppressionLookupAfterExpiryStillAppliesConfirmedPlacementWithoutSuppression() async throws {
        let store = makeStore()
        HelperMessageSuppressionURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        let deadline = try XCTUnwrap(store.activeClaim?.claimExpiresAt)
        let fulfilling = try await startFulfillmentWithPendingSuppressionLookup(
            store: store,
            heldLookup: .failure(.networkConnectionLost)
        )

        store.revalidateActiveClaimExpiration(now: deadline.addingTimeInterval(1))
        HelperMessageSuppressionURLProtocol.releaseHeld()
        await fulfilling.value

        // Suppression could not be established, so it is not shown or fabricated.
        try assertPlacementWonWithoutAnExpiryNotice(store, suppressed: false, "failed lookup after expiry")
    }

    func testAnInconclusiveSuppressionLookupAfterExpiryStillAppliesConfirmedPlacement() async throws {
        let store = makeStore()
        HelperMessageSuppressionURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        let deadline = try XCTUnwrap(store.activeClaim?.claimExpiresAt)
        let fulfilling = try await startFulfillmentWithPendingSuppressionLookup(
            store: store,
            heldLookup: .response(data: placementResponse(requestID: requestID))
        )

        store.revalidateActiveClaimExpiration(now: deadline.addingTimeInterval(1))
        HelperMessageSuppressionURLProtocol.releaseHeld()
        await fulfilling.value

        try assertPlacementWonWithoutAnExpiryNotice(store, suppressed: false, "marker absent after expiry")
    }

    func testACancelledSuppressionLookupStillAppliesConfirmedPlacementWithoutSuppression() async throws {
        let store = makeStore()
        HelperMessageSuppressionURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        let deadline = try XCTUnwrap(store.activeClaim?.claimExpiresAt)
        let fulfilling = try await startFulfillmentWithPendingSuppressionLookup(
            store: store,
            heldLookup: .response(data: placementResponse(requestID: requestID, messageSuppressed: true))
        )

        store.revalidateActiveClaimExpiration(now: deadline.addingTimeInterval(1))
        fulfilling.cancel()
        try await waitUntil(
            { HelperMessageSuppressionURLProtocol.heldRequestCount == 0 },
            "the cancellation to reach the held lookup"
        )
        await fulfilling.value

        try assertPlacementWonWithoutAnExpiryNotice(store, suppressed: false, "cancelled lookup after expiry")
    }

    func testAPlacementWithNoMessagePerformsNoSuppressionLookup() async throws {
        // Suppression is impossible without a Message, so the lookup is never
        // made — for an absent, empty, or whitespace-only Message alike (the
        // backend trims, so each is "no Message").
        for message in [nil, "", "   \n\t "] as [String?] {
            HelperMessageSuppressionURLProtocol.reset()
            let store = makeStore()
            HelperMessageSuppressionURLProtocol.enqueue(.response(data: claimResponse()))
            try await store.claim(requestID: requestID)
            HelperMessageSuppressionURLProtocol.enqueue(.failure(.networkConnectionLost))
            HelperMessageSuppressionURLProtocol.enqueue(.response(data: detailResponse(status: "placed")))
            // A lookup, if one were wrongly made, would find a suppressed placement.
            HelperMessageSuppressionURLProtocol.enqueue(.response(
                data: placementResponse(requestID: requestID, messageSuppressed: true)
            ))

            try await store.fulfillWithFixtureScreenshot(
                requestID: requestID,
                orderNumber: "70154321",
                eta: "15 minutes",
                contactMessage: message
            )

            let label = "message \(String(describing: message))"
            try assertPlacementWonWithoutAnExpiryNotice(store, suppressed: false, label)
            XCTAssertEqual(
                HelperMessageSuppressionURLProtocol.capturedPaths,
                ["/api/request/\(requestID)/claim", "/api/request/\(requestID)/fulfill",
                 "/api/request/\(requestID)"],
                label
            )
        }
    }

    func testAMessageThatIsPresentStillPerformsTheSuppressionLookup() async throws {
        let store = makeStore()
        HelperMessageSuppressionURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        HelperMessageSuppressionURLProtocol.enqueue(.failure(.networkConnectionLost))
        HelperMessageSuppressionURLProtocol.enqueue(.response(data: detailResponse(status: "placed")))
        HelperMessageSuppressionURLProtocol.enqueue(.response(
            data: placementResponse(requestID: requestID, messageSuppressed: true)
        ))

        try await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: "  a real message  "
        )

        XCTAssertTrue(HelperMessageSuppressionURLProtocol.capturedPaths.contains("/api/participant/active-reservation"))
        XCTAssertTrue(try XCTUnwrap(store.fulfillmentConfirmation).messageSuppressed)
    }

    // MARK: - Relaunch

    func testRelaunchReconstructsNoSuccessOrSuppressionAndOffersNoSecondOrder() async throws {
        let store = makeStore()
        HelperMessageSuppressionURLProtocol.enqueue(.response(
            data: placementResponse(requestID: requestID, messageSuppressed: true)
        ))

        let outcome = try await store.continueActiveReservationIfNeeded()

        guard case .none = outcome else {
            return XCTFail("An authoritative placed answer reconciles to helper-available, got \(outcome)")
        }
        XCTAssertNil(store.fulfillmentConfirmation, "no success state is reconstructed")
        XCTAssertNil(store.confirmedFulfillmentOutcome)
        XCTAssertNil(store.fulfillmentAmbiguity)
        XCTAssertNil(store.activeClaim)
        // And no way to submit another fulfillment (another external order).
        XCTAssertFalse(store.canSubmitFulfillment(requestID: requestID))
        XCTAssertEqual(
            HelperMessageSuppressionURLProtocol.capturedPaths,
            ["/api/participant/active-reservation"]
        )
    }

    // MARK: - Copy and presentation

    func testTheApprovedSuppressionCopyIsExactAndHasNoEmailStatusLine() {
        XCTAssertEqual(HelperSuccessCopy.headline, "Thanks for helping.")
        XCTAssertEqual(HelperSuccessCopy.messageSuppressedHeadline, "Thanks for helping someone out.")
        XCTAssertEqual(HelperSuccessCopy.headline(messageSuppressed: true), "Thanks for helping someone out.")
        XCTAssertEqual(HelperSuccessCopy.headline(messageSuppressed: false), "Thanks for helping.")
        XCTAssertEqual(HelperSuccessCopy.messageSuppressedCardTitle, "Message not sent")
        XCTAssertEqual(HelperSuccessCopy.messageSuppressedCardBody, suppressedBody)
        // The approved explicit visual line break is after `meet`.
        XCTAssertEqual(
            HelperSuccessCopy.messageSuppressedCardBodyDisplay,
            "Your message didn’t meet\n\(AppBrand.name)’s guidelines."
        )
        XCTAssertEqual(
            HelperSuccessCopy.messageSuppressedCardBodyDisplay.replacingOccurrences(of: "\n", with: " "),
            suppressedBody
        )

        // Suppression-only: neither email-status line, whatever the outcome.
        for kind in [FulfillmentConfirmationKind.notificationSent, .notificationFailed, .emailStatusUnknown] {
            XCTAssertEqual(
                HelperSuccessCopy.supportingLines(for: kind, messageSuppressed: true),
                [],
                "\(kind)"
            )
            let announcement = HelperSuccessCopy.accessibilityAnnouncement(for: kind, messageSuppressed: true)
            XCTAssertEqual(announcement, "Thanks for helping someone out. Message not sent \(suppressedBody)")
            XCTAssertFalse(announcement.contains("emailed"))
            XCTAssertFalse(announcement.contains("email"))
        }
    }

    func testWithoutSuppressionThePresentationIsExactlyTheUnchangedH1Copy() {
        for kind in [FulfillmentConfirmationKind.notificationSent, .notificationFailed, .emailStatusUnknown] {
            XCTAssertEqual(
                HelperSuccessCopy.supportingLines(for: kind, messageSuppressed: false),
                [HelperSuccessCopy.secondaryLine(for: kind)].compactMap { $0 },
                "\(kind)"
            )
            XCTAssertEqual(
                HelperSuccessCopy.accessibilityAnnouncement(for: kind),
                HelperSuccessCopy.accessibilityAnnouncement(for: kind, messageSuppressed: false)
            )
        }
        XCTAssertEqual(
            HelperSuccessCopy.accessibilityAnnouncement(for: .notificationSent),
            "Thanks for helping."
        )
        // Absence of suppression is the default for every existing construction.
        XCTAssertFalse(FulfillmentConfirmation(
            id: UUID(), requestID: "r", vendor: "v", foodDescription: "f", kind: .notificationSent
        ).messageSuppressed)
    }

    func testTheSuccessPresentationAddsNoControlAndKeepsTheH1TimingContract() throws {
        let view = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("CommonPlateios/Views/HelperSuccessView.swift"),
            encoding: .utf8
        )
        // No retry/edit/dismiss/second-order control, link, sheet, or alert.
        for forbidden in ["Button(", "NavigationLink", "onTapGesture", "Link(", "Menu(", ".sheet(", ".alert(", ".fullScreenCover("] {
            XCTAssertFalse(view.contains(forbidden), forbidden)
        }
        XCTAssertTrue(view.contains("helper-success-message-suppressed"))
        // Suppression-only: the ordinary secondary line stays on the other branch.
        XCTAssertTrue(view.contains("helper-success-secondary"))

        // U1.1 changes no H1 timing or motion value.
        let standard = HelperSuccessMotionPlan.standard
        XCTAssertEqual(standard.ticketHold, .milliseconds(350))
        // Faith-selected Tiny standing ovation (Figma 1596:7322) supersedes the
        // 650 ms / 2000 ms H1 timings; U1.1 itself adds no timing change.
        XCTAssertEqual(standard.transformDuration, .milliseconds(1000))
        XCTAssertEqual(standard.readableDwell, .milliseconds(2400))
        let reduced = HelperSuccessMotionPlan.reducedMotion
        XCTAssertEqual(reduced.ticketHold, .milliseconds(350))
        XCTAssertEqual(reduced.transformDuration, .milliseconds(400))
        XCTAssertEqual(reduced.readableDwell, .milliseconds(2000))
    }

    func testASuppressedConfirmationStillReturnsHomeAutomaticallyExactlyOnce() {
        var announcements: [String] = []
        var homeReturns: [UUID] = []
        let coordinator = HelperSuccessPresentationCoordinator(
            performResolve: { confirmation in
                announcements.append(HelperSuccessCopy.accessibilityAnnouncement(
                    for: confirmation.kind,
                    messageSuppressed: confirmation.messageSuppressed
                ))
            },
            drivesAutomatically: false,
            isVoiceOverRunning: { false }
        )
        coordinator.returnHome = { homeReturns.append($0.id) }
        let confirmation = FulfillmentConfirmation(
            id: UUID(),
            requestID: requestID,
            vendor: "Crave NYU",
            foodDescription: "Rice bowl",
            kind: .notificationSent,
            messageSuppressed: true
        )

        coordinator.updateSceneActivity(isActive: true)
        coordinator.update(confirmation: confirmation, reduceMotion: false)
        let plan = HelperSuccessMotionPlan.standard
        coordinator.advance(by: plan.ticketHold + plan.transformDuration)
        XCTAssertEqual(announcements, ["Thanks for helping someone out. Message not sent \(suppressedBody)"])
        XCTAssertTrue(homeReturns.isEmpty)

        coordinator.advance(by: plan.readableDwell)
        XCTAssertEqual(homeReturns, [confirmation.id])
        // Nothing further, however much more active time passes.
        coordinator.advance(by: .seconds(60))
        XCTAssertEqual(homeReturns, [confirmation.id])
        XCTAssertEqual(announcements.count, 1)
    }

    // MARK: - Helpers

    /// Mirrors `APIClient`'s own date handling (fractional-second ISO-8601),
    /// whose decoder is private, so the DTOs are decoded exactly as on the wire.
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Expected ISO-8601 date string, got \(raw)"
            ))
        }
        return decoder
    }

    private func makeStore(authority: SuppressionAuthorityBox? = nil) -> RequestStore {
        let box = authority ?? SuppressionAuthorityBox(helperAuthority)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HelperMessageSuppressionURLProtocol.self]
        let service = RequestService(client: APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        ))
        return RequestStore(
            service: service,
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { box.value },
            participantAuthorityRejected: {}
        )
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func requestObject(id: String, status: String) -> String {
        """
        {
          "id": "\(id)",
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

    private func claimResponse(expiresIn: TimeInterval = 15 * 60) -> Data {
        Data("""
        {
          "request": \(requestObject(id: requestID, status: "claimed")),
          "claim": {
            "claimToken": "claim-token",
            "claimExpiresAt": "\(iso8601String(Date().addingTimeInterval(expiresIn)))"
          }
        }
        """.utf8)
    }

    /// Polls a main-actor condition so a test can wait for a held request to
    /// arrive without sleeping a guessed duration.
    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(description)", file: file, line: line)
    }

    private func fulfillmentResponse(
        notificationStatus: String,
        messageSuppressed: Bool? = nil
    ) -> Data {
        let suppression = messageSuppressed.map { #","messageSuppressed": \#($0)"# } ?? ""
        return Data("""
        {
          "request": \(requestObject(id: requestID, status: "placed")),
          "notification": { "status": "\(notificationStatus)" }\(suppression)
        }
        """.utf8)
    }

    private func detailResponse(status: String) -> Data {
        Data(#"{"request": \#(requestObject(id: requestID, status: status))}"#.utf8)
    }

    private func placementResponse(
        requestID: String,
        messageSuppressed: Bool? = nil,
        messageSuppressedLiteral: String? = nil
    ) -> Data {
        let literal = messageSuppressedLiteral ?? messageSuppressed.map { "\($0)" }
        let suppression = literal.map { #","messageSuppressed": \#($0)"# } ?? ""
        return Data("""
        {
          "reservation": null,
          "placement": {
            "request": \(requestObject(id: requestID, status: "placed")),
            "orderNumber": "70154321",
            "etaText": "15 minutes",
            "notification": { "status": "sent" }\(suppression)
          }
        }
        """.utf8)
    }
}
