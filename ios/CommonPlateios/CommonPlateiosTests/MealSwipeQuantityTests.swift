//
//  MealSwipeQuantityTests.swift
//  CommonPlateiosTests
//
// Focused coverage for the W3-C1 meal-plan/payment requirement: the bounded
// picker offers exactly 1 through 5, the value round-trips unchanged through
// the create payload and the DTO/domain mapping, and every request this app
// can decode carries one — every shape `POST /api/request` accepts,
// including the legacy web one, now requires it, so a response that omits it
// is a malformed/impossible backend response, not a supported outcome this
// app fabricates a value for.
import Foundation
import XCTest
@testable import CommonPlateios

private final class MealSwipeQuantityURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var stubData: Data = Data()
    private nonisolated(unsafe) static var capturedBodies: [Data] = []

    static func reset(data: Data) {
        lock.lock()
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
        let data = Self.stubData
        Self.lock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 201,
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
final class MealSwipeQuantityTests: XCTestCase {

    // MARK: - Bounded picker / draft

    func testTheDraftOffersExactlyOneThroughFive() {
        XCTAssertEqual(RequestFoodFormDraft.mealSwipeOptions, [1, 2, 3, 4, 5])
    }

    func testANewDraftDefaultsToTheFirstOfferedQuantity() {
        let draft = RequestFoodFormDraft()
        XCTAssertEqual(draft.mealSwipes, RequestFoodFormDraft.mealSwipeOptions.first)
    }

    // MARK: - makePayload carries the exact chosen quantity

    func testMakePayloadCarriesTheExactSelectedQuantityForASAP() throws {
        let payload = try RequestFoodView.makePayload(
            draft: mealExchangeDraft(mealSwipes: 5, timing: .asap),
            now: Date(timeIntervalSince1970: 1_000),
            calendar: Calendar(identifier: .gregorian)
        )

        XCTAssertEqual(payload.mealSwipes, 5)
        // W4-R4: the structured entries travel with the count they describe.
        XCTAssertEqual(payload.mealItems.count, 5)
    }

    func testMakePayloadCarriesTheExactSelectedQuantityForScheduled() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let preferredPickupTime = Date(timeIntervalSince1970: 2_000)
        let payload = try RequestFoodView.makePayload(
            draft: mealExchangeDraft(
                mealSwipes: 3,
                timing: .later,
                preferredPickupTime: preferredPickupTime
            ),
            now: now,
            calendar: Calendar(identifier: .gregorian)
        )

        XCTAssertEqual(payload.mealSwipes, 3)
        XCTAssertEqual(payload.mealItems.count, 3)
    }

    func testEveryPickerOptionEncodesUnchangedInTheOutgoingPayload() throws {
        for quantity in RequestFoodFormDraft.mealSwipeOptions {
            let payload = try RequestFoodView.makePayload(
                draft: mealExchangeDraft(mealSwipes: quantity, timing: .asap),
                now: Date(timeIntervalSince1970: 1_000),
                calendar: Calendar(identifier: .gregorian)
            )
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
            )
            XCTAssertEqual(json["mealSwipes"] as? Int, quantity)
        }
    }

    // MARK: - DTO decoding

    func testTheResponseDTODecodesAPresentQuantity() throws {
        let json = Data("""
        {
          "id": "req-1",
          "vendor": "Jasper Kane Cafe",
          "food": "Rice bowl",
          "pickupWindowText": "ASAP",
          "mealSwipes": 4,
          "menuPath": "meal-exchange",
          "mealItems": ["Meal 1", "Meal 2", "Meal 3", "Meal 4"],
          "orderDetails": null,
          "estimatedDiningDollarsCents": null,
          "windowStart": null,
          "windowEnd": null,
          "status": "open",
          "createdAt": "2026-07-28T16:00:00.000Z",
          "expiresAt": "2026-07-28T19:00:00.000Z"
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dto = try decoder.decode(RequestResponseDTO.self, from: json)
        XCTAssertEqual(dto.mealSwipes, 4)
    }

    /// Every shape `POST /api/request` accepts, including the legacy web one,
    /// has required an integer 1-5 since W3-C1, so a response omitting it is a
    /// malformed/impossible backend response. Decoding must fail loudly
    /// rather than silently substitute `nil` for a field the wire contract no
    /// longer allows to be absent.
    func testTheResponseDTOFailsToDecodeWhenTheQuantityIsMissing() throws {
        let json = Data("""
        {
          "id": "req-2",
          "vendor": "Jasper Kane Cafe",
          "food": "Rice bowl",
          "pickupWindowText": "ASAP",
          "windowStart": null,
          "windowEnd": null,
          "status": "open",
          "createdAt": "2026-07-28T16:00:00.000Z",
          "expiresAt": "2026-07-28T19:00:00.000Z"
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertThrowsError(
            try decoder.decode(RequestResponseDTO.self, from: json)
        ) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    // MARK: - End-to-end: create round-trips the quantity through RequestStore

    /// Round-trips the quantity through the same production
    /// `RequestService.createRequest` the store itself calls, which already
    /// returns the decoded domain `FoodRequest` directly — independent of
    /// `RequestStore`'s own insertion/ownership behavior, which is covered
    /// elsewhere (`RequestCreateDurableOperationTests`,
    /// `RequestOwnershipLifecycleTests`).
    func testCreateRequestRoundTripsTheQuantityIntoTheStoredDomainRequest() async throws {
        MealSwipeQuantityURLProtocol.reset(data: detailResponse(mealSwipes: 2))

        let created = try await makeService().createRequest(makePayload(mealSwipes: 2))

        XCTAssertEqual(created.id, "meal-swipe-quantity-request")
        XCTAssertEqual(created.mealSwipes, 2)

        let sentBody = try XCTUnwrap(MealSwipeQuantityURLProtocol.lastCapturedBody)
        let sentJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sentBody) as? [String: Any]
        )
        XCTAssertEqual(sentJSON["mealSwipes"] as? Int, 2)
    }

    /// A malformed/impossible backend response omitting the now-required
    /// quantity fails to decode. A 201 whose body cannot be decoded is a
    /// genuinely indeterminate outcome (the write may have happened even
    /// though the confirmation could not), so this app's existing ambiguous-
    /// mutation handling — not a fabricated `nil` quantity — is what surfaces
    /// it; no domain request is added to the store either way.
    func testCreateRequestFailsWhenTheBackendResponseOmitsTheQuantity() async throws {
        MealSwipeQuantityURLProtocol.reset(data: detailResponse(mealSwipes: nil))
        let store = makeStore()

        do {
            try await store.createRequest(makePayload(mealSwipes: 1))
            XCTFail("Expected decoding the malformed response to throw")
        } catch RequestServiceError.ambiguousCreateOutcome {
            // Expected: an undecodable 201 body is ambiguous, not a clean
            // failure — the same handling any other undecodable success body
            // already receives.
        }

        XCTAssertNil(
            store.requests.first { $0.id == "meal-swipe-quantity-request" }
        )
    }

    // MARK: - Helpers

    private func makePayload(mealSwipes: Int) -> CreateRequestPayload {
        CreateRequestPayload(
            vendor: "Jasper Kane Cafe",
            timing: .asap,
            windowStart: nil,
            menuPath: .mealExchange,
            mealSwipes: mealSwipes,
            mealItems: (0..<mealSwipes).map { MealItem(name: "Meal \($0 + 1)") },
            orderDetails: nil,
            estimatedDiningDollarsCents: nil
        )
    }

    /// A complete W4-R4 Meal Exchange draft: one filled structured
    /// meal-detail entry per selected swipe, which is what validation now
    /// requires before a payload can be built at all.
    private func mealExchangeDraft(
        mealSwipes: Int,
        timing: RequestTiming,
        preferredPickupTime: Date = Date(timeIntervalSince1970: 0)
    ) -> RequestFoodFormDraft {
        var entries = RequestFoodFormDraft.emptyMealEntries
        for index in 0..<mealSwipes {
            entries[index] = MealItem(name: "Chicken bowl \(index + 1)")
        }
        return RequestFoodFormDraft(
            selectedDiningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            menuPath: .mealExchange,
            timing: timing,
            preferredPickupTime: preferredPickupTime,
            mealSwipes: mealSwipes,
            mealEntries: entries
        )
    }

    private func makeStore() -> RequestStore {
        RequestStore(
            service: makeService(),
            installationCredentialProvider: { "" },
            participantAuthorityProvider: { "64c0000000000000000000a1.1.credential" },
            participantAuthorityRejected: {}
        )
    }

    private func makeService() -> RequestService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MealSwipeQuantityURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: session
        )
        return RequestService(client: client)
    }

    private func detailResponse(mealSwipes: Int?) -> Data {
        let mealSwipesLine = mealSwipes != nil ? "\"mealSwipes\": \(mealSwipes!)," : ""
        return Data("""
        {
          "request": {
            "id": "meal-swipe-quantity-request",
            "vendor": "Jasper Kane Cafe",
            "food": "Vegetable rice bowl",
            "pickupWindowText": "ASAP (available for the next 3 hours)",
            \(mealSwipesLine)
            "menuPath": "meal-exchange",
            "mealItems": ["Vegetable rice bowl"],
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
