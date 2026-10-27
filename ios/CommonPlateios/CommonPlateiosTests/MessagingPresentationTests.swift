import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

/// W4-MSG1 CP3: approved copy, accessibility text, grouping, and the
/// no-persistence/no-logging guard. Hosted interaction proof lives in
/// `MessagingAccessibilityHostedTests`.
@MainActor
final class MessagingPresentationTests: XCTestCase {
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private let locale = Locale(identifier: "en_US_POSIX")

    func testApprovedFailedSheetCopyIsExact() {
        XCTAssertEqual(ConversationCopy.failedSheetTitle, "Message not sent")
        XCTAssertEqual(ConversationCopy.tryAgain, "Try again")
        XCTAssertEqual(ConversationCopy.cancel, "Cancel")
        XCTAssertEqual(ConversationCopy.title, "Chat")
        XCTAssertEqual(ConversationCopy.emptyLine, "For questions or updates about the order.")
        XCTAssertEqual(ConversationCopy.composerPlaceholder, "Message…")
        XCTAssertEqual(ConversationCopy.failureExplanation(.unconfirmed), "You're offline. Reconnect before trying again.")
    }

    func testNoCopyNamesARelationshipStateOrDistinguishesRoles() {
        let all = [
            ConversationCopy.unavailableTitle, ConversationCopy.unavailableDetail, ConversationCopy.authorityRequiredLine,
            ConversationCopy.loading, ConversationCopy.offlineBanner, ConversationCopy.reconnecting, ConversationCopy.openFailed,
            ConversationCopy.reviseMessage, ConversationCopy.sending, ConversationCopy.emptyLine,
            ConversationCopy.failureExplanation(.notDelivered), ConversationCopy.failureExplanation(.unconfirmed),
            ConversationCopy.failureExplanation(.refused(.textNotAllowed)), ConversationCopy.failureExplanation(.refused(.invalidMessage)),
            ConversationCopy.failureExplanation(.refused(.identityConflict)),
        ].joined(separator: " ").lowercased()
        for word in ["block", "report", "release", "replace", "pickup", "picked up", "expire", "moderat", "helper", "requester", "unblock", "delivered", "read receipt", "seen"] {
            XCTAssertFalse(all.contains(word), "copy must not mention \(word)")
        }
    }

    func testBubbleModelsAndAccessibilityLabels() {
        let own = MsgFixture.message(1, sender: .own, text: "hi")
        let other = MsgFixture.message(2, sender: .other, text: "yo")
        let a = ConversationPresentation.bubble(for: own, calendar: utc, locale: locale)
        let b = ConversationPresentation.bubble(for: other, calendar: utc, locale: locale)
        XCTAssertEqual(a.kind, .outgoing)
        XCTAssertEqual(b.kind, .incoming)
        XCTAssertTrue(a.accessibilityLabel.hasPrefix("You, "))
        XCTAssertTrue(a.accessibilityLabel.hasSuffix(": hi"))
        XCTAssertTrue(b.accessibilityLabel.hasPrefix("Other person, "))
        XCTAssertNil(a.accessibilityHint)

        let sending = LocalOutgoingMessage(clientMessageId: MsgFixture.identity(5), conversationId: MsgFixture.conversationId, text: "s", createdAt: MsgFixture.epoch, state: .sending)
        var failed = sending; failed.state = .failed(.unconfirmed)
        XCTAssertEqual(ConversationPresentation.bubble(for: sending).kind, .sending)
        let f = ConversationPresentation.bubble(for: failed)
        XCTAssertEqual(f.kind, .failed(.unconfirmed))
        XCTAssertTrue(f.accessibilityLabel.contains("Delivery unconfirmed"))
        XCTAssertFalse(f.accessibilityLabel.contains("Message not sent"))
        XCTAssertNil(f.accessibilityHint, "the inline indicator owns the retry action")
        failed.state = .failed(.refused(.invalidMessage))
        XCTAssertNil(ConversationPresentation.bubble(for: failed).accessibilityHint)
    }

    func testTimestampGroupingUsesGapsAndSinceTodayLabels() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func msg(_ seq: Int, _ offset: TimeInterval) -> ConversationItem {
            .message(ChatMessage(clientMessageId: MsgFixture.identity(seq), sequence: seq, sender: .other, text: "t", createdAt: base.addingTimeInterval(offset)))
        }
        let rows = ConversationPresentation.rows(for: [msg(1, 0), msg(2, 60), msg(3, 3 * 3600)], now: base, calendar: utc, locale: locale)
        XCTAssertEqual(rows.count, 5)
        guard case .timestamp(_, let first) = rows[0], case .timestamp(_, let second) = rows[3] else { return XCTFail("\(rows)") }
        XCTAssertTrue(first.hasPrefix("Today · "))
        XCTAssertTrue(second.hasPrefix("Today · "))
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(ConversationPresentation.rows(for: [], now: base, calendar: utc, locale: locale).isEmpty)
    }

    func testRowIdentifiersAreStableAndUnique() {
        let items = (1...5).map { ConversationItem.message(MsgFixture.message($0)) }
        let rows = ConversationPresentation.rows(for: items, now: MsgFixture.epoch, calendar: utc, locale: locale)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }

    // MARK: No persistence / logging

    func testMessagingSourcesNeverPersistOrLog() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios/Messaging")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        let forbidden = ["UserDefaults", "FileManager", "NSLog(", "print(", "os_log", "Logger(", "SecItem", "Keychain", "NSUbiquitous", "CoreData", "SwiftData", "@AppStorage", "@SceneStorage", "write(to"]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            scanned += 1
            for token in forbidden { XCTAssertFalse(text.contains(token), "\(url.lastPathComponent) contains \(token)") }
        }
        XCTAssertGreaterThanOrEqual(scanned, 8)
    }

    func testAFullConversationLeavesUserDefaultsUntouched() async {
        let before = UserDefaults.standard.dictionaryRepresentation().filter { !$0.key.hasPrefix("Apple") && !$0.key.hasPrefix("NS") }
            .mapValues { "\($0)" }
        let http = ScriptedHTTP()
        http.readReturning([MsgFixture.message(1)])
        http.enqueueSend { _ in .unknown }
        http.enqueueReconcile { _ in .success(nil) }
        let h = CoordinatorHarness.make(http: http)
        await h.boot()
        h.coordinator.draft = "private"
        h.coordinator.sendDraft()
        await settle()
        h.coordinator.dismiss()
        let after = UserDefaults.standard.dictionaryRepresentation().filter { !$0.key.hasPrefix("Apple") && !$0.key.hasPrefix("NS") }
            .mapValues { "\($0)" }
        XCTAssertEqual(before, after)
    }
}
