//
//  ParticipantBlockEntryTests.swift
//  CommonPlateiosTests
//
// W4-U1.3 final READY contract (2026-10-14, contextual-by-phase Block entry).
// Unit and source-inspection proof of copy, availability predicates, the Home
// destination, and the restricted Helping composition. This target has no UI
// test host for these SwiftUI surfaces: presentation behavior is verified here
// by predicates and source inspection, not by a device run.
import Foundation
import XCTest
@testable import CommonPlateios

final class ParticipantBlockEntryTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
        return try String(
            contentsOf: root.appendingPathComponent(relative), encoding: .utf8
        )
    }

    // MARK: - Exact copy

    func testNormalConfirmationCopyIsExact() {
        XCTAssertEqual(ParticipantBlockCopy.blockActionTitle, "Block this student")
        XCTAssertEqual(ParticipantBlockCopy.blockConfirmationTitle, "Block this student?")
        XCTAssertEqual(
            ParticipantBlockCopy.blockConfirmationMessage,
            "You won’t see each other’s future requests, and neither of you will be able to start helping the other."
        )
        XCTAssertEqual(ParticipantBlockCopy.blockConfirmButtonTitle, "Block student")
        XCTAssertEqual(ParticipantBlockCopy.cancelTitle, "Cancel")
    }

    func testActiveReservationCopyIsExactAndNeutral() {
        XCTAssertEqual(
            ParticipantBlockCopy.externalOrderQuestionTitle,
            "Have you already placed the Grubhub order?"
        )
        XCTAssertEqual(ParticipantBlockCopy.externalOrderYesTitle, "Yes, already placed")
        XCTAssertEqual(ParticipantBlockCopy.externalOrderNoTitle, "No, not yet")
        XCTAssertEqual(
            ParticipantBlockCopy.messageNotSharedWarning,
            "Your message won’t be shared."
        )
        XCTAssertEqual(ParticipantBlockCopy.blockActivePill, "BLOCK ACTIVE")
        XCTAssertEqual(
            ParticipantBlockCopy.blockActiveSupporting,
            "You can continue or stop helping."
        )
        XCTAssertEqual(
            ParticipantBlockCopy.directContactUnavailableNotice,
            "Direct contact is unavailable. You can still finish this order."
        )
        XCTAssertFalse(
            ParticipantBlockCopy.directContactUnavailableNotice.contains("block")
        )
    }

    // MARK: - Message warning

    func testMessageWarningAppearsOnlyForAnEnteredDraft() {
        XCTAssertNil(ParticipantBlockAvailability.messageWarning(forDraft: ""))
        XCTAssertNil(ParticipantBlockAvailability.messageWarning(forDraft: "  \n "))
        XCTAssertEqual(
            ParticipantBlockAvailability.messageWarning(forDraft: "Meet at the door"),
            "Your message won’t be shared."
        )
    }

    func testTheModalShowsTheWarningOnceFromTheLiveDraftAndNothingElse() throws {
        let views = try source("Views/ParticipantBlockViews.swift")
        // One message slot, fed only by the host's live draft value.
        XCTAssertEqual(
            views.components(separatedBy: "messageWarning(forDraft: draftMessage)").count - 1,
            1
        )
        XCTAssertTrue(views.contains("let draftMessage: String"))
        // The draft is not persisted or broadened for Block.
        let fulfill = try source("Views/FulfillRequestView.swift")
        XCTAssertTrue(fulfill.contains("draftMessage: draft.contactMessage"))
        let store = try source("Stores/RequestStore.swift")
        XCTAssertFalse(store.contains("blockDraftMessage"))
    }

    // MARK: - Entry predicates

    func testHelpingMenuAppearsOnlyWhileHeldAndBeforeTheBlockIsActive() {
        XCTAssertTrue(ParticipantBlockAvailability.helpingOffersBlock(
            canBlockHelpedRequester: true, blockIsActive: false
        ))
        XCTAssertFalse(ParticipantBlockAvailability.helpingOffersBlock(
            canBlockHelpedRequester: false, blockIsActive: false
        ))
        XCTAssertFalse(
            ParticipantBlockAvailability.helpingOffersBlock(
                canBlockHelpedRequester: true, blockIsActive: true
            ),
            "once the Block is active the menu has no remaining action"
        )
    }

    func testRequestDetailExcludesAHeldReservationAndHasNoInlineRowOrViewRequest() throws {
        XCTAssertFalse(ParticipantBlockAvailability.requestDetailOffersBlock(
            ownership: .notOwn, hasVerifiedIdentity: true, holdsReservationForRequest: true
        ))
        XCTAssertTrue(ParticipantBlockAvailability.requestDetailOffersBlock(
            ownership: .notOwn, hasVerifiedIdentity: true, holdsReservationForRequest: false
        ))

        let detail = try source("Views/RequestDetailView.swift")
        XCTAssertTrue(detail.contains("RequestDetailBlockMenu("))
        XCTAssertFalse(detail.contains("RequestDetailBlockControl"))
        XCTAssertFalse(detail.contains("View request"))

        let views = try source("Views/ParticipantBlockViews.swift")
        XCTAssertFalse(views.contains("View request"))
        XCTAssertFalse(views.contains("RequestDetailBlockControl"))
        XCTAssertFalse(views.contains("HelpingBlockControl"))
        // Both entries are navigation-bar contextual menus.
        XCTAssertEqual(views.components(separatedBy: ".topBarTrailing").count - 1, 2)
        XCTAssertEqual(views.components(separatedBy: "Menu {").count - 1, 2)
    }

    func testNoHeldRequestRouteWasAdded() throws {
        let route = try source("Navigation/AppRoute.swift")
        XCTAssertFalse(route.contains("heldRequestDetail"))
        XCTAssertFalse(route.contains("viewRequest"))
    }

    // MARK: - Destination

    func testBlockSuccessDestinationIsHomeNotActiveRequests() {
        let request = FoodRequest.fixtureForBlockEntry()
        let path: [AppRoute] = [.requestDetail(request)]
        XCTAssertEqual(AppRoute.afterParticipantBlock(from: path), [])
    }

    func testNoPathReleaseAndNormalBlockBothResetToHome() throws {
        let detail = try source("Views/RequestDetailView.swift")
        XCTAssertTrue(detail.contains("path = AppRoute.afterParticipantBlock(from: path)"))
        let fulfill = try source("Views/FulfillRequestView.swift")
        XCTAssertTrue(fulfill.contains("path = AppRoute.afterParticipantBlock(from: path)"))
        let views = try source("Views/ParticipantBlockViews.swift")
        XCTAssertTrue(views.contains("onBlockedAndReleased()"))
    }

    // MARK: - Restricted Helping (Yes)

    func testRestrictedHelpingKeepsExtensionAndStopAndRemovesOnlyContact() throws {
        let fulfill = try source("Views/FulfillRequestView.swift")
        // Extension and Stop helping are one row, present in the restricted
        // state exactly as in the unrestricted one: not gated on the Block.
        XCTAssertFalse(fulfill.contains("if !isBlockActive {"))
        let controls = try XCTUnwrap(fulfill.range(of: "reservationControls(claim: claim)\n"))
        let section = try XCTUnwrap(fulfill.range(of: "placeOrderSection(claim: claim)\n"))
        XCTAssertLessThan(controls.lowerBound, section.lowerBound)
        XCTAssertFalse(
            fulfill[..<controls.lowerBound].suffix(160).contains("isBlockActive")
        )
        // The Message field stays hidden when contact is suppressed.
        XCTAssertTrue(fulfill.contains("if !store.contactSuppressedRequestIDs.contains(request.id)"))
        // Notice sits directly under the `After you order` heading.
        let heading = try XCTUnwrap(fulfill.range(of: "Text(Self.afterYouOrderHeading)"))
        let notice = try XCTUnwrap(fulfill.range(of: "blockActiveStatus\n                        .padding(.top, 8)"))
        // The pill and its supporting line only when this helper's own Block is
        // known; otherwise the neutral notice.
        XCTAssertTrue(fulfill.contains("store.callerBlockedRequestIDs.contains(request.id)"))
        XCTAssertTrue(fulfill.contains("ParticipantBlockCopy.directContactUnavailableNotice"))
        let fields = try XCTUnwrap(fulfill.range(of: "fulfillmentFields\n                    .padding(.top, 16)"))
        XCTAssertLessThan(heading.lowerBound, notice.lowerBound)
        XCTAssertLessThan(notice.lowerBound, fields.lowerBound)
        // Completion fields and Finish helping remain.
        for kept in ["finishHelpingBar", "fulfillment-eta", "orderNumberLabel", "placeOrderSection(claim: claim)"] {
            XCTAssertTrue(fulfill.contains(kept), kept)
        }
        // W4-H1a: the placed-order screenshot is required for every new
        // fulfillment, including this restricted state, so the one existing
        // field stays and is NOT gated on the Block. U1.3 itself still adds no
        // chooser of its own: there is exactly one chooser, owned by H1a.
        XCTAssertEqual(fulfill.components(separatedBy: "private var screenshotChooser").count - 1, 1)
        let fieldsBody = try XCTUnwrap(fulfill.range(of: "private var fulfillmentFields: some View {"))
        let screenshotField = try XCTUnwrap(fulfill.range(of: "placedOrderScreenshotField\n"))
        let messageGate = try XCTUnwrap(fulfill.range(of: "if !store.contactSuppressedRequestIDs.contains(request.id)"))
        XCTAssertLessThan(fieldsBody.lowerBound, screenshotField.lowerBound)
        XCTAssertLessThan(screenshotField.lowerBound, messageGate.lowerBound)
    }

    // MARK: - Blocked Students

    func testBlockedStudentRowsRenderContextOnlyWithDirectUnblock() throws {
        let views = try source("Views/ParticipantBlockViews.swift")
        XCTAssertFalse(views.contains("unblockConfirmationTitle"))
        XCTAssertFalse(views.contains("studentPendingUnblock"))
        XCTAssertTrue(views.contains("Task { await store.unblockStudent(id: student.id) }"))
        // Never truncate retained context.
        let rowStart = try XCTUnwrap(views.range(of: "private func row(for student"))
        let row = String(views[rowStart.lowerBound...])
        XCTAssertFalse(row.contains("truncationMode"))
        XCTAssertFalse(row.contains(".minimumScaleFactor"))
        XCTAssertTrue(row.contains("ViewThatFits"))
        XCTAssertTrue(row.contains("removingBlockedStudentIDs.contains(student.id)"))
    }

    func testRoleMetadataIsMutedAndNeverCarriesIdentity() {
        let when = Date(timeIntervalSince1970: 1_791_411_300)
        let student = BlockedStudent(
            id: "b1", role: .requester,
            diningLocation: "A very long dining location name that must wrap across lines",
            interactionAt: when
        )
        XCTAssertEqual(BlockedStudentPresentation.roleTitle(for: student), "REQUESTER")
        XCTAssertTrue(
            BlockedStudentPresentation.singleLine(for: student)
                .hasPrefix("A very long dining location name that must wrap across lines · ")
        )
    }
}

private extension FoodRequest {
    static func fixtureForBlockEntry() -> FoodRequest {
        FoodRequest(
            id: "64c0000000000000000000f1",
            diningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            foodDescription: "Rice bowl",
            pickupWindowText: "ASAP",
            mealSwipes: 1,
            windowStart: nil,
            windowEnd: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 3_600),
            status: .open
        )
    }
}
