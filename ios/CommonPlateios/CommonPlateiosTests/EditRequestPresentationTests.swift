//
//  EditRequestPresentationTests.swift
//  CommonPlateiosTests
//
// Focused W4-R5 coverage of the pure Edit / owner-detail rules: the saved
// request as a draft, what counts as a change, which timing selections the
// original-creation-day horizon allows, what is sent, and which approved
// sentence each outcome earns. Includes exact-copy pins for every sentence
// Faith approved on 2026-10-18.
import Foundation
import XCTest
@testable import CommonPlateios

final class EditRequestPresentationTests: XCTestCase {
    private typealias P = EditRequestPresentation
    private let calendar = NYUCampusTime.calendar

    // The request was created at 2:00 PM campus time on 2026-10-14; its latest
    // permitted new start is 11:30 PM that same day.
    private lazy var created = date(2026, 10, 14, 14, 0)
    private lazy var latest = date(2026, 10, 14, 23, 30)

    // MARK: - Approved copy, verbatim

    func testApprovedCopyIsExact() {
        XCTAssertEqual(P.conflictMessage, "This request changed while you were editing. Your changes weren’t saved.")
        XCTAssertEqual(P.unconfirmedEditMessage, "Something went wrong. We couldn’t confirm your changes.")
        XCTAssertEqual(P.unconfirmedWithdrawMessage, "Something went wrong. We couldn’t confirm your withdrawal.")
        XCTAssertEqual(P.saveFailedMessage, "Couldn’t save your changes. Please try again.")
        XCTAssertEqual(P.withdrawFailedMessage, "Couldn’t withdraw this request. Please try again.")
        XCTAssertEqual(P.horizonTonightMessage, "Start by 11:30 PM tonight.")
        XCTAssertEqual(P.horizonPassedMessage, "The 11:30 PM cutoff has passed. The time can’t be changed.")
        XCTAssertEqual(P.reservedEditMessage, "A helper reserved this request. Your changes weren’t saved.")
        XCTAssertEqual(P.updatedSinceNotificationNotice, "This request was updated. You’re viewing the latest details.")
        XCTAssertEqual(RequestTextModeration.noticeCopy, "Keep request details respectful and food-related.")
    }

    // MARK: - Draft

    func testTheDraftIsTheConfirmedSavedRequest() {
        let owner = ownerRequest(
            items: [MealItem(name: "Chicken bowl", details: "no onions"), MealItem(name: "Salad")],
            cents: 650
        )

        let draft = P.draft(from: owner)

        XCTAssertEqual(draft.selectedDiningSpot?.name, "Jasper Kane Cafe")
        XCTAssertEqual(draft.menuPath, .mealExchange)
        XCTAssertEqual(draft.mealSwipes, 2)
        XCTAssertEqual(draft.activeMealEntries.map(\.name), ["Chicken bowl", "Salad"])
        XCTAssertEqual(draft.activeMealEntries.first?.details, "no onions")
        XCTAssertEqual(draft.diningDollars, .cents(650))
        XCTAssertEqual(draft.timing, .asap)
    }

    func testADiningDollarsRequestRestoresOnlyItsOwnBranch() {
        let owner = ownerRequest(
            menuPath: .diningDollars,
            swipes: 0,
            items: [],
            orderDetails: "A latte",
            cents: 450
        )

        let draft = P.draft(from: owner)

        XCTAssertEqual(draft.menuPath, .diningDollars)
        XCTAssertEqual(draft.orderDetails, "A latte")
        XCTAssertEqual(draft.diningDollars, .cents(450))
        XCTAssertEqual(draft.mealExchangeDiningDollarsText, "")
        XCTAssertEqual(draft.activeMealSwipes, 0)
    }

    // MARK: - Timing: unchanged is never recalculated or validated

    func testAnOrdinaryEditLeavesTimingUnchangedForAsapAndForLater() {
        let asap = ownerRequest()
        XCTAssertEqual(P.timingChange(draft: P.draft(from: asap), original: asap).timing, .unchanged)

        let later = ownerRequest(windowStart: date(2026, 10, 14, 19, 0))
        XCTAssertEqual(P.timingChange(draft: P.draft(from: later), original: later).timing, .unchanged)
    }

    func testOnlyAnExplicitSelectionIsATimingChange() {
        let asap = ownerRequest()
        var toLater = P.draft(from: asap)
        toLater.timing = .later
        toLater.preferredPickupTime = date(2026, 10, 14, 20, 0)
        let change = P.timingChange(draft: toLater, original: asap)
        XCTAssertEqual(change.timing, .scheduled)
        XCTAssertEqual(change.windowStart, date(2026, 10, 14, 20, 0))

        let later = ownerRequest(windowStart: date(2026, 10, 14, 19, 0))
        var toAsap = P.draft(from: later)
        toAsap.timing = .asap
        XCTAssertEqual(P.timingChange(draft: toAsap, original: later).timing, .asap)

        var retimed = P.draft(from: later)
        retimed.preferredPickupTime = date(2026, 10, 14, 21, 0)
        XCTAssertEqual(P.timingChange(draft: retimed, original: later).timing, .scheduled)
    }

    func testAnUnchangedTimingIsNotHeldToTheHorizonEvenAfterItHasPassed() throws {
        // Long after the creation day: the saved Later start (7 PM that day) is
        // far in the past and the horizon is gone. A meal-detail edit must still
        // go through, sending no timing at all.
        let later = ownerRequest(windowStart: date(2026, 10, 14, 19, 0))
        var draft = P.draft(from: later)
        draft.mealEntries[0].name = "Edited bowl"
        let afterHorizon = date(2026, 10, 16, 9, 0)

        let payload = try P.makePayload(draft: draft, owner: later, now: afterHorizon)

        XCTAssertEqual(payload.timing, .unchanged)
        XCTAssertNil(payload.windowStart)
        XCTAssertEqual(payload.mealItems.first?.name, "Edited bowl")
        XCTAssertEqual(payload.expectedContentRevision, 3)
    }

    // MARK: - Horizon (new selections only)

    func testHorizonIsTheBackendStatedLatestStartAndKnowsWhetherTonightIsAccurate() {
        let owner = ownerRequest()
        let sameDay = P.horizon(owner: owner, now: date(2026, 10, 14, 15, 0))
        XCTAssertTrue(sameDay.canSchedule)
        XCTAssertTrue(sameDay.creationDayIsToday)
        XCTAssertEqual(sameDay.latestStart, latest)

        let lateTonight = P.horizon(owner: owner, now: date(2026, 10, 14, 23, 45))
        XCTAssertFalse(lateTonight.canSchedule, "after 11:30 PM no start remains")
        XCTAssertTrue(lateTonight.creationDayIsToday)

        let nextDay = P.horizon(owner: owner, now: date(2026, 10, 15, 8, 0))
        XCTAssertFalse(nextDay.canSchedule)
        XCTAssertFalse(nextDay.creationDayIsToday)
    }

    func testTonightIsUsedOnlyWhileItIsAccurate() {
        let owner = ownerRequest()
        XCTAssertEqual(
            P.horizonMessage(horizon: P.horizon(owner: owner, now: date(2026, 10, 14, 15, 0))),
            P.horizonTonightMessage
        )
        XCTAssertEqual(
            P.horizonMessage(horizon: P.horizon(owner: owner, now: date(2026, 10, 14, 23, 50))),
            P.horizonPassedMessage
        )
        XCTAssertEqual(
            P.horizonMessage(horizon: P.horizon(owner: owner, now: date(2026, 10, 15, 8, 0))),
            P.horizonPassedMessage
        )
    }

    func testANewStartMustBeBetweenNowAndTheHorizon() throws {
        let owner = ownerRequest()
        let now = date(2026, 10, 14, 15, 0)
        let horizon = P.horizon(owner: owner, now: now)
        XCTAssertTrue(P.isSelectableStart(date(2026, 10, 14, 15, 0), now: now, horizon: horizon))
        XCTAssertTrue(P.isSelectableStart(latest, now: now, horizon: horizon), "11:30 PM exactly is allowed")
        XCTAssertFalse(P.isSelectableStart(latest.addingTimeInterval(60), now: now, horizon: horizon))
        XCTAssertFalse(P.isSelectableStart(now.addingTimeInterval(-60), now: now, horizon: horizon))

        var draft = P.draft(from: owner)
        draft.timing = .later
        draft.preferredPickupTime = latest.addingTimeInterval(60)
        XCTAssertThrowsError(try P.makePayload(draft: draft, owner: owner, now: now)) {
            XCTAssertEqual($0 as? P.PayloadError, .unusableTiming)
        }
        draft.preferredPickupTime = latest
        let payload = try P.makePayload(draft: draft, owner: owner, now: now)
        XCTAssertEqual(payload.timing, .scheduled)
        XCTAssertEqual(payload.windowStart, latest)
    }

    // MARK: - Changes

    func testNothingChangedMeansNoSave() {
        let owner = ownerRequest(items: [MealItem(name: "Chicken bowl"), MealItem(name: "Salad")])
        let draft = P.draft(from: owner)
        XCTAssertFalse(P.hasChanges(draft: draft, owner: owner, now: created))
    }

    func testRealChangesAreDetectedAndHiddenEntriesAreNot() {
        let owner = ownerRequest(items: [MealItem(name: "Chicken bowl"), MealItem(name: "Salad")])
        var edited = P.draft(from: owner)
        edited.mealEntries[1].name = "Soup"
        XCTAssertTrue(P.hasChanges(draft: edited, owner: owner, now: created))

        var hiddenOnly = P.draft(from: owner)
        hiddenOnly.mealEntries[4].name = "never submitted"
        XCTAssertFalse(P.hasChanges(draft: hiddenOnly, owner: owner, now: created))

        var timing = P.draft(from: owner)
        timing.timing = .later
        XCTAssertTrue(P.hasChanges(draft: timing, owner: owner, now: created))
    }

    // MARK: - Payload

    func testThePayloadCarriesTheStructuredContentAndTheRevisionItWasReadAt() throws {
        let owner = ownerRequest(items: [MealItem(name: "Chicken bowl"), MealItem(name: "Salad")], cents: 650)
        var draft = P.draft(from: owner)
        draft.mealEntries[0].name = "  Edited  "

        let payload = try P.makePayload(draft: draft, owner: owner, now: created)

        XCTAssertEqual(payload.vendor, "Jasper Kane Cafe")
        XCTAssertEqual(payload.menuPath, .mealExchange)
        XCTAssertEqual(payload.mealSwipes, 2)
        XCTAssertEqual(payload.mealItems.map(\.name), ["Edited", "Salad"])
        XCTAssertNil(payload.orderDetails)
        XCTAssertEqual(payload.estimatedDiningDollarsCents, 650)
        XCTAssertEqual(payload.expectedContentRevision, 3)
    }

    func testALegacyRequestWithNoRevisionCanNeverBeSent() {
        let owner = ownerRequest(revision: nil)
        XCTAssertThrowsError(try P.makePayload(draft: P.draft(from: owner), owner: owner, now: created))
    }

    func testAnInvalidFieldIsRefusedLocallyAndNothingIsBuilt() {
        let owner = ownerRequest()
        var draft = P.draft(from: owner)
        draft.mealEntries[0].name = "   "
        XCTAssertThrowsError(try P.makePayload(draft: draft, owner: owner, now: created))
    }

    // MARK: - Save outcomes

    func testEveryServerRefusalMapsToItsOneApprovedOutcome() {
        let owner = ownerRequest()
        let now = date(2026, 10, 14, 15, 0)
        func outcome(_ code: String) -> P.SaveOutcome {
            P.saveOutcome(
                for: RequestServiceError.serverError(code: code, message: "x"),
                unresolved: nil,
                owner: owner,
                now: now
            )
        }
        XCTAssertEqual(outcome(RequestUpdateErrorCode.revisionConflict), .conflict)
        XCTAssertEqual(outcome(RequestUpdateErrorCode.requestReserved), .reserved)
        XCTAssertEqual(outcome(RequestUpdateErrorCode.requestAlreadyPlaced), .reserved)
        XCTAssertEqual(outcome(RequestUpdateErrorCode.horizonExceeded), .horizon(tonight: true))
        XCTAssertEqual(outcome(RequestUpdateErrorCode.requestWithdrawn), .withdrawn)
        XCTAssertEqual(outcome(RequestUpdateErrorCode.requestExpired), .expired)
        XCTAssertEqual(outcome(RequestUpdateErrorCode.invalidVendor), .saveFailed)
        XCTAssertEqual(outcome(RequestUpdateErrorCode.notEditable), .saveFailed)
        XCTAssertEqual(
            P.saveOutcome(
                for: RequestServiceError.serverError(code: RequestOperationErrorCode.textNotAllowed, message: "x"),
                unresolved: nil,
                owner: owner,
                now: now
            ),
            .textNotAllowed
        )
    }

    func testTonightIsNotUsedForAHorizonRefusalOnALaterDay() {
        let outcome = P.saveOutcome(
            for: RequestServiceError.serverError(code: RequestUpdateErrorCode.horizonExceeded, message: "x"),
            unresolved: nil,
            owner: ownerRequest(),
            now: date(2026, 10, 15, 9, 0)
        )
        XCTAssertEqual(outcome, .horizon(tonight: false))
        XCTAssertEqual(P.message(for: outcome), P.horizonPassedMessage)
    }

    func testAnUnknownOutcomeIsNeverWordedAsASuccessOrAFailure() {
        let owner = ownerRequest()
        let unknown = P.saveOutcome(
            for: RequestServiceError.ambiguousUpdateOutcome(underlying: URLError(.timedOut)),
            unresolved: nil,
            owner: owner,
            now: created
        )
        XCTAssertEqual(unknown, .unconfirmedEdit)
        XCTAssertEqual(P.message(for: unknown), P.unconfirmedEditMessage)
        XCTAssertEqual(P.statusKind(for: unknown), .uncertain, "calm and distinct from an error")
        XCTAssertNotEqual(P.statusKind(for: .saveFailed), .uncertain)
    }

    func testAnUnconfirmedWithdrawalBlockingASaveIsNamedAsTheWithdrawal() {
        let withdrawal = PendingRequestUpdate(
            operationId: "op",
            kind: .withdraw,
            requestID: "r1",
            participantIdentifier: "64c0000000000000000000a1",
            operationLedger: nil,
            editPayload: nil
        )
        let outcome = P.saveOutcome(
            for: RequestServiceError.unresolvedUpdate,
            unresolved: withdrawal,
            owner: ownerRequest(),
            now: created
        )
        XCTAssertEqual(outcome, .unconfirmedWithdraw)
        XCTAssertEqual(P.message(for: outcome), P.unconfirmedWithdrawMessage)
    }

    func testPreSendFailuresAreDefinitiveSaveFailures() {
        for error: Error in [
            RequestServiceError.transport(underlying: URLError(.notConnectedToInternet)),
            RequestServiceError.durablePersistenceFailed,
            RequestServiceError.participantAuthorityRequired,
        ] {
            XCTAssertEqual(
                P.saveOutcome(for: error, unresolved: nil, owner: ownerRequest(), now: created),
                .saveFailed
            )
        }
    }

    func testVerifiedGoneRequestsLeaveTheScreenInsteadOfShowingAMessage() {
        XCTAssertNil(P.message(for: P.SaveOutcome.withdrawn))
        XCTAssertNil(P.message(for: P.SaveOutcome.expired))
    }

    // MARK: - Withdraw outcomes

    func testWithdrawOutcomesUseTheApprovedWording() {
        func outcome(_ error: Error, unresolved: PendingRequestUpdate? = nil) -> P.WithdrawOutcome {
            P.withdrawOutcome(for: error, unresolved: unresolved)
        }
        XCTAssertEqual(
            outcome(RequestServiceError.serverError(code: RequestUpdateErrorCode.requestReserved, message: "x")),
            .reserved
        )
        XCTAssertEqual(
            P.message(for: P.WithdrawOutcome.reserved),
            "A helper has reserved this request. It wasn’t withdrawn."
        )
        XCTAssertEqual(
            P.message(for: outcome(RequestServiceError.transport(underlying: URLError(.badURL)))),
            P.withdrawFailedMessage
        )
        XCTAssertEqual(
            P.message(for: outcome(RequestServiceError.ambiguousUpdateOutcome(underlying: URLError(.timedOut)))),
            P.unconfirmedWithdrawMessage
        )
        XCTAssertNil(P.message(for: outcome(
            RequestServiceError.serverError(code: RequestUpdateErrorCode.requestExpired, message: "x")
        )))
    }

    // MARK: - Owner detail presentation

    func testOwnerDetailUsesOneAuthoritativeStatusLine() {
        // The system clock format separates the time and AM/PM with a narrow
        // no-break space; compare on ordinary spaces.
        func plain(_ text: String) -> String {
            text.replacingOccurrences(of: "\u{202F}", with: " ")
        }
        let available = ownerRequest(phase: .available)
        XCTAssertEqual(plain(OwnerRequestDetailView.statusLine(for: available)), "Available to helpers until 5:00 PM")
        XCTAssertTrue(OwnerRequestDetailView.showsStatusDot(for: available))

        let availableLater = ownerRequest(phase: .available, windowStart: date(2026, 10, 14, 18, 30))
        XCTAssertEqual(
            plain(OwnerRequestDetailView.statusLine(for: availableLater)),
            "Available to helpers until 9:30 PM",
            "current phase, not the original Later selection, controls the status"
        )

        let helped = ownerRequest(phase: .reserved)
        XCTAssertEqual(OwnerRequestDetailView.statusLine(for: helped), "Being helped")

        let scheduled = ownerRequest(phase: .scheduled, windowStart: date(2026, 10, 14, 18, 30))
        XCTAssertEqual(plain(OwnerRequestDetailView.statusLine(for: scheduled)), "Scheduled for 6:30 PM")
        XCTAssertFalse(OwnerRequestDetailView.showsStatusDot(for: scheduled))
        XCTAssertEqual(OwnerRequestDetailView.statusLine(for: ownerRequest(phase: .scheduled)), "Scheduled")
    }

    func testWithdrawConfirmationCopyIsTheApprovedFigmaCopy() {
        XCTAssertEqual(OwnerRequestDetailView.withdrawConfirmationTitle, "Withdraw this request?")
        XCTAssertEqual(
            OwnerRequestDetailView.withdrawConfirmationMessage,
            "It will no longer be available to helpers. This request will still count toward today’s limit."
        )
        XCTAssertEqual(OwnerRequestDetailView.keepRequestTitle, "Keep request")
        XCTAssertEqual(OwnerRequestDetailView.withdrawLinkTitle, "Withdraw request")
        XCTAssertEqual(P.editDisabledWhileHelpedNote, "You can’t edit while someone is helping.")
    }

    func testAnExplicitAsapChangeIsHeldToTheHorizonLikeAScheduledStart() throws {
        let later = ownerRequest(windowStart: date(2026, 10, 14, 19, 0))
        var draft = P.draft(from: later)
        draft.timing = .asap

        // Creation day, before the horizon: Later -> ASAP is a valid new selection.
        let before = try P.makePayload(draft: draft, owner: later, now: date(2026, 10, 14, 15, 0))
        XCTAssertEqual(before.timing, .asap)

        // After the horizon the same explicit change is unusable (the backend
        // refuses it with the horizon code); an ASAP request left as ASAP is
        // unchanged and never held to it.
        XCTAssertThrowsError(try P.makePayload(draft: draft, owner: later, now: date(2026, 10, 15, 9, 0))) {
            XCTAssertEqual($0 as? P.PayloadError, .unusableTiming)
        }
        let asap = ownerRequest()
        let unchanged = try P.makePayload(draft: P.draft(from: asap), owner: asap, now: date(2026, 10, 15, 9, 0))
        XCTAssertEqual(unchanged.timing, .unchanged)
    }

    func testAReplayWhoseOperationHasExpiredIsPresentedAsNoLongerOngoing() {
        let error = RequestServiceError.serverError(code: RequestUpdateErrorCode.operationExpired, message: "x")
        XCTAssertEqual(
            P.saveOutcome(for: error, unresolved: nil, owner: ownerRequest(), now: date(2026, 10, 14, 15, 0)),
            .expired
        )
        XCTAssertEqual(P.withdrawOutcome(for: error, unresolved: nil), .expired)
    }

    // MARK: - Fixtures

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private func ownerRequest(
        menuPath: RequestMenuPath = .mealExchange,
        swipes: Int = 2,
        items: [MealItem] = [MealItem(name: "Chicken bowl"), MealItem(name: "Salad")],
        orderDetails: String? = nil,
        cents: Int? = nil,
        phase: OwnerRequestPhase = .available,
        windowStart: Date? = nil,
        revision: Int? = 3
    ) -> OwnerRequest {
        let request = FoodRequest(
            id: "r1",
            diningSpot: DiningSpot(name: "Jasper Kane Cafe", address: nil),
            foodDescription: "Chicken bowl; Salad",
            pickupWindowText: windowStart == nil ? "ASAP" : "Oct 14, 6:30 PM – 9:30 PM",
            mealSwipes: swipes,
            resource: RequestResource(
                menuPath: menuPath,
                mealItems: items,
                orderDetails: orderDetails,
                estimatedDiningDollarsCents: cents
            ),
            windowStart: windowStart,
            windowEnd: windowStart.map { $0.addingTimeInterval(3 * 3600) },
            createdAt: created,
            expiresAt: windowStart.map { $0.addingTimeInterval(3 * 3600) }
                ?? created.addingTimeInterval(3 * 3600),
            status: phase == .reserved ? .claimed : .open,
            ownership: .own
        )
        return OwnerRequest(
            request: request,
            phase: phase,
            contentRevision: revision,
            canEdit: revision != nil && phase != .reserved,
            canWithdraw: phase != .reserved,
            latestScheduledStart: latest
        )
    }
}
