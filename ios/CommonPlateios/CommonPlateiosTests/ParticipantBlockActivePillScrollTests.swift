//
//  ParticipantBlockActivePillScrollTests.swift
//  CommonPlateiosTests
//
// W4-U1.3 final Block-active presentation: the caller-known `BLOCK ACTIVE`
// pill and the one-time orientation scroll after a confirmed Yes. Copy is
// asserted exactly; the scroll trigger is proved by source inspection because
// this target has no UI host. No pixel or layout assertions.
import Foundation
import XCTest
@testable import CommonPlateios

final class ParticipantBlockActivePillScrollTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
        return try String(
            contentsOf: root.appendingPathComponent(relative), encoding: .utf8
        )
    }

    func testPillAndSupportingCopyAreExactAndTheOldSentenceIsGone() throws {
        XCTAssertEqual(ParticipantBlockCopy.blockActivePill, "BLOCK ACTIVE")
        XCTAssertEqual(
            ParticipantBlockCopy.blockActiveSupporting,
            "You can continue or stop helping."
        )
        for file in ["Views/ParticipantBlockViews.swift", "Views/FulfillRequestView.swift"] {
            let text = try source(file)
            XCTAssertFalse(text.contains("Your block is active"), file)
            XCTAssertFalse(text.contains("blockActiveNotice"), file)
        }
    }

    func testReconstructedCopyIsUnchanged() {
        XCTAssertEqual(
            ParticipantBlockCopy.directContactUnavailableNotice,
            "Direct contact is unavailable. You can still finish this order."
        )
    }

    func testPillUsesExistingTintWithNoIconOrErrorStyling() throws {
        let view = try source("Views/FulfillRequestView.swift")
        let start = try XCTUnwrap(view.range(of: "private var blockActiveStatus: some View {"))
        let end = try XCTUnwrap(view.range(of: "private var fulfillmentFields: some View {"))
        let span = String(view[start.upperBound..<end.lowerBound])
        XCTAssertTrue(span.contains("ParticipantBlockCopy.blockActivePill"))
        XCTAssertTrue(span.contains("ParticipantBlockCopy.blockActiveSupporting"))
        XCTAssertTrue(span.contains("HelpingPalette.extendTint"))
        XCTAssertTrue(span.contains(".foregroundStyle(.secondary)"))
        for forbidden in ["Image(", "systemName", ".red", "stopText", "Color(red"] {
            XCTAssertFalse(span.contains(forbidden), forbidden)
        }
    }

    func testOnlyAConfirmedYesBumpsTheScrollRequest() throws {
        let view = try source("Views/FulfillRequestView.swift")
        XCTAssertEqual(
            view.components(separatedBy: "blockYesScrollRequest += 1").count - 1, 1
        )
        // The single bump lives in the keep-reservation (Yes) closure only.
        let yes = try XCTUnwrap(view.range(of: "onBlockedKeepingReservation: {"))
        let after = String(view[yes.upperBound...])
        let bump = try XCTUnwrap(after.range(of: "blockYesScrollRequest += 1"))
        let closeOfClosure = try XCTUnwrap(after.range(of: "\n            }\n"))
        XCTAssertLessThan(bump.lowerBound, closeOfClosure.lowerBound)
        let released = try XCTUnwrap(view.range(of: "onBlockedAndReleased: {"))
        let releasedSpan = String(view[released.upperBound..<yes.lowerBound])
        XCTAssertFalse(releasedSpan.contains("blockYesScrollRequest"))

        // The menu calls the Yes closure only for a `.blocked` Yes result.
        let menu = try source("Views/ParticipantBlockViews.swift")
        let yesCall = try XCTUnwrap(menu.range(of: "blockHelpedRequester(externalOrderPlaced: true)"))
        let yesSpan = String(menu[yesCall.upperBound...].prefix(160))
        XCTAssertTrue(yesSpan.contains("if case .blocked = result"))
        XCTAssertTrue(yesSpan.contains("onBlockedKeepingReservation()"))
    }

    func testScrollIsLocalOrientationOnlyAndReconstructionDoesNotDriveIt() throws {
        let view = try source("Views/FulfillRequestView.swift")
        XCTAssertTrue(view.contains("scrollProxy.scrollTo(Self.afterYouOrderScrollID, anchor: .top)"))
        XCTAssertTrue(view.contains(".onChange(of: blockYesScrollRequest)"))
        // Never driven by restricted state, which is what relaunch restores.
        XCTAssertFalse(view.contains(".onChange(of: isBlockActive)"))
        XCTAssertFalse(view.contains("onAppear { blockYesScrollRequest"))
        // The scroll does not touch focus or navigation.
        let start = try XCTUnwrap(view.range(of: ".onChange(of: blockYesScrollRequest)"))
        let span = String(view[start.upperBound...].prefix(260))
        XCTAssertFalse(span.contains("focusedField"))
        XCTAssertFalse(span.contains("path ="))
    }

    func testAddFiveAndStopControlsAreStillComposedWithBlockActive() throws {
        let view = try source("Views/FulfillRequestView.swift")
        XCTAssertTrue(view.contains("reservationControls(claim: claim)"))
        XCTAssertTrue(view.contains("finishHelpingBar"))
    }
}
