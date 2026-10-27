//
//  RequestCreateTerminalReconciliationTests.swift
//  CommonPlateiosTests
//
// W4-D2 exact request-create terminal reconciliation: the versioned stable
// recovery identity, the recovery matrix, recovery-time error
// classification, and the three recovery presentation states. Reuses
// `RequestFetchingURLProtocol` from `RequestFetchingTests.swift`; a request
// with nothing enqueued fails as a transport error and is still recorded, so
// every path assertion below also proves what was *not* sent. Ledger
// authority reads are answered and counted separately by that stub.
import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class RequestCreateTerminalReconciliationTests: XCTestCase {
    private let authorityA = "64c0000000000000000000a1.1." + String(repeating: "A", count: 42) + "A"
    private let authorityB = "64c0000000000000000000b2.1." + String(repeating: "B", count: 42) + "A"
    private let participantIdentifierA = "64c0000000000000000000a1"
    private let baseURL = URL(string: "https://commonplate.test")!
    private var serviceOrigin: String {
        RequestService.operationAuthorityOrigin(for: baseURL)
    }
    private let serviceLedger = RequestFetchingURLProtocol.defaultOperationLedger
    private let otherLedger = "0a1b2c3d-4e5f-4a6b-8c7d-8e9fa0b1c2d3"
    private var serviceAuthority: RequestOperationAuthorityIdentity {
        RequestOperationAuthorityIdentity(origin: serviceOrigin, ledger: serviceLedger)
    }

    private static let createPath = "/api/request"
    private static let terminalPath = "/api/request-operation/terminal"

    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        suiteName = "RequestCreateTerminalReconciliationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        RequestFetchingURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Stable recovery identity storage

    func testThisBuildWritesAVersionedEnvelopeWithIdentityBesideASeparatelyVersionedPayload() throws {
        let storage = UserDefaultsPendingRequestOperationStorage(defaults: defaults)
        var payload = mealPayload("Envelope meal")
        payload.installationCredential = nil
        let record = PendingRequestOperationRecord(
            operationId: "ENVELOPE-1",
            participantIdentifier: participantIdentifierA,
            operationAuthority: serviceAuthority,
            payload: payload
        )
        XCTAssertTrue(storage.save(record))

        let object = try XCTUnwrap(storedJSON())
        XCTAssertEqual(Set(object.keys), [
            "recoveryVersion", "operationId", "participantIdentifier",
            "authorityOrigin", "authorityLedger", "payloadVersion", "payload",
        ])
        XCTAssertEqual(object["recoveryVersion"] as? Int, PendingRequestOperationIdentity.recoveryVersion)
        XCTAssertEqual(object["recoveryVersion"] as? Int, 2)
        XCTAssertEqual(object["payloadVersion"] as? Int, PendingRequestOperationRecord.payloadVersion)
        XCTAssertEqual(object["authorityOrigin"] as? String, "https://commonplate.test:443")
        XCTAssertEqual(object["authorityLedger"] as? String, serviceLedger)
        XCTAssertEqual(storage.load(), record)
        XCTAssertEqual(storage.restore(), .restored(RestoredPendingRequestOperation(
            identity: record.identity,
            payload: .current(payload)
        )))
    }

    func testAnInProcessAmbiguousCreatePersistsNoCredentialMaterial() async throws {
        let storage = UserDefaultsPendingRequestOperationStorage(defaults: defaults)
        let store = makeStore(storage: storage)
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))

        do {
            try await store.createRequest(mealPayload("No credentials on disk"))
            XCTFail("Expected an ambiguous outcome")
        } catch RequestServiceError.ambiguousCreateOutcome {}

        let bytes = try XCTUnwrap(rawStoredValue)
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertFalse(text.contains(authorityA), "The bearer authority is never persisted")
        XCTAssertFalse(text.contains(String(repeating: "A", count: 42)))
        XCTAssertFalse(text.contains("test-installation-credential"))
        XCTAssertFalse(text.contains("installationCredential"))
        let record = try XCTUnwrap(storage.load())
        XCTAssertEqual(record.participantIdentifier, participantIdentifierA)
        XCTAssertEqual(record.operationAuthority, serviceAuthority)
        XCTAssertEqual(store.createRecoveryPresentation, .unresolved(canCheckAgain: true))
        // The create named the ledger it recorded, and that ledger was read
        // before anything was recorded or sent.
        XCTAssertEqual(RequestFetchingURLProtocol.capturedOperationLedgerReadCount, 1)
        XCTAssertEqual(
            RequestFetchingURLProtocol.lastCapturedHeaders?[RequestService.operationAuthorityHeader],
            serviceLedger
        )
    }

    func testAnUndecodablePayloadNeverHidesTheIdentity() {
        let storage = UserDefaultsPendingRequestOperationStorage(defaults: defaults)
        for payload in [
            // A menu path this build does not know.
            #"{"vendor":"Jasper Kane Cafe","timing":"asap","menuPath":"future-path","mealSwipes":1,"mealItems":["x"]}"#,
            // A field of the wrong type.
            #"{"vendor":"Jasper Kane Cafe","timing":"asap","menuPath":"meal-exchange","mealSwipes":"one","mealItems":["x"]}"#,
            #""not an object""#,
            #"null"#,
        ] {
            writeRaw(d2Envelope(operationId: "PAYLOAD-BAD", payloadJSON: payload))
            XCTAssertEqual(
                storage.restore(),
                .restored(RestoredPendingRequestOperation(
                    identity: PendingRequestOperationIdentity(
                        operationId: "PAYLOAD-BAD",
                        participantIdentifier: participantIdentifierA,
                        operationAuthority: serviceAuthority
                    ),
                    payload: .unreadable
                )),
                payload
            )
            XCTAssertNil(storage.load())
        }
    }

    func testPayloadVersionEvolvesIndependentlyOfTheRecoveryEnvelope() {
        let storage = UserDefaultsPendingRequestOperationStorage(defaults: defaults)
        let validPayload = #"{"vendor":"Jasper Kane Cafe","timing":"asap","menuPath":"meal-exchange","mealSwipes":1,"mealItems":["x"]}"#
        for payloadVersion in ["2", "0", #""1""#] {
            writeRaw(d2Envelope(operationId: "PAYLOAD-V", payloadJSON: validPayload, payloadVersion: payloadVersion))
            guard case .restored(let restored) = storage.restore() else {
                return XCTFail("Identity must survive payload version \(payloadVersion)")
            }
            XCTAssertEqual(restored.identity.operationId, "PAYLOAD-V")
            XCTAssertEqual(restored.identity.operationAuthority, serviceAuthority)
            XCTAssertEqual(restored.payload, .unreadable, "payloadVersion \(payloadVersion)")
        }

        writeRaw(d2Envelope(operationId: "PAYLOAD-V", payloadJSON: validPayload))
        guard case .restored(let restored) = storage.restore(),
              case .current = restored.payload else {
            return XCTFail("The current payload version must decode")
        }
    }

    func testAnUnknownOrCorruptIdentityIsUnavailableNeverAbsentOrGuessed() {
        let storage = UserDefaultsPendingRequestOperationStorage(defaults: defaults)
        let payload = #"{"vendor":"Jasper Kane Cafe","timing":"asap","menuPath":"meal-exchange","mealSwipes":1,"mealItems":["x"]}"#
        let cases: [(String, String)] = [
            ("future recovery version", d2Envelope(operationId: "ID-1", payloadJSON: payload, recoveryVersion: "3")),
            ("stringly recovery version", d2Envelope(operationId: "ID-1", payloadJSON: payload, recoveryVersion: #""2""#)),
            ("versioned record with no authority", #"{"recoveryVersion":2,"operationId":"ID-1","participantIdentifier":"64c0000000000000000000a1","payloadVersion":1,"payload":\#(payload)}"#),
            ("versioned record with no ledger", #"{"recoveryVersion":2,"operationId":"ID-1","participantIdentifier":"64c0000000000000000000a1","authorityOrigin":"https://commonplate.test:443","payloadVersion":1,"payload":\#(payload)}"#),
            ("versioned record with no origin", #"{"recoveryVersion":2,"operationId":"ID-1","participantIdentifier":"64c0000000000000000000a1","authorityLedger":"\#(serviceLedger)","payloadVersion":1,"payload":\#(payload)}"#),
            ("empty origin", d2Envelope(operationId: "ID-1", payloadJSON: payload, origin: "")),
            ("empty ledger", d2Envelope(operationId: "ID-1", payloadJSON: payload, ledger: "")),
            ("uppercase ledger", d2Envelope(operationId: "ID-1", payloadJSON: payload, ledger: serviceLedger.uppercased())),
            ("URL as ledger", d2Envelope(operationId: "ID-1", payloadJSON: payload, ledger: "https://commonplate.test:443")),
            ("ledger with whitespace", d2Envelope(operationId: "ID-1", payloadJSON: payload, ledger: " \(serviceLedger)")),
            ("version 2 also carrying a version 1 authority", #"{"recoveryVersion":2,"operationId":"ID-1","participantIdentifier":"64c0000000000000000000a1","operationAuthority":"https://commonplate.test:443","authorityOrigin":"https://commonplate.test:443","authorityLedger":"\#(serviceLedger)","payloadVersion":1,"payload":\#(payload)}"#),
            ("version 1 with no authority", #"{"recoveryVersion":1,"operationId":"ID-1","participantIdentifier":"64c0000000000000000000a1","payloadVersion":1,"payload":\#(payload)}"#),
            ("version 1 with an empty authority", #"{"recoveryVersion":1,"operationId":"ID-1","participantIdentifier":"64c0000000000000000000a1","operationAuthority":"","payloadVersion":1,"payload":\#(payload)}"#),
            ("version 1 carrying a ledger", #"{"recoveryVersion":1,"operationId":"ID-1","participantIdentifier":"64c0000000000000000000a1","operationAuthority":"https://commonplate.test:443","authorityLedger":"\#(serviceLedger)","payloadVersion":1,"payload":\#(payload)}"#),
            ("malformed operation id", d2Envelope(operationId: "has spaces", payloadJSON: payload)),
            ("overlong operation id", d2Envelope(operationId: String(repeating: "o", count: 129), payloadJSON: payload)),
            ("unversioned record claiming an origin-only authority", #"{"operationId":"ID-1","participantIdentifier":"64c0000000000000000000a1","operationAuthority":"https://commonplate.test:443","payload":\#(payload)}"#),
            ("unversioned record claiming a ledger", #"{"operationId":"ID-1","participantIdentifier":"64c0000000000000000000a1","authorityOrigin":"https://commonplate.test:443","authorityLedger":"\#(serviceLedger)","payload":\#(payload)}"#),
        ]
        for (label, json) in cases {
            writeRaw(json)
            XCTAssertEqual(storage.restore(), .identityUnavailable, label)
        }
        defaults.removeObject(forKey: UserDefaultsPendingRequestOperationStorage.collectionKey)
        XCTAssertEqual(storage.restore(), .absent)
    }

    /// W4-D2 finding 4: a nonempty participant identifier is not identity.
    /// Anything other than the canonical 24-lowercase-hex id names no one.
    static let malformedParticipantIdentifiers: [(String, String)] = [
        ("empty", ""),
        ("too short", "64c0000000000000000000a"),
        ("too long", "64c0000000000000000000a1f"),
        ("uppercase hex", "64C0000000000000000000A1"),
        ("nonhex", "64c0000000000000000000zz"),
        ("leading whitespace", " 64c0000000000000000000a1"),
        ("trailing whitespace", "64c0000000000000000000a1 "),
        ("trailing newline", "64c0000000000000000000a1\n"),
        ("full-width digits", "６４c0000000000000000000a1"),
        ("a whole credential", "64c0000000000000000000a1.1.credential"),
        ("hyphenated", "64c00000-0000-0000-0000-00a1"),
    ]

    func testAMalformedParticipantIdentifierIsIdentityUnavailableInEveryRecordShape() throws {
        let storage = UserDefaultsPendingRequestOperationStorage(defaults: defaults)
        let payload = #"{"vendor":"Jasper Kane Cafe","timing":"asap","menuPath":"meal-exchange","mealSwipes":1,"mealItems":["x"]}"#
        for (label, identifier) in Self.malformedParticipantIdentifiers {
            let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(identifier), encoding: .utf8))
            for (shape, json) in [
                ("current", d2Envelope(operationId: "ID-1", payloadJSON: payload, participantJSON: encoded)),
                ("pre-D2 R4", #"{"operationId":"ID-1","participantIdentifier":\#(encoded),"payload":\#(payload)}"#),
                ("pre-R4", #"{"operationId":"ID-1","participantIdentifier":\#(encoded),"vendor":"Jasper Kane Cafe","food":"x","pickupName":"n","timing":"asap","mealSwipes":1}"#),
            ] {
                writeRaw(json)
                XCTAssertEqual(storage.restore(), .identityUnavailable, "\(label) (\(shape))")
            }
        }
    }

    func testAMalformedParticipantIdentifierFailsClosedForEveryParticipantWithoutANetworkGuess() async throws {
        let payload = #"{"vendor":"Jasper Kane Cafe","timing":"asap","menuPath":"meal-exchange","mealSwipes":1,"mealItems":["x"]}"#
        for (label, identifier) in Self.malformedParticipantIdentifiers {
            for current in [authorityA, authorityB] {
                RequestFetchingURLProtocol.reset()
                let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(identifier), encoding: .utf8))
                let json = d2Envelope(operationId: "MALFORMED-PARTICIPANT", payloadJSON: payload, participantJSON: encoded)
                writeRaw(json)
                let store = makeStore(
                    storage: UserDefaultsPendingRequestOperationStorage(defaults: defaults),
                    authority: current
                )

                _ = await store.reconcilePendingCreateOperationIfNeeded()

                XCTAssertEqual(store.createRecoveryPresentation, .identityUnavailable, label)
                XCTAssertTrue(store.hasUnresolvedCreateAmbiguity, "Create and Remove Email blocked: \(label)")
                XCTAssertTrue(store.hasResolvedPendingCreateStateForRemoval, label)
                do {
                    try await store.createRequest(mealPayload("Would-be second"))
                    XCTFail("A new logical create must be blocked: \(label)")
                } catch RequestServiceError.ambiguousCreateOutcome {}
                XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty, label)
                XCTAssertEqual(RequestFetchingURLProtocol.capturedOperationLedgerReadCount, 0, label)
                XCTAssertEqual(rawStoredValue, Data(json.utf8), "Never deleted or repaired: \(label)")
            }
        }
    }

    func testAnOriginOnlyVersion1RecordKeepsItsIdentityButNoTrustedAuthority() async throws {
        let payload = #"{"vendor":"Jasper Kane Cafe","timing":"asap","menuPath":"meal-exchange","mealSwipes":1,"mealItems":["x"]}"#
        let json = #"{"recoveryVersion":1,"operationId":"V1-ORIGIN-ONLY","participantIdentifier":"64c0000000000000000000a1","operationAuthority":"https://commonplate.test:443","payloadVersion":1,"payload":\#(payload)}"#
        writeRaw(json)
        let storage = UserDefaultsPendingRequestOperationStorage(defaults: defaults)
        guard case .restored(let restored) = storage.restore() else {
            return XCTFail("A version 1 identity is readable")
        }
        XCTAssertEqual(restored.identity.operationId, "V1-ORIGIN-ONLY")
        XCTAssertNil(restored.identity.operationAuthority, "A URL alone is not a trusted authority")

        let store = makeStore(storage: storage)
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: notCreatedBody))
        _ = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
        XCTAssertEqual(RequestFetchingURLProtocol.capturedOperationLedgerReadCount, 0)
        XCTAssertEqual(rawStoredValue, Data(json.utf8))
        XCTAssertEqual(store.createRecoveryPresentation, .unresolved(canCheckAgain: false))
    }

    // MARK: - Authority identity

    func testOperationAuthorityOriginIsANormalizedNonSecretOrigin() {
        func authority(_ string: String) -> String {
            RequestService.operationAuthorityOrigin(for: URL(string: string)!)
        }
        XCTAssertEqual(authority("https://commonplate.test"), "https://commonplate.test:443")
        XCTAssertEqual(authority("HTTPS://CommonPlate.TEST/"), "https://commonplate.test:443")
        XCTAssertEqual(authority("https://commonplate.test:443"), "https://commonplate.test:443")
        XCTAssertEqual(authority("http://127.0.0.1:3000"), "http://127.0.0.1:3000")
        XCTAssertEqual(authority("http://user:secret@127.0.0.1:3000/?q=1#f"), "http://127.0.0.1:3000")
        XCTAssertEqual(authority("https://api.test/v1/"), "https://api.test:443/v1")

        XCTAssertNotEqual(authority("http://127.0.0.1:3000"), authority("http://127.0.0.1:3001"))
        XCTAssertNotEqual(authority("http://commonplate.test"), authority("https://commonplate.test"))
        XCTAssertNotEqual(authority("https://staging.commonplate.test"), authority("https://commonplate.test"))
        XCTAssertNotEqual(authority("https://api.test/v1"), authority("https://api.test/v2"))
    }

    func testTheOperationLedgerIsReadStrictly() async throws {
        let ledger = try await makeService().fetchOperationLedger()
        XCTAssertEqual(ledger, serviceLedger)
        XCTAssertEqual(RequestFetchingURLProtocol.capturedOperationLedgerReadCount, 1)

        let unusable: [(String, RequestFetchingURLProtocol.Stub)] = [
            ("uppercase", RequestFetchingURLProtocol.operationLedgerResponse(serviceLedger.uppercased())),
            ("a URL", RequestFetchingURLProtocol.operationLedgerResponse("https://commonplate.test")),
            ("empty", RequestFetchingURLProtocol.operationLedgerResponse("")),
            ("missing", .response(data: Data("{}".utf8))),
            ("unavailable", .response(statusCode: 503, data: errorBody(code: RequestOperationErrorCode.operationAuthorityUnavailable))),
            ("absent route", .response(statusCode: 404, data: Data("Cannot GET".utf8))),
            ("transport", .failure(.networkConnectionLost)),
        ]
        for (label, stub) in unusable {
            RequestFetchingURLProtocol.enqueueOperationLedger(stub)
            do {
                _ = try await makeService().fetchOperationLedger()
                XCTFail("No ledger may be assumed from \(label)")
            } catch is RequestServiceError {}
        }
    }

    // MARK: - Terminal reconciliation service

    func testTerminalReconciliationSendsOnlyIdentityAndAuthority() async throws {
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: notCreatedBody))

        let outcome = try await makeService().reconcileRequestOperationTerminal(
            operationId: "SERVICE-1",
            participantAuthority: authorityA,
            operationLedger: serviceLedger
        )

        guard case .notCreated = outcome else { return XCTFail("Expected NO-CREATE") }
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, [Self.terminalPath])
        let headers = try XCTUnwrap(RequestFetchingURLProtocol.lastCapturedHeaders)
        XCTAssertEqual(headers[RequestService.operationIdentityHeader], "SERVICE-1")
        XCTAssertEqual(headers[RequestService.participantAuthorityHeader], authorityA)
        XCTAssertEqual(headers[RequestService.operationAuthorityHeader], serviceLedger)
        XCTAssertEqual(RequestFetchingURLProtocol.lastCapturedBody, Data(), "No request content is sent")
    }

    func testTerminalReconciliationAcceptsACreatedRequestInAnyLifecycleStatus() async throws {
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 200,
            data: createdBody(id: "claimed-since", status: "claimed")
        ))

        let outcome = try await makeService().reconcileRequestOperationTerminal(
            operationId: "SERVICE-2",
            participantAuthority: authorityA,
            operationLedger: serviceLedger
        )

        guard case .created(let request) = outcome else { return XCTFail("Expected created") }
        XCTAssertEqual(request.id, "claimed-since")
    }

    func testTerminalReconciliationNeverInfersAnOutcomeFromAnIncoherentAnswer() async {
        let bodies = [
            #"{"outcome":"created"}"#,
            #"{"outcome":"not-created","request":\#(requestObject(id: "x"))}"#,
            #"{"outcome":"maybe"}"#,
            #"{}"#,
            "not json",
        ]
        for body in bodies {
            RequestFetchingURLProtocol.reset()
            RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: Data(body.utf8)))
            do {
                _ = try await makeService().reconcileRequestOperationTerminal(
                    operationId: "SERVICE-3",
                    participantAuthority: authorityA,
                    operationLedger: serviceLedger
                )
                XCTFail("An incoherent answer must not resolve: \(body)")
            } catch let error as RequestServiceError {
                if case .serverError = error {
                    XCTFail("An incoherent answer is not a backend refusal: \(body)")
                }
            } catch {
                XCTFail("Unexpected error \(error) for \(body)")
            }
        }
    }

    // MARK: - Matrix row 1: readable payload keeps exact D1 replay

    func testReadablePayloadReplaysExactlyAndNeverCallsTerminalWhenCreated() async throws {
        let storage = savedStorage(operationId: "ROW1-CREATED")
        let store = makeStore(storage: storage)
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: createdReplayBody(id: "row1")))

        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertTrue(didCreate)
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, [Self.createPath])
        XCTAssertEqual(
            RequestFetchingURLProtocol.lastCapturedHeaders?[RequestService.operationIdentityHeader],
            "ROW1-CREATED"
        )
        XCTAssertEqual(
            RequestFetchingURLProtocol.lastCapturedHeaders?[RequestService.operationAuthorityHeader],
            serviceLedger,
            "The replay names the recorded ledger"
        )
        XCTAssertEqual(RequestFetchingURLProtocol.capturedOperationLedgerReadCount, 1)
        let json = try sentJSON()
        // W4-R4 sends structured `{ name, details }` objects on the wire, not
        // bare strings.
        let mealItemsJSON = try XCTUnwrap(json["mealItems"] as? [[String: Any]])
        let decodedMealItems = try mealItemsJSON.map { entry -> MealItem in
            MealItem(name: try XCTUnwrap(entry["name"] as? String), details: entry["details"] as? String)
        }
        XCTAssertEqual(decodedMealItems, ["ROW1-CREATED meal"])
        XCTAssertNil(storage.load())
        XCTAssertEqual(store.createRecoveryPresentation, .none)
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
    }

    func testReplayAnsweringNoCreateRetiresWithoutATerminalCall() async throws {
        let storage = savedStorage(operationId: "ROW1-NOT-CREATED")
        let store = makeStore(storage: storage)
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorBody(code: RequestOperationErrorCode.operationNotCreated)
        ))

        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertFalse(didCreate)
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, [Self.createPath])
        XCTAssertNil(storage.load())
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        // Path A: the replayed payload was known and readable. The raw
        // payload never leaves the store — presentation carries only the
        // discriminator, and the consume operation is the sole way to see
        // the exact restored content.
        XCTAssertEqual(store.createRecoveryPresentation, .notCreatedRecoverable)
        XCTAssertEqual(
            normalizingPickupTime(store.consumeRecoverableDraftForReturnToRequest()),
            normalizingPickupTime(RequestFoodFormDraft(restoring: mealPayload("ROW1-NOT-CREATED meal")))
        )
    }

    func testPostLookupRefusalsAreNotProofOnTheirOwn() async throws {
        for code in [
            RequestOperationErrorCode.invalidVendor,
            RequestOperationErrorCode.participantPrincipalMismatch,
            RequestOperationErrorCode.invalidRequest,
            RequestOperationErrorCode.requestLimitReached,
        ] {
            RequestFetchingURLProtocol.reset()
            let storage = savedStorage(operationId: "ROW1-\(code)")
            let before = storage.load()
            let store = makeStore(storage: storage)
            RequestFetchingURLProtocol.enqueue(.response(statusCode: 400, data: errorBody(code: code)))
            // Terminal reconciliation itself is inconclusive this time.
            RequestFetchingURLProtocol.enqueue(.failure(.timedOut))

            let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

            XCTAssertFalse(didCreate, code)
            XCTAssertEqual(
                RequestFetchingURLProtocol.capturedRequestedPaths,
                [Self.createPath, Self.terminalPath],
                code
            )
            XCTAssertEqual(storage.load(), before, "\(code) alone must not retire the operation")
            XCTAssertTrue(store.hasUnresolvedCreateAmbiguity, code)
            XCTAssertEqual(store.createRecoveryPresentation, .unresolved(canCheckAgain: true), code)
        }
    }

    func testPostLookupRefusalConvergesWhenTerminalAuthorityAnswersCreated() async throws {
        // The original transmission committed after this replay's lookup.
        let storage = savedStorage(operationId: "ROW1-LATE-COMMIT")
        let store = makeStore(storage: storage)
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 429,
            data: errorBody(code: RequestOperationErrorCode.requestLimitReached)
        ))
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 200,
            data: createdBody(id: "late-commit", status: "open")
        ))

        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertTrue(didCreate)
        XCTAssertNil(storage.load())
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertEqual(store.createRecoveryPresentation, .none)
    }

    func testAnUnacceptableReplaySuccessBodyConvergesThroughTerminalAuthority() async throws {
        // A replay of an operation whose Request has since been claimed:
        // a success status whose body is not the fresh-create shape.
        let storage = savedStorage(operationId: "ROW1-CLAIMED")
        let store = makeStore(storage: storage)
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 200,
            data: Data(#"{"request":\#(requestObject(id: "claimed-now", status: "claimed"))}"#.utf8)
        ))
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 200,
            data: createdBody(id: "claimed-now", status: "claimed")
        ))

        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertTrue(didCreate)
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, [Self.createPath, Self.terminalPath])
        XCTAssertNil(storage.load())
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
    }

    func testRouteLevelAndWriteUncertainReplayAnswersStayPendingWithoutATerminalCall() async throws {
        let cases: [(String, RequestFetchingURLProtocol.Stub)] = [
            ("RATE_LIMITED", .response(statusCode: 429, data: errorBody(code: RequestOperationErrorCode.rateLimited))),
            ("PUBLIC_ACTIONS_PAUSED", .response(statusCode: 503, data: errorBody(code: "PUBLIC_ACTIONS_PAUSED"))),
            ("bare 404", .response(statusCode: 404, data: Data("Cannot POST".utf8))),
            ("REQUEST_CREATION_FAILED", .response(statusCode: 500, data: errorBody(code: "REQUEST_CREATION_FAILED"))),
            ("PARTICIPANT_VERIFICATION_UNAVAILABLE", .response(statusCode: 503, data: errorBody(code: ParticipantErrorCode.verificationUnavailable))),
            ("unreadable 502", .response(statusCode: 502, data: Data("<html>".utf8))),
            ("transport loss", .failure(.networkConnectionLost)),
            ("timeout", .failure(.timedOut)),
        ]
        for (label, stub) in cases {
            RequestFetchingURLProtocol.reset()
            let storage = savedStorage(operationId: "ROW6-\(label.replacingOccurrences(of: " ", with: "-"))")
            let before = storage.load()
            let store = makeStore(storage: storage)
            RequestFetchingURLProtocol.enqueue(stub)

            let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

            XCTAssertFalse(didCreate, label)
            XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, [Self.createPath], label)
            XCTAssertEqual(storage.load(), before, label)
            XCTAssertTrue(store.hasUnresolvedCreateAmbiguity, label)
            XCTAssertEqual(store.createRecoveryPresentation, .unresolved(canCheckAgain: true), label)
        }
    }

    func testRecoveryTimeRateLimitNeverUnlocksANewLogicalCreate() async throws {
        let storage = InMemoryPendingRequestOperationStorage()
        let store = makeStore(storage: storage)
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))
        do {
            try await store.createRequest(mealPayload("Issued then throttled"))
            XCTFail("Expected an ambiguous outcome")
        } catch RequestServiceError.ambiguousCreateOutcome {}
        let issued = try XCTUnwrap(storage.load())

        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 429,
            data: errorBody(code: RequestOperationErrorCode.rateLimited)
        ))
        _ = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertEqual(storage.load(), issued)
        do {
            try await store.createRequest(mealPayload("Would-be second"))
            XCTFail("A new logical create must stay blocked")
        } catch RequestServiceError.serverError(let code, _) {
            XCTAssertEqual(code, RequestOperationErrorCode.rateLimited)
        }
        XCTAssertEqual(
            RequestFetchingURLProtocol.capturedRequestedPaths.filter { $0 == Self.createPath }.count,
            2,
            "Only the original and its exact replay were ever sent"
        )
        XCTAssertEqual(storage.load(), issued)
    }

    // MARK: - Matrix row 2: unreadable payload uses exact terminal reconciliation

    func testUnreadablePayloadIsResolvedByIdentityAloneAndNeverResent() async throws {
        writeRaw(d2Envelope(operationId: "ROW2-CREATED", payloadJSON: #"{"vendor":42}"#))
        let storage = UserDefaultsPendingRequestOperationStorage(defaults: defaults)
        let store = makeStore(storage: storage)
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 200,
            data: createdBody(id: "row2-created", status: "open")
        ))

        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertTrue(didCreate)
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, [Self.terminalPath])
        XCTAssertEqual(
            RequestFetchingURLProtocol.lastCapturedHeaders?[RequestService.operationIdentityHeader],
            "ROW2-CREATED"
        )
        XCTAssertEqual(RequestFetchingURLProtocol.lastCapturedBody, Data())
        XCTAssertNil(rawStoredValue)
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertEqual(store.createRecoveryPresentation, .none)
        // W4-D2 Success→Home continuity: same ingestion boundary as any
        // reconciled create under the still-current authority — inserts
        // immediately, ownership-resolved `.own`.
        XCTAssertEqual(store.requests.map(\.id), ["row2-created"])
        XCTAssertEqual(store.requests.first?.ownership, .own)
    }

    func testNoCreateRetiresTheOldOperationWithoutSubmittingAnythingAndALaterSubmissionIsFresh() async throws {
        writeRaw(d2Envelope(operationId: "ROW5-OLD", payloadJSON: #"{"vendor":42}"#))
        let storage = UserDefaultsPendingRequestOperationStorage(defaults: defaults)
        let store = makeStore(storage: storage)
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: notCreatedBody))

        let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertFalse(didCreate)
        XCTAssertNil(rawStoredValue)
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertTrue(store.hasResolvedPendingCreateStateForRemoval)
        // Path B: the payload was never readable.
        XCTAssertEqual(store.createRecoveryPresentation, .notCreatedUnavailable)
        // Nothing was auto-submitted.
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, [Self.terminalPath])

        // Retired means retired.
        _ = await store.reconcilePendingCreateOperationIfNeeded()
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, [Self.terminalPath])

        store.acknowledgeCreateNotPosted()
        XCTAssertEqual(store.createRecoveryPresentation, .none)

        RequestFetchingURLProtocol.enqueue(.response(statusCode: 201, data: createdReplayBody(id: "fresh")))
        try await store.createRequest(mealPayload("A new intentional request"))
        let freshId = try XCTUnwrap(
            RequestFetchingURLProtocol.lastCapturedHeaders?[RequestService.operationIdentityHeader]
        )
        XCTAssertNotEqual(freshId, "ROW5-OLD")
        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, [Self.terminalPath, Self.createPath])
    }

    func testANewSubmissionAlsoSupersedesAnUnacknowledgedNoCreateNotice() async throws {
        writeRaw(d2Envelope(operationId: "ROW5-NOTICE", payloadJSON: #"{"vendor":42}"#))
        let store = makeStore(storage: UserDefaultsPendingRequestOperationStorage(defaults: defaults))
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: notCreatedBody))
        _ = await store.reconcilePendingCreateOperationIfNeeded()
        XCTAssertEqual(store.createRecoveryPresentation, .notCreatedUnavailable)

        RequestFetchingURLProtocol.enqueue(.response(statusCode: 201, data: createdReplayBody(id: "fresh")))
        try await store.createRequest(mealPayload("Submitted without acknowledging"))

        XCTAssertEqual(store.createRecoveryPresentation, .none)
    }

    // MARK: - Matrix rows 3/4 and definitive identity answers from terminal authority

    func testTerminalExpiredUnauthorizedAndInvalidIdentityRetireWithoutANotice() async throws {
        let cases: [(Int, String)] = [
            (410, RequestOperationErrorCode.operationExpired),
            (403, RequestOperationErrorCode.operationUnauthorized),
            (400, RequestOperationErrorCode.invalidOperationId),
        ]
        for (status, code) in cases {
            RequestFetchingURLProtocol.reset()
            writeRaw(d2Envelope(operationId: "TERMINAL-\(status)", payloadJSON: "null"))
            let store = makeStore(storage: UserDefaultsPendingRequestOperationStorage(defaults: defaults))
            RequestFetchingURLProtocol.enqueue(.response(statusCode: status, data: errorBody(code: code)))

            let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

            XCTAssertFalse(didCreate, code)
            XCTAssertNil(rawStoredValue, code)
            XCTAssertFalse(store.hasUnresolvedCreateAmbiguity, code)
            XCTAssertEqual(store.createRecoveryPresentation, .none, code)
            XCTAssertTrue(store.requests.isEmpty, code)
        }
    }

    // MARK: - Matrix row 6: inconclusive terminal reconciliation stays locked

    func testInconclusiveTerminalReconciliationKeepsTheOperationAndCanBeCheckedAgain() async throws {
        let cases: [(String, RequestFetchingURLProtocol.Stub)] = [
            ("RATE_LIMITED", .response(statusCode: 429, data: errorBody(code: RequestOperationErrorCode.rateLimited))),
            ("PUBLIC_ACTIONS_PAUSED", .response(statusCode: 503, data: errorBody(code: "PUBLIC_ACTIONS_PAUSED"))),
            ("bare 404", .response(statusCode: 404, data: Data("Cannot POST".utf8))),
            ("reconciliation failed", .response(statusCode: 500, data: errorBody(code: "OPERATION_RECONCILIATION_FAILED"))),
            ("authority unavailable", .response(statusCode: 503, data: errorBody(code: ParticipantErrorCode.verificationUnavailable))),
            ("verification required", .response(statusCode: 401, data: errorBody(code: ParticipantErrorCode.verificationRequired))),
            ("unknown outcome", .response(statusCode: 200, data: Data(#"{"outcome":"pending"}"#.utf8))),
            ("undecodable success", .response(statusCode: 200, data: Data("{".utf8))),
            ("transport loss", .failure(.networkConnectionLost)),
        ]
        for (label, stub) in cases {
            RequestFetchingURLProtocol.reset()
            let json = d2Envelope(operationId: "ROW6-TERMINAL", payloadJSON: "null")
            writeRaw(json)
            let store = makeStore(storage: UserDefaultsPendingRequestOperationStorage(defaults: defaults))
            RequestFetchingURLProtocol.enqueue(stub)

            let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

            XCTAssertFalse(didCreate, label)
            XCTAssertEqual(rawStoredValue, Data(json.utf8), label)
            XCTAssertTrue(store.hasUnresolvedCreateAmbiguity, label)
            XCTAssertTrue(store.hasResolvedPendingCreateStateForRemoval, label)
            XCTAssertEqual(store.createRecoveryPresentation, .unresolved(canCheckAgain: true), label)
            XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, [Self.terminalPath], label)

            // `Check again` is a real exact reconciliation that can resolve.
            RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: notCreatedBody))
            _ = await store.reconcilePendingCreateOperationIfNeeded()
            XCTAssertNil(rawStoredValue, label)
            XCTAssertEqual(store.createRecoveryPresentation, .notCreatedUnavailable, label)
            XCTAssertEqual(
                RequestFetchingURLProtocol.capturedRequestedPaths,
                [Self.terminalPath, Self.terminalPath],
                label
            )
        }
    }

    func testARejectedParticipantCredentialIsRetiredButTheOperationIsNot() async throws {
        let json = d2Envelope(operationId: "ROW6-AUTHORITY", payloadJSON: "null")
        writeRaw(json)
        var rejected = 0
        let store = RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { self.authorityA },
            participantAuthorityRejected: { rejected += 1 },
            operationStorage: UserDefaultsPendingRequestOperationStorage(defaults: defaults)
        )
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 401,
            data: errorBody(code: ParticipantErrorCode.authorityInvalid)
        ))

        _ = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertEqual(rejected, 1)
        XCTAssertEqual(rawStoredValue, Data(json.utf8))
        XCTAssertTrue(store.hasUnresolvedCreateAmbiguity)
    }

    // MARK: - Matrix row 8: authority mismatch never terminalizes

    func testARecordFromAnotherAuthorityIsNeverSentEvenWithAReadablePayload() async throws {
        let payload = #"{"vendor":"Jasper Kane Cafe","timing":"asap","menuPath":"meal-exchange","mealSwipes":1,"mealItems":["x"]}"#
        for other in ["https://staging.commonplate.test:443", "http://127.0.0.1:3000", "https://commonplate.test:8443"] {
            RequestFetchingURLProtocol.reset()
            let json = d2Envelope(operationId: "ROW8-MISMATCH", payloadJSON: payload, origin: other)
            writeRaw(json)
            let store = makeStore(storage: UserDefaultsPendingRequestOperationStorage(defaults: defaults))
            // Even an authoritative-looking answer would not be accepted; none
            // is requested at all.
            RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: notCreatedBody))

            let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

            XCTAssertFalse(didCreate, other)
            XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty, other)
            XCTAssertEqual(RequestFetchingURLProtocol.capturedOperationLedgerReadCount, 0, other)
            XCTAssertEqual(rawStoredValue, Data(json.utf8), other)
            XCTAssertTrue(store.hasUnresolvedCreateAmbiguity, other)
            XCTAssertTrue(store.hasResolvedPendingCreateStateForRemoval, other)
            XCTAssertEqual(store.createRecoveryPresentation, .unresolved(canCheckAgain: false), other)
        }
    }

    func testTheSameRecordResolvesOnceTheRecordedAuthorityIsTheOneReached() async throws {
        let json = d2Envelope(
            operationId: "ROW8-MATCH",
            payloadJSON: "null",
            origin: RequestService.operationAuthorityOrigin(for: URL(string: "http://127.0.0.1:3000")!)
        )
        writeRaw(json)
        let store = RequestStore(
            service: makeService(baseURL: URL(string: "http://127.0.0.1:3000/")!),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { self.authorityA },
            participantAuthorityRejected: {},
            operationStorage: UserDefaultsPendingRequestOperationStorage(defaults: defaults)
        )
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: notCreatedBody))

        _ = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, [Self.terminalPath])
        XCTAssertEqual(store.createRecoveryPresentation, .notCreatedUnavailable)
    }

    func testSameURLWithADifferentLedgerFailsClosedAndNeverTerminalizes() async throws {
        let payloads = [
            ("readable", #"{"vendor":"Jasper Kane Cafe","timing":"asap","menuPath":"meal-exchange","mealSwipes":1,"mealItems":["x"]}"#),
            ("unreadable", "null"),
        ]
        for (label, payload) in payloads {
            RequestFetchingURLProtocol.reset()
            // Recorded against this URL, but the ledger behind it is now a
            // different one (a reset or replaced database).
            let json = d2Envelope(operationId: "ROW8-LEDGER", payloadJSON: payload, ledger: otherLedger)
            writeRaw(json)
            let store = makeStore(storage: UserDefaultsPendingRequestOperationStorage(defaults: defaults))
            RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: notCreatedBody))

            let didCreate = await store.reconcilePendingCreateOperationIfNeeded()

            XCTAssertFalse(didCreate, label)
            XCTAssertEqual(RequestFetchingURLProtocol.capturedOperationLedgerReadCount, 1, label)
            XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty, "No replay and no terminalization: \(label)")
            XCTAssertEqual(rawStoredValue, Data(json.utf8), label)
            XCTAssertTrue(store.hasUnresolvedCreateAmbiguity, label)
            XCTAssertEqual(store.createRecoveryPresentation, .unresolved(canCheckAgain: false), label)

            // No check from here can change that, so none is attempted again.
            _ = await store.reconcilePendingCreateOperationIfNeeded()
            XCTAssertEqual(RequestFetchingURLProtocol.capturedOperationLedgerReadCount, 1, label)
            XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty, label)
            do {
                try await store.createRequest(mealPayload("Would-be second"))
                XCTFail("A new logical create must stay blocked: \(label)")
            } catch RequestServiceError.ambiguousCreateOutcome {}
            XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty, label)
            XCTAssertEqual(rawStoredValue, Data(json.utf8), label)
        }
    }

    func testABackendRefusingTheRecordedLedgerFailsClosed() async throws {
        let cases = [
            ("replay", #"{"vendor":"Jasper Kane Cafe","timing":"asap","menuPath":"meal-exchange","mealSwipes":1,"mealItems":["x"]}"#, Self.createPath),
            ("terminal", "null", Self.terminalPath),
        ]
        for (label, payload, path) in cases {
            RequestFetchingURLProtocol.reset()
            let json = d2Envelope(operationId: "ROW8-ENFORCED", payloadJSON: payload)
            writeRaw(json)
            let store = makeStore(storage: UserDefaultsPendingRequestOperationStorage(defaults: defaults))
            // The ledger read matched, but the ledger changed before the
            // request arrived and the backend enforced the recorded one.
            RequestFetchingURLProtocol.enqueue(.response(
                statusCode: 409,
                data: errorBody(code: RequestOperationErrorCode.operationAuthorityMismatch)
            ))

            _ = await store.reconcilePendingCreateOperationIfNeeded()

            XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, [path], label)
            XCTAssertEqual(rawStoredValue, Data(json.utf8), label)
            XCTAssertTrue(store.hasUnresolvedCreateAmbiguity, label)
            XCTAssertEqual(store.createRecoveryPresentation, .unresolved(canCheckAgain: false), label)
        }
    }

    func testAnUnreadableCurrentLedgerIsInconclusiveAndSendsNothingElse() async throws {
        let cases: [(String, RequestFetchingURLProtocol.Stub)] = [
            ("unavailable", .response(statusCode: 503, data: errorBody(code: RequestOperationErrorCode.operationAuthorityUnavailable))),
            ("transport", .failure(.networkConnectionLost)),
            ("malformed", RequestFetchingURLProtocol.operationLedgerResponse("not-a-ledger")),
            ("absent route", .response(statusCode: 404, data: Data("Cannot GET".utf8))),
        ]
        for (label, stub) in cases {
            RequestFetchingURLProtocol.reset()
            let json = d2Envelope(operationId: "ROW6-LEDGER", payloadJSON: "null")
            writeRaw(json)
            let store = makeStore(storage: UserDefaultsPendingRequestOperationStorage(defaults: defaults))
            RequestFetchingURLProtocol.enqueueOperationLedger(stub)

            _ = await store.reconcilePendingCreateOperationIfNeeded()

            XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty, label)
            XCTAssertEqual(rawStoredValue, Data(json.utf8), label)
            XCTAssertEqual(store.createRecoveryPresentation, .unresolved(canCheckAgain: true), label)

            // A later explicit check against the same ledger resolves it.
            RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: notCreatedBody))
            _ = await store.reconcilePendingCreateOperationIfNeeded()
            XCTAssertEqual(RequestFetchingURLProtocol.capturedRequestedPaths, [Self.terminalPath], label)
            XCTAssertNil(rawStoredValue, label)
            XCTAssertEqual(store.createRecoveryPresentation, .notCreatedUnavailable, label)
        }
    }

    func testTerminalLedgerUnavailableIsInconclusive() async throws {
        let json = d2Envelope(operationId: "ROW6-TERMINAL-LEDGER", payloadJSON: "null")
        writeRaw(json)
        let store = makeStore(storage: UserDefaultsPendingRequestOperationStorage(defaults: defaults))
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 503,
            data: errorBody(code: RequestOperationErrorCode.operationAuthorityUnavailable)
        ))

        _ = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertEqual(rawStoredValue, Data(json.utf8))
        XCTAssertEqual(store.createRecoveryPresentation, .unresolved(canCheckAgain: true))
    }

    // MARK: - Participant binding

    func testAnotherParticipantsRecordWithAnUnreadablePayloadIsUntouchedAndNonBlocking() async throws {
        let json = d2Envelope(operationId: "OTHER-PARTICIPANT", payloadJSON: "null")
        writeRaw(json)
        let store = makeStore(storage: UserDefaultsPendingRequestOperationStorage(defaults: defaults), authority: authorityB)

        _ = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertTrue(RequestFetchingURLProtocol.capturedRequestedPaths.isEmpty)
        XCTAssertEqual(rawStoredValue, Data(json.utf8))
        XCTAssertFalse(store.hasUnresolvedCreateAmbiguity)
        XCTAssertTrue(store.hasEstablishedRemovalSafetyForD1Only)
        XCTAssertEqual(store.createRecoveryPresentation, .none)
    }

    // MARK: - Remove Email stays blocked in both unresolved states

    func testRemoveEmailStaysBlockedInBothUnresolvedStatesAndNotAfterNoCreate() async throws {
        // Identity unavailable.
        writeRaw("garbage")
        let unavailable = makeStore(storage: UserDefaultsPendingRequestOperationStorage(defaults: defaults))
        _ = await unavailable.reconcilePendingCreateOperationIfNeeded()
        XCTAssertTrue(unavailable.hasResolvedPendingCreateStateForRemoval)
        XCTAssertTrue(unavailable.hasUnresolvedCreateAmbiguity, "Remove Email blocked: identity unavailable")

        // Identity known, unresolved.
        writeRaw(d2Envelope(operationId: "REMOVE-EMAIL", payloadJSON: "null"))
        let unresolved = makeStore(storage: UserDefaultsPendingRequestOperationStorage(defaults: defaults))
        RequestFetchingURLProtocol.enqueue(.failure(.networkConnectionLost))
        _ = await unresolved.reconcilePendingCreateOperationIfNeeded()
        XCTAssertTrue(unresolved.hasResolvedPendingCreateStateForRemoval)
        XCTAssertTrue(unresolved.hasUnresolvedCreateAmbiguity, "Remove Email blocked: unresolved")

        // Authoritative NO-CREATE no longer blocks it.
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: notCreatedBody))
        _ = await unresolved.reconcilePendingCreateOperationIfNeeded()
        XCTAssertFalse(unresolved.hasUnresolvedCreateAmbiguity)
    }

    // MARK: - Presentation

    /// Faith's final 2026-09-17 recovery-UX decision: the stable-unresolved
    /// copy, and the NO-CREATE Path A/Path B split.
    func testRecoveryCopyAndActionsMatchTheRecordedDecision() {
        XCTAssertNil(RequestFoodView.recoveryCopy(for: .none))

        XCTAssertEqual(
            RequestFoodView.recoveryCopy(for: .unresolved(canCheckAgain: true)),
            RequestCreateRecoveryCopy(
                headline: "Your request may have posted",
                body: "\(AppBrand.name) couldn’t confirm whether your request posted.",
                actionLabel: "Check again"
            )
        )
        XCTAssertEqual(
            RequestFoodView.recoveryCopy(for: .unresolved(canCheckAgain: false)),
            RequestCreateRecoveryCopy(
                headline: "Your request may have posted",
                body: "\(AppBrand.name) couldn’t confirm whether your request posted.",
                actionLabel: nil
            )
        )
        XCTAssertEqual(
            RequestFoodView.recoveryCopy(for: .identityUnavailable),
            RequestCreateRecoveryCopy(
                headline: "We can’t safely confirm what happened to this request.",
                body: "To prevent a duplicate, \(AppBrand.name) won’t submit another request.",
                actionLabel: nil
            )
        )
        // Path A: the submitted information is recoverable.
        XCTAssertEqual(
            RequestFoodView.recoveryCopy(for: .notCreatedRecoverable),
            RequestCreateRecoveryCopy(
                headline: "Your request wasn’t posted",
                body: "Your request details are still here. Return to your request to review them before submitting again.",
                actionLabel: "Return to request"
            )
        )
        // Path B: the submitted information is genuinely unavailable.
        XCTAssertEqual(
            RequestFoodView.recoveryCopy(for: .notCreatedUnavailable),
            RequestCreateRecoveryCopy(
                headline: "Your request wasn’t posted",
                body: "You’ll need to enter the request details again.",
                actionLabel: "Start a new request"
            )
        )

        // No state promises checking it does not do, and no state offers a
        // retry, clear, or reinstall. Neither NO-CREATE path uses drafts
        // product language.
        for state: RequestCreateRecoveryPresentation in [
            .unresolved(canCheckAgain: true), .unresolved(canCheckAgain: false),
            .identityUnavailable,
            .notCreatedRecoverable,
            .notCreatedUnavailable,
        ] {
            let copy = RequestFoodView.presentedRecoveryCopy(for: state)
            let text = [copy.headline, copy.body, copy.actionLabel ?? ""].joined(separator: " ").lowercased()
            for forbidden in [
                "keep checking", "try again", "clear", "reinstall", "check active requests",
                "saved draft", "review draft",
            ] {
                XCTAssertFalse(text.contains(forbidden), "\(state) must not say \(forbidden)")
            }
        }
        XCTAssertEqual(
            RequestCreatePresentationError.ambiguous.message,
            "\(AppBrand.name) couldn’t confirm whether your request posted."
        )
    }

    func testTheViewDistinguishesTheThreeRecoveryStates() {
        func presentation(
            unresolved: Bool,
            isCreating: Bool = false,
            recovery: RequestCreateRecoveryPresentation
        ) -> RequestFormPresentation {
            RequestFoodView.presentation(
                hasUnresolvedCreateAmbiguity: unresolved,
                availability: .available,
                isCheckingAvailability: false,
                hasAttemptedAvailabilityCheck: true,
                didCreateRequest: false,
                isCreating: isCreating,
                createRecovery: recovery
            )
        }

        XCTAssertEqual(
            presentation(unresolved: true, recovery: .unresolved(canCheckAgain: true)),
            .blockedByUnresolvedCreateAmbiguity
        )
        XCTAssertEqual(
            presentation(unresolved: true, recovery: .unresolved(canCheckAgain: false)),
            .blockedByUnresolvedCreateAmbiguity
        )
        XCTAssertEqual(
            presentation(unresolved: true, isCreating: true, recovery: .unresolved(canCheckAgain: true)),
            .checkingCreateAmbiguity
        )
        XCTAssertEqual(
            presentation(unresolved: true, recovery: .identityUnavailable),
            .createIdentityUnavailable
        )
        // Both NO-CREATE paths gate the same presentation.
        XCTAssertEqual(
            presentation(unresolved: false, recovery: .notCreatedRecoverable),
            .createNotPosted
        )
        XCTAssertEqual(
            presentation(unresolved: false, recovery: .notCreatedUnavailable),
            .createNotPosted
        )
        // A new submission in flight is ordinary posting, not the old notice.
        XCTAssertEqual(
            presentation(unresolved: false, isCreating: true, recovery: .notCreatedUnavailable),
            .posting
        )
        XCTAssertEqual(presentation(unresolved: false, recovery: .none), .form)

        // Normal navigation away stays available in every recovery state.
        for state: RequestFormPresentation in [
            .blockedByUnresolvedCreateAmbiguity, .checkingCreateAmbiguity,
            .createIdentityUnavailable, .createNotPosted,
        ] {
            XCTAssertFalse(RequestFoodView.shouldSuppressBackNavigation(presentation: state))
        }

        XCTAssertEqual(
            RequestFoodView.unresolvedRecovery(.unresolved(canCheckAgain: true)),
            .unresolved(canCheckAgain: true)
        )
        XCTAssertEqual(RequestFoodView.unresolvedRecovery(.none), .unresolved(canCheckAgain: false))
    }

    func testRecoveryStatesFireNoHapticsInSource() throws {
        // Source inspection only: the three recovery views and the actions
        // they call contain no haptic, matching the R2 boundary. Posting a
        // created result goes through the existing success view.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("CommonPlateios/Views/RequestFoodView.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private var blockedByAmbiguityView: some View"))
        let end = try XCTUnwrap(source.range(of: "/// W4-R2 Posting: one native indeterminate progress owner"))
        let recoverySource = source[start.lowerBound..<end.lowerBound]
        XCTAssertFalse(recoverySource.contains("CommonPlateHaptics"))
        XCTAssertTrue(recoverySource.contains("createIdentityUnavailableView"))
        XCTAssertTrue(recoverySource.contains("createNotPostedView"))
    }

    /// Faith's final 2026-09-17 decision: no separate `Checking your
    /// request` screen exists — the unresolved screen's own primary action
    /// becomes `Checking…` while reconciliation is in flight. Source
    /// inspection, matching the existing no-haptics precedent above: there is
    /// no iOS UI-test target (`docs/testing.md`).
    func testCheckAgainRemainsOnTheSameScreenWithACheckingLoadingLabel() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("CommonPlateios/Views/RequestFoodView.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func unresolvedCreateAmbiguityView"))
        let end = try XCTUnwrap(source.range(of: "/// W4-D2 state 2: a pending operation exists"))
        let unresolvedSource = source[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(unresolvedSource.contains("checkingAgainLabel"))
        XCTAssertTrue(unresolvedSource.contains("isActivelyChecking"))
        // No distinct "Checking your request" screen/string anywhere live.
        XCTAssertFalse(source.contains("\"Checking your request\""))
    }

    /// Both NO-CREATE paths always offer `Go to Home` as ordinary,
    /// non-mutating navigation alongside their one distinguishing action.
    func testCreateNotPostedOffersGoToHomeAlongsideEitherPathsAction() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("CommonPlateios/Views/RequestFoodView.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private var createNotPostedView"))
        let end = try XCTUnwrap(source.range(of: "/// The shared centered layout"))
        let section = source[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(section.contains("goToHomeLabel"))
        XCTAssertTrue(section.contains("request-return-to-request"))
        XCTAssertTrue(section.contains("request-start-new"))
    }

    /// W4-D2 FIX 2026-09-18 (independent-review MUST FIX 2): Path A and Path
    /// B must reset the same centralized set of form-local presentation
    /// state, and must route the draft/session replacement through
    /// `RequestFoodDraftSession`'s own terminal-recovery operations rather
    /// than assigning `draft` directly — so the two paths can never drift on
    /// what they clear. No UI-test target exists (`docs/testing.md`), so
    /// this remains production-wiring source inspection, supplementary to
    /// the behavioral proof below (rereview MUST FIX 3) rather than the
    /// primary proof of the reset itself.
    func testPathAAndPathBBothRouteThroughTheCentralizedLocalStateReset() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("CommonPlateios/Views/RequestFoodView.swift"),
            encoding: .utf8
        )

        let resetStart = try XCTUnwrap(source.range(of: "private func resetFormLocalPresentationState()"))
        let resetEnd = try XCTUnwrap(source.range(of: "private func startNewRequest()"))
        let resetBody = source[resetStart.lowerBound..<resetEnd.lowerBound]
        // The reset body itself now delegates every field it owns to
        // `RequestFoodMountedPresentationState`'s own tested reset, rather
        // than assigning them inline — this only proves the delegation is
        // wired, not that the reset behaves correctly (the behavioral test
        // below does that).
        XCTAssertTrue(resetBody.contains("RequestFoodMountedPresentationState("))
        XCTAssertTrue(resetBody.contains("mountedState.resetForTerminalRecovery(screenshotProposalStore:"))
        XCTAssertTrue(resetBody.contains("mealSwipeMismatch: mealSwipeMismatch"))
        XCTAssertTrue(resetBody.contains("mealSwipeMismatch = mountedState.mealSwipeMismatch"))
        for field in ["focusedField = nil", "selectedScreenshotItems = []"] {
            XCTAssertTrue(resetBody.contains(field), "resetFormLocalPresentationState must reset \(field)")
        }

        let startNewStart = try XCTUnwrap(source.range(of: "private func startNewRequest()"))
        let startNewEnd = try XCTUnwrap(source.range(of: "private func returnToRequest()"))
        let startNewBody = source[startNewStart.lowerBound..<startNewEnd.lowerBound]
        XCTAssertTrue(startNewBody.contains("draftSession.startEmptyAfterTerminalRecovery()"))
        XCTAssertTrue(startNewBody.contains("resetFormLocalPresentationState()"))
        XCTAssertFalse(
            startNewBody.contains("draft = RequestFoodFormDraft()"),
            "Path B must go through the session's own reset, never assign draft directly"
        )

        let returnStart = try XCTUnwrap(source.range(of: "private func returnToRequest()"))
        let returnEnd = try XCTUnwrap(source.range(of: "/// W4-R2 Posting: one native indeterminate progress owner"))
        let returnBody = source[returnStart.lowerBound..<returnEnd.lowerBound]
        XCTAssertTrue(returnBody.contains("store.consumeRecoverableDraftForReturnToRequest()"))
        XCTAssertTrue(returnBody.contains("draftSession.replaceForTerminalRecovery(restoring:"))
        XCTAssertTrue(returnBody.contains("resetFormLocalPresentationState()"))
        XCTAssertFalse(
            returnBody.contains("draft = RequestFoodFormDraft(restoring:"),
            "Path A must go through the session's own reset, never assign draft directly"
        )
        XCTAssertFalse(
            returnBody.contains("CreateRequestPayload"),
            "The raw payload type must never appear in the view's restoration path"
        )
        // FIX (rereview MUST FIX 2): a failed/stale/repeated Path A consume
        // (`store.consumeRecoverableDraftForReturnToRequest()` returning
        // `nil`) must never fall through to Path B behavior — it is not
        // proof Path B is now authoritative, only that Path A is no longer
        // current. The store-level proof that `nil` means exactly
        // "already consumed / superseded / not actually Path A" lives in
        // `testConsumeRecoverableDraftConsumesExactlyOnceAndNeverTwice` and
        // `testConsumeRecoverableDraftReturnsNilOutsidePathA` below.
        XCTAssertFalse(
            returnBody.contains("startNewRequest()"),
            "a failed Path A consume must do nothing, never fall back to Path B's startNewRequest()"
        )
    }

    // MARK: - Mounted-view local-state reset (rereview MUST FIX 3)

    /// Behavioral proof, not source inspection: contaminates every field
    /// `RequestFoodMountedPresentationState` owns, calls the exact production
    /// reset `resetFormLocalPresentationState()` delegates to
    /// (`resetForTerminalRecovery(screenshotProposalStore:)`), and asserts
    /// the result is indistinguishable from a fresh instance. Also proves the
    /// `ScreenshotProposalStore` integration is real: a token minted by
    /// `beginSelection(...)` — standing in for an in-flight analysis for the
    /// form being replaced — is current before the reset and stale after it,
    /// which only actually invalidating the store's current selection (not
    /// merely calling a method that exists) can produce. There is no
    /// UI-test target (`docs/testing.md`); this is the seam that stands in
    /// for mounting `RequestFoodView` and exercising Path A/B end to end.
    func testMountedPresentationStateResetProducesCleanStateAndInvalidatesScreenshotSelection() {
        let preservedManualContent = ScreenshotProposalAppliedFields(
            preservedManualFieldCount: 1
        )
        var feedback = ScreenshotPreservedEntryFeedbackState()
        feedback.beginSelection()
        XCTAssertNil(feedback.completeAnalysis(eligible: true, applying: preservedManualContent))
        feedback.beginSelection()
        let staleFeedbackTimeout = feedback.completeAnalysis(eligible: true, applying: preservedManualContent)
        XCTAssertTrue(feedback.isShowing)
        let feedbackGenerationBeforeReset = feedback.timeoutGeneration

        var contaminated = RequestFoodMountedPresentationState(
            validationPresentation: {
                var presentation = RequestFoodValidationPresentation()
                presentation.presentAll([
                    RequestFoodFieldError(
                        field: .diningDollars,
                        error: .invalidDiningDollars(ceilingCents: 5_000)
                    ),
                ])
                return presentation
            }(),
            submissionError: .ambiguous,
            showsLocalRejectionPointer: true,
            isShowingFailureSummary: true,
            isPresentingScreenshotPicker: true,
            isPresentingExactTimePicker: true,
            isPresentingTimingInfo: true,
            screenshotAfterglowFields: ScreenshotProposalAppliedFields(
                location: true,
                mealSwipes: true,
                mealItemNames: [0, 1],
                mealItemDetails: [0, 1],
                orderDetails: true
            ),
            screenshotChecked: true,
            preservedEntryFeedback: feedback,
            expandedMealIndex: 1
        )
        XCTAssertNotEqual(contaminated, RequestFoodMountedPresentationState())

        let screenshotProposalStore = makeScreenshotProposalStore()
        var draftForSelection = RequestFoodFormDraft()
        let staleSelectionToken = screenshotProposalStore.beginSelection(
            clearing: &draftForSelection,
            manualEdits: ScreenshotFieldManualEditState()
        )
        XCTAssertTrue(screenshotProposalStore.isCurrent(staleSelectionToken))
        contaminated.mealSwipeMismatch.present(2, for: staleSelectionToken)
        XCTAssertEqual(contaminated.mealSwipeMismatch.suggestion?.proposedCount, 2)

        contaminated.resetForTerminalRecovery(screenshotProposalStore: screenshotProposalStore)

        XCTAssertEqual(contaminated.validationPresentation, RequestFoodValidationPresentation())
        XCTAssertNil(contaminated.submissionError)
        XCTAssertFalse(contaminated.showsLocalRejectionPointer)
        XCTAssertFalse(contaminated.isShowingFailureSummary)
        XCTAssertFalse(contaminated.isPresentingScreenshotPicker)
        XCTAssertFalse(contaminated.isPresentingExactTimePicker)
        XCTAssertFalse(contaminated.isPresentingTimingInfo)
        XCTAssertEqual(contaminated.screenshotAfterglowFields, ScreenshotProposalAppliedFields())
        XCTAssertFalse(contaminated.screenshotChecked)
        XCTAssertNil(contaminated.mealSwipeMismatch.suggestion)
        XCTAssertNil(contaminated.mealSwipeMismatch.dismissedToken)
        XCTAssertFalse(contaminated.preservedEntryFeedback.isShowing)
        XCTAssertFalse(contaminated.preservedEntryFeedback.hasCompletedScreenshotAssistanceRun)
        XCTAssertNil(contaminated.expandedMealIndex)
        XCTAssertGreaterThan(
            contaminated.preservedEntryFeedback.timeoutGeneration,
            feedbackGenerationBeforeReset
        )
        contaminated.preservedEntryFeedback.clearAfterTimeout(
            ifCurrent: try! XCTUnwrap(staleFeedbackTimeout)
        )
        XCTAssertFalse(
            contaminated.preservedEntryFeedback.isShowing,
            "a stale preserved-entry timeout cannot resurrect feedback on the replacement form"
        )
        XCTAssertFalse(
            screenshotProposalStore.isCurrent(staleSelectionToken),
            "the previous selection's in-flight work must stop mattering, exactly as leaving the screen would"
        )
    }

    // MARK: - Path A/B restoration

    /// Path A round-trip: the frozen Dining-Dollars-only payload restores
    /// into a fresh draft with nothing reconstructed or guessed — only what
    /// the payload itself carries. `mealSwipes` falls back to the picker's
    /// own first option since `0` (this path's submitted value) is out of
    /// the picker's bounded range.
    func testPathARestoresTheFrozenDiningDollarsPayloadIntoAFreshDraft() {
        let payload = CreateRequestPayload(
            vendor: "Jasper Kane Cafe",
            timing: .scheduled,
            windowStart: Date(timeIntervalSince1970: 1_800_000_000),
            menuPath: .diningDollars,
            mealSwipes: 0,
            mealItems: [],
            orderDetails: "Two burritos, extra guac",
            estimatedDiningDollarsCents: 1234
        )

        let draft = RequestFoodFormDraft(restoring: payload)

        XCTAssertEqual(draft.selectedDiningSpot, DiningSpot(name: "Jasper Kane Cafe", address: nil))
        XCTAssertEqual(draft.menuPath, .diningDollars)
        XCTAssertEqual(draft.timing, .later)
        XCTAssertEqual(draft.preferredPickupTime, payload.windowStart)
        XCTAssertEqual(draft.mealSwipes, RequestFoodFormDraft.mealSwipeOptions.first)
        XCTAssertEqual(draft.orderDetails, "Two burritos, extra guac")
        XCTAssertEqual(draft.diningDollarsText, "$12.34")
        XCTAssertEqual(draft.activeMealEntries, [])
    }

    /// Path A round-trip: the frozen Meal Exchange payload's entries land
    /// back at their original active positions.
    func testPathARestoresMealExchangeEntriesIntoTheirOriginalPositions() {
        let payload = CreateRequestPayload(
            vendor: "Kimmel",
            timing: .asap,
            windowStart: nil,
            menuPath: .mealExchange,
            mealSwipes: 3,
            mealItems: ["Burger", "Fries", "Shake"],
            orderDetails: nil,
            estimatedDiningDollarsCents: nil
        )

        let draft = RequestFoodFormDraft(restoring: payload)

        XCTAssertEqual(draft.menuPath, .mealExchange)
        XCTAssertEqual(draft.timing, .asap)
        XCTAssertEqual(draft.mealSwipes, 3)
        XCTAssertEqual(draft.activeMealEntries, ["Burger", "Fries", "Shake"])
        XCTAssertEqual(draft.diningDollarsText, "")
    }

    /// W4-D2 FIX (rereview MUST FIX 1): a direct fresh `createRequest()`
    /// supersession of an unacknowledged Path A notice must clear the
    /// private frozen payload in the same step as the notice flag, not
    /// merely hide the notice while leaving the payload allocated. This is
    /// the specific gap the rereview found: `createRequest()`'s own
    /// supersession branch previously cleared only `hasNotCreatedNotice`.
    /// `notCreatedRecoverablePayload` has no public accessor by design (the
    /// payload never leaves the store) — `Mirror` reflection is used only to
    /// prove this private invariant directly, the same technique this test
    /// target already uses elsewhere to prove absent/present fields.
    func testFreshCreateSupersessionClearsThePrivatePayloadNotJustTheNoticeFlag() async throws {
        writeRaw(d2Envelope(
            operationId: "SUPERSEDE-PATHA",
            payloadJSON: try encodedPayloadJSON(mealPayload("Superseded meal"))
        ))
        let store = makeStore(storage: UserDefaultsPendingRequestOperationStorage(defaults: defaults))
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorBody(code: RequestOperationErrorCode.operationNotCreated)
        ))
        _ = await store.reconcilePendingCreateOperationIfNeeded()
        guard store.createRecoveryPresentation == .notCreatedRecoverable else {
            return XCTFail("Expected Path A")
        }
        XCTAssertTrue(isNotCreatedRecoverablePayloadAllocated(in: store))

        // A fresh intentional submission supersedes the old, unacknowledged
        // notice — never acknowledged or consumed first.
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 201, data: createdReplayBody(id: "fresh-supersede")))
        try await store.createRequest(mealPayload("Fresh submission"))

        XCTAssertEqual(store.createRecoveryPresentation, .none)
        XCTAssertFalse(
            isNotCreatedRecoverablePayloadAllocated(in: store),
            "a fresh create's supersession must retire the private payload along with the notice"
        )
    }

    /// A dismissed Path A notice must never leak its payload into an
    /// unrelated, later NO-CREATE for a different operation.
    func testAcknowledgingNoCreateClearsTheRecoveredPayloadForTheNextOperation() async throws {
        let storage = UserDefaultsPendingRequestOperationStorage(defaults: defaults)
        let store = makeStore(storage: storage)

        // Path A: a readable payload, answered directly by the replayed
        // create attempt.
        let readablePayload = #"{"vendor":"Jasper Kane Cafe","timing":"asap","menuPath":"meal-exchange","mealSwipes":1,"mealItems":["x"]}"#
        writeRaw(d2Envelope(operationId: "PATHA-FIRST", payloadJSON: readablePayload))
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorBody(code: RequestOperationErrorCode.operationNotCreated)
        ))
        _ = await store.reconcilePendingCreateOperationIfNeeded()
        guard store.createRecoveryPresentation == .notCreatedRecoverable else {
            return XCTFail("Expected Path A")
        }

        store.acknowledgeCreateNotPosted()
        XCTAssertEqual(store.createRecoveryPresentation, .none)

        // Path B: a second, unrelated NO-CREATE with an unreadable payload
        // must never carry the earlier operation's payload forward.
        RequestFetchingURLProtocol.reset()
        writeRaw(d2Envelope(operationId: "PATHB-SECOND", payloadJSON: "null"))
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: notCreatedBody))
        _ = await store.reconcilePendingCreateOperationIfNeeded()

        XCTAssertEqual(store.createRecoveryPresentation, .notCreatedUnavailable)
    }

    // MARK: - Store privacy boundary (independent-review 2026-09-18 MUST FIX 1)

    /// The public recovery presentation is a plain, payload-free enum — the
    /// exact ambiguity-recovery payload can never cross this boundary by
    /// construction, not merely by convention or call-site discipline.
    func testNotCreatedPresentationCarriesNoRecoverablePayloadByConstruction() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("CommonPlateios/Stores/RequestStore.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "enum RequestCreateRecoveryPresentation: Equatable {"))
        let end = try XCTUnwrap(source.range(of: "enum ClaimErrorCode {"))
        let enumSource = source[start.lowerBound..<end.lowerBound]
        // The type may still be named in prose explaining the boundary; what
        // must never reappear is an associated value carrying it.
        XCTAssertFalse(enumSource.contains("recoverablePayload: CreateRequestPayload"))
        XCTAssertFalse(enumSource.contains("(CreateRequestPayload"))
        XCTAssertTrue(enumSource.contains("case notCreatedRecoverable"))
        XCTAssertTrue(enumSource.contains("case notCreatedUnavailable"))
    }

    /// Path A: the store-owned consume operation is the only way to see the
    /// exact restored draft, and it can never be called twice for the same
    /// operation — the second call, after the notice is already gone, must
    /// return nothing rather than repeat the earlier restoration.
    func testConsumeRecoverableDraftConsumesExactlyOnceAndNeverTwice() async throws {
        let store = makeStore(storage: UserDefaultsPendingRequestOperationStorage(defaults: defaults))
        let readablePayload = mealPayload("CONSUME-ONCE meal")
        writeRaw(d2Envelope(operationId: "CONSUME-ONCE", payloadJSON: try encodedPayloadJSON(readablePayload)))
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorBody(code: RequestOperationErrorCode.operationNotCreated)
        ))
        _ = await store.reconcilePendingCreateOperationIfNeeded()
        XCTAssertEqual(store.createRecoveryPresentation, .notCreatedRecoverable)

        let restored = store.consumeRecoverableDraftForReturnToRequest()

        XCTAssertEqual(
            normalizingPickupTime(restored),
            normalizingPickupTime(RequestFoodFormDraft(restoring: readablePayload))
        )
        // Consumed: the notice is gone and cannot be acted on again.
        XCTAssertEqual(store.createRecoveryPresentation, .none)
        XCTAssertNil(store.consumeRecoverableDraftForReturnToRequest())
    }

    /// Path B, and the absence of any notice, must never hand back a draft:
    /// there is nothing trusted to restore, and the attempt must not disturb
    /// whatever notice (if any) is actually showing.
    func testConsumeRecoverableDraftReturnsNilOutsidePathA() async throws {
        let store = makeStore(storage: UserDefaultsPendingRequestOperationStorage(defaults: defaults))
        XCTAssertNil(store.consumeRecoverableDraftForReturnToRequest())

        writeRaw(d2Envelope(operationId: "NIL-PATH-B", payloadJSON: "null"))
        RequestFetchingURLProtocol.enqueue(.response(statusCode: 200, data: notCreatedBody))
        _ = await store.reconcilePendingCreateOperationIfNeeded()
        XCTAssertEqual(store.createRecoveryPresentation, .notCreatedUnavailable)

        XCTAssertNil(store.consumeRecoverableDraftForReturnToRequest())
        // A Path B notice is not silently consumed by the failed attempt.
        XCTAssertEqual(store.createRecoveryPresentation, .notCreatedUnavailable)
    }

    /// A consumed Path A payload can never leak into a later, unrelated
    /// operation's own Path A notice.
    func testConsumeRecoverableDraftNeverLeaksAcrossOperations() async throws {
        let store = makeStore(storage: UserDefaultsPendingRequestOperationStorage(defaults: defaults))
        let firstPayload = mealPayload("LEAK-FIRST meal")
        writeRaw(d2Envelope(operationId: "LEAK-FIRST", payloadJSON: try encodedPayloadJSON(firstPayload)))
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorBody(code: RequestOperationErrorCode.operationNotCreated)
        ))
        _ = await store.reconcilePendingCreateOperationIfNeeded()
        XCTAssertEqual(
            normalizingPickupTime(store.consumeRecoverableDraftForReturnToRequest()),
            normalizingPickupTime(RequestFoodFormDraft(restoring: firstPayload))
        )

        RequestFetchingURLProtocol.reset()
        let secondPayload = mealPayload("LEAK-SECOND meal")
        writeRaw(d2Envelope(operationId: "LEAK-SECOND", payloadJSON: try encodedPayloadJSON(secondPayload)))
        RequestFetchingURLProtocol.enqueue(.response(
            statusCode: 409,
            data: errorBody(code: RequestOperationErrorCode.operationNotCreated)
        ))
        _ = await store.reconcilePendingCreateOperationIfNeeded()

        let restoredSecond = normalizingPickupTime(store.consumeRecoverableDraftForReturnToRequest())
        XCTAssertEqual(restoredSecond, normalizingPickupTime(RequestFoodFormDraft(restoring: secondPayload)))
        XCTAssertNotEqual(restoredSecond, normalizingPickupTime(RequestFoodFormDraft(restoring: firstPayload)))
    }

    // MARK: - Helpers

    private func makeStore(
        storage: PendingRequestOperationStorage,
        authority: String? = nil
    ) -> RequestStore {
        let resolved = authority ?? authorityA
        return RequestStore(
            service: makeService(),
            installationCredentialProvider: { "test-installation-credential" },
            participantAuthorityProvider: { resolved },
            participantAuthorityRejected: {},
            operationStorage: storage
        )
    }

    private func makeService(baseURL: URL? = nil) -> RequestService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFetchingURLProtocol.self]
        return RequestService(client: APIClient(
            configuration: APIConfiguration(baseURL: baseURL ?? self.baseURL),
            session: URLSession(configuration: configuration)
        ))
    }

    /// A real `ScreenshotProposalStore` for the mounted-view reset test
    /// (rereview MUST FIX 3) — no network call is ever exercised, so this
    /// needs no request stub, only a valid client. Reuses
    /// `InMemoryScreenshotProposalPreferencesStorage` from
    /// `ScreenshotProposalStoreTests.swift`, in the same test target.
    private func makeScreenshotProposalStore() -> ScreenshotProposalStore {
        ScreenshotProposalStore(
            availability: .enabledForTesting(),
            service: ScreenshotProposalService(availability: .enabledForTesting(), client: APIClient(
                configuration: APIConfiguration(baseURL: baseURL),
                session: URLSession(configuration: .ephemeral)
            )),
            preferences: InMemoryScreenshotProposalPreferencesStorage()
        )
    }

    private func savedStorage(operationId: String) -> InMemoryPendingRequestOperationStorage {
        let storage = InMemoryPendingRequestOperationStorage()
        storage.save(PendingRequestOperationRecord(
            operationId: operationId,
            participantIdentifier: participantIdentifierA,
            operationAuthority: serviceAuthority,
            payload: mealPayload("\(operationId) meal")
        ))
        return storage
    }

    private func mealPayload(_ meal: String) -> CreateRequestPayload {
        CreateRequestPayload(
            vendor: "Jasper Kane Cafe",
            timing: .asap,
            windowStart: nil,
            menuPath: .mealExchange,
            mealSwipes: 1,
            mealItems: [MealItem(name: meal)],
            orderDetails: nil,
            estimatedDiningDollarsCents: nil
        )
    }

    /// W4-D2 FIX (rereview MUST FIX 1) white-box helper: whether `store`'s
    /// private `notCreatedRecoverablePayload` currently holds a value.
    /// `Mirror` reflects an `Optional`-typed stored property as a nested
    /// single-child `.optional` mirror (`.some` has exactly one child,
    /// `.none` has zero) regardless of the wrapped type, which is what makes
    /// this reliable without casting to `CreateRequestPayload` directly.
    private func isNotCreatedRecoverablePayloadAllocated(in store: RequestStore) -> Bool {
        guard let field = Mirror(reflecting: store).children
            .first(where: { $0.label == "notCreatedRecoverablePayload" }) else {
            return false
        }
        let wrapped = Mirror(reflecting: field.value)
        guard wrapped.displayStyle == .optional else { return true }
        return !wrapped.children.isEmpty
    }

    /// Encodes a payload exactly as the durable record's `frozenPayload`
    /// would (installation credential cleared), for building a `d2Envelope`
    /// without hand-writing its JSON.
    private func encodedPayloadJSON(_ payload: CreateRequestPayload) throws -> String {
        var frozen = payload
        frozen.installationCredential = nil
        let data = try JSONEncoder().encode(frozen)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    /// `RequestFoodFormDraft(restoring:)` falls back to `Date()` for an ASAP
    /// payload's `preferredPickupTime` (there is no frozen `windowStart` to
    /// restore), so two independently restored drafts for the identical
    /// payload can differ by microseconds in that one field alone. Tests
    /// that restore the same ASAP payload twice, or restore it and separately
    /// construct the expected value, compare with that field normalized away
    /// rather than asserting exact wall-clock equality neither call site can
    /// guarantee.
    private func normalizingPickupTime(_ draft: RequestFoodFormDraft?) -> RequestFoodFormDraft? {
        guard var draft else { return nil }
        draft.preferredPickupTime = Date(timeIntervalSince1970: 0)
        return draft
    }

    private func d2Envelope(
        operationId: String,
        payloadJSON: String,
        origin: String? = nil,
        ledger: String? = nil,
        participantJSON: String? = nil,
        recoveryVersion: String = "2",
        payloadVersion: String = "1"
    ) -> String {
        let originValue = origin ?? serviceOrigin
        let ledgerValue = ledger ?? serviceLedger
        let participant = participantJSON ?? "\"\(participantIdentifierA)\""
        return #"{"recoveryVersion":\#(recoveryVersion),"operationId":"\#(operationId)","participantIdentifier":\#(participant),"authorityOrigin":"\#(originValue)","authorityLedger":"\#(ledgerValue)","payloadVersion":\#(payloadVersion),"payload":\#(payloadJSON)}"#
    }

    /// Stores exactly one entry in this build's collection.
    private func writeRaw(_ json: String) {
        defaults.removeObject(forKey: UserDefaultsPendingRequestOperationStorage.singleRecordKey)
        defaults.set([Data(json.utf8)], forKey: UserDefaultsPendingRequestOperationStorage.collectionKey)
    }

    /// The one entry in this build's collection; `nil` once it is retired.
    private var rawStoredValue: Data? {
        guard let entries = defaults.array(forKey: UserDefaultsPendingRequestOperationStorage.collectionKey) else {
            return nil
        }
        XCTAssertEqual(entries.count, 1)
        return entries.first as? Data
    }

    private func storedJSON() throws -> [String: Any]? {
        guard let data = rawStoredValue else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func sentJSON() throws -> [String: Any] {
        let body = try XCTUnwrap(RequestFetchingURLProtocol.lastCapturedBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private var notCreatedBody: Data {
        Data(#"{"outcome":"not-created"}"#.utf8)
    }

    private func createdBody(id: String, status: String) -> Data {
        Data(#"{"outcome":"created","request":\#(requestObject(id: id, status: status))}"#.utf8)
    }

    private func createdReplayBody(id: String) -> Data {
        Data(#"{"request":\#(requestObject(id: id))}"#.utf8)
    }

    private func requestObject(id: String, status: String = "open") -> String {
        """
        {"id":"\(id)","vendor":"Jasper Kane Cafe","food":"Meal","pickupWindowText":"ASAP","mealSwipes":1,"menuPath":"meal-exchange","mealItems":["Meal"],"orderDetails":null,"estimatedDiningDollarsCents":null,"windowStart":null,"windowEnd":null,"status":"\(status)","createdAt":"2026-09-16T17:00:00.000Z","expiresAt":"2026-09-16T20:00:00.000Z"}
        """
    }

    private func errorBody(code: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"backend detail"}}"#.utf8)
    }
}

private extension RequestStore {
    /// The D1 half of removal readiness together with the absence of a D1
    /// block — what a different participant's record must leave intact.
    var hasEstablishedRemovalSafetyForD1Only: Bool {
        hasResolvedPendingCreateStateForRemoval && !hasUnresolvedCreateAmbiguity
    }
}
