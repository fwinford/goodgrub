//
//  RequestManagementServiceTests.swift
//  CommonPlateiosTests
//
// Focused W4-R5 coverage for the service boundary of owner reads, Withdraw and
// Edit: what is sent, what is decoded, and — above all — which failures are
// definitive and which leave the outcome unknown.
//
// The rules these cases hold:
//  - authority is required and, without it, nothing is sent;
//  - an owner read never turns a failure into an empty list;
//  - a Withdraw / Edit that may have committed is `ambiguousUpdateOutcome`,
//    never a success, a refusal or "unchanged", and is never retried here;
//  - a decoded refusal is passed through verbatim for presentation to map.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class RequestManagementServiceTests: XCTestCase {
    private let authority = "64c0000000000000000000a1.1.credential"

    override func tearDown() {
        ClaimFlowURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Owner reads

    func testOwnerListMapsPhaseRevisionAndOwnerRelativeFlags() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: ownerList([
            ownerObject(id: "o1", phase: "available", revision: 3),
            ownerObject(id: "o2", phase: "scheduled", timing: "scheduled", windowStart: true),
            ownerObject(id: "o3", phase: "reserved", canEdit: false, canWithdraw: false),
        ])))

        let owned = try await makeService().fetchOwnerRequests(participantAuthority: authority)

        XCTAssertEqual(owned.map(\.id), ["o1", "o2", "o3"])
        XCTAssertEqual(owned.map(\.phase), [.available, .scheduled, .reserved])
        XCTAssertEqual(owned[0].contentRevision, 3)
        XCTAssertTrue(owned[0].canEdit)
        XCTAssertTrue(owned[0].canWithdraw)
        XCTAssertFalse(owned[2].canEdit)
        XCTAssertFalse(owned[2].canWithdraw)
        // Every row is the participant's own, and a reserved one is never open.
        XCTAssertTrue(owned.allSatisfy { $0.request.ownership == .own })
        XCTAssertEqual(owned[0].request.status, .open)
        XCTAssertEqual(owned[2].request.status, .claimed)
        XCTAssertNotNil(owned[1].request.windowStart)
        XCTAssertEqual(
            ClaimFlowURLProtocol.capturedRequests.first?.headers["x-commonplate-participant"],
            authority
        )
        XCTAssertEqual(ClaimFlowURLProtocol.capturedPaths, ["/api/participant/requests"])
    }

    func testOwnerListWithoutAuthoritySendsNothing() async {
        do {
            _ = try await makeService().fetchOwnerRequests(participantAuthority: "")
            XCTFail("expected authority-required")
        } catch RequestServiceError.participantAuthorityRequired {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(ClaimFlowURLProtocol.capturedPaths.isEmpty)
    }

    func testAnAuthoritativeEmptyOwnerListIsEmptyButEveryFailureIsNot() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: ownerList([])))
        let empty = try await makeService().fetchOwnerRequests(participantAuthority: authority)
        XCTAssertEqual(empty, [])

        for stub in [
            ClaimFlowURLProtocol.Stub.failure(.timedOut),
            .response(statusCode: 503, data: errorBody("PARTICIPANT_VERIFICATION_UNAVAILABLE")),
            .response(statusCode: 200, data: Data("not json".utf8)),
        ] {
            ClaimFlowURLProtocol.enqueue(stub)
            do {
                _ = try await makeService().fetchOwnerRequests(participantAuthority: authority)
                XCTFail("a failed read must never read as an empty list")
            } catch {
                XCTAssertEqual(
                    RequestReadClassification(error),
                    .unavailableOrUnknown,
                    "an unknown result is unknown, not an authority verdict"
                )
            }
        }
    }

    func testOwnerListPassesAnInvalidCredentialVerdictThrough() async {
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 401,
            data: errorBody("PARTICIPANT_AUTHORITY_INVALID")
        ))
        do {
            _ = try await makeService().fetchOwnerRequests(participantAuthority: authority)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(RequestReadClassification(error), .authorityInvalid)
        }
    }

    func testOwnerDetailRejectsAResponseForADifferentRequest() async {
        ClaimFlowURLProtocol.enqueue(.response(data: ownerDetail(ownerObject(id: "someone-else"))))
        do {
            _ = try await makeService().fetchOwnerRequest(id: "o1", participantAuthority: authority)
            XCTFail("a mismatched request id must not be accepted")
        } catch {
            // Expected: never mapped as the requested request.
        }
    }

    func testOwnerDetailSurfacesTheIndistinguishableNotFound() async {
        ClaimFlowURLProtocol.enqueue(.response(
            statusCode: 404,
            data: errorBody("REQUEST_NOT_FOUND")
        ))
        do {
            _ = try await makeService().fetchOwnerRequest(id: "o1", participantAuthority: authority)
            XCTFail("expected not found")
        } catch RequestServiceError.serverError(let code, _) {
            XCTAssertEqual(code, RequestUpdateErrorCode.requestNotFound)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Withdraw

    func testWithdrawSendsTheExactOperationIdentityAndAuthority() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: withdrawn("r1")))

        try await makeService().withdrawRequest(
            id: "r1",
            operationId: "wd-op-1",
            participantAuthority: authority,
            operationLedger: "ledger-1"
        )

        let captured = try XCTUnwrap(ClaimFlowURLProtocol.capturedRequests.first)
        XCTAssertEqual(captured.path, "/api/request/r1/withdraw")
        XCTAssertEqual(captured.method, "POST")
        XCTAssertEqual(captured.headers["x-commonplate-operation-id"], "wd-op-1")
        XCTAssertEqual(captured.headers["x-commonplate-operation-authority"], "ledger-1")
        XCTAssertEqual(captured.headers["x-commonplate-participant"], authority)
    }

    func testWithdrawWithoutAuthoritySendsNothing() async {
        do {
            try await makeService().withdrawRequest(
                id: "r1",
                operationId: "wd-op",
                participantAuthority: ""
            )
            XCTFail("expected authority-required")
        } catch RequestServiceError.participantAuthorityRequired {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(ClaimFlowURLProtocol.capturedPaths.isEmpty)
    }

    func testWithdrawPassesEveryDecodedRefusalThroughAsDefinitive() async {
        let codes = [
            RequestUpdateErrorCode.requestReserved,
            RequestUpdateErrorCode.requestWithdrawn,
            RequestUpdateErrorCode.requestAlreadyPlaced,
            RequestUpdateErrorCode.requestExpired,
            RequestUpdateErrorCode.requestNotFound,
            RequestUpdateErrorCode.operationConflict,
            RequestUpdateErrorCode.operationUnauthorized,
        ]
        for code in codes {
            ClaimFlowURLProtocol.enqueue(.response(statusCode: 409, data: errorBody(code)))
            do {
                try await makeService().withdrawRequest(
                    id: "r1",
                    operationId: "wd-\(code)",
                    participantAuthority: authority
                )
                XCTFail("expected a refusal for \(code)")
            } catch RequestServiceError.serverError(let received, _) {
                XCTAssertEqual(received, code)
            } catch {
                XCTFail("\(code) must be a definitive refusal, got \(error)")
            }
        }
    }

    func testWithdrawTreatsEveryUnknownOutcomeAsAmbiguousNeverAsAnAnswer() async {
        let unknowns: [(String, ClaimFlowURLProtocol.Stub)] = [
            ("connection lost", .failure(.networkConnectionLost)),
            ("timeout", .failure(.timedOut)),
            ("no internet", .failure(.notConnectedToInternet)),
            ("unclassified server failure", .response(
                statusCode: 500,
                data: errorBody(RequestUpdateErrorCode.requestUpdateFailed)
            )),
            ("internal failure", .response(
                statusCode: 500,
                data: errorBody(RequestUpdateErrorCode.internalFailure)
            )),
            ("unreadable 502", .response(statusCode: 502, data: Data("bad gateway".utf8))),
            ("undecodable success", .response(statusCode: 200, data: Data("{}".utf8))),
        ]
        for (label, stub) in unknowns {
            ClaimFlowURLProtocol.enqueue(stub)
            do {
                try await makeService().withdrawRequest(
                    id: "r1",
                    operationId: "wd-\(label)",
                    participantAuthority: authority
                )
                XCTFail("\(label) must not read as a success")
            } catch RequestServiceError.ambiguousUpdateOutcome {
                // Expected: the outcome is unknown.
            } catch {
                XCTFail("\(label) must be ambiguous, got \(error)")
            }
        }
    }

    func testWithdrawRejectsASuccessThatNamesAnotherRequestOrOutcome() async {
        for body in [withdrawn("a-different-request"), Data(#"{"outcome":"edited","requestId":"r1"}"#.utf8)] {
            ClaimFlowURLProtocol.enqueue(.response(data: body))
            do {
                try await makeService().withdrawRequest(
                    id: "r1",
                    operationId: "wd-mismatch",
                    participantAuthority: authority
                )
                XCTFail("a mismatched success must not be accepted")
            } catch RequestServiceError.ambiguousUpdateOutcome {
                // Expected.
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testWithdrawNonEnvelope404IsDefinitiveRouteAbsent() async {
        ClaimFlowURLProtocol.enqueue(.response(statusCode: 404, data: Data("Cannot POST".utf8)))
        do {
            try await makeService().withdrawRequest(
                id: "r1",
                operationId: "wd-404",
                participantAuthority: authority
            )
            XCTFail("expected not found")
        } catch RequestServiceError.notFound {
            // Expected: nothing was written at a base URL without the route.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testACancelledWithdrawAfterDispatchIsAmbiguous() async {
        let gate = RequestFetchingGate()
        ClaimFlowURLProtocol.enqueue(.response(data: withdrawn("r1"), gate: gate))
        let service = makeService()
        let task = Task {
            try await service.withdrawRequest(
                id: "r1",
                operationId: "wd-cancel",
                participantAuthority: authority
            )
        }
        for _ in 0..<200 where !gate.isWaiting {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        task.cancel()
        gate.open()

        do {
            try await task.value
            XCTFail("a cancelled in-flight mutation is not a success")
        } catch RequestServiceError.ambiguousUpdateOutcome {
            // Expected: the body may already have been sent.
        } catch {
            // A cancellation that reached the transport as a cancellation is
            // equally "unknown"; it must never read as a refusal.
            XCTAssertTrue(
                error is CancellationError || {
                    if case RequestServiceError.ambiguousUpdateOutcome = error { return true }
                    return false
                }(),
                "unexpected error: \(error)"
            )
        }
    }

    // MARK: - Edit

    func testEditSendsOnlyTheAcceptedFieldsAndTheExpectedRevision() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: edited(revision: 4, request: ownerObject(id: "e1", revision: 4))))
        let payload = EditRequestPayload(
            vendor: "Crave NYU",
            menuPath: .mealExchange,
            mealSwipes: 2,
            mealItems: [MealItem(name: "Chicken bowl"), MealItem(name: "Side salad", details: "no dressing")],
            orderDetails: nil,
            estimatedDiningDollarsCents: nil,
            timing: .unchanged,
            windowStart: nil,
            expectedContentRevision: 3
        )

        let outcome = try await makeService().editRequest(
            id: "e1",
            payload: payload,
            operationId: "ed-op-1",
            participantAuthority: authority
        )

        let captured = try XCTUnwrap(ClaimFlowURLProtocol.capturedRequests.first)
        XCTAssertEqual(captured.path, "/api/request/e1/edit")
        XCTAssertEqual(captured.headers["x-commonplate-operation-id"], "ed-op-1")
        let body = try XCTUnwrap(captured.bodyObject)
        XCTAssertEqual(body["timing"] as? String, "unchanged")
        XCTAssertEqual(body["expectedContentRevision"] as? Int, 3)
        XCTAssertEqual(body["menuPath"] as? String, "meal-exchange")
        XCTAssertEqual(body["mealSwipes"] as? Int, 2)
        // Absent, never null, and none of the fields the strict schema refuses.
        for forbidden in ["orderDetails", "estimatedDiningDollarsCents", "windowStart",
                          "email", "food", "windowEnd", "installationCredential", "pickupName"] {
            XCTAssertNil(body[forbidden], "\(forbidden) must not be sent")
        }
        XCTAssertEqual(outcome.resultingRevision, 4)
        XCTAssertEqual(outcome.request?.contentRevision, 4)
    }

    func testAScheduledEditSendsItsStartAndADiningDollarsEditItsStructuredValues() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: edited(revision: 2, request: nil)))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = EditRequestPayload(
            vendor: "Crave NYU",
            menuPath: .diningDollars,
            mealSwipes: 0,
            mealItems: [],
            orderDetails: "A latte",
            estimatedDiningDollarsCents: 650,
            timing: .scheduled,
            windowStart: start,
            expectedContentRevision: 1
        )

        let outcome = try await makeService().editRequest(
            id: "e2",
            payload: payload,
            operationId: "ed-op-2",
            participantAuthority: authority
        )

        let body = try XCTUnwrap(ClaimFlowURLProtocol.capturedRequests.first?.bodyObject)
        XCTAssertEqual(body["timing"] as? String, "scheduled")
        XCTAssertNotNil(body["windowStart"])
        XCTAssertEqual(body["orderDetails"] as? String, "A latte")
        XCTAssertEqual(body["estimatedDiningDollarsCents"] as? Int, 650)
        // The request has since left ongoing work: reported as nil, never
        // fabricated as an edited copy.
        XCTAssertEqual(outcome.resultingRevision, 2)
        XCTAssertNil(outcome.request)
    }

    func testEditPassesRevisionConflictAndOtherRefusalsThroughAsDefinitive() async {
        let codes = [
            RequestUpdateErrorCode.revisionConflict,
            RequestUpdateErrorCode.notEditable,
            RequestUpdateErrorCode.horizonExceeded,
            RequestUpdateErrorCode.textNotAllowed,
            RequestUpdateErrorCode.invalidVendor,
            RequestUpdateErrorCode.invalidRequest,
            RequestUpdateErrorCode.requestReserved,
        ]
        for code in codes {
            ClaimFlowURLProtocol.enqueue(.response(statusCode: 409, data: errorBody(code)))
            do {
                _ = try await makeService().editRequest(
                    id: "e1",
                    payload: simplePayload(),
                    operationId: "ed-\(code)",
                    participantAuthority: authority
                )
                XCTFail("expected a refusal for \(code)")
            } catch RequestServiceError.serverError(let received, _) {
                XCTAssertEqual(received, code)
            } catch {
                XCTFail("\(code) must be a definitive refusal, got \(error)")
            }
        }
    }

    func testEditTreatsEveryUnknownOutcomeAsAmbiguous() async {
        let unknowns: [ClaimFlowURLProtocol.Stub] = [
            .failure(.networkConnectionLost),
            .failure(.timedOut),
            .response(statusCode: 500, data: errorBody(RequestUpdateErrorCode.requestUpdateFailed)),
            .response(statusCode: 200, data: Data("{}".utf8)),
            // A decoded success for a different request, or one with an invalid
            // revision, is not a usable decided answer.
            .response(data: edited(revision: 2, request: ownerObject(id: "not-e1"))),
            .response(data: edited(revision: 0, request: nil)),
        ]
        for (index, stub) in unknowns.enumerated() {
            ClaimFlowURLProtocol.enqueue(stub)
            do {
                _ = try await makeService().editRequest(
                    id: "e1",
                    payload: simplePayload(),
                    operationId: "ed-unknown-\(index)",
                    participantAuthority: authority
                )
                XCTFail("case \(index) must not read as an edit")
            } catch RequestServiceError.ambiguousUpdateOutcome {
                // Expected.
            } catch {
                XCTFail("case \(index) must be ambiguous, got \(error)")
            }
        }
    }

    // MARK: - A withdrawn request is a decoded status, not a decode failure

    func testPublicDetailDecodesAWithdrawnStatusInsteadOfFailing() async throws {
        ClaimFlowURLProtocol.enqueue(.response(data: Data(#"""
        {"request": \#(publicObject(id: "w1", status: "withdrawn", revision: 5))}
        """#.utf8)))

        let request = try await makeService().fetchRequest(id: "w1", participantAuthority: authority)

        XCTAssertEqual(request.status, .withdrawn)
        XCTAssertFalse(request.allowsHelperAction || request.ownership == .own)
    }

    // MARK: - Fixtures

    private func makeService() -> RequestService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaimFlowURLProtocol.self]
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        )
        return RequestService(client: client)
    }

    private func simplePayload() -> EditRequestPayload {
        EditRequestPayload(
            vendor: "Crave NYU",
            menuPath: .mealExchange,
            mealSwipes: 1,
            mealItems: [MealItem(name: "Rice bowl")],
            orderDetails: nil,
            estimatedDiningDollarsCents: nil,
            timing: .unchanged,
            windowStart: nil,
            expectedContentRevision: 1
        )
    }

    private func errorBody(_ code: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"detail","fields":null}}"#.utf8)
    }

    private func ownerList(_ objects: [String]) -> Data {
        Data(#"{"requests":[\#(objects.joined(separator: ","))]}"#.utf8)
    }

    private func ownerDetail(_ object: String) -> Data {
        Data(#"{"request":\#(object)}"#.utf8)
    }

    private func withdrawn(_ id: String) -> Data {
        Data(#"{"outcome":"withdrawn","requestId":"\#(id)"}"#.utf8)
    }

    private func edited(revision: Int, request: String?) -> Data {
        let requestField = request.map { ",\"request\":\($0)" } ?? ",\"request\":null"
        return Data(#"{"outcome":"edited","resultingRevision":\#(revision)\#(requestField)}"#.utf8)
    }

    private func ownerObject(
        id: String,
        phase: String = "available",
        timing: String = "asap",
        windowStart: Bool = false,
        revision: Int? = 1,
        canEdit: Bool = true,
        canWithdraw: Bool = true
    ) -> String {
        let window = windowStart
            ? #""windowStart": "2099-07-20T19:00:00.000Z", "windowEnd": "2099-07-20T22:00:00.000Z","#
            : #""windowStart": null, "windowEnd": null,"#
        let revisionField = revision.map(String.init) ?? "null"
        return """
        {
          "id": "\(id)",
          "vendor": "Crave NYU",
          "food": "Rice bowl",
          "pickupWindowText": "ASAP",
          "mealSwipes": 1,
          "menuPath": "meal-exchange",
          "mealItems": [{"name": "Rice bowl"}],
          "orderDetails": null,
          "estimatedDiningDollarsCents": null,
          \(window)
          "createdAt": "2026-07-20T18:30:00.000Z",
          "expiresAt": "2099-07-20T23:30:00.000Z",
          "timing": "\(timing)",
          "phase": "\(phase)",
          "contentRevision": \(revisionField),
          "canEdit": \(canEdit),
          "canWithdraw": \(canWithdraw),
          "latestScheduledStart": "2026-07-21T03:30:00.000Z"
        }
        """
    }

    private func publicObject(id: String, status: String, revision: Int) -> String {
        """
        {
          "id": "\(id)",
          "vendor": "Crave NYU",
          "food": "Rice bowl",
          "pickupWindowText": "ASAP",
          "mealSwipes": 1,
          "menuPath": "meal-exchange",
          "mealItems": [{"name": "Rice bowl"}],
          "orderDetails": null,
          "estimatedDiningDollarsCents": null,
          "windowStart": null,
          "windowEnd": null,
          "status": "\(status)",
          "createdAt": "2026-07-20T18:30:00.000Z",
          "expiresAt": "2099-07-20T23:30:00.000Z",
          "contentRevision": \(revision)
        }
        """
    }
}
