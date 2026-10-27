//
//  ParticipantBlockTests.swift
//  CommonPlateiosTests
//
// W4-U1.3 participant blocking, iOS side. Unit proof of store state, service
// wiring, and presentation truth — not device evidence of the SwiftUI surfaces
// (`docs/testing.md`: the project has no UI-test target).
//
// What these prove:
// - the block routes carry a request id and the external-order answer and never
//   a participant identifier, and nothing in the wire or domain types can hold
//   another student's identity;
// - `No` ends the reservation only when the backend confirms it did; `Yes`
//   leaves the reservation exactly as it was, and neither fabricates placement,
//   release, or cancellation;
// - an outcome iOS cannot confirm is never retried and changes no local state;
// - a requester gets no helper-directed Block from their own request;
// - management is backend-confirmed, per participant, and Unblock only removes
//   what the backend confirms is gone.
import Foundation
import XCTest
@testable import CommonPlateios

/// Isolated transport stub: this suite's queue can never be consumed by
/// another suite.
final class ParticipantBlockURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let data: Data
        let errorCode: URLError.Code?
        /// Holds the response back so a test can observe the in-flight state.
        var delay: TimeInterval = 0

        static func response(statusCode: Int = 200, data: Data) -> Stub {
            Stub(statusCode: statusCode, data: data, errorCode: nil)
        }

        static func delayed(_ seconds: TimeInterval, data: Data) -> Stub {
            Stub(statusCode: 200, data: data, errorCode: nil, delay: seconds)
        }

        static func failure(_ code: URLError.Code) -> Stub {
            Stub(statusCode: 0, data: Data(), errorCode: code)
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

    static func enqueue(_ stub: Stub) {
        lock.lock(); defer { lock.unlock() }
        stubs.append(stub)
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        stubs.removeAll()
        captured.removeAll()
    }

    static var capturedRequests: [Captured] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

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
        let deliver = {
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: stub.data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if stub.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {}
}

@MainActor
private final class BlockAuthorityBox {
    var value: String?
    init(_ value: String?) { self.value = value }
}

@MainActor
final class ParticipantBlockTests: XCTestCase {
    private let requestID = "meal-a"
    private let authority = "64c0000000000000000000a1.1.credential"

    override func tearDown() {
        ParticipantBlockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Wire and domain shape

    func testBlockWireTypesCarryContextOnlyAndNoParticipantIdentity() throws {
        let decoded = try decoder().decode(
            CreateParticipantBlockResponseDTO.self,
            from: blockResponse(id: "block-1", role: "requester", released: true)
        )
        XCTAssertEqual(decoded.block.id, "block-1")
        XCTAssertEqual(decoded.block.blockedRole, .requester)
        XCTAssertEqual(decoded.block.diningLocation, "Jasper Kane Cafe")
        XCTAssertTrue(decoded.reservationReleased)

        // The domain row has exactly the accepted snapshot: role, location,
        // time, and the block's own handle.
        let mirrored = Mirror(reflecting: BlockedStudent(
            id: "b", role: .helper, diningLocation: "Kimmel", interactionAt: Date()
        ))
        XCTAssertEqual(
            Set(mirrored.children.compactMap(\.label)),
            ["id", "role", "diningLocation", "interactionAt"]
        )
    }

    func testPayloadOmitsTheAnswerWhenNoneIsGiven() throws {
        let omitted = try JSONEncoder().encode(
            CreateParticipantBlockPayload(externalOrderPlaced: nil)
        )
        XCTAssertEqual(String(decoding: omitted, as: UTF8.self), "{}")
        let answered = try JSONEncoder().encode(
            CreateParticipantBlockPayload(externalOrderPlaced: false)
        )
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: answered) as? [String: Bool],
            ["externalOrderPlaced": false]
        )
    }

    func testManagementRowUsesOnlyAcceptedInteractionContext() {
        let when = Date(timeIntervalSince1970: 1_791_411_300) // Oct 7 2026 22:15 UTC
        let helper = BlockedStudent(
            id: "1", role: .helper, diningLocation: "Jasper Kane Cafe", interactionAt: when
        )
        let requester = BlockedStudent(
            id: "2", role: .requester, diningLocation: "Kimmel", interactionAt: when
        )
        let zone = TimeZone(identifier: "America/New_York")!

        // Recent iOS formats the time with a narrow no-break space before the
        // meridiem; normalize it so the assertion is about the content.
        func plain(_ text: String) -> String {
            text.replacingOccurrences(of: "\u{202F}", with: " ")
        }
        XCTAssertEqual(BlockedStudentPresentation.roleTitle(for: helper), "HELPER")
        XCTAssertEqual(BlockedStudentPresentation.roleTitle(for: requester), "REQUESTER")
        XCTAssertEqual(
            plain(BlockedStudentPresentation.singleLine(for: helper, timeZone: zone)),
            "Jasper Kane Cafe · Oct 7 · 6:15 PM"
        )
        XCTAssertEqual(
            plain(BlockedStudentPresentation.timestamp(for: requester, timeZone: zone)),
            "Oct 7 · 6:15 PM"
        )
    }

    // MARK: - Block while helping

    func testNoAnswerReleasesLocallyOnlyWhenTheBackendConfirmsRelease() async throws {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        XCTAssertNotNil(store.activeClaim)
        ParticipantBlockURLProtocol.enqueue(.response(
            data: blockResponse(id: "block-1", role: "requester", released: true)
        ))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))

        let result = await store.blockHelpedRequester(externalOrderPlaced: false)

        XCTAssertEqual(result, .blocked(reservationReleased: true))
        let sent = try XCTUnwrap(
            ParticipantBlockURLProtocol.capturedRequests.first { $0.path.hasSuffix("/block") }
        )
        XCTAssertEqual(sent.path, "/api/request/\(requestID)/block")
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.bodyObject as? [String: Bool], ["externalOrderPlaced": false])
        XCTAssertEqual(sent.headers["x-commonplate-participant"], authority)
        // Reservation ended through confirmed backend truth, nothing placed.
        XCTAssertNil(store.activeClaim)
        XCTAssertNil(store.fulfillmentConfirmation)
        XCTAssertNil(store.confirmedFulfillmentOutcome)
        XCTAssertEqual(store.currentBlockedStudents.map(\.id), ["block-1"])
        XCTAssertNil(store.blockError)
    }

    func testYesAnswerKeepsTheReservationAndNeverReleasesOrReopens() async throws {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        let before = try XCTUnwrap(store.activeClaim)
        ParticipantBlockURLProtocol.enqueue(.response(
            data: blockResponse(id: "block-1", role: "requester", released: false)
        ))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))

        let result = await store.blockHelpedRequester(externalOrderPlaced: true)

        XCTAssertEqual(result, .blocked(reservationReleased: false))
        let sent = try XCTUnwrap(
            ParticipantBlockURLProtocol.capturedRequests.first { $0.path.hasSuffix("/block") }
        )
        XCTAssertEqual(sent.bodyObject as? [String: Bool], ["externalOrderPlaced": true])
        // Same reservation, same deadline; no release request was ever sent.
        let after = try XCTUnwrap(store.activeClaim)
        XCTAssertEqual(after.requestID, before.requestID)
        XCTAssertEqual(after.claimExpiresAt, before.claimExpiresAt)
        XCTAssertFalse(
            ParticipantBlockURLProtocol.capturedRequests.contains { $0.path.hasSuffix("/release") }
        )
        // A Block does not disable the single extension: it stays on offer
        // under the ordinary rules, while the helper's optional Message is
        // withheld.
        XCTAssertEqual(after.isExtensionAvailable, before.isExtensionAvailable)
        XCTAssertTrue(after.isExtensionAvailable)
        XCTAssertTrue(store.contactSuppressedRequestIDs.contains(requestID))
        // This helper just took the Block itself, so the live state may say so.
        XCTAssertTrue(store.callerBlockedRequestIDs.contains(requestID))
        XCTAssertTrue(store.canExtendActiveClaim)
        XCTAssertTrue(store.canReleaseActiveClaim)
        // Still recordable through the one placement path.
        XCTAssertNil(store.fulfillmentConfirmation)
    }

    func testPlacementAfterYesNeverSendsTheOptionalMessage() async throws {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ParticipantBlockURLProtocol.enqueue(.response(
            data: blockResponse(id: "block-1", role: "requester", released: false)
        ))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
        await store.blockHelpedRequester(externalOrderPlaced: true)
        // The confirmed block triggers one board refresh in its own task; let it
        // consume its stub before the placement response is queued.
        try await waitUntil(
            {
                ParticipantBlockURLProtocol.capturedRequests.contains { $0.path == "/api/requests" }
                    && !store.isFetching
            },
            "the post-block board refresh"
        )
        ParticipantBlockURLProtocol.enqueue(.response(data: fulfillmentResponse()))

        try await store.fulfillWithFixtureScreenshot(
            requestID: requestID,
            orderNumber: "70154321",
            eta: "15 minutes",
            contactMessage: "thanks so much"
        )

        let fulfill = try XCTUnwrap(
            ParticipantBlockURLProtocol.capturedRequests.last { $0.path.hasSuffix("/fulfill") }
        )
        let fulfillment = try XCTUnwrap(fulfill.bodyObject?["fulfillment"] as? [String: Any])
        XCTAssertNil(fulfillment["contactMessage"])
        XCTAssertEqual(fulfillment["orderNumber"] as? String, "70154321")
        // Ordinary placement success, and suppression state is released with
        // the claim.
        XCTAssertNotNil(store.fulfillmentConfirmation)
        XCTAssertNil(store.activeClaim)
        XCTAssertFalse(store.contactSuppressedRequestIDs.contains(requestID))
    }

    func testNoAnswerThatTheBackendDidNotReleaseIsNeverReportedAsReleased() async throws {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        let before = try XCTUnwrap(store.activeClaim)
        // Backend: block recorded, reservation not released (it lapsed or was
        // recorded in the meantime). The client must not assume a release.
        ParticipantBlockURLProtocol.enqueue(.response(
            data: blockResponse(id: "block-1", role: "requester", released: false)
        ))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))

        let result = await store.blockHelpedRequester(externalOrderPlaced: false)

        XCTAssertEqual(result, .blocked(reservationReleased: false))
        XCTAssertEqual(store.activeClaim?.requestID, before.requestID)
        XCTAssertEqual(store.activeClaim?.claimExpiresAt, before.claimExpiresAt)
        XCTAssertFalse(
            ParticipantBlockURLProtocol.capturedRequests.contains { $0.path.hasSuffix("/release") }
        )
        // Block still takes effect: contact withheld, extension untouched.
        XCTAssertTrue(store.contactSuppressedRequestIDs.contains(requestID))
        XCTAssertTrue(try XCTUnwrap(store.activeClaim).isExtensionAvailable)
        // A `No` does not establish the live Yes-path ownership knowledge,
        // even when a stale/race response left the reservation held.
        XCTAssertFalse(store.callerBlockedRequestIDs.contains(requestID))
        XCTAssertEqual(store.currentBlockedStudents.map(\.id), ["block-1"])
    }

    func testAnUnconfirmedBlockChangesNothingAndIsNeverRetried() async throws {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        let before = try XCTUnwrap(store.activeClaim)
        ParticipantBlockURLProtocol.enqueue(.failure(.networkConnectionLost))

        let result = await store.blockHelpedRequester(externalOrderPlaced: false)

        XCTAssertEqual(result, .notBlocked)
        let blockRequests = ParticipantBlockURLProtocol.capturedRequests.filter {
            $0.path.hasSuffix("/block")
        }
        XCTAssertEqual(blockRequests.count, 1)
        guard case .ambiguousBlockOutcome? = store.blockError else {
            return XCTFail("expected an ambiguous block outcome, got \(String(describing: store.blockError))")
        }
        XCTAssertEqual(
            ParticipantBlockPresentationError.map(store.blockError),
            .unconfirmed
        )
        // No fabricated success, release, or placement.
        XCTAssertEqual(store.activeClaim?.claimExpiresAt, before.claimExpiresAt)
        XCTAssertTrue(store.currentBlockedStudents.isEmpty)
        XCTAssertTrue(store.contactSuppressedRequestIDs.isEmpty)
        XCTAssertNil(store.fulfillmentConfirmation)
    }

    func testAnUnreadableInternalFailureIsTreatedAsUnconfirmedNotAsNothingHappened() async throws {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ParticipantBlockURLProtocol.enqueue(.response(
            statusCode: 500,
            data: Data(#"{"error": {"code": "INTERNAL_FAILURE", "message": "x", "fields": null}}"#.utf8)
        ))

        let result = await store.blockHelpedRequester(externalOrderPlaced: false)

        XCTAssertEqual(result, .notBlocked)
        guard case .ambiguousBlockOutcome? = store.blockError else {
            return XCTFail("expected an ambiguous block outcome")
        }
        XCTAssertNotNil(store.activeClaim)
    }

    func testADefinitiveRefusalLeavesTheReservationAndIsNotAmbiguous() async throws {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ParticipantBlockURLProtocol.enqueue(.response(
            statusCode: 409,
            data: Data(#"{"error": {"code": "RESERVATION_STATE_CHANGED", "message": "x", "fields": null}}"#.utf8)
        ))

        let result = await store.blockHelpedRequester(externalOrderPlaced: false)

        XCTAssertEqual(result, .notBlocked)
        XCTAssertEqual(
            ParticipantBlockPresentationError.map(store.blockError),
            .reservationChanged
        )
        XCTAssertNotNil(store.activeClaim)
        XCTAssertTrue(store.currentBlockedStudents.isEmpty)
    }

    func testNoBlockWithoutAHeldReservationOrAParticipant() async {
        let signedOut = makeStore(authority: BlockAuthorityBox(nil))
        let result = await signedOut.blockHelpedRequester(externalOrderPlaced: true)
        XCTAssertEqual(result, .notBlocked)
        XCTAssertFalse(signedOut.canBlockHelpedRequester)

        let idle = makeStore()
        let idleResult = await idle.blockHelpedRequester(externalOrderPlaced: false)
        XCTAssertEqual(idleResult, .notBlocked)
        XCTAssertTrue(ParticipantBlockURLProtocol.capturedRequests.isEmpty)
    }

    // MARK: - Block from Request Detail

    func testDetailBlockSendsOnlyTheRequestAndNoAnswer() async throws {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(
            data: blockResponse(id: "block-9", role: "requester", released: false)
        ))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))

        let result = await store.blockRequesterOfViewedRequest(requestID: requestID)

        XCTAssertEqual(result, .blocked(reservationReleased: false))
        let sent = try XCTUnwrap(
            ParticipantBlockURLProtocol.capturedRequests.first { $0.path.hasSuffix("/block") }
        )
        XCTAssertEqual(sent.path, "/api/request/\(requestID)/block")
        XCTAssertEqual(sent.bodyObject?.count, 0)
        XCTAssertEqual(store.currentBlockedStudents.map(\.id), ["block-9"])
    }

    func testDetailBlockRefusesLocallyForARequestTheHelperIsHolding() async throws {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        let sentBefore = ParticipantBlockURLProtocol.capturedRequests.count

        let result = await store.blockRequesterOfViewedRequest(requestID: requestID)

        XCTAssertEqual(result, .notBlocked)
        XCTAssertEqual(ParticipantBlockURLProtocol.capturedRequests.count, sentBefore)
        XCTAssertEqual(
            ParticipantBlockPresentationError.map(store.blockError),
            .helpingFlowRequired
        )
    }

    func testBlockEntryAvailabilityNeverOffersARequesterTheirOwnRequestsHelper() {
        // Requester → unknown helper before placement is not a surface here.
        XCTAssertFalse(ParticipantBlockAvailability.requestDetailOffersBlock(
            ownership: .own, hasVerifiedIdentity: true, holdsReservationForRequest: false
        ))
        // Ownership not established: fail closed.
        XCTAssertFalse(ParticipantBlockAvailability.requestDetailOffersBlock(
            ownership: .unresolved, hasVerifiedIdentity: true, holdsReservationForRequest: false
        ))
        // No participant, no block.
        XCTAssertFalse(ParticipantBlockAvailability.requestDetailOffersBlock(
            ownership: .notOwn, hasVerifiedIdentity: false, holdsReservationForRequest: false
        ))
        // Holding the reservation goes through Helping and its question.
        XCTAssertFalse(ParticipantBlockAvailability.requestDetailOffersBlock(
            ownership: .notOwn, hasVerifiedIdentity: true, holdsReservationForRequest: true
        ))
        XCTAssertTrue(ParticipantBlockAvailability.requestDetailOffersBlock(
            ownership: .notOwn, hasVerifiedIdentity: true, holdsReservationForRequest: false
        ))
    }

    // MARK: - Management and Unblock

    func testLoadAndUnblockAreBackendConfirmedAndOwnerScoped() async throws {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(
            data: listResponse([("b1", "requester"), ("b2", "helper")])
        ))
        await store.loadBlockedStudents()
        XCTAssertEqual(store.blockedStudentsLoadState, .loaded)
        XCTAssertEqual(store.currentBlockedStudents.map(\.id), ["b1", "b2"])
        let listed = try XCTUnwrap(ParticipantBlockURLProtocol.capturedRequests.first)
        XCTAssertEqual(listed.path, "/api/participant/blocks")
        XCTAssertEqual(listed.method, "GET")

        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"removed": true}"#.utf8)))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
        await store.unblockStudent(id: "b1")

        let removal = try XCTUnwrap(
            ParticipantBlockURLProtocol.capturedRequests.first { $0.method == "DELETE" }
        )
        XCTAssertEqual(removal.path, "/api/participant/blocks/b1")
        XCTAssertEqual(removal.headers["x-commonplate-participant"], authority)
        XCTAssertEqual(store.currentBlockedStudents.map(\.id), ["b2"])
        XCTAssertNil(store.unblockError)
    }

    func testAFailedUnblockKeepsTheBlockAndAMissingOneIsRemoved() async throws {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(
            data: listResponse([("b1", "requester"), ("b2", "helper")])
        ))
        await store.loadBlockedStudents()

        ParticipantBlockURLProtocol.enqueue(.failure(.notConnectedToInternet))
        await store.unblockStudent(id: "b1")
        XCTAssertEqual(store.currentBlockedStudents.map(\.id), ["b1", "b2"])
        XCTAssertNotNil(store.unblockError)

        ParticipantBlockURLProtocol.enqueue(.response(
            statusCode: 404,
            data: Data(#"{"error": {"code": "BLOCK_NOT_FOUND", "message": "x", "fields": null}}"#.utf8)
        ))
        await store.unblockStudent(id: "b2")
        XCTAssertEqual(store.currentBlockedStudents.map(\.id), ["b1"])
    }

    func testSuccessfulUnblockClearsOnlyTheLiveCallerOwnedHelpingKnowledge() async throws {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.response(data: claimResponse()))
        try await store.claim(requestID: requestID)
        ParticipantBlockURLProtocol.enqueue(.response(
            data: blockResponse(id: "block-1", role: "requester", released: false)
        ))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{\"requests\": []}"#.utf8)))

        let blockResult = await store.blockHelpedRequester(externalOrderPlaced: true)

        XCTAssertEqual(blockResult, .blocked(reservationReleased: false))
        XCTAssertTrue(store.callerBlockedRequestIDs.contains(requestID))
        XCTAssertTrue(store.contactSuppressedRequestIDs.contains(requestID))
        try await waitUntil(
            {
                ParticipantBlockURLProtocol.capturedRequests.contains { $0.path == "/api/requests" }
                    && !store.isFetching
            },
            "the post-block board refresh"
        )

        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"removed": true}"#.utf8)))
        // The authoritative reservation read still reports a restriction.
        ParticipantBlockURLProtocol.enqueue(.response(data: Data("""
        {
          "reservation": {
            "request": \(requestObject(id: requestID, status: "claimed")),
            "claimExpiresAt": "\(iso8601String(Date().addingTimeInterval(10 * 60)))",
            "claimExtendedAt": null,
            "directContactRestricted": true
          },
          "placement": null
        }
        """.utf8)))
        ParticipantBlockURLProtocol.enqueue(.response(data: Data(#"{"requests": []}"#.utf8)))
        await store.unblockStudent(id: "block-1")

        // The successful Unblock removes only the ephemeral ownership claim.
        // The pair restriction stays until an authoritative reservation read
        // says otherwise (ParticipantBlockManagementTests), so Helping uses
        // neutral "Direct contact is unavailable" copy rather than "Your block".
        XCTAssertFalse(store.callerBlockedRequestIDs.contains(requestID))
        XCTAssertTrue(store.contactSuppressedRequestIDs.contains(requestID))
        XCTAssertNotNil(store.activeClaim)
        XCTAssertEqual(store.currentBlockedStudents.map(\.id), [])
    }

    func testAFailedLoadIsAFailureNeverAnEmptyList() async {
        let store = makeStore()
        ParticipantBlockURLProtocol.enqueue(.failure(.timedOut))

        await store.loadBlockedStudents()

        XCTAssertEqual(store.blockedStudentsLoadState, .failed)
        XCTAssertTrue(store.currentBlockedStudents.isEmpty)
    }

    func testAListReadForAnotherParticipantIsNeverPresented() async {
        let box = BlockAuthorityBox(authority)
        let store = makeStore(authority: box)
        ParticipantBlockURLProtocol.enqueue(.response(data: listResponse([("b1", "requester")])))
        await store.loadBlockedStudents()
        XCTAssertEqual(store.currentBlockedStudents.count, 1)

        box.value = "64c0000000000000000000b2.1.other"

        XCTAssertTrue(store.currentBlockedStudents.isEmpty)
    }

    // MARK: - Copy and source boundaries

    func testCopyNeverStatesWhoBlockedWhomOrImpliesAReportOrCancellation() {
        let strings: [String] = [
            ParticipantBlockCopy.blockActionTitle,
            ParticipantBlockCopy.blockConfirmationTitle,
            ParticipantBlockCopy.blockConfirmationMessage,
            ParticipantBlockCopy.externalOrderQuestionTitle,
            ParticipantBlockCopy.messageNotSharedWarning,
            ParticipantBlockCopy.blockActivePill,
            ParticipantBlockCopy.blockActiveSupporting,
            ParticipantBlockCopy.directContactUnavailableNotice,
        ] + [
            ParticipantBlockPresentationError.helpingFlowRequired,
            .reservationChanged, .unconfirmed, .paused, .rateLimited, .unavailable, .couldNotBlock,
        ].map(\.message)

        for text in strings {
            let lowered = text.lowercased()
            XCTAssertFalse(lowered.contains("report"), text)
            XCTAssertFalse(lowered.contains("blocked you"), text)
            XCTAssertFalse(lowered.contains("blocked by"), text)
            XCTAssertFalse(lowered.contains("second order"), text)
            XCTAssertFalse(lowered.contains("another grubhub order"), text)
        }
    }

    func testBlockSourcesHoldNoParticipantIdentityFieldAndReuseTheBoundary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
        func source(_ relative: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        }

        for file in ["DTOs/ParticipantBlockDTOs.swift", "Models/BlockedStudent.swift"] {
            let text = try source(file)
            for forbidden in ["email", "participantId", "participantID", "displayName", "name:"] {
                XCTAssertFalse(
                    text.contains(forbidden),
                    "\(file) must not carry \(forbidden)"
                )
            }
        }
        // Views reach the backend only through the store.
        let views = try source("Views/ParticipantBlockViews.swift")
        XCTAssertFalse(views.contains("RequestService("))
        XCTAssertFalse(views.contains("service."))
        XCTAssertFalse(views.contains("APIClient"))
        // Management is reached only through Privacy & Safety, and only with a
        // verified participant; Settings carries no duplicate entry.
        let settings = try source("Views/SettingsView.swift")
        XCTAssertFalse(settings.contains("AppRoute.blockedStudents"))
        let privacy = try source("Views/PrivacySafetyView.swift")
        let identityGate = try XCTUnwrap(privacy.range(of: "if participantIdentityStore.identity != nil {"))
        let managementLink = try XCTUnwrap(privacy.range(of: "NavigationLink(value: AppRoute.blockedStudents)"))
        XCTAssertLessThan(identityGate.lowerBound, managementLink.lowerBound)
        XCTAssertTrue(privacy.contains("privacy-safety-blocked-students"))
        // Helping hosts the external-order question; Detail hosts the plain block.
        XCTAssertTrue(try source("Views/FulfillRequestView.swift").contains("HelpingBlockMenu("))
        XCTAssertTrue(try source("Views/RequestDetailView.swift").contains("RequestDetailBlockMenu("))
    }

    // MARK: - Fixtures

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

    private func makeStore(authority box: BlockAuthorityBox? = nil) -> RequestStore {
        let box = box ?? BlockAuthorityBox(authority)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ParticipantBlockURLProtocol.self]
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

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: raw) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: raw)
                )
            }
            return date
        }
        return decoder
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
          "vendor": "Jasper Kane Cafe",
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

    private func fulfillmentResponse() -> Data {
        Data("""
        {
          "request": \(requestObject(id: requestID, status: "placed")),
          "notification": { "status": "sent" }
        }
        """.utf8)
    }

    private func blockObject(id: String, role: String) -> String {
        """
        {
          "id": "\(id)",
          "blockedRole": "\(role)",
          "diningLocation": "Jasper Kane Cafe",
          "interactionAt": "2026-07-20T18:30:00.000Z",
          "createdAt": "2026-07-20T18:31:00.000Z"
        }
        """
    }

    private func blockResponse(id: String, role: String, released: Bool) -> Data {
        Data("""
        { "block": \(blockObject(id: id, role: role)), "reservationReleased": \(released) }
        """.utf8)
    }

    private func listResponse(_ rows: [(String, String)]) -> Data {
        let items = rows.map { blockObject(id: $0.0, role: $0.1) }.joined(separator: ",")
        return Data(#"{ "blocks": [\#(items)] }"#.utf8)
    }
}
