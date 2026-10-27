//
//  RequestCreationInstallationCredentialTests.swift
//  CommonPlateiosTests
//
// Focused coverage for Week 3 Day 6 Slice 6E's iOS half: `RequestStore`
// fills in `CreateRequestPayload.installationCredential` from its injected
// provider immediately before sending, `RequestFoodView.makePayload` never
// sets it, and the raw credential travels only in the outgoing POST body —
// never logged, never read back from a response.
import Foundation
import XCTest
@testable import CommonPlateios

/// Its own double, matching the convention in `HelperNotificationRoutingTests`
/// and `RequestFetchingTests`: each test file owns its stubbing state. Unlike
/// those, this one also captures the outgoing request body, since these cases
/// need to inspect exactly what was sent.
final class RequestCreationCredentialURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var stubData: Data = Data()
    private nonisolated(unsafe) static var stubStatusCode = 201
    private nonisolated(unsafe) static var capturedBodies: [Data] = []

    static func reset(statusCode: Int = 201, data: Data) {
        lock.lock()
        stubStatusCode = statusCode
        stubData = data
        capturedBodies.removeAll()
        lock.unlock()
    }

    static var lastCapturedBody: Data? {
        lock.lock()
        defer { lock.unlock() }
        return capturedBodies.last
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if answerOperationLedgerReadIfNeeded() { return }
        // `URLProtocol` hands the body through `httpBodyStream` for POST
        // requests built by `URLSession`, not `httpBody`.
        let body: Data
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            body = data
        } else {
            body = request.httpBody ?? Data()
        }
        Self.lock.lock()
        Self.capturedBodies.append(body)
        let statusCode = Self.stubStatusCode
        let data = Self.stubData
        Self.lock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: statusCode,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class RequestCreationInstallationCredentialTests: XCTestCase {
    private let requestID = "installation-association-request"

    func testCreateRequestSendsTheProvidedInstallationCredential() async throws {
        RequestCreationCredentialURLProtocol.reset(data: detailResponse())
        let store = makeStore(credential: "fixture-installation-credential")

        try await store.createRequest(makePayload())

        let body = try XCTUnwrap(RequestCreationCredentialURLProtocol.lastCapturedBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["installationCredential"] as? String, "fixture-installation-credential")
    }

    func testCreateRequestReadsTheProviderFreshOnEachCall() async throws {
        var currentCredential = "first-credential"
        RequestCreationCredentialURLProtocol.reset(data: detailResponse())
        let store = RequestStore(
            service: makeService(),
            installationCredentialProvider: { currentCredential },
            // W3-I1: a verified participant, unless a case says otherwise.
            participantAuthorityProvider: { "64c0000000000000000000a1.1.test-credential" },
            participantAuthorityRejected: {}
        )

        try await store.createRequest(makePayload())
        let firstBody = try XCTUnwrap(RequestCreationCredentialURLProtocol.lastCapturedBody)
        let firstJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: firstBody) as? [String: Any])
        XCTAssertEqual(firstJSON["installationCredential"] as? String, "first-credential")

        currentCredential = "second-credential"
        RequestCreationCredentialURLProtocol.reset(data: detailResponse(id: "second-request"))
        try await store.createRequest(makePayload())
        let secondBody = try XCTUnwrap(RequestCreationCredentialURLProtocol.lastCapturedBody)
        let secondJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: secondBody) as? [String: Any])
        XCTAssertEqual(secondJSON["installationCredential"] as? String, "second-credential")
    }

    func testTheFormPayloadBuilderNeverSetsTheInstallationCredential() throws {
        // `RequestFoodView.makePayload` builds the payload purely from form
        // fields; the credential is store-owned installation identity, filled
        // in by `RequestStore.createRequest` immediately before sending.
        let payload = try RequestFoodView.makePayload(
            draft: RequestFoodFormDraft(
                selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
                menuPath: .mealExchange,
                timing: .asap,
                preferredPickupTime: Date(timeIntervalSince1970: 0),
                mealSwipes: 2,
                mealEntries: ["Chicken bowl"] + Array(repeating: "filler", count: 2 - 1) + Array(repeating: "", count: RequestFoodFormDraft.maxMealSwipes - 2)
            ),
            now: Date(timeIntervalSince1970: 1_000),
            calendar: Calendar(identifier: .gregorian)
        )

        XCTAssertNil(payload.installationCredential)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        )
        XCTAssertFalse(json.keys.contains("installationCredential"))
    }

    // MARK: - Helpers

    private func makePayload() -> CreateRequestPayload {
        CreateRequestPayload(
            vendor: "Jasper Kane Cafe",
            timing: .asap,
            windowStart: nil,
            menuPath: .mealExchange,
            mealSwipes: 2,
            mealItems: ["Vegetable rice bowl"],
            orderDetails: nil,
            estimatedDiningDollarsCents: nil
        )
    }

    private func makeStore(credential: String) -> RequestStore {
        RequestStore(
            service: makeService(),
            installationCredentialProvider: { credential },
            // W3-I1: a verified participant, so these cases prove the
            // installation credential rather than the participant gate.
            participantAuthorityProvider: { "64c0000000000000000000a1.1.credential" },
            participantAuthorityRejected: {}
        )
    }

    private func makeService() -> RequestService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestCreationCredentialURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return RequestService(client: client)
    }

    private func detailResponse(id: String? = nil) -> Data {
        Data("""
        {
          "request": {
            "id": "\(id ?? requestID)",
            "vendor": "Jasper Kane Cafe",
            "food": "Vegetable rice bowl",
            "pickupWindowText": "ASAP (available for the next 3 hours)",
            "mealSwipes": 2,
            "menuPath": "meal-exchange",
            "mealItems": ["Meal 1", "Meal 2"],
            "orderDetails": null,
            "estimatedDiningDollarsCents": null,
            "windowStart": null,
            "windowEnd": null,
            "status": "open",
            "createdAt": "2026-07-20T18:30:00.000Z",
            "expiresAt": "\(iso8601String(Date().addingTimeInterval(3 * 60 * 60)))"
          }
        }
        """.utf8)
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
