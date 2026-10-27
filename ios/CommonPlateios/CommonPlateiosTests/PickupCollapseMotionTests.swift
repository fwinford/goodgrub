import XCTest
@testable import CommonPlateios

/// Faith-selected requester pickup collapse (Figma `1603:7208`). Presentation
/// only: these pin the choreography constants and that the collapse and its one
/// success haptic are armed solely by the store's confirmed-pickup flag, never
/// by a card merely disappearing.
final class PickupCollapseMotionTests: XCTestCase {
    func testChoreographyMatchesTheSelectedFigmaTimeline() {
        XCTAssertEqual(PickupCollapseMotion.rise, 10)
        XCTAssertEqual(PickupCollapseMotion.popSettle, .milliseconds(300))
        XCTAssertEqual(PickupCollapseMotion.noticeDelay, .milliseconds(250))
    }

    func testCollapseAndHapticAreArmedOnlyByTheConfirmedFlag() throws {
        let home = try source("Views/HomeExchangeView.swift")
        // One for the requester collapse, one for the helper acknowledgement.
        XCTAssertEqual(occurrences(of: "CommonPlateHaptics.success()", in: home), 2)
        // The only trigger is the notice flag turning on.
        XCTAssertTrue(home.contains("guard noticeOn, !lastSeenPickupNotice else { return }"))
        // A held card only exists for a placed request the confirmation retired.
        XCTAssertTrue(home.contains("$0.request.status == .placed && !liveIDs.contains($0.request.id)"))
        // The haptic is behind the presented-Home and not-cancelled guard.
        XCTAssertTrue(home.contains("guard !Task.isCancelled, isHomePresented else { return }"))
    }

    func testReduceMotionKeepsTheConfirmationAndSkipsMotion() throws {
        let home = try source("Views/HomeExchangeView.swift")
        XCTAssertTrue(home.contains("withAnimation(reduceMotion ? nil : PickupCollapseMotion.exit)"))
        XCTAssertTrue(home.contains("withAnimation(reduceMotion ? nil : PickupCollapseMotion.notice)"))
        XCTAssertTrue(home.contains("? .identity"))
    }

    func testStoreStillOnlyRaisesTheNoticeFromConfirmedPaths() throws {
        let store = try source("Stores/RequestStore.swift")
        XCTAssertEqual(occurrences(of: "hasPickupConfirmationNotice = true", in: store), 1)
        let retire = try XCTUnwrap(store.range(of: "private func retireMissingPlacedOrder"))
        let tail = store[retire.lowerBound...].prefix(260)
        XCTAssertFalse(tail.contains("hasPickupConfirmationNotice = true"), "not-found is never a confirmation")
    }

    func testHelperAcknowledgementComesOnlyFromTheAuthoritativeSignal() throws {
        let waiting = try source("Views/HelperWaitingDetailView.swift")
        XCTAssertFalse(waiting.contains("Thanks for helping!"))
        let store = try source("Stores/RequestStore.swift")
        // The notice id is only ever set from the server's confirmed ids in
        // applyHelperPickupConfirmations, never from a card leaving the set.
        XCTAssertEqual(occurrences(of: "helperPickupNoticeRequestID = requestIDs", in: store), 1)
        XCTAssertTrue(store.contains("func applyHelperPickupConfirmations"))
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }
}
