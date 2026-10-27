import Foundation
import XCTest
@testable import CommonPlateios

final class ParticipantReportingURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let data: Data
        let errorCode: URLError.Code?

        static func response(_ json: String, statusCode: Int = 200) -> Stub {
            Stub(statusCode: statusCode, data: Data(json.utf8), errorCode: nil)
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

        var normalizedHeaders: [String: String] {
            Dictionary(
                uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) }
            )
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var stubs: [Stub] = []
    private nonisolated(unsafe) static var captured: [Captured] = []

    static func enqueue(_ stub: Stub) {
        lock.lock()
        defer { lock.unlock() }
        stubs.append(stub)
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        stubs.removeAll()
        captured.removeAll()
    }

    static var capturedRequests: [Captured] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    private static func record(_ capturedRequest: Captured) -> Stub? {
        lock.lock()
        defer { lock.unlock() }
        captured.append(capturedRequest)
        return stubs.isEmpty ? nil : stubs.removeFirst()
    }

    private static func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = Self.record(Captured(
            path: request.url?.path ?? "",
            method: request.httpMethod ?? "",
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.bodyData(request)
        ))
        guard let stub else {
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
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class ParticipantReportingFlowTests: XCTestCase {
    private let requestID = "64b0000000000000000000a1"
    private let authority = canonicalParticipantAuthorityFixture
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        suiteName = "ParticipantReportingFlowTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        ParticipantReportingURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testReasonOrderExplanationLimitAndConfiguredSupportContact() throws {
        XCTAssertEqual(ParticipantReportReason.allCases.map(\.rawValue), [
            "Harassment or hateful behavior",
            "Sexual or inappropriate content",
            "Threats or unsafe behavior",
            "Spam or misuse of CommonPlate",
            "Other concern",
        ])

        let twoHundredFortyNineCharacters = String(repeating: "a", count: 249)
        let supplementaryCharacter = "🙂"
        XCTAssertEqual(
            ParticipantReportView.limitedExplanation(twoHundredFortyNineCharacters + supplementaryCharacter),
            twoHundredFortyNineCharacters
        )
        XCTAssertEqual(
            ParticipantReportView.limitedExplanation(String(repeating: "b", count: 251)).count,
            250
        )

        let contact = CommonPlateSupportContact(address: " support@example.edu \n")
        XCTAssertTrue(contact.isConfigured)
        XCTAssertEqual(contact.mailtoURL?.absoluteString, "mailto:support@example.edu")
        XCTAssertFalse(CommonPlateSupportContact(address: nil).isConfigured)
        XCTAssertFalse(CommonPlateSupportContact(address: "not-an-address").isConfigured)
    }

    func testContextualEntryEligibilityStopCancelAndRestrictionSupportPresentation() throws {
        XCTAssertTrue(ParticipantReportAvailability.requestDetailOffersReport(
            requestStatus: .open,
            ownership: .notOwn,
            hasVerifiedIdentity: true,
            holdsReservationForRequest: false
        ))
        for (status, ownership, verified, held) in [
            (RequestStatus.claimed, RequestOwnership.notOwn, true, false),
            (RequestStatus.open, RequestOwnership.own, true, false),
            (RequestStatus.open, RequestOwnership.notOwn, false, false),
            (RequestStatus.open, RequestOwnership.notOwn, true, true),
        ] {
            XCTAssertFalse(ParticipantReportAvailability.requestDetailOffersReport(
                requestStatus: status,
                ownership: ownership,
                hasVerifiedIdentity: verified,
                holdsReservationForRequest: held
            ))
        }
        XCTAssertTrue(ParticipantReportAvailability.helpingOffersReport(
            requestStatus: .claimed,
            hasVerifiedIdentity: true,
            holdsReservation: true
        ))
        XCTAssertFalse(ParticipantReportAvailability.helpingOffersReport(
            requestStatus: .claimed,
            hasVerifiedIdentity: true,
            holdsReservation: false
        ))

        let detail = try source("Views/RequestDetailView.swift")
        XCTAssertTrue(ParticipantReportAvailability.placedOrderOffersReport(
            isPickupPending: true,
            hasVerifiedIdentity: true
        ))
        XCTAssertFalse(ParticipantReportAvailability.placedOrderOffersReport(
            isPickupPending: false,
            hasVerifiedIdentity: true
        ))
        XCTAssertFalse(ParticipantReportAvailability.placedOrderOffersReport(
            isPickupPending: true,
            hasVerifiedIdentity: false
        ))
        let placedOrder = try source("Views/PlacedOrderDetailView.swift")
        XCTAssertTrue(placedOrder.contains("ParticipantReportAvailability.placedOrderOffersReport("))
        XCTAssertTrue(placedOrder.contains("store.presentReportPopup("))
        XCTAssertTrue(placedOrder.contains("hasReportedRequest(requestID: requestID)"))
        let helping = try source("Views/FulfillRequestView.swift")
        XCTAssertTrue(detail.contains("ParticipantReportAvailability.requestDetailOffersReport("))
        XCTAssertTrue(helping.contains("ParticipantReportAvailability.helpingOffersReport("))
        let menus = try source("Views/ParticipantBlockViews.swift")
        XCTAssertTrue(menus.contains("Button(\"Report student\", action: onReport)"))
        let report = try source("Views/ParticipantReportView.swift")
        XCTAssertTrue(report.contains("selectedReason == .otherConcern"))
        XCTAssertTrue(report.contains("requiresDetails ? \"Add details (required)\" : \"Add details (optional)\""))
        XCTAssertTrue(report.contains("!requiresDetails || !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty"))
        XCTAssertTrue(report.contains("didSubmit ? \"Report submitted\" : \"Report student\""))
        XCTAssertTrue(report.contains("Text(\"Thanks for letting us know.\")"))
        XCTAssertTrue(report.contains(".alert(\"Report not confirmed\""))
        XCTAssertTrue(report.contains(
            "We couldn't confirm that your report was received. If you still have a concern, you can email \\(AppBrand.name) Support."
        ))
        let root = try source("ContentView.swift")
        XCTAssertTrue(root.contains("Would you also like to report this student?"))
        XCTAssertTrue(root.contains("requestStore.consumePostBlockReportOffer()"))
        let stopQuestion = try XCTUnwrap(menus.range(of: "else if activeQuestion == .stop {"))
        let stopQuestionBody = menus[stopQuestion.lowerBound...]
        let cancel = try XCTUnwrap(stopQuestionBody.range(
            of: "Button(ParticipantBlockCopy.cancelTitle, role: .cancel) {}"
        ))
        XCTAssertFalse(stopQuestionBody[cancel].contains("store."))

        let home = try source("Views/HomeExchangeView.swift")
        XCTAssertTrue(home.contains("if store.isParticipantRestricted {\n            HomeRestrictionBanner()"))
        let support = try source("Views/CommonPlateSupportAction.swift")
        XCTAssertTrue(support.contains("contact.open(using: openURL)"))
        XCTAssertTrue(support.contains("isShowingFallback = true"))
        XCTAssertTrue(support.contains("UIPasteboard.general.string = address"))
        XCTAssertFalse(support.contains("subject="))
    }

    func testPendingReportStoragePersistsIdentityOnlyAndRetiresOnlyMatchingOperation() throws {
        let storage = UserDefaultsPendingReportOperationStorage(defaults: defaults)
        let record = pendingReportRecord(
            operationID: "rp1.1720000000000.ABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789"
        )
        XCTAssertTrue(storage.save(record))
        XCTAssertEqual(storage.load(), .record(record))

        let savedJSON = try XCTUnwrap(defaults.data(
            forKey: UserDefaultsPendingReportOperationStorage.key
        ))
        let text = try XCTUnwrap(String(data: savedJSON, encoding: .utf8))
        XCTAssertTrue(text.contains(record.operationId))
        XCTAssertTrue(text.contains(record.participantIdentifier))
        XCTAssertTrue(text.contains(record.requestID))
        for privateValue in ["claim-token", "report-auth", "explanation text", "Harassment"] {
            XCTAssertFalse(text.contains(privateValue))
        }

        let other = pendingReportRecord(operationID: "rp1.1720000000001.ZYXWVUTSRQPONMLKJIHGFEDCBA_9876543210")
        XCTAssertFalse(storage.save(other))
        storage.clear(operationId: other.operationId)
        XCTAssertEqual(storage.load(), .record(record))
        storage.clear(operationId: record.operationId)
        XCTAssertEqual(storage.load(), .absent)
    }

    func testAmbiguousReportRecoversAfterStoreRecreationWithoutRetransmission() async throws {
        let storage = UserDefaultsPendingReportOperationStorage(defaults: defaults)
        let firstStore = makeStore(reportStorage: storage)
        ParticipantReportingURLProtocol.enqueue(.response(ledgerResponse))
        ParticipantReportingURLProtocol.enqueue(.failure(.networkConnectionLost))

        let firstResult = await firstStore.submitParticipantReport(
            requestID: requestID,
            reason: .otherConcern,
            explanation: "sensitive report details"
        )
        XCTAssertEqual(firstResult, .notConfirmed)
        XCTAssertTrue(firstStore.hasUnresolvedReportOperation)
        let savedRecord = try XCTUnwrap(record(from: storage.load()))

        let relaunchedStore = makeStore(
            reportStorage: UserDefaultsPendingReportOperationStorage(defaults: defaults)
        )
        ParticipantReportingURLProtocol.enqueue(.response(ledgerResponse))
        ParticipantReportingURLProtocol.enqueue(.response(#"{"outcome":"created"}"#))
        await relaunchedStore.reconcilePendingReportOperationSilently()

        XCTAssertFalse(relaunchedStore.hasUnresolvedReportOperation)
        XCTAssertEqual(storage.load(), .absent)
        let requests = ParticipantReportingURLProtocol.capturedRequests
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("/report") }.count, 1)
        let reconcile = try XCTUnwrap(requests.first {
            $0.path == "/api/participant/report-operations/\(savedRecord.operationId)/reconcile"
        })
        XCTAssertEqual(reconcile.method, "POST")
        XCTAssertNil(reconcile.body)
        XCTAssertEqual(
            reconcile.normalizedHeaders[RequestService.participantAuthorityHeader],
            authority
        )
    }

    func testNoCreateReconciliationAllowsExactlyOneNewReportOperation() async throws {
        let storage = InMemoryPendingReportOperationStorage()
        let store = makeStore(reportStorage: storage)
        ParticipantReportingURLProtocol.enqueue(.response(ledgerResponse))
        ParticipantReportingURLProtocol.enqueue(.failure(.networkConnectionLost))
        let ambiguousResult = await store.submitParticipantReport(
            requestID: requestID,
            reason: .otherConcern,
            explanation: nil
        )
        XCTAssertEqual(ambiguousResult, .notConfirmed)
        let original = try XCTUnwrap(record(from: storage.load()))

        ParticipantReportingURLProtocol.enqueue(.response(ledgerResponse))
        ParticipantReportingURLProtocol.enqueue(.response(#"{"outcome":"no-create"}"#))
        ParticipantReportingURLProtocol.enqueue(.response(ledgerResponse))
        ParticipantReportingURLProtocol.enqueue(.response(#"{"outcome":"reported"}"#))
        let retryResult = await store.submitParticipantReport(
            requestID: requestID,
            reason: .threatsOrUnsafeBehavior,
            explanation: nil
        )
        XCTAssertEqual(
            retryResult,
            .submitted,
            "captured paths: \(ParticipantReportingURLProtocol.capturedRequests.map(\.path)); pending: \(String(describing: storage.load()))"
        )

        let reportRequests = ParticipantReportingURLProtocol.capturedRequests.filter {
            $0.path.hasSuffix("/report")
        }
        XCTAssertEqual(reportRequests.count, 2)
        guard reportRequests.count == 2 else { return }
        let firstOperationID = try XCTUnwrap(reportRequests[0].bodyObject?["operationId"] as? String)
        let secondOperationID = try XCTUnwrap(reportRequests[1].bodyObject?["operationId"] as? String)
        XCTAssertEqual(firstOperationID, original.operationId)
        XCTAssertNotEqual(secondOperationID, firstOperationID)
        XCTAssertEqual(
            ParticipantReportingURLProtocol.capturedRequests.filter {
                $0.path.hasSuffix("/reconcile")
            }.count,
            1
        )
        XCTAssertEqual(storage.load(), .absent)
    }

    func testExpiredReportRequiresAnotherExplicitSubmitAndUnknownRemainsBlocked() async throws {
        let storage = InMemoryPendingReportOperationStorage()
        let store = makeStore(reportStorage: storage)
        ParticipantReportingURLProtocol.enqueue(.response(ledgerResponse))
        ParticipantReportingURLProtocol.enqueue(.failure(.networkConnectionLost))
        _ = await store.submitParticipantReport(
            requestID: requestID,
            reason: .otherConcern,
            explanation: nil
        )
        let original = try XCTUnwrap(record(from: storage.load()))

        ParticipantReportingURLProtocol.enqueue(.response(ledgerResponse))
        ParticipantReportingURLProtocol.enqueue(.response(
            #"{"error":{"code":"OPERATION_EXPIRED","message":"Expired","fields":null}}"#,
            statusCode: 409
        ))
        let expiredResult = await store.submitParticipantReport(
            requestID: requestID,
            reason: .otherConcern,
            explanation: nil
        )
        XCTAssertEqual(expiredResult, .notConfirmed)
        XCTAssertEqual(storage.load(), .absent)

        ParticipantReportingURLProtocol.enqueue(.response(ledgerResponse))
        ParticipantReportingURLProtocol.enqueue(.response(#"{"outcome":"reported"}"#))
        let freshExplicitResult = await store.submitParticipantReport(
            requestID: requestID,
            reason: .threatsOrUnsafeBehavior,
            explanation: nil
        )
        XCTAssertEqual(freshExplicitResult, .submitted)
        let operationIDs = ParticipantReportingURLProtocol.capturedRequests
            .filter { $0.path.hasSuffix("/report") }
            .compactMap { $0.bodyObject?["operationId"] as? String }
        XCTAssertEqual(operationIDs.count, 2)
        guard operationIDs.count == 2 else { return }
        XCTAssertEqual(operationIDs[0], original.operationId)
        XCTAssertNotEqual(operationIDs[1], original.operationId)

        let unresolvedStorage = InMemoryPendingReportOperationStorage()
        let unresolvedStore = makeStore(reportStorage: unresolvedStorage)
        ParticipantReportingURLProtocol.enqueue(.response(ledgerResponse))
        ParticipantReportingURLProtocol.enqueue(.failure(.networkConnectionLost))
        _ = await unresolvedStore.submitParticipantReport(
            requestID: requestID,
            reason: .otherConcern,
            explanation: nil
        )
        let unresolvedRecord = try XCTUnwrap(record(from: unresolvedStorage.load()))
        ParticipantReportingURLProtocol.enqueue(.response(ledgerResponse))
        ParticipantReportingURLProtocol.enqueue(.response(#"{"outcome":"refused"}"#))
        await unresolvedStore.reconcilePendingReportOperationSilently()
        XCTAssertEqual(record(from: unresolvedStorage.load()), unresolvedRecord)
        XCTAssertTrue(unresolvedStore.hasUnresolvedReportOperation)
        XCTAssertEqual(
            ParticipantReportingURLProtocol.capturedRequests.filter {
                $0.path.hasSuffix("/report")
            }.count,
            3
        )
    }

    func testBlockReportAuthorizationIsPrivateAndConsumedAfterConfirmedReport() async throws {
        let store = makeStore()
        ParticipantReportingURLProtocol.enqueue(.response(blockResponse))
        ParticipantReportingURLProtocol.enqueue(.response(#"{"requests":[]}"#))
        let blockResult = await store.blockRequesterOfViewedRequest(requestID: requestID)
        XCTAssertEqual(blockResult, .blocked(reservationReleased: true))
        await waitForRequestRefresh(store)
        let offer = try XCTUnwrap(store.consumePostBlockReportOffer())
        XCTAssertEqual(offer.requestID, requestID)
        XCTAssertTrue(offer.returnsHome)
        XCTAssertFalse(String(describing: Mirror(reflecting: offer)).contains("report-auth-secret"))

        ParticipantReportingURLProtocol.enqueue(.response(ledgerResponse))
        ParticipantReportingURLProtocol.enqueue(.response(#"{"outcome":"reported"}"#))
        let firstReportResult = await store.submitParticipantReport(
            requestID: requestID,
            reason: .otherConcern,
            explanation: nil
        )
        XCTAssertEqual(firstReportResult, .submitted)
        ParticipantReportingURLProtocol.enqueue(.response(ledgerResponse))
        ParticipantReportingURLProtocol.enqueue(.response(#"{"outcome":"reported"}"#))
        let secondReportResult = await store.submitParticipantReport(
            requestID: requestID,
            reason: .otherConcern,
            explanation: nil
        )
        XCTAssertEqual(secondReportResult, .submitted)

        let reportRequests = ParticipantReportingURLProtocol.capturedRequests.filter {
            $0.path.hasSuffix("/report")
        }
        XCTAssertEqual(reportRequests.count, 2)
        guard reportRequests.count == 2 else { return }
        XCTAssertEqual(reportRequests[0].method, "POST")
        XCTAssertEqual(reportRequests[0].path, "/api/request/\(requestID)/report")
        XCTAssertEqual(
            reportRequests[0].bodyObject?["reason"] as? String,
            ParticipantReportReason.otherConcern.rawValue
        )
        XCTAssertEqual(
            Set(reportRequests[0].bodyObject?.keys ?? Dictionary<String, Any>().keys),
            Set(["operationId", "reason", "reportAuthorization"])
        )
        XCTAssertEqual(
            Set(reportRequests[1].bodyObject?.keys ?? Dictionary<String, Any>().keys),
            Set(["operationId", "reason"])
        )
        XCTAssertEqual(reportRequests[0].bodyObject?["reportAuthorization"] as? String, "report-auth-secret")
        XCTAssertNil(reportRequests[1].bodyObject?["reportAuthorization"])
        for request in reportRequests {
            XCTAssertEqual(
                request.normalizedHeaders[RequestService.participantAuthorityHeader],
                authority
            )
        }
    }

    func testSuspendedHelperStopYesNoAndStaleStateUseOnlyAuthorizedAnswer() async throws {
        let yesStore = makeStore()
        ParticipantReportingURLProtocol.enqueue(.response(activeReservationResponse))
        _ = try await yesStore.continueActiveReservationIfNeeded()
        XCTAssertTrue(yesStore.stopAsksOrderQuestion(requestID: requestID))
        ParticipantReportingURLProtocol.enqueue(.response(#"{"released":false}"#))
        let yesResult = await yesStore.answerStopOrderQuestion(externalOrderPlaced: true)
        XCTAssertEqual(yesResult, .keptHelping)
        XCTAssertNotNil(yesStore.activeClaim)
        XCTAssertEqual(
            ParticipantReportingURLProtocol.capturedRequests.last?.bodyObject?["externalOrderPlaced"] as? Bool,
            true
        )

        let noStore = makeStore()
        ParticipantReportingURLProtocol.enqueue(.response(activeReservationResponse))
        _ = try await noStore.continueActiveReservationIfNeeded()
        ParticipantReportingURLProtocol.enqueue(.response(#"{"released":true}"#))
        ParticipantReportingURLProtocol.enqueue(.response(#"{"requests":[]}"#))
        let noResult = await noStore.answerStopOrderQuestion(externalOrderPlaced: false)
        XCTAssertEqual(noResult, .released)
        await waitForRequestRefresh(noStore)
        XCTAssertNil(noStore.activeClaim)
        XCTAssertFalse(noStore.stopAsksOrderQuestion(requestID: requestID))

        let staleStore = makeStore()
        ParticipantReportingURLProtocol.enqueue(.response(activeReservationResponse))
        _ = try await staleStore.continueActiveReservationIfNeeded()
        ParticipantReportingURLProtocol.enqueue(.response(
            #"{"error":{"code":"RESERVATION_STATE_CHANGED","message":"Changed","fields":null}}"#,
            statusCode: 409
        ))
        let staleResult = await staleStore.answerStopOrderQuestion(externalOrderPlaced: false)
        XCTAssertEqual(staleResult, .notConfirmed)
        XCTAssertEqual(staleStore.activeClaim?.requestID, requestID)
        XCTAssertTrue(staleStore.stopAsksOrderQuestion(requestID: requestID))
    }

    func testRequestCreatedUnavailableRetiresExactOperationAndShowsApprovedNotice() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(operationStorage: storage)
        ParticipantReportingURLProtocol.enqueue(.response(ledgerResponse))
        ParticipantReportingURLProtocol.enqueue(.response(
            #"{"error":{"code":"REQUEST_CREATED_UNAVAILABLE","message":"Unavailable","fields":null}}"#,
            statusCode: 409
        ))

        do {
            try await store.createRequest(CreateRequestPayload(
                vendor: "Jasper Kane Cafe",
                timing: .asap,
                windowStart: nil,
                menuPath: .mealExchange,
                mealSwipes: 1,
                mealItems: ["Rice bowl"],
                orderDetails: nil,
                estimatedDiningDollarsCents: nil
            ))
            XCTFail("A created-but-unavailable request must not be presented as an ordinary success")
        } catch RequestServiceError.serverError(let code, _) {
            XCTAssertEqual(code, "REQUEST_CREATED_UNAVAILABLE")
        }

        let createRequest = try XCTUnwrap(ParticipantReportingURLProtocol.capturedRequests.first {
            $0.path == "/api/request" && $0.method == "POST"
        })
        let exactOperationID = try XCTUnwrap(
            createRequest.normalizedHeaders[RequestService.operationIdentityHeader]
        )
        XCTAssertNil(storage.loadAll().first { $0.operationId == exactOperationID })
        XCTAssertEqual(store.requesterNotice, .createdUnavailable)
        XCTAssertEqual(
            RequestOperationErrorCode.requestCreatedUnavailableMessage,
            "Your request was posted, but it's no longer available."
        )
    }

    func testRecoveredRequestCreatedUnavailableRetiresOnlyItsStoredOperation() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let operationID = "create-operation-to-retire"
        let origin = RequestService.operationAuthorityOrigin(
            for: URL(string: "https://commonplate.test")!
        )
        let ledger = "11111111-1111-4111-8111-111111111111"
        XCTAssertTrue(storage.save(PendingRequestOperationRecord(
            operationId: operationID,
            participantIdentifier: "64c0000000000000000000a1",
            operationAuthority: RequestOperationAuthorityIdentity(origin: origin, ledger: ledger),
            payload: createPayload
        )))
        let store = makeStore(operationStorage: storage)
        ParticipantReportingURLProtocol.enqueue(.response(#"{"operationAuthority":"11111111-1111-4111-8111-111111111111"}"#))
        ParticipantReportingURLProtocol.enqueue(.response(
            #"{"error":{"code":"REQUEST_CREATED_UNAVAILABLE","message":"Unavailable","fields":null}}"#,
            statusCode: 409
        ))

        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()
        XCTAssertFalse(didCreate)
        XCTAssertTrue(storage.restoreAll().isEmpty)
        XCTAssertEqual(store.requesterNotice, .createdUnavailable)
        let replay = try XCTUnwrap(ParticipantReportingURLProtocol.capturedRequests.first {
            $0.path == "/api/request" && $0.method == "POST"
        })
        XCTAssertEqual(
            replay.normalizedHeaders[RequestService.operationIdentityHeader],
            operationID
        )
        XCTAssertEqual(
            replay.normalizedHeaders[RequestService.operationAuthorityHeader],
            ledger
        )
    }

    private var ledgerResponse: String {
        #"{"operationAuthority":"11111111-1111-4111-8111-111111111111"}"#
    }

    private var createPayload: CreateRequestPayload {
        CreateRequestPayload(
            vendor: "Jasper Kane Cafe",
            timing: .asap,
            windowStart: nil,
            menuPath: .mealExchange,
            mealSwipes: 1,
            mealItems: ["Rice bowl"],
            orderDetails: nil,
            estimatedDiningDollarsCents: nil
        )
    }

    private var blockResponse: String {
        """
        {
          "block": {
            "id": "block-1",
            "blockedRole": "requester",
            "diningLocation": "Jasper Kane Cafe",
            "interactionAt": "\(iso8601String(Date()))",
            "createdAt": "\(iso8601String(Date()))"
          },
          "reservationReleased": true,
          "reportAuthorization": "report-auth-secret"
        }
        """
    }

    private var activeReservationResponse: String {
        """
        {
          "reservation": {
            "request": \(requestObject(status: "claimed")),
            "pickupName": "Taylor",
            "claimExpiresAt": "\(iso8601String(Date().addingTimeInterval(15 * 60)))",
            "claimExtendedAt": null,
            "stopAsksOrderQuestion": true
          }
        }
        """
    }

    private func makeStore(
        reportStorage: PendingReportOperationStorage? = nil,
        operationStorage: PendingRequestOperationStorage? = nil
    ) -> RequestStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ParticipantReportingURLProtocol.self]
        let service = RequestService(client: APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        ))
        return RequestStore(
            service: service,
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { self.authority },
            participantAuthorityRejected: {},
            operationStorage: operationStorage ?? InMemoryPendingRequestOperationStorage(),
            reportOperationStorage: reportStorage ?? InMemoryPendingReportOperationStorage()
        )
    }

    func testAlreadyReportedRequestIsRememberedAndSuppressesPostBlockReportOffer() throws {
        let store = try source("Stores/RequestStore.swift")
        XCTAssertTrue(store.contains("ParticipantLocalPresentationStorage(defaults: .standard).key(\"ReportedRequestKeys\")"))
        XCTAssertTrue(store.contains("UserDefaults.standard.dictionary(forKey: key)"))
        XCTAssertTrue(store.contains("guard !hasReportedRequest(requestID: requestID),\n              participantAuthorityProvider() == participantAuthority,"))
    }

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func pendingReportRecord(operationID: String) -> PendingReportOperationRecord {
        PendingReportOperationRecord(
            operationId: operationID,
            participantIdentifier: "64c0000000000000000000a1",
            requestID: requestID,
            authority: RequestOperationAuthorityIdentity(
                origin: RequestService.operationAuthorityOrigin(
                    for: URL(string: "https://commonplate.test")!
                ),
                ledger: "11111111-1111-4111-8111-111111111111"
            )
        )
    }

    private func record(
        from load: PendingReportOperationLoad
    ) -> PendingReportOperationRecord? {
        guard case .record(let record) = load else { return nil }
        return record
    }

    private func requestObject(status: String) -> String {
        """
        {
          "id": "\(requestID)",
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
          "createdAt": "\(iso8601String(Date()))",
          "expiresAt": "\(iso8601String(Date().addingTimeInterval(5 * 60 * 60)))"
        }
        """
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for the request refresh", file: file, line: line)
    }

    private func waitForRequestRefresh(_ store: RequestStore) async {
        await waitUntil {
            ParticipantReportingURLProtocol.capturedRequests.contains {
                $0.path == "/api/requests" && $0.method == "GET"
            }
        }
        await waitUntil { !store.isFetching }
    }
}
