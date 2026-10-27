import Foundation
import XCTest
@testable import CommonPlateios

final class MessagingHistoryWireTests: XCTestCase {
    private func decode(_ object: [String: Any]) throws -> ChatMessageHistoryDTO {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ChatMessageHistoryDTO.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func message(_ sequence: Int) -> [String: Any] {
        ["clientMessageId": MsgFixture.identity(sequence % 100_000), "sequence": sequence,
         "sender": "other", "text": "hello", "createdAt": "2026-10-21T12:00:00Z"]
    }

    private func page(_ sequences: [Int], older: Bool = false, head: Int? = nil) -> [String: Any] {
        ["messages": sequences.map(message), "hasOlder": older,
         "nextBefore": sequences.first.map { $0 as Any } ?? NSNull(),
         "newestSequence": head ?? sequences.last ?? 0]
    }

    func testEmptyNullableBoundAndNoncontiguousOlderSnapshot() throws {
        XCTAssertNil(try decode(page([])).nextBefore)
        let decoded = try decode(page([2, 5, 9], older: true, head: 151))
        XCTAssertEqual(decoded.messages.map(\.sequence), [2, 5, 9])
        XCTAssertEqual(decoded.newestSequence, 151)
        XCTAssertTrue(decoded.isValid(before: 10, limit: 50))
        XCTAssertFalse(decoded.isValid(before: nil, limit: 50))
    }

    func testExactShapeRejectsExtraMissingAndWrongTypes() {
        let valid = page([1])
        for key in valid.keys {
            var object = valid
            object.removeValue(forKey: key)
            XCTAssertThrowsError(try decode(object), key)
        }
        var extra = valid
        extra["nextAfter"] = 1
        XCTAssertThrowsError(try decode(extra))
        for (key, value) in [("hasOlder", "true" as Any), ("nextBefore", "1"), ("newestSequence", 1.5), ("messages", NSNull())] {
            var object = valid
            object[key] = value
            XCTAssertThrowsError(try decode(object), key)
        }
    }

    func testRejectsUnsafeNegativeAndContradictoryValues() {
        for key in ["nextBefore", "newestSequence"] {
            for value in [-1, 9_007_199_254_740_992] {
                var object = page([1])
                object[key] = value
                XCTAssertThrowsError(try decode(object), "\(key)/\(value)")
            }
        }
        for object in [
            page([], older: true), page([2, 1]), page([1, 1]), page([3], head: 2),
            page(Array(1...101)), page([9_007_199_254_740_992])
        ] { XCTAssertThrowsError(try decode(object)) }
        var object = page([1, 2])
        object["nextBefore"] = 2
        XCTAssertThrowsError(try decode(object))
        object["nextBefore"] = NSNull()
        XCTAssertThrowsError(try decode(object))
    }

    func testSafeIntegerMaximumAndRequestRelativeBounds() throws {
        let maximum = MessagingWire.maxSequence
        let decoded = try decode(page([maximum]))
        XCTAssertTrue(decoded.isValid(before: nil, limit: 50))
        XCTAssertFalse(decoded.isValid(before: maximum, limit: 50))
        XCTAssertFalse(MsgFixture.historyPage(total: 51).isValid(before: nil, limit: 49))
    }

    func testForwardDTOShapeIsUnchanged() throws {
        let data = try JSONSerialization.data(withJSONObject: ["messages": [message(1)], "nextAfter": 1])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(ChatMessagePageDTO.self, from: data).nextAfter, 1)
        XCTAssertThrowsError(try decoder.decode(ChatMessageHistoryDTO.self, from: data))
    }
}
